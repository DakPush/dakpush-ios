import Security
import XCTest

@testable import DakPush

/// What needs an app around it: the keychain and file protection. These run
/// inside the example app (the package's own tests have no keychain).
final class HostedTests: XCTestCase {
    func testTheKeychainKeepsTheSecretOfOneDevice() throws {
        let store = KeychainSecretStore(service: "dakpush.test.\(UUID().uuidString)")
        defer { try? store.delete() }
        XCTAssertNil(try store.read())
        try store.write(DakDeviceSecret(deviceId: "d1", secret: "s1"))
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
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        try store.delete()
        XCTAssertNil(try store.read())
        try store.delete()
    }

    /// An item saved with another accessibility (by hand, or an older
    /// version) gets the right one on the next write.
    func testAWriteFixesTheAccessibility() throws {
        let service = "dakpush.test.\(UUID().uuidString)"
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "device", kSecValueData as String: Data("{}".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
        let store = KeychainSecretStore(service: service)
        defer { try? store.delete() }
        XCTAssertNil(try store.read(), "not a device secret")
        try store.write(DakDeviceSecret(deviceId: "d1", secret: "s1"))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
        ]
        var out: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &out), errSecSuccess)
        XCTAssertEqual(
            (out as? [String: Any])?[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testTheStateFileIsWrittenWithItsProtection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dakpush-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStateStore(url: dir.appendingPathComponent("DakPush/state.json"))
        try store.write(Data("{}".utf8))
        let protection = try FileManager.default.attributesOfItem(atPath: store.url.path)[.protectionKey] as? FileProtectionType
        // The simulator has no data protection and may not report it.
        if let protection { XCTAssertEqual(protection, .completeUntilFirstUserAuthentication) }
        XCTAssertEqual(
            try store.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
            true)
    }

    func testTheAppSharesWithItsExtension() throws {
        let group = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "DakAppGroup") as? String)
        XCTAssertNotNil(
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
            "the App Group entitlement reached the app")
    }
}
