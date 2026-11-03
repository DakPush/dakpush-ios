import XCTest

@testable import DakPush

final class StoresTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dakpush-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStateSurvivesAndAMissingFileIsNil() throws {
        let store = FileStateStore(url: dir.appendingPathComponent("DakPush/state.json"))
        XCTAssertNil(try store.read())
        try store.write(Data(#"{"v":1}"#.utf8))
        try store.write(Data(#"{"v":2}"#.utf8))
        XCTAssertEqual(try store.read(), Data(#"{"v":2}"#.utf8))
        let again = FileStateStore(url: store.url)
        XCTAssertEqual(try again.read(), Data(#"{"v":2}"#.utf8))
    }

    func testTheFolderIsOutOfBackups() throws {
        let store = FileStateStore(url: dir.appendingPathComponent("DakPush/state.json"))
        try store.write(Data("{}".utf8))
        let values = try store.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTheStandardFileIsInApplicationSupport() {
        let url = FileStateStore.standard().url
        XCTAssertEqual(url.lastPathComponent, "state.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "DakPush")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    /// The real keychain; skipped where the test host has no keychain access.
    func testTheKeychainKeepsTheSecretOfOneDevice() throws {
        let store = KeychainSecretStore(service: "dakpush.test.\(UUID().uuidString)")
        do {
            try store.write(DakDeviceSecret(deviceId: "d1", secret: "s1"))
        } catch let e as KeychainSecretStore.KeychainError where e.status == errSecMissingEntitlement {
            throw XCTSkip("no keychain in this test host: \(e)")
        }
        defer { try? store.delete() }
        XCTAssertEqual(try store.read(), DakDeviceSecret(deviceId: "d1", secret: "s1"))
        try store.write(DakDeviceSecret(deviceId: "d2", secret: "s2"))
        XCTAssertEqual(try store.read(), DakDeviceSecret(deviceId: "d2", secret: "s2"))

        // Readable after the first unlock, on this device only.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
            kSecReturnAttributes as String: true,
        ]
        var out: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)
        let attributes = try XCTUnwrap(out as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        try store.delete()
        XCTAssertNil(try store.read())
        try store.delete()
    }
}
