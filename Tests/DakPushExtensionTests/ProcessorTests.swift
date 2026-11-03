@_spi(DakInternal) @testable import DakPushExtension
import UserNotifications
import XCTest

/// Answers *.ext.test requests from a table the test fills.
final class FakeWeb: URLProtocol {
    struct Answer {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Seconds before the body comes.
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private static var answers: [String: Answer] = [:]
    private static var requestsStore: [URLRequest] = []

    static func set(_ path: String, _ answer: Answer) {
        lock.lock()
        answers[path] = answer
        lock.unlock()
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStore
    }

    static func reset() {
        lock.lock()
        answers = [:]
        requestsStore = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".ext.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var cancelled = false

    override func startLoading() {
        Self.lock.lock()
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            copy.httpBody = data
        }
        Self.requestsStore.append(copy)
        let answer = Self.answers[request.url?.path ?? ""]
        Self.lock.unlock()
        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let send = { [weak self] in
            guard let self, !self.cancelled else { return }
            let response = HTTPURLResponse(
                url: self.request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: answer.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if answer.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + answer.delay, execute: send)
        } else {
            send()
        }
    }

    override func stopLoading() { cancelled = true }
}

final class ProcessorTests: XCTestCase {
    private var group: DakAppGroup!
    private var center: FakeCategoryCenter!

    override func setUp() {
        FakeWeb.reset()
        group = testGroup()
        center = FakeCategoryCenter()
    }

    private func request(_ info: [AnyHashable: Any], title: String = "Hi") -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "Body"
        content.userInfo = info
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    /// Processes [req] and returns the content handed back.
    private func process(
        _ req: UNNotificationRequest, group: DakAppGroup?? = nil, timeout: TimeInterval = 10,
        expire: TimeInterval? = nil
    ) -> UNMutableNotificationContent? {
        let p = DakNotificationProcessor(
            group: group ?? self.group, center: center, protocolClasses: [FakeWeb.self], receiptTimeout: 3)
        let done = expectation(description: "content")
        var out: UNMutableNotificationContent?
        var calls = 0
        p.process(req) { c in
            calls += 1
            out = c
            done.fulfill()
        }
        if let expire { DispatchQueue.global().asyncAfter(deadline: .now() + expire) { p.finishNow() } }
        wait(for: [done], timeout: timeout)
        p.finishNow()
        XCTAssertEqual(calls, 1)
        return out
    }

    private func share() {
        group.share(.init(baseURL: "https://dak.ext.test", appId: "app1", deviceId: "dev1", receiptToken: "rt"))
    }

    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    func testTheReceiptGoesWithTheReceiptToken() throws {
        share()
        FakeWeb.set("/v1/apps/app1/devices/dev1/delivered", .init(status: 204))
        _ = process(request(["_dak_id": "m1"]))
        let sent = try XCTUnwrap(FakeWeb.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Receipt rt")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "User-Agent"), "dakpush-ios/0.1.0")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: String], ["message_id": "m1"])
        XCTAssertTrue(group.keptReceipts.isEmpty)
        XCTAssertEqual(group.extensionSchema, DakAppGroup.schema)
    }

    func testAReceiptThatCouldNotGoIsKeptForTheApp() {
        share()
        FakeWeb.set("/v1/apps/app1/devices/dev1/delivered", .init(status: 503))
        _ = process(request(["_dak_id": "m1"]))
        XCTAssertEqual(group.keptReceipts, ["m1"])

        FakeWeb.set("/v1/apps/app1/devices/dev1/delivered", .init(status: 401))
        _ = process(request(["_dak_id": "m2"]))
        XCTAssertEqual(group.keptReceipts, ["m1", "m2"], "the app sends it after registering again")

        FakeWeb.set("/v1/apps/app1/devices/dev1/delivered", .init(status: 422))
        _ = process(request(["_dak_id": "m3"]))
        XCTAssertEqual(group.keptReceipts, ["m1", "m2"], "refused for good: dropped")
    }

    func testBeforeTheAppRegisteredTheReceiptIsKept() {
        _ = process(request(["_dak_id": "m1"]))
        XCTAssertTrue(FakeWeb.requests.isEmpty)
        XCTAssertEqual(group.keptReceipts, ["m1"])
    }

    func testWithoutAnAppGroupThePushStillShows() {
        let out = process(request(["_dak_id": "m1", "_dak_buttons": #"[{"id":"a","text":"A"}]"#]), group: .some(nil))
        XCTAssertEqual(out?.title, "Hi")
        XCTAssertTrue(out?.categoryIdentifier.hasPrefix("dak_") == true)
    }

    func testButtonsBecomeTheCategoryThePushNames() {
        let json = #"[{"id":"accept","text":"Accept"},{"id":"later","text":"মনে করিয়ে দিন"}]"#
        let out = process(request(["_dak_buttons": json, "aps": ["category": "dak_mcws1hz92z87"]]))
        XCTAssertEqual(out?.categoryIdentifier, "dak_mcws1hz92z87")
        XCTAssertTrue(center.ids.contains("dak_mcws1hz92z87"))
    }

    func testBadgeIncrementsAddToTheAppsBadge() {
        group.badge = 3
        let out = process(request(["_dak_badge_inc": "2"]))
        XCTAssertEqual(out?.badge, 5)
        XCTAssertEqual(group.badge, 5)
        _ = process(request(["_dak_badge_inc": "-9"]))
        XCTAssertEqual(group.badge, 0)
        _ = process(request(["aps": ["badge": 7]]))
        XCTAssertEqual(group.badge, 7)
    }

    func testTheImageIsAttached() {
        FakeWeb.set("/a.png", .init(headers: ["Content-Type": "image/png"], body: Self.png))
        let out = process(request(["fcm_options": ["image": "https://img.ext.test/a.png"]]))
        XCTAssertEqual(out?.attachments.count, 1)
        XCTAssertEqual(FakeWeb.requests.first?.value(forHTTPHeaderField: "User-Agent"), "dakpush-ios/0.1.0")
    }

    func testImagesThatAreNotImagesOrTooBigOrHttpAreSkipped() {
        FakeWeb.set("/page", .init(headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)))
        XCTAssertEqual(process(request(["fcm_options": ["image": "https://img.ext.test/page"]]))?.attachments.count, 0)

        FakeWeb.set(
            "/big.png",
            .init(
                headers: ["Content-Type": "image/png", "Content-Length": "\(6 * 1024 * 1024)"],
                body: Data(count: 6 * 1024 * 1024)))
        XCTAssertEqual(process(request(["fcm_options": ["image": "https://img.ext.test/big.png"]]))?.attachments.count, 0)

        XCTAssertNil(DakNotificationProcessor.imageURL(["fcm_options": ["image": "http://img.ext.test/a.png"]]))
        XCTAssertNotNil(DakNotificationProcessor.imageURL(["_dak_image": "https://img.ext.test/a.png"]))
    }

    func testASlowImageIsGivenUpAndThePushShowsWithoutIt() {
        FakeWeb.set("/slow.png", .init(headers: ["Content-Type": "image/png"], body: Self.png, delay: 30))
        let start = Date()
        let out = process(request(["fcm_options": ["image": "https://img.ext.test/slow.png"]]), timeout: 15)
        XCTAssertEqual(out?.attachments.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), DakImageDownload.timeout + 3)
    }

    func testWhenTimeRunsOutTheContentGoesAsItIs() {
        FakeWeb.set("/slow.png", .init(headers: ["Content-Type": "image/png"], body: Self.png, delay: 30))
        let out = process(request(["fcm_options": ["image": "https://img.ext.test/slow.png"]], title: "Now"), expire: 0.2)
        XCTAssertEqual(out?.title, "Now")
        XCTAssertEqual(out?.attachments.count, 0)
    }

    func testImageTypes() {
        func ext(_ mime: String, _ url: String = "https://x.ext.test/a") -> String? {
            DakImageDownload.fileExtension(
                HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!)
        }
        XCTAssertEqual(ext("image/png"), "png")
        XCTAssertEqual(ext("image/jpeg"), "jpg")
        XCTAssertEqual(ext("image/gif"), "gif")
        XCTAssertEqual(ext("image/x-something", "https://x.ext.test/a.png"), "png")
        XCTAssertEqual(ext("image/x-something"), "jpg")
        XCTAssertEqual(ext("application/octet-stream", "https://x.ext.test/a.gif"), "gif")
        XCTAssertNil(ext("application/octet-stream", "https://x.ext.test/a.exe"))
        XCTAssertNil(ext("text/html"))
    }
}
