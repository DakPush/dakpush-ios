# DakPush iOS SDK

Native iOS SDK for DakPush, a self-hosted push notification server. It
registers the iPhone with your DakPush server straight through APNs (no
Firebase), links it to your user, keeps tags, and reports deliveries, opens
and button taps. A small second library for your notification service
extension adds the push's image and buttons and reports the delivery even
while the app is not running.

Swift, iOS 15 and newer. In-app messages come in 0.2.

Version 0.1.0.

> **Pre-release.** Nothing is published to a registry yet, and the URLs in the
> podspecs are temporary until the product's domain is chosen.

## Requirements

| | Minimum |
|---|---|
| iOS | 15.0 |
| Xcode | 15 (Swift 5.9) |
| Server | A DakPush server with an APNs key for the app (Settings → APNs, or `dak app set-apns`) |

Apple's side: an App ID with **Push Notifications**, and an APNs key (.p8) from
your Apple Developer account. Upload the key to your DakPush app with the
app's bundle id and the environment: `sandbox` for builds you run from Xcode,
`production` for TestFlight and the App Store.

## Install

**Swift Package Manager.** Until it is published, add the folder as a local
package (File → Add Package Dependencies → Add Local…), or a git URL once
there is one. Link `DakPush` to the app and `DakPushExtension` to the
notification service extension.

**CocoaPods.**

```ruby
target 'MyApp' do
  pod 'DakPush', :path => '../dak-push-ios'
end

target 'NotificationService' do
  pod 'DakPushExtension', :path => '../dak-push-ios'
end
```

## Quick start

1. In Xcode, give the app the **Push Notifications** capability, and
   **Background Modes → Remote notifications** if you send silent pushes.
2. Start the SDK in your app delegate, so the tap that launches the app is
   seen. A SwiftUI app adds one with `@UIApplicationDelegateAdaptor`:

```swift
import DakPush
import SwiftUI

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { WindowGroup { ContentView() } }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Dak.initialize(appId: "APP_ID", baseURL: "https://push.example.com",
                       options: DakOptions(appGroup: "group.com.example.app.dakpush"))
        Dak.installNotificationDelegate()

        // Taps, the one that launched the app included. n.url is the deep
        // link (the tapped button's own URL if it has one).
        Dak.addOpenedListener { n in
            if n.actionId == "accept" { acceptRequest(n.data["request_id"]) }
            router.open(n.url)
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Dak.setDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Dak.failedToRegister(with: error)
    }
}
```

Then, where it makes sense in your app:

```swift
Dak.requestPermission { allowed in … }        // the normal prompt
Dak.requestPermission(provisional: true)      // no prompt: quiet delivery to Notification Center

// After your own login. authHash comes from your server (see Identity verification).
Dak.login(user.id, authHash: user.pushAuthHash)
Dak.logout()                                  // also removes this device's tags

Dak.setTags(["name": "Rahim", "level": "b2", "premium": true])
Dak.deleteTag("level")
Dak.setSubscribed(false)                      // the user turned pushes off in your settings
```

Each of them also comes as `async`:

```swift
do {
    try await Dak.login(user.id, authHash: user.pushAuthHash)
} catch let error as DakError {
    log("refused: \(error.code)")
}
```

`Dak.initialize` returns at once: reading the saved state and registering the
device run in the background, so a bad network never holds your app's start.
It calls `registerForRemoteNotifications()` itself on every start, as Apple
recommends (that never shows a prompt). Calls made meanwhile (`login`,
`setTags`) wait for the saved state and are then sent.

`login`, `setTags` and the others take an optional completion. It gets `nil`
when the change was saved, and sent or kept to send later (no network: it goes
out on a later start), and a `DakError` when it was refused: by the server for
good, such as a wrong auth hash, or by the SDK before sending, such as a bad
tag key or an email address as the user id (code `invalid`). On a server
refusal only the refused field is rolled back: an opt-out sent together with a
wrong auth hash still goes through. Refusals from syncs that run in the
background come to `Dak.addErrorListener`. Completions and listeners run on the
main thread.

`baseURL` must be `https`; plain `http` works only for `localhost` and
`127.0.0.1` (the simulator). Lengths are counted in UTF-8 bytes, as the server
does: a tag value is at most 255 bytes (85 Bangla letters), a user id 128.

## Why the SDK does not swizzle

Many push SDKs swap methods of your app delegate at runtime ("swizzling") to
get the APNs token and notification taps without code. DakPush does not:

- The token comes from two lines you add (`setDeviceToken`,
  `failedToRegister`). They are easy to see, to debug and to test, and nothing
  breaks when another library swizzles the same methods, or when Apple
  changes how the app delegate is called.
- Taps and foreground notifications come through `UNUserNotificationCenter`'s
  delegate. iOS allows one; `Dak.installNotificationDelegate()` makes the SDK
  that delegate **and forwards every call to the delegate that was set before
  it**, so set your own (or another library's) first. For DakPush
  notifications it records the tap or the delivery and decides how to show
  them in the foreground; other notifications are left entirely to the earlier
  delegate.
- If your app has its own delegate and you would rather keep it, skip
  `installNotificationDelegate()` and call the SDK from it:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    if !Dak.handle(response) { handleMyOwn(response) }
    completionHandler()
}

func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler(Dak.presentationOptions(for: notification) ?? myOptions(notification))
}
```

A response passed to the SDK more than once still counts once. Debug builds
log a warning when no delegate is set, when something replaced the SDK's, and
when no APNs token came 15 seconds after start (the two app delegate lines
are missing).

## The device id

`Dak.deviceId` is nil until the device registers, which happens after
`Dak.initialize` returns on a first start. A listener gets the id at once if
it is known, and when it comes (and a new one if the device ever registers
again):

```swift
Dak.addDeviceIdListener { id in api.saveDakDevice(id) }
```

`remove()` on what `add…Listener` returns stops a listener.

## Taps and deep links

The SDK reports opens and button taps itself; your listener only routes.
Taps that come before your first opened listener exists (the one that
launched the app) are kept for it. The SDK never opens `n.url` itself.

## While the app is open

A DakPush notification that arrives while the app is open shows as a banner,
in the list, with its sound and badge (`DakOptions.foregroundPresentation`),
and the foreground listeners get it:

```swift
Dak.addForegroundListener { n in refreshInbox() }
Dak.setForegroundPresentation { n in n.data["type"] == "chat" ? [] : [.banner, .list, .sound] }
```

## Notification service extension: images, buttons, receipts

Images and buttons need a notification service extension, and so do delivered
receipts while the app is not running. It takes three steps:

1. Xcode → File → New → Target → **Notification Service Extension**. Link
   `DakPushExtension` to it, and make its class:

   ```swift
   import DakPushExtension

   class NotificationService: DakNotificationService {}
   ```

2. Add the same **App Group** to the app and the extension (Signing &
   Capabilities → App Groups), and put it in the extension's Info.plist under
   `DakAppGroup` (or override `appGroupIdentifier`).
3. Pass it to the SDK: `DakOptions(appGroup: "group.com.example.app.dakpush")`.

For every push, the extension then

- attaches the image (`image` in the API; at most 5 MB, downloaded within 8
  seconds, https only; otherwise the push shows without it);
- adds up to 3 buttons as a notification category named like the server names
  it in `aps.category`, keeping your own categories and DakPush's 30 most
  recently used;
- adds badge increments (`badge_increment`) to the badge the app last set with
  `Dak.setBadge`;
- reports the delivery to your server with a receipt token that can do
  nothing else (never the device secret), or keeps it in the App Group for the
  app to send at its next start.

Override `willDeliver(_:for:)` to change the content yourself. Without an
extension, pushes still arrive and show; they count as delivered when the app
sees them (open, or tapped) and have no image or buttons.

## Silent pushes

Pass them on from your app delegate, so they count as delivered (and reach the
foreground listeners while the app is open):

```swift
func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    if !Dak.didReceiveRemoteNotification(userInfo, completion: completionHandler) {
        completionHandler(.noData)   // not a DakPush push
    }
}
```

## Identity verification

So nobody can claim another user's id and receive their pushes, the server
checks `authHash = hex(HMAC-SHA256(key: identity secret, message: user id))`.
Get the secret from the dashboard (or `dak app identity-secret <app id>` on
the server) and compute the hash on your server, for example in Laravel:

```php
'push_auth_hash' => hash_hmac('sha256', (string) $user->id, config('services.dak.identity_secret')),
```

The identity secret must never be in the app.

## Options

```swift
Dak.initialize(appId: appId, baseURL: baseURL, options: DakOptions(
    appGroup: "group.com.example.app.dakpush",           // shared with the notification service extension
    shareTimezoneOffset: true,                           // for local-time sends and quiet hours
    foregroundPresentation: [.banner, .list, .sound, .badge],
    registerForRemoteNotifications: true,                // at every start
    debugLogs: false                                     // Console.app, subsystem "dakpush"
))
```

`shareTimezoneOffset` sends only the offset in minutes (+360 in Bangladesh),
and again when it changes: no timezone name, city or location. Without it the
app's timezone (set on the server) is used.

## What is stored and sent

The SDK sends: the APNs token, platform, app version
(`CFBundleShortVersionString+CFBundleVersion`), iOS and SDK version
(`ios-0.1.0`), language, whether notifications are allowed (provisional
counts), the user id and tags you set, which pushes arrived and were opened
(with the button), and the UTC offset only if you turn it on. Nothing else: no
IP, location, phone number, email or device model.

Its state (device id, what the server last accepted, changes not yet sent) is
a small file in Application Support/DakPush: left out of backups (a restored
copy would make two phones one device), deleted with the app, and readable
after the first unlock since the phone started, so a push that wakes the app
on a locked phone can still read it. The device secret is in the keychain,
readable after the first unlock and on this device only. On a phone that has
not been unlocked since it started, the SDK waits for the unlock and never
writes over state it could not read. The device secret is sent only to your
`baseURL`; the extension gets only a receipt token derived from it.

Both libraries include a privacy manifest (`PrivacyInfo.xcprivacy`).

## How it works

The SDK keeps two copies of the device: what the app wants (token, user, tags,
subscription, permission) and what the server last accepted. After every
change, and on start and when the app comes to the foreground, it sends the
difference: the whole state to register, then only changed fields. One sync
runs at a time, changes made together go in one request, and failed syncs are
retried with backoff and jitter (and never sooner than the server's
`Retry-After`). When the server no longer knows the device, it registers again
with the whole state. The same logic runs in the DakPush Flutter and Android
SDKs.

## Troubleshooting

Turn on `DakOptions(debugLogs: true)` and filter Console.app by the subsystem
`dakpush`.

**The device never shows up on the server.**
- `no APNs token` in the log: the app needs the Push Notifications capability
  and a provisioning profile with it (a team in Signing & Capabilities). On
  the simulator, Apple-silicon Macs get real sandbox tokens.
- No token and no error: the two app delegate methods do not call
  `Dak.setDeviceToken` and `Dak.failedToRegister`.
- Check `appId` and `baseURL` (the server's public URL, without `/v1`).

**Pushes do not arrive.** The DakPush app needs an APNs key, the same bundle
id, and the right environment: `sandbox` for Xcode builds, `production` for
TestFlight and the App Store. With the wrong one, Apple refuses every token;
the server pauses APNs sending and the dashboard offers to switch.

**Taps are not reported.** `Dak.initialize` and the delegate must be set in
`application(_:didFinishLaunchingWithOptions:)`; see
[Why the SDK does not swizzle](#why-the-sdk-does-not-swizzle).

**No image or buttons, or no delivered count while the app is closed.** The
notification service extension is missing, or the App Group is not the same
in the app, the extension's entitlements and its `DakAppGroup` (Console.app
shows `DakPush:` errors from the extension).

## Example app

[`Example/`](Example) is a SwiftUI app with a notification service extension.
Put your values in `Example/Config/Local.xcconfig` (git-ignored):

```
DAK_APP_ID = YOUR_APP_ID
DAK_BASE_URL = https:/$()/push.example.com
DEVELOPMENT_TEAM = YOUR_TEAM_ID
DAK_EXAMPLE_BUNDLE_ID = com.example.dakpush
```

(`/$()/` because `//` starts a comment in xcconfig files.) Then open
`Example/DakPushExample.xcodeproj` and run. Without a team the simulator build
is signed to run locally; its "Use a made-up token" button registers without
APNs, to try the rest against a local `dak serve`.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the tests and the layout of the
code.

## Security

Report security problems privately, as [SECURITY.md](SECURITY.md) describes,
not in a public issue.

## License

[MIT](LICENSE)
