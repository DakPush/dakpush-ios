import UserNotifications
import XCTest

@testable import DakPush

final class DakNotificationTests: XCTestCase {
    /// A payload as the server's internal/apns Build makes it.
    private let payload: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "নতুন request", "body": "Rahim"], "mutable-content": 1, "category": "dak_x"],
        "_dak_id": "01a1-msg",
        "_dak_url": "amarpartner://friends",
        "_dak_buttons": #"[{"id":"accept","text":"Accept"},{"id":"later","text":"Later","url":"amarpartner://later"}]"#,
        "fcm_options": ["image": "https://img.example/a.png"],
        "type": "friend",
    ]

    func testReadsDaksKeysAndKeepsTheAppsData() {
        let n = DakNotification(userInfo: payload, title: "নতুন request", body: "Rahim")
        XCTAssertEqual(n.id, "01a1-msg")
        XCTAssertEqual(n.title, "নতুন request")
        XCTAssertEqual(n.body, "Rahim")
        XCTAssertEqual(n.url, "amarpartner://friends")
        XCTAssertEqual(n.imageURL, "https://img.example/a.png")
        XCTAssertEqual(n.data, ["type": "friend"])
        XCTAssertEqual(n.buttons.map(\.id), ["accept", "later"])
        XCTAssertEqual(n.raw["_dak_id"], "01a1-msg")
        XCTAssertNil(n.raw["aps"])
        XCTAssertNil(n.actionId)
        XCTAssertFalse(n.isSilent)
        XCTAssertTrue(DakNotification.isDak(payload))
    }

    func testAButtonsOwnURLWins() {
        XCTAssertEqual(DakNotification(userInfo: payload, actionId: "later").url, "amarpartner://later")
        XCTAssertEqual(DakNotification(userInfo: payload, actionId: "accept").url, "amarpartner://friends")
        XCTAssertEqual(DakNotification(userInfo: payload, actionId: "later").actionId, "later")
    }

    func testFromTheShownContent() {
        let content = UNMutableNotificationContent()
        content.title = "Hi"
        content.body = ""
        content.userInfo = payload
        let n = DakNotification(content: content, actionId: nil)
        XCTAssertEqual(n.title, "Hi")
        XCTAssertNil(n.body, "empty is nil")
    }

    func testSilentAndForeignPushes() {
        let silent = DakNotification(userInfo: ["aps": ["content-available": 1], "_dak_id": "m", "sync": "1"])
        XCTAssertTrue(silent.isSilent)
        XCTAssertEqual(silent.data, ["sync": "1"])
        XCTAssertFalse(DakNotification.isDak(["aps": ["alert": "x"]]))
        XCTAssertFalse(DakNotification.isDak(["_dak_id": ""]))
        XCTAssertFalse(DakNotification.isDak(["_dak_id": 5]))
    }

    func testBadButtonsAreSkipped() {
        XCTAssertEqual(DakNotification.parseButtons(#"[{"text":"no id"},{"id":"ok","text":"OK","url":""},5]"#).map(\.id), ["ok"])
        XCTAssertNil(DakNotification.parseButtons(#"[{"id":"ok","text":"OK","url":""}]"#).first?.url)
        XCTAssertEqual(DakNotification.parseButtons("not json"), [])
        XCTAssertEqual(DakNotification.parseButtons(nil), [])
    }
}

final class SupportTests: XCTestCase {
    func testAppVersionsLikeTheFlutterSDK() {
        XCTAssertEqual(IOSPlatformInfo.appVersion(short: "8.0.2", build: "535"), "8.0.2+535")
        XCTAssertEqual(IOSPlatformInfo.appVersion(short: "1.0", build: "1.0"), "1.0+1.0")
        XCTAssertEqual(IOSPlatformInfo.appVersion(short: "1.0", build: nil), "1.0")
        XCTAssertEqual(IOSPlatformInfo.appVersion(short: nil, build: "7"), "7")
    }

    func testLanguageCodesAsTheServerWantsThem() {
        XCTAssertEqual(IOSPlatformInfo.languageCode("bn-BD"), "bn")
        XCTAssertEqual(IOSPlatformInfo.languageCode("en_US"), "en")
        XCTAssertEqual(IOSPlatformInfo.languageCode("zh-Hans-CN"), "zh")
        XCTAssertEqual(IOSPlatformInfo.languageCode("FIL"), "fil")
        XCTAssertEqual(IOSPlatformInfo.languageCode("und"), "")
        XCTAssertEqual(IOSPlatformInfo.languageCode(""), "")
        XCTAssertEqual(IOSPlatformInfo.languageCode("e1"), "")
    }

    func testPermissionStates() {
        XCTAssertTrue(IOSPlatformInfo.allows(.authorized))
        XCTAssertTrue(IOSPlatformInfo.allows(.provisional))
        XCTAssertTrue(IOSPlatformInfo.allows(.ephemeral))
        XCTAssertFalse(IOSPlatformInfo.allows(.denied))
        XCTAssertFalse(IOSPlatformInfo.allows(.notDetermined))
    }

    func testClampNeverCutsACharacter() {
        XCTAssertEqual(clampUtf8("8.0.2+535", 32), "8.0.2+535")
        XCTAssertEqual(clampUtf8(String(repeating: "a", count: 40), 32).utf8.count, 32)
        // ব is 3 bytes: 32 bytes hold 10 of them.
        XCTAssertEqual(clampUtf8(String(repeating: "ব", count: 20), 32), String(repeating: "ব", count: 10))
        // A family emoji is one character of 25 bytes.
        XCTAssertEqual(clampUtf8("ab👨‍👩‍👧‍👦", 26), "ab")
    }

    func testTokensInLowerCaseHex() {
        XCTAssertEqual(hex(Data([0x00, 0xAB, 0xff])), "00abff")
    }

    func testReceiptTokenIsTheSecretsSHA256() {
        XCTAssertEqual(receiptToken("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTagValues() {
        XCTAssertEqual(Dak.tagValue("b2"), "b2")
        // A removal: a value that is nil.
        for removal in [Dak.tagValue(""), Dak.tagValue(nil)] {
            XCTAssertTrue(removal != nil)
            XCTAssertNil(removal ?? "not a removal")
        }
        XCTAssertEqual(Dak.tagValue(true), "true")
        XCTAssertEqual(Dak.tagValue(NSNumber(value: false)), "false")
        XCTAssertEqual(Dak.tagValue(42), "42")
        XCTAssertEqual(Dak.tagValue(Int64(7)), "7")
        XCTAssertEqual(Dak.tagValue(1.5), "1.5")
        XCTAssertEqual(Dak.tagValue(NSNumber(value: 3)), "3")
        // Other types are refused (nil outside).
        XCTAssertTrue(Dak.tagValue(Date()) == nil)
        XCTAssertTrue(Dak.tagValue(["a"]) == nil)
    }

    func testTheVersionIsInTheChangelogAndThePodspecs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["CHANGELOG.md", "DakPush.podspec", "DakPushExtension.podspec", "README.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(Dak.version), "\(file) names \(Dak.version)")
        }
    }
}

final class ListenerTests: XCTestCase {
    func testTapsBeforeTheFirstListenerAreKeptForIt() {
        let listeners = DakOpenedListeners()
        for i in 0..<25 { listeners.dispatch(DakNotification(userInfo: ["_dak_id": "m\(i)"])) }
        var got: [String] = []
        let sub = listeners.add { got.append($0.id ?? "") }
        waitUntil { got.count == 20 }
        XCTAssertEqual(got.first, "m5")
        listeners.dispatch(DakNotification(userInfo: ["_dak_id": "late"]))
        waitUntil { got.count == 21 }
        sub.remove()
        sub.remove()
        listeners.dispatch(DakNotification(userInfo: ["_dak_id": "after"]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(got.count, 21)
    }

    func testTheDeviceIdComesAtOnceAndNeverTwiceInARow() {
        var current: String?
        let listeners = DakDeviceIdListeners { current }
        var got: [String] = []
        _ = listeners.add { got.append($0) }
        listeners.dispatch("d1")
        listeners.dispatch("d1")
        listeners.dispatch("d2")
        current = "d2"
        var late: [String] = []
        _ = listeners.add { late.append($0) }
        waitUntil { got.count == 2 && late.count == 1 }
        XCTAssertEqual(got, ["d1", "d2"])
        XCTAssertEqual(late, ["d2"])
    }

    func testATapCountsOnceHoweverOftenItIsPassed() {
        let runtime = DakRuntime()
        var got: [String?] = []
        _ = runtime.opened.add { got.append($0.actionId) }
        let n = DakNotification(userInfo: ["_dak_id": "m1"], actionId: "accept")
        runtime.tap(n)
        runtime.tap(n)
        runtime.tap(DakNotification(userInfo: [:]))
        waitUntil { got.count == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(got, ["accept"])
    }

    func testForegroundListenersGetAMessageOnce() {
        let runtime = DakRuntime()
        var got = 0
        _ = runtime.foreground.add { _ in got += 1 }
        let n = DakNotification(userInfo: ["_dak_id": "m1"], title: "Hi")
        runtime.arrived(n, listeners: true)
        runtime.arrived(n, listeners: true)
        waitUntil { got == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(got, 1)
        XCTAssertEqual(runtime.presentation(for: n), [.banner, .list, .sound, .badge])
        runtime.foregroundChooser.value = { _ in [] }
        XCTAssertEqual(runtime.presentation(for: n), [])
    }
}
