@_spi(DakInternal) import DakPushExtension
import UserNotifications
import XCTest

@testable import DakPush

/// The client against a real Dak server (`dak serve`), with a made-up APNs
/// token. Skipped unless these are set (xcodebuild passes TEST_RUNNER_X to
/// the tests as X):
///
/// ```
/// TEST_RUNNER_DAK_IT_BASE_URL=http://127.0.0.1:8091 TEST_RUNNER_DAK_IT_APP_ID=… \
/// TEST_RUNNER_DAK_IT_IDENTITY_SECRET=… TEST_RUNNER_DAK_IT_REST_KEY=dak_… \
///   xcodebuild test -scheme DakPush-Package -destination 'platform=iOS Simulator,name=iPhone 17' \
///   -only-testing:DakPushTests/LocalServerTests
/// ```
final class LocalServerTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var baseURL: String { env["DAK_IT_BASE_URL"] ?? "" }
    private var appId: String { env["DAK_IT_APP_ID"] ?? "" }
    private var identitySecret: String { env["DAK_IT_IDENTITY_SECRET"] ?? "" }
    private var restKey: String { env["DAK_IT_REST_KEY"] ?? "" }

    private final class Events: DakClientEvents, @unchecked Sendable {
        let ids = Locked<[String]>([])
        let errors = Locked<[DakError]>([])
        func deviceId(_ id: String) { ids.update { $0.append(id) } }
        func error(_ error: DakError) { errors.update { $0.append(error) } }
    }

    func testRegistersAndKeepsTheServerInStep() throws {
        try XCTSkipIf(
            [baseURL, appId, identitySecret, restKey].contains(""), "set TEST_RUNNER_DAK_IT_BASE_URL and the others to run it")
        let api = DakApi(
            baseURL: DakApi.checkBaseURL(baseURL)!, appId: appId, http: URLSessionHTTP(), userAgent: "dakpush-ios/it")
        let store = MemoryStateStore()
        let secrets = MemorySecretStore()
        let suite = "dakpush.it.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let group = DakAppGroup(identifier: suite, defaults: UserDefaults(suiteName: suite)!)
        let events = Events()
        let platform = FakePlatform()
        let c = DakClient(
            api: api, store: store, secrets: secrets, platform: platform, scheduler: QueueScheduler(),
            callbacks: { $0() }, events: events, log: DakLog(debug: true) { _, m in print(m) },
            sdkVersion: "ios-\(Dak.version)", shareTimezoneOffset: true, appGroup: group)
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        c.start()
        c.onNewToken(token)
        try waitFor { c.currentDeviceId != nil }
        let deviceId = try XCTUnwrap(c.currentDeviceId)

        let user = "it-ios-\(Int(Date().timeIntervalSince1970 * 1000))"
        XCTAssertEqual(call { c.login(user, authHash: String(repeating: "0", count: 64), callback: $0) }?.code, "identity_verification_failed")
        XCTAssertEqual(events.errors.value.count, 1)
        XCTAssertEqual(try userDevices(user).count, 0)

        XCTAssertNil(call { c.login(user, authHash: FakeDak.hmac(identitySecret, user), callback: $0) })
        XCTAssertNil(call { c.setTags(["level": "b2", "name": "রহিম"], callback: $0) })
        XCTAssertNil(call { c.setSubscribed(false, callback: $0) })

        let device = try XCTUnwrap(try userDevices(user).first)
        XCTAssertEqual(device["id"] as? String, deviceId)
        XCTAssertEqual(device["platform"] as? String, "ios")
        XCTAssertEqual(device["sdk_version"] as? String, "ios-\(Dak.version)")
        XCTAssertEqual(device["app_version"] as? String, "1.2.0+7")
        XCTAssertEqual(device["os_version"] as? String, "26.1")
        XCTAssertEqual(device["language"] as? String, "bn")
        XCTAssertEqual(device["utc_offset_minutes"] as? Int, 360)
        XCTAssertEqual(device["push_permission"] as? Bool, true)
        XCTAssertEqual(device["subscribed"] as? Bool, false)
        XCTAssertEqual((device["tags"] as? [String: String])?["name"], "রহিম")

        // Opens and receipts for messages the server does not know are
        // accepted and ignored; the extension's receipts go with the client's.
        c.addOpen(UUID().uuidString.lowercased(), action: "accept")
        group.keepReceipt(UUID().uuidString.lowercased())
        XCTAssertNil(call { c.flush(callback: $0) })
        XCTAssertEqual(store.json["opens"], .array([]))
        XCTAssertEqual(store.json["receipts"], .array([]))
        XCTAssertTrue(group.keptReceipts.isEmpty)

        // The extension reports with the receipt token the client shared.
        XCTAssertEqual(group.config?.deviceId, deviceId)
        XCTAssertEqual(group.config?.baseURL, DakApi.checkBaseURL(baseURL))
        let processor = DakNotificationProcessor(group: group, center: nil, receiptTimeout: 5)
        let content = UNMutableNotificationContent()
        content.title = "Hi"
        content.userInfo = ["_dak_id": UUID().uuidString.lowercased()]
        let done = expectation(description: "extension")
        processor.process(UNNotificationRequest(identifier: "x", content: content, trigger: nil)) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(group.keptReceipts.isEmpty, "the server took the extension's receipt")

        // The server forgets the device (account deletion): the next change
        // registers again with the whole state.
        XCTAssertEqual(try deleteUser(user), 1)
        XCTAssertNil(call { c.setTags(["level": "c1"], callback: $0) })
        let back = try XCTUnwrap(try userDevices(user).first)
        XCTAssertEqual((back["tags"] as? [String: String])?["level"], "c1")
        XCTAssertEqual((back["tags"] as? [String: String])?["name"], "রহিম")
        XCTAssertEqual(back["subscribed"] as? Bool, false)
        let newId = try XCTUnwrap(c.currentDeviceId)
        XCTAssertNotEqual(newId, deviceId)
        XCTAssertEqual(group.config?.deviceId, newId)

        XCTAssertNil(call { c.logout(callback: $0) })
        XCTAssertEqual(try userDevices(user).count, 0)
        XCTAssertEqual(events.ids.value, [deviceId, newId])
        XCTAssertNotNil(c.credentials)
        print("dak-it: device \(newId) token \(token)")
    }

    /// In-app messages end to end: the server picks this device's messages,
    /// the controller shows them by trigger and priority, and the server
    /// counts the impressions, clicks and dismissals it sends.
    func testInAppMessagesAgainstTheServer() throws {
        try XCTSkipIf(
            [baseURL, appId, identitySecret, restKey].contains(""), "set TEST_RUNNER_DAK_IT_BASE_URL and the others to run it")
        let http = RecordingHTTP()
        let api = DakApi(baseURL: DakApi.checkBaseURL(baseURL)!, appId: appId, http: http, userAgent: "dakpush-ios/it")
        let client = DakClient(
            api: api, store: MemoryStateStore(), secrets: MemorySecretStore(), platform: FakePlatform(),
            scheduler: QueueScheduler(), callbacks: { $0() }, events: Events(), log: DakLog(debug: true) { _, m in print(m) },
            sdkVersion: "ios-\(Dak.version)")
        client.start()
        client.onNewToken((0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined())
        try waitFor { client.credentials != nil }
        let deviceId = try XCTUnwrap(client.currentDeviceId)

        // Two messages for this device only: a modal waiting for a trigger,
        // and a banner for when the app opens. The highest priorities, so
        // other messages of the app cannot come first.
        let modal = try create([
            "name": "iOS IT modal", "status": "active", "layout": "modal", "priority": 1000,
            "content": [
                "title": "নতুন স্পিকিং চ্যালেঞ্জ!", "body": "আজকের বিষয়: ভ্রমণ",
                "buttons": [
                    ["id": "join", "text": "শুরু করুন", "action": ["type": "deep_link", "url": "amarpartner://challenge"]],
                    ["id": "later", "text": "পরে", "action": ["type": "dismiss"]],
                ],
            ],
            "target": ["device_ids": [deviceId]],
            "triggers": [[["kind": "custom", "key": "screen", "op": "=", "value": "home"]]],
            "frequency": ["type": "every_session", "max_displays": 3],
        ])
        let banner = try create([
            "name": "iOS IT banner", "status": "active", "layout": "banner_top", "priority": 999,
            "content": ["title": "Welcome back", "auto_dismiss_seconds": 5],
            "target": ["device_ids": [deviceId]], "frequency": ["type": "once"],
        ])
        defer {
            _ = try? restJSON("DELETE", "/v1/in-app/\(modal)", nil, expect: 204)
            _ = try? restJSON("DELETE", "/v1/in-app/\(banner)", nil, expect: 204)
        }

        let scheduler = TestScheduler()
        let clicks = Locked<[DakInAppClick]>([])
        let c = InAppController(
            api: api, store: MemoryStateStore(), credentials: { client.credentials }, setTags: { _ in }, openURL: nil,
            home: scheduler, io: scheduler, clock: Date.init, log: DakLog(debug: true) { _, m in print(m) },
            eventDelay: nil)
        c.onClick = { click in clicks.update { $0.append(click) } }
        c.attach("scene")
        c.start()
        scheduler.runUntilIdle()
        // The app may have other messages; these two come first.
        let mine = { c.messages.map(\.id).filter { [modal, banner].contains($0) } }
        XCTAssertEqual(Array(c.messages.prefix(2).map(\.id)), [modal, banner], "highest priority first")
        XCTAssertEqual(c.messages.first?.content.title, "নতুন স্পিকিং চ্যালেঞ্জ!")
        XCTAssertEqual(c.messages.first?.content.buttons.map(\.text), ["শুরু করুন", "পরে"])
        XCTAssertEqual(c.current?.id, banner, "the modal waits for its trigger")

        c.didDisplay(c.current!)
        c.dismiss(c.current!)
        c.addTriggers(["screen": .string("home")])
        XCTAssertEqual(c.current?.id, modal)
        let shown = c.current!
        c.didDisplay(shown)
        c.click(shown, button: shown.content.buttons.first)
        XCTAssertEqual(clicks.value.map(\.buttonId), ["join"])
        c.flushEvents()
        scheduler.runUntilIdle()
        XCTAssertEqual(c.pendingEvents, 0)

        let modalStats = try restJSON("GET", "/v1/in-app/\(modal)", nil)["stats"] as? [String: Any]
        XCTAssertEqual(modalStats?["impressions"] as? Int, 1)
        XCTAssertEqual(modalStats?["clicks"] as? Int, 1)
        XCTAssertEqual((modalStats?["buttons"] as? [String: Int])?["join"], 1)
        let bannerStats = try restJSON("GET", "/v1/in-app/\(banner)", nil)["stats"] as? [String: Any]
        XCTAssertEqual(bannerStats?["impressions"] as? Int, 1)
        XCTAssertEqual(bannerStats?["dismissals"] as? Int, 1)

        // The banner (once) is used up: the server leaves it out now, and an
        // unchanged list comes back as 304.
        c.refresh(force: true)
        scheduler.runUntilIdle()
        XCTAssertEqual(mine(), [modal])
        XCTAssertEqual(c.messages.first?.shown, 1, "the server's count for this device")
        c.refresh(force: true)
        scheduler.runUntilIdle()
        XCTAssertEqual(http.statuses.value.suffix(2), [200, 304])
        XCTAssertEqual(mine(), [modal])
        c.dispose()
        client.dispose()
    }

    // MARK: - Helpers

    /// [DakHTTP] that keeps the statuses of the in-app list's answers.
    private final class RecordingHTTP: DakHTTP, @unchecked Sendable {
        private let http = URLSessionHTTP()
        let statuses = Locked<[Int]>([])

        func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) throws
            -> DakHTTPResponse
        {
            let res = try http.send(method: method, url: url, headers: headers, body: body, timeout: timeout)
            if url.path.hasSuffix("/in-app") { statuses.update { $0.append(res.status) } }
            return res
        }
    }

    /// Creates an in-app message with the REST API; returns its id.
    private func create(_ message: [String: Any]) throws -> String {
        let js = try restJSON("POST", "/v1/in-app", message, expect: 201)
        return try XCTUnwrap(js["id"] as? String)
    }

    private func restJSON(_ method: String, _ path: String, _ body: [String: Any]?, expect: Int = 200) throws
        -> [String: Any]
    {
        var headers = ["Authorization": "Bearer \(restKey)"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let res = try URLSessionHTTP().send(
            method: method, url: URL(string: "\(DakApi.checkBaseURL(baseURL)!)\(path)")!, headers: headers,
            body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, timeout: 10)
        XCTAssertEqual(res.status, expect, String(decoding: res.body, as: UTF8.self))
        if res.body.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: res.body) as? [String: Any] ?? [:]
    }

    private func rest(_ method: String, _ path: String) throws -> [String: Any] {
        let http = URLSessionHTTP()
        let res = try http.send(
            method: method, url: URL(string: "\(DakApi.checkBaseURL(baseURL)!)\(path)")!,
            headers: ["Authorization": "Bearer \(restKey)"], body: nil, timeout: 10)
        XCTAssertEqual(res.status, 200, String(decoding: res.body, as: UTF8.self))
        return try JSONSerialization.jsonObject(with: res.body) as? [String: Any] ?? [:]
    }

    private func userDevices(_ user: String) throws -> [[String: Any]] {
        try rest("GET", "/v1/users/\(user)/devices")["devices"] as? [[String: Any]] ?? []
    }

    private func deleteUser(_ user: String) throws -> Int? {
        try rest("DELETE", "/v1/users/\(user)")["deleted"] as? Int
    }

    /// Runs [action] with a callback and returns what the callback got.
    private func call(_ action: (@escaping DakCallback) -> Void) -> DakError? {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<DakError?>(nil)
        action { e in
            result.value = e
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success)
        return result.value
    }

    private func waitFor(_ condition: () -> Bool) throws {
        let until = Date().addingTimeInterval(20)
        while !condition() {
            if Date() > until {
                XCTFail("timed out")
                throw URLError(.timedOut)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
