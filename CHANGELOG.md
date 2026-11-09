# Changelog

All notable changes to the DakPush iOS SDK. Versions follow
[semantic versioning](https://semver.org); below 1.0 a breaking change raises
the minor version. **Breaking** marks changes that need code or settings
changes in apps.

## 0.2.0 - 2026-11-09

In-app messages, as in the Flutter SDK (dak_push 0.2+), native and with no
setup.

- Fetched at each session start (a cold start, or back after 5 minutes,
  `DakOptions.sessionTimeout`) with the ETag, kept for offline use, and not
  shown when no fetch has worked for a week. Messages this version cannot show
  are skipped one by one.
- Triggers checked on the phone: session count, time in the session, time
  since install, and custom triggers (`Dak.addTrigger(s)`, `removeTrigger(s)`,
  `clearTriggers`; strings, numbers and booleans). Timers wake the SDK when a
  time trigger comes true. Priority, schedule window and frequency (`once`,
  `every_session`, interval, `max_displays`) with the server's counts merged.
- Modal, top and bottom banner, full-screen page (always with a way out) and
  card, drawn with UIKit in a window of their own above the app, so SwiftUI
  apps work too. Sizes and spacing of the dashboard preview; images (https, 5
  MB, 5 s, decoded at the drawn size); up to three buttons with deep links,
  web links (`DakOptions.inAppUrlSchemes`), tags or a custom action; the
  app's tint, or `Dak.inAppTheme`.
- Dark mode, Dynamic Type (buttons stack at the largest sizes), Bangla and
  other tall scripts unclipped, right-to-left, rotation, the keyboard, several
  windows (iPad). VoiceOver: dialogs, announced banners, Escape and the
  two-finger scrub close, no timer for VoiceOver users; Reduce Motion fades.
- `Dak.addInAppClickListener` and `Dak.inAppClicks` (`AsyncStream`);
  `Dak.pauseInApp`, `Dak.blockInApp()` and SwiftUI `.dakInAppBlocked()` for
  screens that must not be covered (a hidden message comes back, counted
  once); `Dak.refreshInApp()` with a completion or `async`.
- Impressions, clicks and dismissals saved first and sent in batches of 100,
  also when the app goes to the background; refusals for good are dropped,
  everything else is kept.
- `DakOptions.inAppMessages` turns it off. Reports `ios-0.2.0`.

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
