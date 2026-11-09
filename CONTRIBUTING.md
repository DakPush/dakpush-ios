# Contributing

Thanks for helping. Bug reports, docs fixes and pull requests are all welcome.
For a larger change, open an issue first so we can agree on the approach
before you spend time on it.

Security problems are the exception: report them privately, as
[SECURITY.md](SECURITY.md) describes.

## Set up

You need Xcode 15 or newer and an iOS simulator.

```bash
# The package's tests (DakPushTests, DakPushExtensionTests)
xcodebuild test -scheme DakPush-Package -destination 'platform=iOS Simulator,name=iPhone 17'

# The example app and its hosted tests (keychain, file protection, App Group)
cd Example && xcodebuild test -project DakPushExample.xcodeproj -scheme DakPushExample \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# CocoaPods
pod lib lint DakPushExtension.podspec && pod lib lint DakPush.podspec --include-podspecs=DakPushExtension.podspec
```

## Tests

- **Unit tests** (`Tests/`) run the real client and HTTP code against
  `FakeDak`, a `URLProtocol` that answers like the DakPush server's SDK
  endpoints (registration taking over a token's row, device secrets, identity
  verification, tag checks, opens and receipts, the receipt token, in-app
  lists with their ETag and in-app events).
  `TestScheduler` runs the SDK's worker on the test thread with virtual time,
  for retries, backoff and the locked-phone waits. The extension's tests use
  `FakeWeb` for images and receipts.
- **Hosted tests** (`Example/DakPushExampleTests`) need an app around them:
  the real keychain and its accessibility, file protection, the App Group
  entitlement, and the in-app messages' windows in a real scene (sizes against
  the dashboard preview, right to left, dark mode, Dynamic Type, VoiceOver,
  the keyboard, the presenter end to end). With
  `TEST_RUNNER_DAK_SNAPSHOTS=/some/folder` they also save each layout as a
  PNG there to look at. Package tests on the simulator have no keychain.
- **In-app logic** (`InAppControllerTests`) runs the controller against
  `FakeDak`'s in-app endpoints on a `TestScheduler`: the Flutter SDK's
  controller tests, ported, plus the iOS parts.
- **Against a real server** (`LocalServerTests`), skipped unless you point it
  at a running `dak serve` (xcodebuild passes `TEST_RUNNER_X` to the tests as
  `X`):

  ```bash
  TEST_RUNNER_DAK_IT_BASE_URL=http://127.0.0.1:8080 TEST_RUNNER_DAK_IT_APP_ID=… \
  TEST_RUNNER_DAK_IT_IDENTITY_SECRET=… TEST_RUNNER_DAK_IT_REST_KEY=dak_… \
    xcodebuild test -scheme DakPush-Package -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:DakPushTests/LocalServerTests
  ```

`xcrun simctl push` hands a push to the app as a local request: the
notification service extension does not run for it. Images, buttons and the
extension's receipts need a real push (an Apple-silicon simulator gets real
sandbox tokens). In automated runs, never tap the system's permission prompts;
`Dak.requestPermission(provisional: true)` asks nothing.

## How the code is laid out

`DakPush` (the app's library). Public: `Dak` (the entry point), `DakOptions`,
`DakNotification`, `DakButton`, `DakError`, `DakSubscription`,
`DakNotificationCenterDelegate` and the listener types. Everything in
`Internal/` is internal:

| File | What it does |
|---|---|
| `DakClient` | The state the app wants and the state the server last accepted, kept on disk; sends the difference. All of it runs on one serial queue (`DakScheduler`). |
| `DakApi` | The SDK endpoints over `URLSession`, each exchange within one deadline, no redirects. |
| `Stores` | The state file in Application Support and the device secret in the keychain. |
| `Platform` | The facts the server targets by (versions, language, offset, permission). |
| `Runtime` | What `Dak` keeps: the client, the listeners, taps and receipts from before `initialize`. |
| `JSON`, `Support` | The JSON the state is made of; the worker queue, logging, small helpers. |

In-app messages (`InApp/`). Public: the `Dak` methods in `Dak+InApp`,
`DakInAppClick`, `DakInAppActionType`, `DakTriggerValue`, `DakInAppBlock`,
`DakInAppTheme`, `.dakInAppBlocked()`. The rest is internal:

| File | What it does |
|---|---|
| `InAppModel` | The server's JSON, read as strictly as the Flutter SDK reads it. |
| `InAppController` | The logic (port of the Flutter SDK's `controller.dart`): cache, sessions, triggers, frequency, priority, events. It lives on the main queue in the app, with network and disk on a queue of its own. |
| `InAppPresenter` | Shows the controller's message in a window per scene, loads the image first, counts the impression once it is on screen. |
| `InAppViews` | The layouts in UIKit, with the dashboard preview's sizes. |
| `InAppImages` | Image download (through the extension's `DakImageDownload`) and decoding at the drawn size. |

`DakPushExtension` (the notification service extension's library, safe for
app extensions). Public: `DakNotificationService`. The rest is SPI
(`@_spi(DakInternal)`), shared with `DakPush`: the App Group keys
(`DakAppGroup`, the Flutter SDK's), the category naming (`DakCategories`),
the image download and `DakNotificationProcessor`.

The client is a port of the Flutter SDK's `client.dart`, like the Android
SDK's; keep them in step when the protocol changes. The category name
(`dak_` and FNV-1a in base 36 of the buttons' ids and texts) must stay byte
for byte the same as the server's `internal/apns` `Category`;
`CategoryTests.testTheNameMatchesTheServer` checks the server's golden value.

**In-app messages** sit beside the client, not in it: they read
`DakClient.credentials`, hear about registrations through the device id
event, and follow the app's lifecycle from `Dak.observeApp`. Keep the
controller in step with the Flutter SDK's `controller.dart` (and the Android
SDK's) when the in-app protocol changes, and the layouts with the dashboard's
`InAppPreview.svelte`.

## Names

The product is DakPush; the libraries are `DakPush` and `DakPushExtension`,
the entry type `Dak`. The podspecs' homepage and source, and the example's
bundle id (`Example/Config/Config.xcconfig`), are temporary until the domain
is chosen.

## Before you open a pull request

- Both test commands above pass, with no new warnings.
- New behaviour and fixed bugs have tests.
- Public API has documentation comments.
- A line in CHANGELOG.md under `## Unreleased`; start it with **Breaking:** if
  apps must change code or settings to update.
- Notification and tap changes: say which devices and iOS versions you tried
  them on.
- Keep each pull request to one change.
