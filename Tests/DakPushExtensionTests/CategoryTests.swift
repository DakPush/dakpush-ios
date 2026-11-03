@_spi(DakInternal) @testable import DakPushExtension
import UserNotifications
import XCTest

/// A notification center that keeps categories in memory.
final class FakeCategoryCenter: DakCategoryCenter {
    var categories = Set<UNNotificationCategory>()
    var sets = 0

    func notificationCategories() -> Set<UNNotificationCategory> { categories }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
        sets += 1
    }

    var ids: Set<String> { Set(categories.map(\.identifier)) }
}

func testGroup() -> DakAppGroup {
    let suite = "dakpush.test.\(UUID().uuidString)"
    return DakAppGroup(identifier: suite, defaults: UserDefaults(suiteName: suite)!)
}

final class CategoryTests: XCTestCase {
    /// The server's internal/apns TestBuildOptions golden value: the push names
    /// the category the extension makes.
    func testTheNameMatchesTheServer() {
        let json = #"[{"id":"accept","text":"Accept"},{"id":"later","text":"মনে করিয়ে দিন","url":"amarpartner://later"}]"#
        let category = DakCategories.category(forButtonsJSON: json)
        XCTAssertEqual(category?.identifier, "dak_mcws1hz92z87")
        XCTAssertEqual(category?.actions.map(\.identifier), ["accept", "later"])
        XCTAssertEqual(category?.actions.map(\.title), ["Accept", "মনে করিয়ে দিন"])
        XCTAssertEqual(category?.actions.first?.options, [.foreground])
    }

    func testTheFirstThreeButtonsOfWhichThoseWithIdAndText() {
        let json = #"[{"id":"a","text":""},{"id":"b","text":"B"},{"text":"C"},{"id":"d","text":"D"}]"#
        XCTAssertEqual(DakCategories.buttons(fromJSON: json).map(\.id), ["b"])
        XCTAssertNil(DakCategories.category(forButtonsJSON: "[]"))
        XCTAssertNil(DakCategories.category(forButtonsJSON: "nope"))
        XCTAssertEqual(DakCategories.fnv1a(""), String(UInt64(0xcbf2_9ce4_8422_2325), radix: 36))
    }

    func testRegisteringKeepsTheAppsOwnAndTheMostRecentDakOnes() {
        let center = FakeCategoryCenter()
        let own = UNNotificationCategory(identifier: "chat", actions: [], intentIdentifiers: [], options: [])
        center.categories = [own]
        let group = testGroup()
        for i in 0..<35 {
            let c = DakCategories.category(forButtonsJSON: #"[{"id":"b\#(i)","text":"B"}]"#)!
            DakCategories.register(c, center: center, group: group, pollInterval: 0)
        }
        XCTAssertTrue(center.ids.contains("chat"))
        XCTAssertEqual(center.ids.filter { $0.hasPrefix("dak_") }.count, 30)
        let newest = DakCategories.category(forButtonsJSON: #"[{"id":"b34","text":"B"}]"#)!.identifier
        let oldest = DakCategories.category(forButtonsJSON: #"[{"id":"b0","text":"B"}]"#)!.identifier
        XCTAssertTrue(center.ids.contains(newest))
        XCTAssertFalse(center.ids.contains(oldest))
        XCTAssertEqual(group.savedCategories.count, 30)
        XCTAssertEqual(group.savedCategories.last?["id"] as? String, newest)

        // Using an old one again makes it the newest.
        let again = DakCategories.category(forButtonsJSON: #"[{"id":"b5","text":"B"}]"#)!
        DakCategories.register(again, center: center, group: group, pollInterval: 0)
        XCTAssertEqual(group.savedCategories.last?["id"] as? String, again.identifier)
        XCTAssertEqual(group.savedCategories.count, 30)
    }

    func testTheAppPutsBackCategoriesSomethingReplaced() {
        let center = FakeCategoryCenter()
        let group = testGroup()
        let c = DakCategories.category(forButtonsJSON: #"[{"id":"accept","text":"Accept"}]"#)!
        DakCategories.register(c, center: center, group: group, pollInterval: 0)
        center.categories = [UNNotificationCategory(identifier: "theirs", actions: [], intentIdentifiers: [], options: [])]
        DakCategories.restore(center: center, group: group)
        XCTAssertEqual(center.ids, ["theirs", c.identifier])
        XCTAssertEqual(center.categories.first { $0.identifier == c.identifier }?.actions.first?.title, "Accept")
        let sets = center.sets
        DakCategories.restore(center: center, group: group)
        XCTAssertEqual(center.sets, sets, "nothing missing, nothing set")
    }

    func testTheAppGroupKeepsReceiptsOneKeyEach() {
        let group = testGroup()
        for i in 0..<210 { group.keepReceipt("m\(i)") }
        XCTAssertEqual(group.keptReceipts.count, DakAppGroup.maxKeptReceipts)
        group.removeReceipts(["m0", "m1"])
        XCTAssertEqual(group.keptReceipts.count, DakAppGroup.maxKeptReceipts - 2)
        XCTAssertNil(group.config)
        let config = DakAppGroup.Config(baseURL: "https://x.test", appId: "a", deviceId: "d", receiptToken: "t")
        group.share(config)
        XCTAssertEqual(group.config, config)
        // The Flutter SDK's keys: an extension built for either works with both.
        XCTAssertEqual(
            group.defaults.dictionary(forKey: "dak_push") as? [String: String],
            ["base_url": "https://x.test", "app_id": "a", "device_id": "d", "receipt_token": "t"])
        XCTAssertEqual(group.defaults.integer(forKey: "dak_push_schema"), 2)
        group.removeConfig()
        XCTAssertNil(group.config)
    }
}
