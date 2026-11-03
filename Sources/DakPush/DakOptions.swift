import UserNotifications

/// Settings for ``Dak/initialize(appId:baseURL:options:)``. All of them have
/// defaults.
///
/// ```swift
/// DakOptions(appGroup: "group.com.example.app.dakpush", shareTimezoneOffset: true)
/// ```
public struct DakOptions: Sendable {
    /// The App Group the app shares with its notification service extension
    /// (DakPushExtension), so the extension can report deliveries and badge
    /// increments. Without it, pushes count as delivered only when the app
    /// sees them (open, or tapped).
    public var appGroup: String?

    /// Send the phone's UTC offset in minutes (only the offset, like +360),
    /// so pushes can go at the user's local time and respect quiet hours. Off
    /// by default; then the app's timezone is used.
    public var shareTimezoneOffset: Bool

    /// How a DakPush notification shows while the app is open, unless
    /// ``Dak/setForegroundPresentation(_:)`` decides per message. `[]` shows
    /// nothing (the foreground listeners still get it).
    public var foregroundPresentation: UNNotificationPresentationOptions

    /// Call `UIApplication.registerForRemoteNotifications()` at every start,
    /// as Apple recommends, to get the APNs token. It never shows a prompt.
    public var registerForRemoteNotifications: Bool

    /// Log what the SDK does (Console.app, subsystem "dakpush").
    public var debugLogs: Bool

    public init(
        appGroup: String? = nil,
        shareTimezoneOffset: Bool = false,
        foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound, .badge],
        registerForRemoteNotifications: Bool = true,
        debugLogs: Bool = false
    ) {
        self.appGroup = appGroup
        self.shareTimezoneOffset = shareTimezoneOffset
        self.foregroundPresentation = foregroundPresentation
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.debugLogs = debugLogs
    }
}
