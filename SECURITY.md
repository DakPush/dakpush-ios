# Security policy

## Supported versions

The SDK is below 1.0, so only the newest release gets security fixes. Fixes go
into a new patch release; update to it.

| Version | Supported |
|---|---|
| Newest 0.x release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do not open a public issue, discussion or pull request for a security
problem.

Report it privately on GitHub: open the repository's **Security** tab and
choose **Report a vulnerability**. Only the maintainers can see the report.

Include what you can of:

- the affected version or commit, the iOS version and the Xcode version;
- what an attacker can do, and what they need first (another app on the
  phone, a network position, a stolen device, access to the DakPush server);
- steps or a small app that shows the problem.

## What happens next

- We aim to confirm we received the report within 3 working days and to give a
  first assessment within 7.
- We fix confirmed problems in a new release and publish a GitHub security
  advisory with it. Unless you prefer otherwise, the advisory credits you.
- Please give us 90 days, or until the fix is released if that is sooner,
  before you disclose the problem publicly. If a problem is already being
  exploited, we will move faster and tell you.

## Scope

In scope: this repository, both libraries and the example app.

Report problems in the DakPush server the same way; we pass them on.

## How the SDK handles secrets

Useful context for a report:

- The device secret the server issues is kept in the keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: not in backups, not on
  another phone). It is sent only to the `baseURL` given to
  `Dak.initialize`, which must be `https` (plain `http` only for `localhost`
  and `127.0.0.1`), and the SDK never follows a redirect.
- The notification service extension never sees the device secret. The app
  shares, through its App Group, a receipt token (hex SHA-256 of the secret),
  which the server accepts only for reporting deliveries.
- The rest of the state (device id, user id, tags, pending changes) is a file
  in Application Support/DakPush, left out of backups and readable after the
  first unlock.
- The identity verification hash (`authHash`) is an HMAC your server
  computes. The identity secret must never be in the app.
- Opens are reported only for notifications iOS hands the app through
  `UNUserNotificationCenter`; a response passed more than once counts once.
