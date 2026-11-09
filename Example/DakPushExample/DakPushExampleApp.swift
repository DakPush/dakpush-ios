import DakPush
import SwiftUI
import UIKit

@main
struct DakPushExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.model)
        }
    }
}

/// The SDK starts in the app delegate, so the tap that launches the app is seen.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = ExampleModel()

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard let config = ExampleConfig.fromInfoPlist() else {
            model.log("Set DAK_APP_ID in Example/Config/Local.xcconfig, then run again")
            return true
        }
        Dak.initialize(
            appId: config.appId, baseURL: config.baseURL,
            options: DakOptions(appGroup: config.appGroup, shareTimezoneOffset: true, debugLogs: true))
        Dak.installNotificationDelegate()
        Dak.addDeviceIdListener { [model] id in
            model.deviceId = id
            model.log("device \(id)")
        }
        Dak.addOpenedListener { [model] n in
            model.log("opened \(n.id ?? "-") button \(n.actionId ?? "-") url \(n.url ?? "-")")
        }
        Dak.addForegroundListener { [model] n in
            model.log("arrived while open: \(n.title ?? n.body ?? "(silent)")")
        }
        Dak.addErrorListener { [model] e in
            model.log("refused: \(e.code) \(e.field ?? "") \(e.message)")
        }
        // Taps on in-app messages: deep links are the app's to route.
        Dak.addInAppClickListener { [model] click in
            model.log("in-app click \(click.messageId.prefix(8)) button \(click.buttonId ?? "-") \(click.actionType.rawValue) \(click.url ?? "")")
        }
        model.started = true
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.token = deviceToken.map { String(format: "%02x", $0) }.joined()
        model.log("APNs token \(model.token.prefix(12))…")
        Dak.setDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.log("no APNs token: \(error.localizedDescription)")
        Dak.failedToRegister(with: error)
    }

    /// Silent pushes.
    func application(
        _ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if !Dak.didReceiveRemoteNotification(userInfo, completion: completionHandler) {
            completionHandler(.noData)
        }
    }
}

struct ExampleConfig {
    let appId: String
    let baseURL: String
    let appGroup: String?

    /// Filled from Config.xcconfig and Local.xcconfig.
    static func fromInfoPlist() -> ExampleConfig? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let appId = info["DakAppId"] as? String, !appId.isEmpty, let baseURL = info["DakBaseURL"] as? String
        else { return nil }
        let group = info["DakAppGroup"] as? String
        return ExampleConfig(appId: appId, baseURL: baseURL, appGroup: group?.isEmpty == false ? group : nil)
    }
}
