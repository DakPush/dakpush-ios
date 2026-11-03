# Changelog

All notable changes to the DakPush iOS SDK. Versions follow
[semantic versioning](https://semver.org); below 1.0 a breaking change raises
the minor version. **Breaking** marks changes that need code or settings
changes in apps.

## 0.1.0 - 2026-11-03

The first release: the push half of the Flutter SDK (dak_push 0.4), native,
straight through APNs without Firebase.

- `Dak.initialize` returns at once; the saved state and the registration
  follow in the background. Changes are kept and sent when the phone is
  online, also after a restart.
- Registers the APNs token (`token_type: "apns"`, lower-case hex), the app
  version as `CFBundleShortVersionString+CFBundleVersion`, the language and,
  if the app opts in, the UTC offset. Reports its version as `ios-0.1.0`.
- `login(externalId, authHash:)` with identity verification, `logout` (which
  also removes the device's tags), `setTags`/`deleteTags`, `setSubscribed`,
  each with a completion and as `async`. A refusal rolls back only the
  refused field; network trouble never fails.
- `requestPermission()` with the normal prompt or `provisional: true` (no
  prompt), `hasPermission`, `openNotificationSettings`, `setBadge`.
- Taps and foreground notifications through `UNUserNotificationCenter`:
  `installNotificationDelegate()` forwards to the delegate set before it, or
  call `handle(_:)` and `presentationOptions(for:)` from your own. No
  swizzling. Opens are reported once, with the tapped button.
- Listeners for taps (kept until the first listener), foreground messages,
  the device id and refusals from background syncs.
- `DakPushExtension` for the notification service extension: image (5 MB, 8
  s), up to 3 buttons as the category the server names, badge increments,
  and delivered receipts with a receipt token, kept in the App Group when they
  cannot be sent.
- State in Application Support (out of backups, readable after the first
  unlock), the device secret in the keychain (after first unlock, this device
  only). A locked phone is waited for; unread state is never written over.
- Swift Package Manager and CocoaPods; privacy manifests in both libraries.
