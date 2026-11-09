import Foundation
import XCTest

@testable import DakPush

/// An in-app controller against FakeDak, on a TestScheduler: tasks run when
/// the test says so, timers when it moves the clock.
final class InAppHarness {
    let server: FakeDak
    let scheduler = TestScheduler()
    /// Network and disk; the same scheduler unless the test wants to hold
    /// them back.
    let io: TestScheduler
    let store: DakStateStore
    var registered = true
    var foreground = true
    /// The controller's clock. Timers run on the scheduler's.
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var deviceId = "dev-1"
    var secret = "secret-1"
    private(set) var clicks: [DakInAppClick] = []
    private(set) var opened: [URL] = []
    private(set) var tagsSet: [[String: String]] = []
    private(set) var logs: [String] = []
    let urlSchemes: Set<String>
    private var made: InAppController?

    init(
        server: FakeDak = FakeDak(), store: DakStateStore = MemoryStateStore(), urlSchemes: Set<String> = ["https", "http"],
        separateIO: Bool = false, registered: Bool = true, background: Bool = false
    ) {
        self.server = server
        self.store = store
        self.urlSchemes = urlSchemes
        self.registered = registered
        foreground = !background
        io = separateIO ? TestScheduler() : scheduler
        server.addDevice(deviceId, secret: secret)
    }

    lazy var api = DakApi(
        baseURL: server.baseURL, appId: server.appId, http: URLSessionHTTP(protocolClasses: [FakeDakProtocol.self]),
        userAgent: "dakpush-ios/test", timeout: 5)

    var controller: InAppController {
        if let made { return made }
        let c = InAppController(
            api: api, store: store,
            credentials: { [unowned self] in registered ? (deviceId, secret) : nil },
            setTags: { [unowned self] in tagsSet.append($0) },
            openURL: { [unowned self] in opened.append($0) },
            urlSchemes: urlSchemes, home: scheduler, io: io, clock: { [unowned self] in now },
            log: DakLog(debug: true) { [unowned self] _, m in logs.append(m) },
            isForeground: { [unowned self] in foreground }, eventDelay: nil)
        c.onClick = { [unowned self] in clicks.append($0) }
        made = c
        return c
    }

    /// Starts the controller and lets it read, fetch and choose.
    @discardableResult
    func start(attach: Bool = true) -> InAppController {
        let c = controller
        c.start()
        settle()
        if attach {
            c.attach("host")
            settle()
        }
        return c
    }

    /// Runs everything queued (both schedulers).
    func settle() {
        for _ in 0..<20 {
            scheduler.runUntilIdle()
            if io !== scheduler { io.runUntilIdle() }
            scheduler.runUntilIdle()
        }
    }

    /// The id of the message the controller wants on screen.
    var showing: String? { controller.current?.id }

    /// What the presenter does once the message is drawn.
    @discardableResult
    func display() -> String? {
        if let m = controller.current { controller.didDisplay(m) }
        settle()
        return showing
    }

    /// Closes the message on screen as the user would.
    func dismiss() {
        if let m = controller.current { controller.dismiss(m) }
        settle()
    }

    /// Leaves the app for [away] seconds and comes back.
    func background(_ away: TimeInterval) {
        controller.lifecycle(foreground: false)
        settle()
        now = now.addingTimeInterval(away)
        controller.lifecycle(foreground: true)
        settle()
    }

    func flush() {
        controller.flushEvents()
        settle()
    }

    /// The events the server got, as "type message [button]".
    var eventTypes: [String] {
        server.inAppEvents.map { e in
            [e["type"]?.string, e["message_id"]?.string, e["button_id"]?.string].compactMap { $0 }.joined(separator: " ")
        }
    }

    var inAppFetches: Int { server.calls("GET", "/in-app").count }
}

/// A Dak in-app message as the server sends it.
func inAppMessage(
    _ id: String, layout: String = "modal", priority: Int = 0, content: [String: Any] = ["title": "T"],
    triggers: [[[String: Any]]] = [], frequency: [String: Any] = ["type": "once"], shown: Int = 0,
    lastShownAt: Date? = nil, startAt: Date? = nil, endAt: Date? = nil
) -> JSON {
    var m: [String: Any] = [
        "id": id, "layout": layout, "priority": priority, "content": content, "triggers": triggers,
        "frequency": frequency, "shown": shown, "updated_at": "2026-11-01T10:00:00Z",
    ]
    if let lastShownAt { m["last_shown_at"] = InAppParse.formatTime(lastShownAt) }
    if let startAt { m["start_at"] = InAppParse.formatTime(startAt) }
    if let endAt { m["end_at"] = InAppParse.formatTime(endAt) }
    return JSON(any: m)
}

/// A custom condition on trigger "k".
func custom(_ op: String, _ value: Any? = nil) -> [String: Any] {
    var c: [String: Any] = ["kind": "custom", "key": "k", "op": op]
    if op == "in" { c["values"] = value } else if let value { c["value"] = value }
    return c
}

/// A state store that is locked (a phone not unlocked since it started).
final class LockableStore: DakStateStore {
    var value: Data?
    var locked = false

    func read() throws -> Data? {
        if locked { throw DakStoreUnavailable(description: "locked") }
        return value
    }

    func write(_ data: Data) throws {
        if locked { throw DakStoreUnavailable(description: "locked") }
        value = data
    }

    var json: [String: JSON] { value.flatMap(JSON.decodeObject) ?? [:] }
}
