@_spi(DakInternal) import DakPushExtension
import XCTest

@testable import DakPush

final class DakClientTests: XCTestCase {
    private var server: FakeDak!
    private var scheduler: TestScheduler!
    private var store: MemoryStateStore!
    private var secrets: MemorySecretStore!
    private var platform: FakePlatform!
    private var events: RecordingEvents!
    private var defaultsSuite: String?

    override func setUp() {
        server = FakeDak()
        scheduler = TestScheduler()
        store = MemoryStateStore()
        secrets = MemorySecretStore()
        platform = FakePlatform()
        events = RecordingEvents()
    }

    override func tearDown() {
        if let defaultsSuite { UserDefaults().removePersistentDomain(forName: defaultsSuite) }
    }

    private func api(_ server: FakeDak? = nil) -> DakApi {
        let s = server ?? self.server!
        return DakApi(
            baseURL: s.baseURL, appId: s.appId, http: URLSessionHTTP(protocolClasses: [FakeDakProtocol.self]),
            userAgent: "dakpush-ios/test", timeout: 5)
    }

    private func client(
        server: FakeDak? = nil, shareTimezoneOffset: Bool = false, appGroup: DakAppGroup? = nil,
        random: @escaping () -> Double = { 0.5 }, retryDelays: [TimeInterval] = [5, 15, 60, 300]
    ) -> DakClient {
        let scheduler = self.scheduler!
        return DakClient(
            api: api(server), store: store, secrets: secrets, platform: platform, scheduler: scheduler,
            callbacks: { $0() }, events: events, log: DakLog(debug: true) { _, m in print(m) },
            sdkVersion: "ios-0.1.0", shareTimezoneOffset: shareTimezoneOffset, appGroup: appGroup,
            clock: { scheduler.now }, random: random, retryDelays: retryDelays)
    }

    /// A started client registered with token 1.
    private func registered(appGroup: DakAppGroup? = nil, shareTimezoneOffset: Bool = false) -> DakClient {
        let c = client(shareTimezoneOffset: shareTimezoneOffset, appGroup: appGroup)
        c.start()
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertNotNil(c.currentDeviceId)
        return c
    }

    private func group() -> DakAppGroup {
        let suite = "dakpush.test.\(UUID().uuidString)"
        defaultsSuite = suite
        return DakAppGroup(identifier: suite, defaults: UserDefaults(suiteName: suite)!)
    }

    /// Runs [f] with a callback, runs the queue, and returns what the callback got.
    @discardableResult
    private func call(
        _ f: (@escaping DakCallback) -> Void, file: StaticString = #filePath, line: UInt = #line
    ) -> DakError? {
        var called = false
        var error: DakError?
        f {
            called = true
            error = $0
        }
        scheduler.runUntilIdle()
        XCTAssertTrue(called, "the callback did not run", file: file, line: line)
        return error
    }

    private func device(_ c: DakClient) -> FakeDak.Device { server.device(c.currentDeviceId)! }

    // MARK: - Registration and changes

    func testRegistersWithTheWholeStateThenSendsOnlyChanges() {
        let c = registered()
        XCTAssertEqual(server.registrations.count, 1)
        let reg = server.registrations[0]
        XCTAssertEqual(
            reg.body,
            [
                "token": .string(apnsToken()), "token_type": .string("apns"), "platform": .string("ios"),
                "app_version": .string("1.2.0+7"), "os_version": .string("26.1"), "sdk_version": .string("ios-0.1.0"),
                "language": .string("bn"), "push_permission": .bool(true), "subscribed": .bool(true),
                "external_id": .null, "utc_offset_minutes": .null, "tags": .object([:]),
            ])
        XCTAssertNil(reg.header("Authorization"))
        XCTAssertEqual(reg.header("User-Agent"), "dakpush-ios/test")
        let d = device(c)
        XCTAssertEqual(events.deviceIds, [d.id])
        XCTAssertEqual(secrets.value, DakDeviceSecret(deviceId: d.id, secret: d.secret))
        XCTAssertEqual(c.credentials?.secret, d.secret)
        // The secret stays out of the state file.
        XCTAssertNil(store.json["secret"])
        XCTAssertFalse(String(decoding: store.value!, as: UTF8.self).contains(d.secret))

        XCTAssertNil(call { c.setTags(["level": "b2"], callback: $0) })
        XCTAssertEqual(server.patches.last?.body, ["tags": .object(["level": .string("b2")])])
        XCTAssertEqual(server.patches.last?.header("Authorization"), "Device \(d.secret)")

        let before = server.calls.count
        XCTAssertNil(call { c.flush(callback: $0) })
        XCTAssertEqual(server.calls.count, before, "nothing changed, nothing sent")
    }

    func testChangesMadeTogetherGoInOneRound() {
        let c = registered()
        var done = 0
        c.login("u1", authHash: nil) { XCTAssertNil($0); done += 1 }
        c.setTags(["level": "b2", "name": "রহিম"]) { XCTAssertNil($0); done += 1 }
        c.setSubscribed(false) { XCTAssertNil($0); done += 1 }
        scheduler.runUntilIdle()
        XCTAssertEqual(done, 3)
        XCTAssertEqual(server.patches.count, 1)
        XCTAssertEqual(
            server.patches[0].body,
            [
                "external_id": .string("u1"), "subscribed": .bool(false),
                "tags": .object(["level": .string("b2"), "name": .string("রহিম")]),
            ])
    }

    func testNothingIsSentUntilAPNsGivesAToken() {
        let c = client()
        c.start()
        XCTAssertNil(call { c.login("u1", authHash: nil, callback: $0) })
        XCTAssertTrue(server.calls.isEmpty)
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 1)
        XCTAssertEqual(server.registrations[0].body?["external_id"], .string("u1"))
    }

    func testChangesMadeOfflineAreSentOnALaterStart() {
        let first = registered()
        server.queue(.fail(.notConnectedToInternet))
        XCTAssertNil(call { first.setTags(["level": "b2"], callback: $0) }, "kept, not refused")
        first.dispose()
        scheduler.runUntilIdle()

        let second = client()
        second.start()
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 1)
        XCTAssertEqual(server.patches.last?.body, ["tags": .object(["level": .string("b2")])])
        XCTAssertEqual(device(second).fields["tags"], .object(["level": .string("b2")]))
    }

    func testFailedSyncsAreRetriedWithBackoff() {
        server.queue(.status(500), .status(503), .fail(.timedOut))
        let c = client()
        c.start()
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 1)
        // A random half of each step: 0.75 × 5, 15, 60 here.
        XCTAssertEqual(scheduler.nextTimer!, 3.75, accuracy: 0.001)
        scheduler.advance(3.75)
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertEqual(scheduler.nextTimer!, 11.25, accuracy: 0.001)
        scheduler.advance(11.25)
        XCTAssertEqual(server.registrations.count, 3)
        XCTAssertEqual(scheduler.nextTimer!, 45, accuracy: 0.001)
        scheduler.advance(45)
        XCTAssertEqual(server.registrations.count, 4)
        XCTAssertNotNil(c.currentDeviceId)
        XCTAssertEqual(scheduler.pendingTimers, 0)
    }

    // MARK: - Refusals

    func testAWrongAuthHashRollsBackOnlyTheUserAndTheOptOutStillGoesThrough() {
        server.identitySecret = "identity"
        let c = registered()
        XCTAssertNil(call { c.login("u1", authHash: FakeDak.hmac("identity", "u1"), callback: $0) })

        var error: DakError?
        c.login("u2", authHash: String(repeating: "0", count: 64)) { error = $0 }
        c.setSubscribed(false, callback: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(error?.code, "identity_verification_failed")
        XCTAssertEqual(error?.status, 403)
        XCTAssertEqual(events.errors.map(\.code), ["identity_verification_failed"])
        XCTAssertEqual(device(c).fields["external_id"], .string("u1"))
        XCTAssertEqual(device(c).fields["subscribed"], .bool(false))
        XCTAssertEqual(store.json["external_id"], .string("u1"))
    }

    func testAWrongAuthHashAtRegistrationRegistersWithoutTheUser() {
        server.identitySecret = "identity"
        let c = client()
        c.start()
        XCTAssertNil(call { c.login("u1", authHash: "bad", callback: $0) })
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertEqual(server.registrations[1].body?["external_id"], .null)
        XCTAssertEqual(device(c).fields["external_id"], .null)
        XCTAssertEqual(events.errors.map(\.code), ["identity_verification_failed"])
    }

    func testARefusedTagRollsBackTheTagsOnly() {
        let c = registered()
        XCTAssertNil(call { c.setTags(["a": "1"], callback: $0) })
        var error: DakError?
        c.setTags(["b": String(repeating: "x", count: 300)]) { error = $0 }
        c.login("u1", authHash: nil, callback: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(error?.code, "invalid")
        XCTAssertEqual(error?.field, "tags")
        XCTAssertEqual(device(c).fields["tags"], .object(["a": .string("1")]))
        XCTAssertEqual(device(c).fields["external_id"], .string("u1"))
        XCTAssertEqual(store.json["tags"], .object(["a": .string("1")]))
    }

    func testAnAnswerFromAProxyIsRetriedNotActedOn() {
        let c = registered()
        let id = c.currentDeviceId
        server.queue(.status(401, body: "<html>login</html>", headers: ["Content-Type": "text/html"]))
        XCTAssertNil(call { c.setTags(["a": "1"], callback: $0) })
        XCTAssertEqual(c.currentDeviceId, id, "a proxy's 401 does not drop the device")
        XCTAssertEqual(server.registrations.count, 1)
        XCTAssertTrue(events.errors.isEmpty)
        XCTAssertEqual(scheduler.pendingTimers, 1)

        server.queue(.status(403, body: "<html>forbidden</html>"))
        scheduler.advance(3.75)
        XCTAssertTrue(events.errors.isEmpty, "a proxy's 403 is not a refusal")
        scheduler.advance(11.25)
        XCTAssertEqual(device(c).fields["tags"], .object(["a": .string("1")]))
    }

    func testRetryAfterIsHonoured() {
        server.queue(
            server.error(429, "rate_limited", "slow down").withHeaders(["Retry-After": "120"]))
        let c = client()
        c.start()
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertEqual(server.calls.count, 1)
        // Changes made meanwhile are only saved.
        XCTAssertNil(call { c.setTags(["a": "1"], callback: $0) })
        XCTAssertEqual(server.calls.count, 1)
        XCTAssertEqual(store.json["tags"], .object(["a": .string("1")]))
        scheduler.advance(119)
        XCTAssertEqual(server.calls.count, 1)
        scheduler.advance(1)
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertEqual(device(c).fields["tags"], .object(["a": .string("1")]))
    }

    func testLogoutRemovesTheUserAndTheTags() {
        let c = registered()
        XCTAssertNil(call { c.login("u1", authHash: nil, callback: $0) })
        XCTAssertNil(call { c.setTags(["a": "1", "b": "2"], callback: $0) })
        XCTAssertNil(call { c.logout(callback: $0) })
        XCTAssertEqual(server.patches.last?.body, ["external_id": .null, "tags": .object(["a": .null, "b": .null])])
        XCTAssertEqual(device(c).fields["external_id"], .null)
        XCTAssertEqual(device(c).fields["tags"], .object([:]))
        XCTAssertEqual(device(c).fields["subscribed"], .bool(true))
    }

    func testMoreThanFiftyTagsFailWithoutSending() {
        let c = registered()
        let before = server.calls.count
        var tags: [String: String?] = [:]
        for i in 0...50 { tags["t\(i)"] = "v" }
        let error = call { c.setTags(tags, callback: $0) }
        XCTAssertEqual(error?.code, "invalid")
        XCTAssertEqual(error?.field, "tags")
        XCTAssertEqual(server.calls.count, before)
    }

    // MARK: - The server forgets the device

    func testADeviceTheServerForgotRegistersAgainWithItsState() {
        let c = registered()
        XCTAssertNil(call { c.login("u1", authHash: nil, callback: $0) })
        let old = c.currentDeviceId!
        server.forget(old)
        XCTAssertNil(call { c.setTags(["a": "1"], callback: $0) })
        XCTAssertEqual(server.registrations.count, 2)
        let again = server.registrations[1].body!
        XCTAssertEqual(again["external_id"], .string("u1"))
        XCTAssertEqual(again["tags"], .object(["a": .string("1")]))
        XCTAssertNotEqual(c.currentDeviceId, old)
        XCTAssertEqual(events.deviceIds, [old, c.currentDeviceId!])
        XCTAssertEqual(secrets.value?.deviceId, c.currentDeviceId)
    }

    func testAServerThatKeepsRefusingTheDeviceIsNotLooped() {
        let c = registered()
        let unauthorized = server.error(401, "unauthorized", "register again")
        server.queue(unauthorized, .normal, unauthorized)
        c.addOpen("m1", action: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertEqual(server.calls("POST", "/opened").count, 2)
        XCTAssertEqual(scheduler.pendingTimers, 0)
    }

    // MARK: - Opens and receipts

    func testTapsMadeOfflineAreKeptUntilTheyCanBeSent() {
        let c = client()
        c.start()
        c.addOpen("m0", action: nil)
        scheduler.runUntilIdle()
        XCTAssertTrue(server.calls.isEmpty, "no device yet")
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertEqual(server.opens.map(\.id), ["m0"])

        server.queue(.fail(.networkConnectionLost))
        c.addOpen("m1", action: "accept")
        c.addOpen("m1", action: "accept")
        scheduler.runUntilIdle()
        XCTAssertEqual(store.json["opens"], .array([.object(["id": .string("m1"), "action": .string("accept")])]))
        scheduler.advance(3.75)
        XCTAssertEqual(server.opens.last?.id, "m1")
        XCTAssertEqual(server.opens.last?.action, "accept")
        XCTAssertEqual(store.json["opens"], .array([]))
    }

    func testReceiptsGoInBatchesOfFifty() {
        let c = client()
        c.start()
        for i in 0..<120 { c.addReceipt("m\(i)") }
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertEqual(server.calls("POST", "/delivered").map { $0.body?["message_ids"]?.array?.count }, [50, 50, 20])
        XCTAssertEqual(server.receipts.count, 120)
        XCTAssertEqual(store.json["receipts"], .array([]))
    }

    func testReceiptsTheExtensionKeptAreSentAndThenForgotten() {
        let g = group()
        g.keepReceipt("m1")
        g.keepReceipt("m2")
        _ = registered(appGroup: g)
        XCTAssertEqual(Set(server.receipts), ["m1", "m2"])
        XCTAssertTrue(g.keptReceipts.isEmpty)

        g.keepReceipt("m3")
        let c = client(appGroup: g)
        c.start()
        scheduler.runUntilIdle()
        XCTAssertEqual(server.receipts.last, "m3")
    }

    func testTheExtensionGetsTheReceiptTokenNotTheSecret() {
        let g = group()
        let c = registered(appGroup: g)
        let d = device(c)
        XCTAssertEqual(
            g.config,
            DakAppGroup.Config(baseURL: server.baseURL, appId: server.appId, deviceId: d.id, receiptToken: receiptToken(d.secret)))
        XCTAssertNotEqual(g.config?.receiptToken, d.secret)
        XCTAssertEqual(g.appSchema, DakAppGroup.schema)
        XCTAssertFalse(g.defaults.dictionaryRepresentation().values.contains { "\($0)".contains(d.secret) })

        server.forget(d.id)
        XCTAssertNil(call { c.setTags(["a": "1"], callback: $0) })
        XCTAssertEqual(g.config?.deviceId, c.currentDeviceId)
        XCTAssertNotEqual(g.config?.deviceId, d.id)
    }

    // MARK: - Token, last seen, permission

    func testANewTokenIsSentWithItsType() {
        let c = registered()
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertTrue(server.patches.isEmpty, "the same token every start sends nothing")
        c.onNewToken(apnsToken(2))
        scheduler.runUntilIdle()
        XCTAssertEqual(server.patches.last?.body, ["token": .string(apnsToken(2)), "token_type": .string("apns")])
    }

    func testLastSeenIsKeptFreshTwiceADay() {
        let c = registered()
        scheduler.advance(11 * 3600)
        c.flush()
        scheduler.runUntilIdle()
        XCTAssertTrue(server.patches.isEmpty)
        scheduler.advance(3600)
        c.flush()
        scheduler.runUntilIdle()
        XCTAssertEqual(server.patches.map(\.body), [[:]])
    }

    func testResumePicksUpAPermissionChangedInSettings() {
        let c = registered(shareTimezoneOffset: true)
        XCTAssertEqual(server.registrations[0].body?["utc_offset_minutes"], .int(360))
        platform.permission = false
        platform.offset = 330
        c.onResume()
        scheduler.runUntilIdle()
        XCTAssertEqual(server.patches.last?.body, ["push_permission": .bool(false), "utc_offset_minutes": .int(330)])
    }

    // MARK: - Saved state

    func testTheSavedDeviceIdComesBeforeAnyNetwork() {
        let first = registered()
        let id = first.currentDeviceId!
        first.dispose()
        scheduler.runUntilIdle()
        events.deviceIds = []
        let calls = server.calls.count

        let second = client()
        second.start()
        scheduler.runUntilIdle()
        XCTAssertEqual(events.deviceIds, [id])
        XCTAssertEqual(second.currentDeviceId, id)
        XCTAssertEqual(server.calls.count, calls)
    }

    func testAChangeMadeBeforeTheStateLoadsWinsOverTheSavedOne() {
        let first = registered()
        XCTAssertNil(call { first.login("old", authHash: nil, callback: $0) })
        first.dispose()
        scheduler.runUntilIdle()

        store.failure = DakStoreUnavailable(description: "locked")
        let second = client()
        second.start()
        var done = false
        second.login("new", authHash: nil) { _ in done = true }
        scheduler.runUntilIdle()
        XCTAssertFalse(done, "waits for the saved state")
        store.failure = nil
        second.retryLoad()
        scheduler.runUntilIdle()
        XCTAssertTrue(done)
        XCTAssertEqual(device(second).fields["external_id"], .string("new"))
    }

    func testALockedPhoneIsWaitedForAndNeverWrittenOver() {
        let first = registered()
        XCTAssertNil(call { first.login("u1", authHash: nil, callback: $0) })
        first.dispose()
        scheduler.runUntilIdle()
        let saved = store.value
        let writes = store.writes
        let calls = server.calls.count

        store.failure = DakStoreUnavailable(description: "locked")
        let second = client()
        second.start()
        second.onNewToken(apnsToken(2))
        scheduler.advance(6 * 3600)
        XCTAssertEqual(store.writes, writes)
        XCTAssertEqual(store.value, saved)
        XCTAssertEqual(server.calls.count, calls)
        XCTAssertNil(second.currentDeviceId)

        // The keychain alone locked counts the same.
        store.failure = nil
        secrets.failure = DakStoreUnavailable(description: "keychain locked")
        second.retryLoad()
        scheduler.advance(3600)
        XCTAssertNil(second.currentDeviceId)

        secrets.failure = nil
        second.retryLoad()
        scheduler.runUntilIdle()
        XCTAssertEqual(second.currentDeviceId, first.currentDeviceId)
        XCTAssertEqual(server.patches.last?.body, ["token": .string(apnsToken(2)), "token_type": .string("apns")])
        XCTAssertEqual(device(second).fields["external_id"], .string("u1"))
    }

    func testAStateThatCannotBeReadOnAnUnlockedPhoneIsGivenUp() {
        store.failure = CocoaError(.fileReadCorruptFile)
        let c = client()
        c.start()
        c.onNewToken(apnsToken())
        scheduler.runUntilIdle()
        XCTAssertNil(c.currentDeviceId)
        scheduler.advance(5)
        XCTAssertNil(c.currentDeviceId)
        store.failure = nil
        // The third failed read starts over; here the next read works first.
        scheduler.advance(15)
        XCTAssertNotNil(c.currentDeviceId)

        let other = MemoryStateStore()
        other.failure = CocoaError(.fileReadCorruptFile)
        store = other
        let d = client()
        d.start()
        d.onNewToken(apnsToken(3))
        scheduler.advance(5 + 15)
        XCTAssertNotNil(d.currentDeviceId, "started over after three reads")
    }

    func testAnotherAppIdRegistersAgainButKeepsTheUser() {
        let first = registered()
        XCTAssertNil(call { first.login("u1", authHash: nil, callback: $0) })
        first.addReceipt("m-of-the-first-app")
        first.dispose()
        scheduler.runUntilIdle()
        XCTAssertEqual(store.json["receipts"], .array([.string("m-of-the-first-app")]))

        let other = FakeDak(appId: "other-app")
        let second = client(server: other)
        second.start()
        scheduler.runUntilIdle()
        XCTAssertEqual(other.registrations.count, 1)
        XCTAssertEqual(other.registrations[0].body?["external_id"], .string("u1"))
        XCTAssertTrue(other.receipts.isEmpty)
    }

    func testAMissingSecretRegistersAgainAndKeepsTheUser() {
        let first = registered()
        XCTAssertNil(call { first.login("u1", authHash: nil, callback: $0) })
        let old = first.currentDeviceId
        first.dispose()
        scheduler.runUntilIdle()

        secrets.value = nil
        let second = client()
        second.start()
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertEqual(server.registrations[1].body?["external_id"], .string("u1"))
        // The server took the row of the token over.
        XCTAssertEqual(second.currentDeviceId, old)
    }

    func testASecretOfAnotherDeviceIsNotUsed() {
        let first = registered()
        first.dispose()
        scheduler.runUntilIdle()
        secrets.value = DakDeviceSecret(deviceId: "someone-else", secret: "s")
        let second = client()
        second.start()
        scheduler.runUntilIdle()
        XCTAssertEqual(server.registrations.count, 2)
        XCTAssertTrue(server.patches.isEmpty)
    }

    func testRetryWaitsAreJitteredAndHonourRetryAfterUpToAnHour() {
        var r = 0.0
        let c = client(random: { r })
        XCTAssertEqual(c.retryDelay(failures: 0, retryAfter: nil), 2.5, accuracy: 0.001)
        r = 0.999_999
        XCTAssertEqual(c.retryDelay(failures: 0, retryAfter: nil), 5, accuracy: 0.001)
        XCTAssertEqual(c.retryDelay(failures: 9, retryAfter: nil), 300, accuracy: 0.001)
        XCTAssertEqual(c.retryDelay(failures: 0, retryAfter: 7200), 3600)
        XCTAssertEqual(c.retryDelay(failures: 0, retryAfter: 1), 5, accuracy: 0.001)
    }
}

extension FakeDak.Answer {
    func withHeaders(_ extra: [String: String]) -> FakeDak.Answer {
        guard case .status(let status, let body, let headers) = self else { return self }
        return .status(status, body: body, headers: headers.merging(extra) { _, new in new })
    }
}
