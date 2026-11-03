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
  verification, tag checks, opens and receipts, the receipt token).
  `TestScheduler` runs the SDK's worker on the test thread with virtual time,
  for retries, backoff and the locked-phone waits. The extension's tests use
  `FakeWeb` for images and receipts.
- **Hosted tests** (`Example/DakPushExampleTests`) need an app around them:
  the real keychain and its accessibility, file protection, the App Group
  entitlement. Package tests on the simulator have no keychain.
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

**In-app messages (0.2)** plug in beside the client, not into it:
`DakClient.credentials` gives the device id and secret once registered,
`DakApi.fetchInApp` and `sendInAppEvents` are the endpoints, and `Dak`
already observes the app coming to the foreground (`observeApp`), where the
in-app controller would fetch and show.

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
