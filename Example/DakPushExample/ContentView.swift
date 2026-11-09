import DakPush
import SwiftUI
import UIKit

@MainActor
final class ExampleModel: ObservableObject {
    @Published var started = false
    @Published var deviceId: String?
    @Published var token = ""
    @Published var permission = false
    @Published var lines: [String] = []

    func log(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        lines.insert("\(time)  \(line)", at: 0)
        if lines.count > 100 { lines.removeLast() }
        print("example: \(line)")
    }

    func refreshPermission() async {
        permission = await Dak.hasPermission()
    }
}

struct ContentView: View {
    @ObservedObject var model: ExampleModel
    @State private var userId = ""
    @State private var authHash = ""
    @State private var tagKey = "level"
    @State private var tagValue = "b2"
    @State private var subscribed = true
    @State private var inAppPaused = false
    @State private var showCall = false
    @State private var note = ""
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationView {
            Form {
                Section("Device") {
                    row("SDK", "DakPush iOS \(Dak.version)")
                    row("Device id", model.deviceId ?? "not registered yet")
                    row("APNs token", model.token.isEmpty ? "none yet" : "\(model.token.prefix(12))…")
                    row("Notifications", model.permission ? "allowed" : "not allowed")
                }
                Section("Permission") {
                    Button("Ask to allow notifications") { ask(provisional: false) }
                    Button("Allow quietly (provisional, no prompt)") { ask(provisional: true) }
                    Button("Notification settings") { Dak.openNotificationSettings() }
                }
                Section("User") {
                    TextField("User id", text: $userId).textInputAutocapitalization(.never)
                    TextField("Auth hash from your server", text: $authHash).textInputAutocapitalization(.never)
                    Button("Log in") {
                        Dak.login(userId, authHash: authHash) { e in model.log(e.map { "login refused: \($0.code)" } ?? "logged in as \(userId)") }
                    }
                    .disabled(userId.isEmpty)
                    Button("Log out") { Dak.logout { e in model.log(e.map { "logout: \($0.code)" } ?? "logged out") } }
                }
                Section("Tags") {
                    TextField("Key", text: $tagKey).textInputAutocapitalization(.never)
                    TextField("Value (empty removes it)", text: $tagValue)
                    Button("Set tag") {
                        Dak.setTag(tagKey, tagValue) { e in model.log(e.map { "tag refused: \($0.message)" } ?? "tag \(tagKey) set") }
                    }
                }
                Section("Pushes") {
                    Toggle("Get pushes", isOn: $subscribed)
                        .onChange(of: subscribed) { on in Dak.setSubscribed(on) { _ in model.log(on ? "subscribed" : "opted out") } }
                    Button("Clear the badge") { Dak.setBadge(0) }
                    #if DEBUG
                        // The simulator gets no APNs token without a team that has Push
                        // Notifications; this registers a made-up one to try the rest.
                        Button("Use a made-up token (simulator)") {
                            Dak.setDeviceToken(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
                            model.log("made-up token sent")
                        }
                    #endif
                }
                Section("In-app messages") {
                    // Triggers: conditions a message can wait for (custom
                    // triggers in the dashboard). Kept in memory only.
                    Button("Trigger: screen = home") {
                        Dak.addTrigger("screen", "home")
                        model.log("trigger screen = home")
                    }
                    Button("Trigger: screen = cart") {
                        Dak.addTrigger("screen", "cart")
                        model.log("trigger screen = cart")
                    }
                    Button("Trigger: lessons_done = 3") {
                        Dak.addTrigger("lessons_done", 3)
                        model.log("trigger lessons_done = 3")
                    }
                    Button("Remove all triggers") {
                        Dak.clearTriggers()
                        model.log("triggers removed")
                    }
                    Toggle("Pause in-app messages", isOn: $inAppPaused)
                        .onChange(of: inAppPaused) { on in Dak.pauseInApp(on) }
                    Button("Fetch messages now") {
                        Task {
                            await Dak.refreshInApp()
                            model.log("in-app messages fetched")
                        }
                    }
                    Button("Open a call screen (keeps messages away)") { showCall = true }
                    if UIApplication.shared.supportsMultipleScenes {
                        // iPad: a message shows in the window the user is in.
                        Button("Open another window") {
                            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
                        }
                    }
                    TextField("Type here: a modal message takes the keyboard", text: $note)
                }
                Section("Log") {
                    ForEach(model.lines, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
            .navigationTitle("DakPush")
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: $showCall) { CallScreen { showCall = false } }
        .task { await model.refreshPermission() }
        .onChange(of: phase) { p in if p == .active { Task { await model.refreshPermission() } } }
    }

    /// LabeledContent needs iOS 16.
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }

    private func ask(provisional: Bool) {
        Dak.requestPermission(provisional: provisional) { granted in
            model.log("permission: \(granted ? "allowed" : "not allowed")\(provisional ? " (provisional)" : "")")
            Task { await model.refreshPermission() }
        }
    }
}

/// A screen that must not be covered: in-app messages wait until it closes.
struct CallScreen: View {
    let hangUp: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "phone.fill").font(.system(size: 56)).foregroundColor(.green)
            Text("On a call").font(.title.bold())
            Text("In-app messages are kept away while this screen is open.")
                .multilineTextAlignment(.center).foregroundColor(.secondary).padding(.horizontal, 32)
            Spacer()
            Button(action: hangUp) {
                Text("Hang up").bold().frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent).tint(.red).padding(.horizontal, 32).padding(.bottom, 24)
        }
        .dakInAppBlocked()
    }
}
