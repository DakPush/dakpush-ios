import XCTest

@testable import DakPush

final class DakApiTests: XCTestCase {
    private var server: FakeDak!

    override func setUp() {
        server = FakeDak()
    }

    private func api(timeout: TimeInterval = 5) -> DakApi {
        DakApi(
            baseURL: server.baseURL, appId: server.appId, http: URLSessionHTTP(protocolClasses: [FakeDakProtocol.self]),
            userAgent: "dakpush-ios/0.1.0", timeout: timeout)
    }

    private let state: [String: JSON] = [
        "token": .string(apnsToken()), "token_type": .string("apns"), "platform": .string("ios"),
        "external_id": .null, "tags": .object(["name": .string("রহিম")]),
    ]

    func testRegisterPostsTheStateAndReadsTheSecret() throws {
        let reg = try api().register(state)
        let call = server.calls[0]
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.path, "/v1/apps/\(server.appId)/devices")
        XCTAssertEqual(call.body, state, "nulls and UTF-8 arrive as sent")
        XCTAssertEqual(call.header("User-Agent"), "dakpush-ios/0.1.0")
        XCTAssertEqual(call.header("Content-Type"), "application/json")
        XCTAssertEqual(call.header("Accept"), "application/json")
        XCTAssertNil(call.header("Authorization"))
        XCTAssertEqual(server.device(reg.deviceId)?.secret, reg.deviceSecret)
    }

    func testUpdateIsAPatchWithTheDeviceSecret() throws {
        let reg = try api().register(state)
        try api().update(deviceId: reg.deviceId, secret: reg.deviceSecret, ["subscribed": .bool(false)])
        let call = server.calls[1]
        XCTAssertEqual(call.method, "PATCH")
        XCTAssertEqual(call.path, "/v1/apps/\(server.appId)/devices/\(reg.deviceId)")
        XCTAssertEqual(call.header("Authorization"), "Device \(reg.deviceSecret)")
        XCTAssertEqual(server.device(reg.deviceId)?.fields["subscribed"], .bool(false))
    }

    func testOpensAndReceipts() throws {
        let a = api()
        let reg = try a.register(state)
        try a.opened(deviceId: reg.deviceId, secret: reg.deviceSecret, messageId: "m1", actionId: "accept")
        try a.opened(deviceId: reg.deviceId, secret: reg.deviceSecret, messageId: "m2", actionId: nil)
        try a.delivered(deviceId: reg.deviceId, secret: reg.deviceSecret, messageIds: ["m1", "m2"])
        XCTAssertEqual(server.opens.map(\.id), ["m1", "m2"])
        XCTAssertEqual(server.opens.map(\.action), ["accept", nil])
        XCTAssertEqual(server.calls("POST", "/opened")[1].body, ["message_id": .string("m2")])
        XCTAssertEqual(server.receipts, ["m1", "m2"])
    }

    func testInAppMessagesWithTheirETag() throws {
        server.queue(
            .status(200, body: #"{"messages":[{"id":"x"}]}"#, headers: ["ETag": "\"v1\""]),
            .status(304))
        let a = api()
        let list = try XCTUnwrap(try a.fetchInApp(deviceId: "d1", secret: "s", etag: nil))
        XCTAssertEqual(list.messages.count, 1)
        XCTAssertEqual(list.etag, "\"v1\"")
        XCTAssertNil(try a.fetchInApp(deviceId: "d1", secret: "s", etag: "\"v1\""))
        XCTAssertEqual(server.calls[1].header("If-None-Match"), "\"v1\"")
        XCTAssertEqual(server.calls[1].method, "GET")
    }

    func testDakErrorsCarryTheirCodeAndField() {
        server.queue(server.error(422, "invalid", "tag a is too long", field: "tags"))
        XCTAssertThrowsError(try api().register(state)) { e in
            let error = e as? DakApiError
            XCTAssertEqual(error?.status, 422)
            XCTAssertEqual(error?.code, "invalid")
            XCTAssertEqual(error?.field, "tags")
            XCTAssertEqual(error?.message, "tag a is too long")
            XCTAssertEqual(error?.fromDak, true)
            XCTAssertEqual(error?.isPermanent, true)
        }
    }

    func testWhatIsPermanentAndWhatIsNot() {
        func e(_ status: Int, fromDak: Bool = true) -> DakApiError {
            DakApiError(status: status, code: "x", message: "", fromDak: fromDak)
        }
        XCTAssertTrue(e(403).isPermanent)
        XCTAssertTrue(e(422).isPermanent)
        XCTAssertFalse(e(401).isPermanent)
        XCTAssertTrue(e(401).isUnauthorized)
        XCTAssertFalse(e(408).isPermanent)
        XCTAssertFalse(e(429).isPermanent)
        XCTAssertFalse(e(500).isPermanent)
        XCTAssertFalse(e(403, fromDak: false).isPermanent)
        XCTAssertFalse(e(401, fromDak: false).isUnauthorized)
    }

    func testAnAnswerThatIsNotDaksIsMarkedSo() {
        server.queue(.status(502, body: "<html>bad gateway</html>", headers: ["Content-Type": "text/html", "Retry-After": "30"]))
        XCTAssertThrowsError(try api().register(state)) { e in
            let error = e as? DakApiError
            XCTAssertEqual(error?.code, "http_502")
            XCTAssertEqual(error?.fromDak, false)
            XCTAssertEqual(error?.retryAfter, 30)
        }
    }

    func testAStalledAnswerTimesOutAsAWhole() {
        server.queue(.stall)
        let start = Date()
        XCTAssertThrowsError(try api(timeout: 1).register(state)) { e in
            XCTAssertEqual((e as? URLError)?.code, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testNoAnswerAtAllIsANetworkError() {
        server.queue(.fail(.notConnectedToInternet))
        XCTAssertThrowsError(try api().register(state)) { e in
            XCTAssertEqual((e as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testRedirectsAreNotFollowed() {
        server.queue(.status(307, headers: ["Location": "https://elsewhere.dak.test/v1/apps/x/devices"]))
        XCTAssertThrowsError(try api().register(state)) { e in
            XCTAssertEqual((e as? DakApiError)?.status, 307)
            XCTAssertEqual((e as? DakApiError)?.fromDak, false)
        }
        XCTAssertEqual(server.calls.count, 1)
    }

    func testARegistrationAnswerWithoutTheSecretIsAnError() {
        server.queue(.status(201, body: #"{"device_id":"d1"}"#), .status(201, body: #"{"device_id":"../x","device_secret":"s"}"#))
        XCTAssertThrowsError(try api().register(state)) { XCTAssertTrue($0 is DakBadAnswer) }
        XCTAssertThrowsError(try api().register(state)) { XCTAssertTrue($0 is DakBadAnswer) }
    }

    func testBaseURLsMustBeHttps() {
        XCTAssertEqual(DakApi.checkBaseURL(" https://push.example.com/ "), "https://push.example.com")
        XCTAssertEqual(DakApi.checkBaseURL("https://example.com/dak//"), "https://example.com/dak")
        XCTAssertEqual(DakApi.checkBaseURL("http://localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(DakApi.checkBaseURL("http://127.0.0.1:8090"), "http://127.0.0.1:8090")
        XCTAssertEqual(DakApi.checkBaseURL("http://[::1]:8090"), "http://[::1]:8090")
        XCTAssertNil(DakApi.checkBaseURL("http://push.example.com"))
        XCTAssertNil(DakApi.checkBaseURL("push.example.com"))
        XCTAssertNil(DakApi.checkBaseURL("https://"))
        XCTAssertNil(DakApi.checkBaseURL("https://push.example.com?x=1"))
        XCTAssertNil(DakApi.checkBaseURL("https://push.example.com#x"))
        XCTAssertNil(DakApi.checkBaseURL("https://user@push.example.com"))
        XCTAssertNil(DakApi.checkBaseURL("ftp://push.example.com"))
    }

    func testAppIdsCannotChangeThePath() {
        XCTAssertTrue(DakApi.checkAppId("01a15a03-86ed-7ea0-bf12-c1a457202c12"))
        XCTAssertFalse(DakApi.checkAppId(""))
        XCTAssertFalse(DakApi.checkAppId("../admin"))
        XCTAssertFalse(DakApi.checkAppId("a/b"))
        XCTAssertFalse(DakApi.checkAppId("a?b"))
        XCTAssertFalse(DakApi.checkAppId(String(repeating: "a", count: 65)))
    }

    func testRetryAfterInSecondsOrAsADate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DakApi.parseRetryAfter("120"), 120)
        XCTAssertNil(DakApi.parseRetryAfter("-1"))
        XCTAssertNil(DakApi.parseRetryAfter(""))
        XCTAssertNil(DakApi.parseRetryAfter(nil))
        XCTAssertNil(DakApi.parseRetryAfter("soon"))
        // 1_800_000_000 is Fri, 15 Jan 2027 08:00:00 GMT.
        XCTAssertEqual(DakApi.parseRetryAfter("Fri, 15 Jan 2027 08:01:00 GMT", now: now), 60)
        XCTAssertEqual(DakApi.parseRetryAfter("Fri, 15 Jan 2027 07:00:00 GMT", now: now), 0)
    }
}
