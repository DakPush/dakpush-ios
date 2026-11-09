import XCTest

@testable import DakPush

/// The in-app logic against FakeDak: the Flutter SDK's controller tests,
/// ported, and the iOS parts (hosts are window scenes).
final class InAppControllerTests: XCTestCase {
    private var h: InAppHarness!

    override func setUp() {
        super.setUp()
        h = InAppHarness()
    }

    override func tearDown() {
        h.controller.dispose()
        h = nil
        super.tearDown()
    }

    func testASessionStartFetchesTheListAndShowsTheHighestPriorityMessage() throws {
        h.server.inApp = [inAppMessage("low", priority: 1), inAppMessage("high", priority: 5), inAppMessage("also-low", priority: 1)]
        let c = h.start()
        XCTAssertEqual(h.server.calls.map { "\($0.method) \($0.path)" }, ["GET /v1/apps/\(h.server.appId)/devices/dev-1/in-app"])
        XCTAssertEqual(h.server.calls.first?.header("Authorization"), "Device secret-1")
        XCTAssertEqual(c.messages.map(\.id), ["high", "low", "also-low"], "ties keep the server's order")
        XCTAssertEqual(c.sessionCount, 1)
        XCTAssertEqual(h.showing, "high")

        h.display()
        h.flush()
        XCTAssertEqual(h.eventTypes, ["impression high"])
        let e = try XCTUnwrap(h.server.inAppEvents.first)
        XCTAssertGreaterThan(e["seq"]?.int ?? 0, 0)
        XCTAssertEqual(e["at"]?.string, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(InAppParse.parseTime(e["at"]?.string ?? ""), h.now)
    }

    func testNothingShowsBeforeAHostIsAttachedAndWhilePaused() {
        h.server.inApp = [inAppMessage("a")]
        let c = h.start(attach: false)
        XCTAssertNil(h.showing)
        c.setPaused(true)
        c.attach("host")
        XCTAssertNil(h.showing)
        XCTAssertTrue(c.isPaused)
        c.setPaused(false)
        XCTAssertEqual(h.showing, "a")
    }

    func testOneMessageAtATimeOneTriggeredMeanwhileFollowsARefreshedListDoesNot() {
        h.server.inApp = [
            inAppMessage("first"),
            inAppMessage("on-home", triggers: [[["kind": "custom", "key": "screen", "op": "=", "value": "home"]]]),
            inAppMessage("plain"),
        ]
        let c = h.start()
        h.display()
        c.addTriggers(["screen": .string("home")])
        XCTAssertEqual(h.showing, "first", "still the first one")
        h.dismiss()
        XCTAssertEqual(h.showing, "on-home", "the triggered one follows")
        h.display()
        h.dismiss()
        XCTAssertNil(h.showing, "no event since: plain waits for the next one")

        c.refresh(force: true)
        h.settle()
        c.check()
        XCTAssertEqual(h.showing, "plain")
    }

    // MARK: - Triggers

    /// Whether a message with [triggers] shows after [set] in session [sessions].
    private func shows(_ triggers: [[[String: Any]]], set: [String: InAppTrigger] = [:], sessions: Int = 1) -> Bool {
        let local = InAppHarness()
        defer { local.controller.dispose() }
        local.server.inApp = [inAppMessage("m", triggers: triggers, frequency: ["type": "every_session"])]
        let c = local.start(attach: false)
        for _ in 1..<sessions { local.background(3600) }
        if !set.isEmpty { c.addTriggers(set) }
        c.attach("host")
        local.settle()
        return local.showing == "m"
    }

    func testCustomTriggers() {
        XCTAssertTrue(shows([[custom("=", "home")]], set: ["k": .string("home")]))
        XCTAssertFalse(shows([[custom("=", "home")]], set: ["k": .string("away")]))
        XCTAssertFalse(shows([[custom("=", "home")]]))
        XCTAssertTrue(shows([[custom("=", 5)]], set: ["k": .string("5")]), "numbers compare as numbers")
        XCTAssertTrue(shows([[custom("=", 5)]], set: ["k": .number(5.0)]))
        XCTAssertTrue(shows([[custom("=", 2.5)]], set: ["k": .string("2.50")]))
        XCTAssertTrue(shows([[custom("=", true)]], set: ["k": .bool(true)]))
        XCTAssertFalse(shows([[custom("=", true)]], set: ["k": .bool(false)]))
        XCTAssertTrue(shows([[custom("!=", "home")]]), "an unset trigger is not home")
        XCTAssertFalse(shows([[custom("!=", "home")]], set: ["k": .string("home")]))
        XCTAssertTrue(shows([[custom(">", 3)]], set: ["k": .number(4)]))
        XCTAssertTrue(shows([[custom(">", 3)]], set: ["k": .string("10")]))
        XCTAssertFalse(shows([[custom("<=", 3)]], set: ["k": .number(4)]))
        XCTAssertFalse(shows([[custom(">", 3)]], set: ["k": .string("x")]))
        XCTAssertTrue(shows([[custom("in", ["b1", "b2"])]], set: ["k": .string("b2")]))
        XCTAssertTrue(shows([[custom("in", ["1", "2"])]], set: ["k": .number(2.0)]))
        XCTAssertFalse(shows([[custom("in", ["b1"])]], set: ["k": .string("c1")]))
        XCTAssertTrue(shows([[custom("exists")]], set: ["k": .bool(false)]))
        XCTAssertFalse(shows([[custom("exists")]]))
        XCTAssertTrue(shows([[custom("not_exists")]]))
        XCTAssertTrue(shows([[custom("=", "রহিম")]], set: ["k": .string("রহিম")]), "Bangla values")
    }

    func testGroupsAreOredAndConditionsInsideAnded() {
        let a: [String: Any] = ["kind": "custom", "key": "a", "op": "exists"]
        let b: [String: Any] = ["kind": "custom", "key": "b", "op": "exists"]
        let c: [String: Any] = ["kind": "custom", "key": "c", "op": "exists"]
        XCTAssertFalse(shows([[a, b]], set: ["a": .number(1)]))
        XCTAssertTrue(shows([[a, b]], set: ["a": .number(1), "b": .number(1)]))
        XCTAssertTrue(shows([[a, b], [c]], set: ["c": .number(1)]))
    }

    func testSessionCount() {
        let third: [[[String: Any]]] = [[["kind": "session_count", "op": ">=", "value": 3]]]
        XCTAssertFalse(shows(third, sessions: 2))
        XCTAssertTrue(shows(third, sessions: 3))
        XCTAssertTrue(shows([[["kind": "session_count", "op": "=", "value": 1]]]))
    }

    func testTriggersAreCheckedWhenTheyChange() {
        h.server.inApp = [inAppMessage("m", triggers: [[custom("not_exists")]])]
        let c = h.start(attach: false)
        c.addTriggers(["k": .number(1)])
        c.attach("host")
        XCTAssertNil(h.showing)
        c.removeTriggers(["k"])
        XCTAssertEqual(h.showing, "m")
        XCTAssertTrue(c.triggers.isEmpty)
        c.addTriggers(["k": .number(1), "j": .bool(true)])
        c.clearTriggers()
        XCTAssertTrue(c.triggers.isEmpty)
    }

    func testTriggerValuesAndKeys() {
        XCTAssertEqual(InAppTrigger("home"), .string("home"))
        XCTAssertEqual(InAppTrigger(3), .number(3))
        XCTAssertEqual(InAppTrigger(Int64(4)), .number(4))
        XCTAssertEqual(InAppTrigger(2.5), .number(2.5))
        XCTAssertEqual(InAppTrigger(Float(1.5)), .number(1.5))
        XCTAssertEqual(InAppTrigger(true), .bool(true))
        XCTAssertEqual(InAppTrigger(3).text, "3")
        XCTAssertEqual(InAppTrigger(2.5).text, "2.5")
        XCTAssertEqual(InAppTrigger(false).text, "false")
        XCTAssertNil(InAppTrigger(true).number)
        XCTAssertEqual(InAppTrigger(" 7 ").number, 7)
        XCTAssertTrue(Dak.tagKeyIsValid("screen"))
        XCTAssertTrue(Dak.tagKeyIsValid("a.b:c-d_e"))
        XCTAssertFalse(Dak.tagKeyIsValid("bad key"))
        XCTAssertFalse(Dak.tagKeyIsValid(""))
        XCTAssertFalse(Dak.tagKeyIsValid(String(repeating: "k", count: 65)))
    }

    func testTimeTriggersWakeTheControllerUpWhenTheyComeTrue() {
        h.server.inApp = [
            inAppMessage("after-30s", triggers: [[["kind": "session_time", "op": ">=", "value": 30]]]),
            inAppMessage("after-a-day", triggers: [[["kind": "since_install", "op": ">=", "value": 86400]]]),
        ]
        let start = h.now
        let c = h.start()
        XCTAssertNil(h.showing)
        XCTAssertEqual(c.nextTimeCheck, start.addingTimeInterval(30))
        XCTAssertEqual(h.scheduler.nextTimer, 30)

        // The timer fires by itself.
        h.now = start.addingTimeInterval(30)
        h.scheduler.advance(30)
        XCTAssertEqual(h.showing, "after-30s")
        h.display()
        h.dismiss()
        XCTAssertEqual(c.nextTimeCheck, start.addingTimeInterval(86400))
        XCTAssertEqual(h.scheduler.nextTimer, 86400 - 30, "a day away is checked by a timer too")

        // The install time is kept across restarts.
        let again = InAppHarness(store: h.store)
        defer { again.controller.dispose() }
        again.now = start.addingTimeInterval(86400 + 60)
        again.server.inApp = h.server.inApp
        again.start()
        XCTAssertEqual(again.showing, "after-a-day")
        XCTAssertEqual(again.controller.sessionCount, 2)
    }

    func testTimeTriggersFurtherThanADayGetNoTimer() {
        h.server.inApp = [inAppMessage("week", triggers: [[["kind": "since_install", "op": ">=", "value": 7 * 86400]]])]
        let c = h.start()
        XCTAssertEqual(c.nextTimeCheck, h.now.addingTimeInterval(7 * 86400))
        XCTAssertNil(h.scheduler.nextTimer)
    }

    // MARK: - Frequency and schedule

    func testOnceNeverAgainAlsoAfterARestartBeforeTheServerKnows() {
        h.server.inApp = [inAppMessage("m")]
        let c = h.start()
        h.display()
        h.dismiss()
        h.background(7200)
        XCTAssertEqual(c.sessionCount, 2)
        XCTAssertNil(h.showing)

        let restarted = InAppHarness(store: h.store)
        defer { restarted.controller.dispose() }
        restarted.now = h.now.addingTimeInterval(86400)
        restarted.server.inApp = [inAppMessage("m")]  // shown: 0, events not counted yet
        restarted.start()
        XCTAssertNil(restarted.showing)
    }

    func testEverySessionAtMostMaxDisplaysAndAShortTripAwayIsTheSameSession() {
        h.server.inApp = [inAppMessage("m", frequency: ["type": "every_session", "max_displays": 2])]
        let c = h.start()
        XCTAssertEqual(h.display(), "m")
        h.dismiss()

        h.background(60)
        XCTAssertEqual(c.sessionCount, 1)
        c.check()
        XCTAssertNil(h.showing)

        h.background(360)
        XCTAssertEqual(c.sessionCount, 2)
        XCTAssertEqual(h.display(), "m")
        h.dismiss()

        h.background(360)
        XCTAssertEqual(c.sessionCount, 3)
        XCTAssertNil(h.showing, "shown twice already")
    }

    func testInterval() {
        h.server.inApp = [inAppMessage("m", frequency: ["type": "interval", "interval_seconds": 7200])]
        let c = h.start()
        XCTAssertEqual(h.display(), "m")
        h.dismiss()
        h.now += 3600
        c.check()
        XCTAssertNil(h.showing)
        h.now += 3600
        c.check()
        XCTAssertEqual(h.showing, "m")
    }

    func testTheServersCountsAreMergedWithThePhones() {
        h.server.inApp = [
            inAppMessage("seen-once", shown: 1),
            inAppMessage(
                "recent", frequency: ["type": "interval", "interval_seconds": 3600], shown: 1,
                lastShownAt: h.now.addingTimeInterval(-600)),
            inAppMessage("maxed", frequency: ["type": "every_session", "max_displays": 3], shown: 3),
            inAppMessage(
                "ok", frequency: ["type": "interval", "interval_seconds": 3600], shown: 4,
                lastShownAt: h.now.addingTimeInterval(-7200)),
        ]
        h.start()
        XCTAssertEqual(h.showing, "ok")
    }

    func testScheduleWindow() {
        let soon = h.now.addingTimeInterval(3600)
        h.server.inApp = [
            inAppMessage("ended", endAt: h.now.addingTimeInterval(-60)),
            inAppMessage("later", startAt: soon, endAt: soon.addingTimeInterval(3600)),
        ]
        let c = h.start()
        XCTAssertNil(h.showing)
        h.now = soon
        c.check()
        XCTAssertEqual(h.showing, "later")
        c.setPaused(true)
        h.now = soon.addingTimeInterval(3600)
        c.setPaused(false)
        XCTAssertNil(h.showing, "over at end_at")
    }

    // MARK: - Pause, hosts, clicks

    func testPausingHidesTheMessageWithoutCountingADismissalAndBlocksNest() {
        h.server.inApp = [inAppMessage("a", priority: 2), inAppMessage("b", priority: 1)]
        let c = h.start()
        h.display()
        c.block()
        c.block()
        XCTAssertNil(h.showing)
        c.unblock()
        XCTAssertTrue(c.isPaused)
        XCTAssertNil(h.showing)
        c.unblock()
        XCTAssertFalse(c.isPaused)
        XCTAssertEqual(h.showing, "a", "the user did not close a: it comes back after the block")
        h.display()
        h.dismiss()
        c.check()
        XCTAssertEqual(h.showing, "b", "a was seen (once) now")
        h.flush()
        XCTAssertEqual(h.eventTypes, ["impression a", "dismiss a"], "one impression for the interrupted display")
        c.unblock()  // more unblocks than blocks are harmless
        XCTAssertFalse(c.isPaused)
    }

    func testClicksAreReportedCloseTheMessageRunTheActionAndReachTheApp() {
        let buttons: [[String: Any]] = [
            ["id": "go", "text": "Go", "action": ["type": "deep_link", "url": "example://challenge"]],
            ["id": "web", "text": "Web", "action": ["type": "url", "url": "https://example.com/x"]],
            ["id": "b2", "text": "B2", "action": ["type": "tags", "tags": ["level": "b2", "old": ""]]],
        ]
        h.server.inApp =
            buttons.map {
                inAppMessage(
                    "m-\($0["id"]!)", content: ["title": "T", "buttons": [$0]], frequency: ["type": "every_session"])
            } + [
                inAppMessage("tap", content: ["title": "T", "click_action": ["type": "custom"]]),
                inAppMessage("no-action", content: ["title": "T"]),
            ]
        let c = h.start()
        for b in ["go", "web", "b2"] {
            let m = c.current!
            XCTAssertEqual(m.id, "m-\(b)")
            h.display()
            c.click(m, button: m.content.buttons.first)
            XCTAssertNil(h.showing)
            c.check()
        }
        let tap = c.current!
        h.display()
        c.click(tap)
        XCTAssertEqual(
            h.clicks.map { "\($0.messageId) \($0.buttonId ?? "-") \($0.actionType.rawValue) \($0.url ?? "-")" },
            [
                "m-go go deep_link example://challenge", "m-web web url https://example.com/x", "m-b2 b2 tags -",
                "tap - custom -",
            ])
        XCTAssertEqual(h.clicks.first?.link, URL(string: "example://challenge"))
        XCTAssertEqual(h.clicks[2].tags, ["level": "b2", "old": ""])
        XCTAssertEqual(h.opened, [URL(string: "https://example.com/x")!])
        XCTAssertEqual(h.tagsSet, [["level": "b2", "old": ""]])

        c.check()
        let plain = c.current!
        XCTAssertEqual(plain.id, "no-action")
        h.display()
        c.click(plain)  // no click_action: tapping the message does nothing
        XCTAssertEqual(h.showing, "no-action")
        XCTAssertTrue(c.isShowing)
        h.dismiss()
        XCTAssertFalse(c.isShowing)

        h.flush()
        XCTAssertEqual(
            h.eventTypes,
            [
                "impression m-go", "click m-go go", "impression m-web", "click m-web web", "impression m-b2",
                "click m-b2 b2", "impression tap", "click tap", "impression no-action", "dismiss no-action",
            ])
        let seqs = h.server.inAppEvents.compactMap { $0["seq"]?.int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
    }

    func testOnlyAllowedURLSchemesAreOpened() {
        let strict = InAppHarness(urlSchemes: ["https"])
        defer { strict.controller.dispose() }
        let urls = [
            ("web", "https://example.com/a"), ("plain", "http://example.com/b"),
            ("intent", "intent://scan/#Intent;scheme=zxing;end"), ("file", "file:///etc/passwd"),
            ("js", "javascript:alert(1)"), ("broken", "not a url"),
        ]
        strict.server.inApp = urls.map { id, url in
            inAppMessage(
                id, content: ["title": id, "click_action": ["type": "url", "url": url]],
                frequency: ["type": "every_session"])
        }
        let c = strict.start()
        for _ in urls {
            let m = c.current!
            strict.display()
            c.click(m)
            c.check()
        }
        XCTAssertEqual(strict.opened.map(\.absoluteString), ["https://example.com/a"])
        XCTAssertEqual(strict.clicks.count, urls.count, "the app still hears about every click")
    }

    func testHostsAreCountedTheFirstDrawsAndTheMessageMovesOnWithoutANewImpression() {
        h.server.inApp = [inAppMessage("a")]
        let c = h.start(attach: false)
        var changes = 0
        c.onChange = { changes += 1 }
        c.attach("outer")
        c.attach("inner")
        XCTAssertEqual(c.activeHost, "outer")
        XCTAssertGreaterThan(changes, 0)
        h.display()
        c.detach("inner")
        XCTAssertEqual(h.showing, "a", "the other host is still there")
        c.detach("outer")
        XCTAssertNil(h.showing)
        XCTAssertNil(c.activeHost)

        c.attach("inner")
        XCTAssertEqual(h.showing, "a", "it was taken off screen, not closed")
        h.display()
        h.flush()
        XCTAssertEqual(h.eventTypes, ["impression a"])
        c.detach("unknown")  // harmless
    }

    func testTheSceneTheUserTurnsToShowsTheNextMessage() {
        h.server.inApp = [inAppMessage("a"), inAppMessage("b", triggers: [[custom("exists")]])]
        let c = h.start(attach: false)
        c.attach("left")
        c.attach("right")
        XCTAssertEqual(c.activeHost, "left")
        c.prefer("right")
        XCTAssertEqual(c.activeHost, "left", "a message already chosen stays where it is")
        h.display()
        h.dismiss()
        c.prefer("right")
        XCTAssertEqual(c.activeHost, "right")
        c.addTriggers(["k": .bool(true)])
        XCTAssertEqual(h.showing, "b")
    }

    // MARK: - Network and storage

    func testOfflineTheCachedListIsUsedAndEventsWait() {
        h.server.inApp = [inAppMessage("a", frequency: ["type": "every_session"])]
        h.start()
        h.display()

        let offline = InAppHarness(store: h.store)
        defer { offline.controller.dispose() }
        offline.now = h.now.addingTimeInterval(3600)
        offline.server.offline = true
        let c = offline.start()
        XCTAssertEqual(offline.showing, "a")
        offline.display()
        offline.flush()
        XCTAssertEqual(c.pendingEvents, 2, "the first run never sent its impression either")

        offline.server.offline = false
        offline.flush()
        XCTAssertEqual(offline.eventTypes, ["impression a", "impression a"])
        XCTAssertEqual(c.pendingEvents, 0)
    }

    func testAnUnchangedListIsNotDownloadedAgain() {
        h.server.inApp = [inAppMessage("a")]
        let c = h.start()
        h.now += 120
        c.refresh()
        h.settle()
        XCTAssertEqual(h.server.calls("GET", "/in-app").last?.header("If-None-Match"), "\"v1\"")
        XCTAssertEqual(c.messages.map(\.id), ["a"], "a 304 keeps the list")

        c.refresh()  // within a minute: no request
        h.settle()
        XCTAssertEqual(h.inAppFetches, 2)

        h.server.inApp = [inAppMessage("b")]
        h.server.inAppEtag = "\"v2\""
        c.refresh(force: true)
        h.settle()
        XCTAssertEqual(c.messages.map(\.id), ["b"])
    }

    func testASessionStartWaitsAShortTimeForTheServerThenUsesTheCache() {
        let first = InAppHarness()
        first.server.inApp = [inAppMessage("cached", frequency: ["type": "every_session"])]
        first.start()
        first.controller.dispose()

        let slow = InAppHarness(store: first.store, separateIO: true)
        defer { slow.controller.dispose() }
        slow.now = first.now.addingTimeInterval(3600)
        slow.server.inApp = [inAppMessage("fresh", priority: 9, frequency: ["type": "every_session"])]
        slow.server.inAppEtag = "\"v2\""
        let c = slow.controller
        c.attach("host")  // the scene comes before the saved state is read
        c.start()
        slow.io.runUntilIdle()  // the saved state is read
        slow.scheduler.runUntilIdle()  // the session starts; the fetch is queued on io
        XCTAssertNil(slow.showing, "it waits for the server first")
        slow.scheduler.advance(3)
        XCTAssertEqual(slow.showing, "cached", "after 3 s from the cache")
        c.dismiss(c.current!)  // closed before the server answers
        slow.scheduler.runUntilIdle()
        XCTAssertNil(slow.showing)
        slow.settle()  // the fetch comes back
        XCTAssertEqual(slow.showing, "fresh", "the fresh list is checked when it comes")
    }

    func testMessagesThisSDKCannotShowAreSkipped() {
        h.server.inApp = [
            inAppMessage("new-layout", layout: "sidebar", priority: 9),
            inAppMessage(
                "new-action", priority: 9,
                content: ["title": "T", "buttons": [["id": "x", "text": "X", "action": ["type": "share"]]]]),
            inAppMessage("new-trigger", priority: 9, triggers: [[["kind": "weather", "op": "=", "value": "rain"]]]),
            inAppMessage("new-op", priority: 9, triggers: [[["kind": "session_time", "op": "=", "value": 3]]]),
            inAppMessage("new-frequency", priority: 9, frequency: ["type": "hourly"]),
            inAppMessage("fine"),
        ]
        let c = h.start()
        XCTAssertEqual(c.messages.map(\.id), ["fine"])
        XCTAssertEqual(h.showing, "fine")
    }

    func testAMessageWithAFieldOfTheWrongTypeIsSkippedAloneAlsoFromTheCache() {
        var badPriority = inAppMessage("bad-priority").object!
        badPriority["priority"] = .string("high")
        h.server.inApp = [
            inAppMessage("bad-title", priority: 9, content: ["title": 5]),
            .object(badPriority),
            inAppMessage("bad-url", priority: 9, content: ["title": "T", "click_action": ["type": "url", "url": 42]]),
            inAppMessage("bad-close", priority: 9, content: ["title": "T", "close_button": "no"]),
            inAppMessage(
                "bad-button", priority: 9,
                content: [
                    "title": "T",
                    "buttons": [["id": "x", "text": "X", "action": ["type": "dismiss"], "background_color": 7]],
                ]),
            inAppMessage("fine"),
        ]
        let c = h.start()
        XCTAssertEqual(c.messages.map(\.id), ["bad-button", "fine"], "a bad colour is only left out")
        XCTAssertEqual(h.showing, "bad-button")

        let again = InAppHarness(store: h.store, registered: false)
        defer { again.controller.dispose() }
        let cold = again.start()
        XCTAssertEqual(cold.messages.map(\.id), ["bad-button", "fine"])
    }

    func testBeforeTheDeviceIsRegisteredNothingIsFetchedRegisteringFetches() {
        h.registered = false
        h.server.inApp = [inAppMessage("a")]
        let c = h.start()
        XCTAssertTrue(h.server.calls.isEmpty)
        XCTAssertNil(h.showing)
        h.registered = true
        c.onRegistered()
        h.settle()
        XCTAssertEqual(h.showing, "a")
        // The saved id read again (the client reports it at each start): no
        // second fetch within the minute.
        c.onRegistered()
        h.settle()
        XCTAssertEqual(h.inAppFetches, 1)
    }

    func testANewDeviceIdFetchesWithoutTheOldETag() {
        h.server.inApp = [inAppMessage("a")]
        let c = h.start()
        h.server.addDevice("dev-2", secret: "secret-2")
        h.deviceId = "dev-2"
        h.secret = "secret-2"
        c.onRegistered()
        h.settle()
        let last = h.server.calls("GET", "/in-app").last
        XCTAssertEqual(last?.path.contains("dev-2"), true)
        XCTAssertNil(last?.header("If-None-Match"))
    }

    func testAMessageThePresenterCannotDrawIsSkippedForTheSession() {
        h.server.inApp = [
            inAppMessage("image-only", priority: 2, content: ["image_url": "https://x.test/a.png"]),
            inAppMessage("text"),
        ]
        let c = h.start()
        XCTAssertEqual(h.showing, "image-only")
        c.didFail(c.current!)
        XCTAssertEqual(h.showing, "text")
        h.display()
        h.dismiss()
        h.background(600)
        XCTAssertEqual(h.showing, "image-only", "tried again next session")
    }

    func testEventsPermanentRefusalsAreDroppedOtherFailuresKept() {
        h.server.inApp = [inAppMessage("a", frequency: ["type": "every_session"])]
        let c = h.start()
        h.display()
        let server = h.server
        server.intercept = { [unowned server] _, path in path.hasSuffix("/events") ? server.error(503, "down", "down") : nil }
        h.flush()
        XCTAssertEqual(c.pendingEvents, 1)
        server.intercept = { [unowned server] _, path in
            path.hasSuffix("/events") ? server.error(422, "invalid", "bad") : nil
        }
        h.flush()
        XCTAssertEqual(c.pendingEvents, 0)
        server.intercept = { [unowned server] _, path in
            path.hasSuffix("/events") ? server.error(401, "unauthorized", "who") : nil
        }
        h.dismiss()
        h.flush()
        XCTAssertEqual(c.pendingEvents, 1, "kept until the device registers again")
        h.server.intercept = { _, path in path.hasSuffix("/events") ? .status(502, body: "<html>bad gateway</html>") : nil }
        h.flush()
        XCTAssertEqual(c.pendingEvents, 1, "a proxy's error page is not Dak refusing")
        h.server.intercept = nil
        h.flush()
        XCTAssertEqual(c.pendingEvents, 0)
        XCTAssertEqual(h.eventTypes, ["dismiss a"])
    }

    func testEventsGoInBatchesOfAHundredAndAtMostFiveHundredWait() {
        h.server.inApp = (0..<3).map { inAppMessage("m\($0)", frequency: ["type": "every_session"]) }
        let c = h.start()
        h.server.offline = true
        for i in 0..<260 {
            h.background(600)
            h.now += 1
            XCTAssertNotNil(h.display(), "round \(i)")
            h.dismiss()
        }
        XCTAssertEqual(c.pendingEvents, InAppController.maxEvents, "the oldest are dropped")
        h.server.offline = false
        h.flush()
        let posts = h.server.calls("POST", "/events")
        XCTAssertEqual(posts.suffix(5).map { $0.body?["events"]?.array?.count ?? 0 }, [100, 100, 100, 100, 100])
        XCTAssertEqual(h.server.inAppEvents.count, 500)
        XCTAssertEqual(c.pendingEvents, 0)
    }

    func testEventsQueuedWhileABatchIsOnItsWayAreKept() {
        let held = InAppHarness(separateIO: true)
        defer { held.controller.dispose() }
        held.server.inApp = [inAppMessage("a", frequency: ["type": "every_session"])]
        let c = held.start()
        held.display()
        c.flushEvents()  // the impression is on its way (queued on io)
        held.dismiss()  // queued meanwhile
        held.settle()
        XCTAssertEqual(held.eventTypes, ["impression a", "dismiss a"])
        XCTAssertEqual(c.pendingEvents, 0)
    }

    func testEventsWaitAfterARestart() {
        h.server.inApp = [inAppMessage("a")]
        h.start()
        h.display()
        h.server.offline = true
        h.flush()
        h.controller.dispose()

        let next = InAppHarness(server: h.server, store: h.store)
        defer { next.controller.dispose() }
        next.server.offline = false
        next.start()
        XCTAssertEqual(next.eventTypes, ["impression a"], "the session start sends what was saved")
    }

    func testAStorageThatFailsDoesNotStopInAppMessages() {
        let store = MemoryStateStore()
        store.failure = NSError(domain: "disk", code: 1)
        let broken = InAppHarness(store: store)
        defer { broken.controller.dispose() }
        broken.server.inApp = [inAppMessage("a")]
        let c = broken.start()
        XCTAssertEqual(broken.showing, "a")
        broken.display()
        broken.flush()
        XCTAssertEqual(broken.eventTypes, ["impression a"])
        XCTAssertEqual(c.pendingEvents, 0)
    }

    func testACacheNotRefreshedForAWeekIsNotShown() {
        h.server.inApp = [inAppMessage("a", frequency: ["type": "every_session"])]
        h.start()
        h.display()

        let later = InAppHarness(store: h.store)
        defer { later.controller.dispose() }
        later.now = h.now.addingTimeInterval(8 * 86400)
        later.server.offline = true
        let c = later.start()
        XCTAssertNil(later.showing, "the server may have stopped it since")

        later.server.offline = false
        later.server.inApp = [inAppMessage("a", frequency: ["type": "every_session"])]
        c.refresh(force: true)
        later.settle()
        c.check()
        XCTAssertEqual(later.showing, "a")
    }

    func testAOnceMessageHiddenByABlockComesBackAfterARestartToo() {
        h.server.inApp = [inAppMessage("a")]
        let c = h.start()
        h.display()
        c.block()
        h.flush()

        let next = InAppHarness(store: h.store)
        defer { next.controller.dispose() }
        next.now = h.now.addingTimeInterval(3600)
        next.server.inApp = [inAppMessage("a", shown: 1)]
        next.start()
        XCTAssertEqual(next.showing, "a")
        next.display()
        next.flush()
        XCTAssertEqual(next.eventTypes, [], "its impression was counted the first time")
        next.dismiss()
        next.controller.check()
        XCTAssertNil(next.showing)
    }

    // MARK: - Only in the foreground

    func testALaunchInTheBackgroundCountsNoSessionAndShowsNothingUntilTheAppIsOpened() {
        let bg = InAppHarness(background: true)
        defer { bg.controller.dispose() }
        bg.server.inApp = [inAppMessage("a")]
        let c = bg.start()
        XCTAssertEqual(c.sessionCount, 0)
        XCTAssertNil(bg.showing)
        XCTAssertEqual(bg.inAppFetches, 0)

        bg.foreground = true
        c.lifecycle(foreground: true)
        bg.settle()
        XCTAssertEqual(c.sessionCount, 1)
        XCTAssertEqual(bg.showing, "a")
    }

    func testAMessageThatComesDueInTheBackgroundWaitsForTheForeground() {
        h.server.inApp = [inAppMessage("cart", triggers: [[["kind": "custom", "key": "screen", "op": "=", "value": "cart"]]])]
        let c = h.start()
        c.lifecycle(foreground: false)
        c.addTriggers(["screen": .string("cart")])
        XCTAssertNil(h.showing)
        c.lifecycle(foreground: true)
        XCTAssertEqual(h.showing, "cart")
    }

    func testGoingToTheBackgroundSendsTheEvents() {
        h.server.inApp = [inAppMessage("a")]
        h.start()
        h.display()
        XCTAssertTrue(h.server.inAppEvents.isEmpty)
        h.controller.lifecycle(foreground: false)
        h.settle()
        XCTAssertEqual(h.eventTypes, ["impression a"])
    }

    func testASavedStateThatCannotBeReadIsNotOverwrittenTheNextResumeReadsItAndKeepsWhatHappened() {
        let store = LockableStore()
        let first = InAppHarness(store: store)
        first.server.inApp = [inAppMessage("a")]
        first.start()
        first.display()  // its impression is saved, not sent
        first.settle()
        first.controller.dispose()
        let saved = store.value

        store.locked = true
        let second = InAppHarness(server: first.server, store: store)
        defer { second.controller.dispose() }
        second.now = first.now.addingTimeInterval(60)
        second.server.inApp = [inAppMessage("b", frequency: ["type": "every_session"])]
        let c = second.start()
        XCTAssertEqual(second.showing, "b", "runs from memory meanwhile")
        second.display()
        second.settle()
        XCTAssertEqual(store.value, saved, "never saved over")

        store.locked = false
        c.lifecycle(foreground: true)
        second.settle()
        let js = store.json
        XCTAssertEqual(js["sessions"]?.int, 2)
        XCTAssertEqual(Set(js["local"]?.object?.keys.map { $0 } ?? []), ["a", "b"])
        XCTAssertEqual(
            js["events"]?.array?.map { "\($0.object?["type"]?.string ?? "") \($0.object?["message_id"]?.string ?? "")" },
            ["impression a", "impression b"])

        second.flush()
        XCTAssertEqual(second.eventTypes, ["impression a", "impression b"])
        XCTAssertEqual(c.pendingEvents, 0)
    }

    func testUnlockingThePhoneReadsTheStateAgain() {
        let store = LockableStore()
        store.locked = true
        let h2 = InAppHarness(store: store)
        defer { h2.controller.dispose() }
        h2.server.inApp = [inAppMessage("a")]
        h2.start()
        XCTAssertNil(store.value)
        store.locked = false
        h2.controller.retryLoad()
        h2.settle()
        XCTAssertEqual(store.json["sessions"]?.int, 1)
    }

    func testTheSavedStateKeepsWhatAnUpdateNeeds() throws {
        h.server.inApp = [inAppMessage("a", frequency: ["type": "every_session"])]
        h.start()
        h.display()
        let js = try XCTUnwrap((h.store as? MemoryStateStore)?.json)
        XCTAssertEqual(js["v"]?.int, 1)
        XCTAssertEqual(js["etag"]?.string, "\"v1\"")
        XCTAssertEqual(js["fetched_for"]?.string, "dev-1")
        XCTAssertEqual(js["messages"]?.array?.count, 1)
        XCTAssertEqual(js["local"]?.object?["a"]?.object?["shown"]?.int, 1)
        XCTAssertEqual(js["installed_at"]?.int, InAppController.millis(h.now))
    }
}
