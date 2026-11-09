import XCTest

@testable import DakPush

/// Reading the server's in-app JSON, and the facade's calls before initialize.
final class InAppModelTests: XCTestCase {
    func testAFullMessageIsRead() throws {
        let js = JSON(any: [
            "id": "01a1-m", "layout": "banner_bottom", "priority": 7,
            "content": [
                "title": "নতুন চ্যালেঞ্জ", "body": "আজ: ভ্রমণ", "image_url": "https://cdn.example.com/a.png",
                "background_color": "#112233", "title_color": "#80FFFFFF", "body_color": "#zzzzzz",
                "close_button": false, "auto_dismiss_seconds": 8,
                "click_action": ["type": "deep_link", "url": "app://x"],
                "buttons": [
                    ["id": "go", "text": "Go", "action": ["type": "tags", "tags": ["level": "b2", "n": 3, "gone": NSNull()]]]
                ],
            ],
            "triggers": [[["kind": "custom", "key": "screen", "op": "in", "values": ["home", 2]]]],
            "frequency": ["type": "interval", "interval_seconds": 3600, "max_displays": 3],
            "start_at": "2026-11-09T10:00:00.123456789Z", "end_at": "2026-11-10T10:00:00+06:00", "shown": 2,
            "last_shown_at": "2026-11-09T09:00:00Z",
        ])
        let m = try XCTUnwrap(InAppMessage.parse(js))
        XCTAssertEqual(m.id, "01a1-m")
        XCTAssertEqual(m.layout, .bannerBottom)
        XCTAssertTrue(m.layout.isBanner)
        XCTAssertEqual(m.priority, 7)
        XCTAssertEqual(m.content.title, "নতুন চ্যালেঞ্জ")
        XCTAssertEqual(m.content.backgroundColor, 0xFF11_2233)
        XCTAssertEqual(m.content.titleColor, 0x80FF_FFFF)
        XCTAssertNil(m.content.bodyColor, "a bad colour is left out")
        XCTAssertFalse(m.content.closeButton)
        XCTAssertFalse(m.showsClose)
        XCTAssertEqual(m.content.autoDismiss, 8)
        XCTAssertEqual(m.content.clickAction, InAppAction(type: .deepLink, url: "app://x", tags: [:]))
        XCTAssertEqual(m.content.buttons.first?.action.tags, ["level": "b2", "n": "3", "gone": ""])
        XCTAssertEqual(m.triggers.first?.first?.values, ["home", "2"])
        XCTAssertEqual(m.frequency, InAppFrequency(kind: .interval, interval: 3600, maxDisplays: 3))
        XCTAssertEqual(m.startAt?.timeIntervalSince1970 ?? 0, 1_794_218_400.123457, accuracy: 0.000001)
        XCTAssertEqual(m.endAt, Date(timeIntervalSince1970: 1_794_283_200))
        XCTAssertEqual(m.shown, 2)
        XCTAssertEqual(m.lastShownAt, Date(timeIntervalSince1970: 1_794_214_800))
        XCTAssertTrue(m.content.hasText)
        XCTAssertNil(m.withoutImage().content.imageURL)
    }

    func testDefaultsAndTheWayOutOfAFullscreenMessage() throws {
        let plain = try XCTUnwrap(
            InAppMessage.parse(JSON(any: ["id": "a", "layout": "fullscreen", "content": [:], "frequency": ["type": "once"]])))
        XCTAssertTrue(plain.content.closeButton)
        XCTAssertNil(plain.content.autoDismiss)
        XCTAssertEqual(plain.priority, 0)
        XCTAssertTrue(plain.triggers.isEmpty)
        XCTAssertFalse(plain.content.hasText)

        let noWayOut = try XCTUnwrap(
            InAppMessage.parse(
                JSON(any: [
                    "id": "b", "layout": "fullscreen", "content": ["title": "T", "close_button": false],
                    "frequency": ["type": "once"],
                ])))
        XCTAssertTrue(noWayOut.showsClose, "iOS has no back button: the X stays")
        let withButton = try XCTUnwrap(
            InAppMessage.parse(
                JSON(any: [
                    "id": "c", "layout": "fullscreen",
                    "content": [
                        "title": "T", "close_button": false,
                        "buttons": [["id": "ok", "text": "OK", "action": ["type": "dismiss"]]],
                    ], "frequency": ["type": "once"],
                ])))
        XCTAssertFalse(withButton.showsClose)
        XCTAssertNil(InAppMessage.parse(JSON(any: ["id": "d", "layout": "modal", "content": [:]])), "no frequency")
        XCTAssertNil(InAppMessage.parse(.string("x")))
        XCTAssertNil(
            InAppMessage.parse(JSON(any: ["id": "e", "layout": "modal", "content": [:], "frequency": ["type": "once"], "triggers": [[]]])),
            "an empty group")
    }

    func testConditionsNeedTheirParts() {
        func cond(_ js: [String: Any]) -> InAppCondition? { try? InAppCondition.parse(JSON(any: js)) ?? nil }
        XCTAssertNil(cond(["kind": "custom", "op": "="]), "custom needs a key")
        XCTAssertNil(cond(["kind": "custom", "key": "", "op": "exists"]))
        XCTAssertNil(cond(["kind": "session_count", "op": ">="]), "a count needs a number")
        XCTAssertNil(cond(["kind": "session_count", "op": ">=", "value": "3"]))
        XCTAssertNil(cond(["kind": "session_time", "op": ">", "value": 3]), "time: only >= and <")
        XCTAssertEqual(cond(["kind": "since_install", "op": "<", "value": 60])?.seconds, 60)
        XCTAssertEqual(cond(["kind": "custom", "key": "k", "op": "=", "value": 2.5])?.value, .double(2.5))
    }

    func testColoursAndTimes() {
        XCTAssertEqual(InAppParse.color(.string("#FFFFFF")), 0xFFFF_FFFF)
        XCTAssertEqual(InAppParse.color(.string("#00000000")), 0)
        XCTAssertNil(InAppParse.color(.string("FFFFFF")))
        XCTAssertNil(InAppParse.color(.string("#FFF")))
        XCTAssertNil(InAppParse.color(.string("#+1234567")))
        XCTAssertNil(InAppParse.color(.int(7)))
        XCTAssertEqual(InAppParse.parseTime("2026-11-09T10:00:00Z"), Date(timeIntervalSince1970: 1_794_218_400))
        XCTAssertEqual(InAppParse.parseTime("2026-11-09T16:00:00+06:00"), Date(timeIntervalSince1970: 1_794_218_400))
        XCTAssertEqual(
            InAppParse.parseTime("2026-11-09T10:00:00.5Z")?.timeIntervalSince1970 ?? 0, 1_794_218_400.5, accuracy: 0.0001)
        XCTAssertNil(InAppParse.parseTime("yesterday"))
        XCTAssertEqual(InAppParse.formatTime(Date(timeIntervalSince1970: 1_794_218_400.25)), "2026-11-09T10:00:00.250Z")
        XCTAssertEqual(InAppParse.numberText(3), "3")
        XCTAssertEqual(InAppParse.numberText(2.5), "2.5")
    }

    func testNumbersWithAFractionSurviveJSON() {
        let data = Data(#"{"a":2.5,"b":3,"c":3.0,"d":true}"#.utf8)
        XCTAssertEqual(JSON.decodeObject(data), ["a": .double(2.5), "b": .int(3), "c": .int(3), "d": .bool(true)])
        XCTAssertEqual(JSON.decodeObject(JSON.encode(["a": .double(2.5)])), ["a": .double(2.5)])
        XCTAssertEqual(JSON.int(3).number, 3)
        XCTAssertNil(JSON.string("3").number)
    }

    func testTheClickTellsWhatHappened() {
        let click = DakInAppClick(messageId: "m", buttonId: nil, actionType: .url, url: "https://example.com/a b")
        XCTAssertNotNil(click.link)
        XCTAssertEqual(click.description, "DakInAppClick(m, -, url https://example.com/a b)")
        XCTAssertEqual(DakInAppActionType(rawValue: "deep_link"), .deepLink)
        XCTAssertEqual(DakInAppActionType.allCases.count, 5)
    }

    func testABlockEndsOnceAndWhenReleased() {
        var ends = 0
        var block: DakInAppBlock? = DakInAppBlock { ends += 1 }
        block?.end()
        block?.end()
        XCTAssertEqual(ends, 1)
        block = DakInAppBlock { ends += 1 }
        XCTAssertNotNil(block)
        block = nil
        XCTAssertEqual(ends, 2)
    }

    @MainActor
    func testCallsBeforeInitializeAreKeptForTheController() {
        let h = InAppHarness()
        defer { h.controller.dispose() }
        h.server.inApp = [inAppMessage("m", triggers: [[custom("=", "home")]])]
        let runtime = DakInAppRuntime()
        runtime.addTriggers(["k": .string("home"), "gone": .number(1)])
        runtime.removeTriggers(["gone"])
        runtime.block()
        runtime.setPaused(true)
        runtime.setPaused(false)
        runtime.install(h.controller, InAppPresenter(controller: h.controller))
        XCTAssertEqual(h.controller.triggers, ["k": .string("home")])
        XCTAssertTrue(h.controller.isPaused, "the block is still on")
        h.start()
        XCTAssertNil(h.showing)
        runtime.unblock()
        XCTAssertFalse(h.controller.isPaused)
        XCTAssertEqual(h.showing, "m")
        runtime.clearTriggers()
        XCTAssertTrue(h.controller.triggers.isEmpty)
    }

    func testImageSizesFollowTheLayout() {
        let phone = CGSize(width: 390, height: 844)
        XCTAssertEqual(InAppImages.maxPixels(.modal, screen: phone, scale: 3), 342 * 3)
        XCTAssertEqual(InAppImages.maxPixels(.modal, screen: CGSize(width: 1024, height: 1366), scale: 2), 800)
        XCTAssertEqual(InAppImages.maxPixels(.card, screen: phone, scale: 3), 390 * 1.5 * 3)
        XCTAssertEqual(InAppImages.maxPixels(.fullscreen, screen: phone, scale: 3), 844 * 3)
        XCTAssertEqual(InAppImages.maxPixels(.bannerTop, screen: phone, scale: 2), 192)
    }
}
