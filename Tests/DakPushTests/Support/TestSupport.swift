import Foundation
import XCTest

@testable import DakPush

/// A [DakScheduler] the test drives: tasks run on the test's thread when it
/// says so, and timers fire when it moves the clock.
final class TestScheduler: DakScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [() -> Void] = []
    private var timers: [Timer] = []
    private var seq = 0
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)

    final class Timer: DakCancelable {
        let at: Date
        let seq: Int
        let task: () -> Void
        var cancelled = false

        init(at: Date, seq: Int, task: @escaping () -> Void) {
            self.at = at
            self.seq = seq
            self.task = task
        }

        func cancel() { cancelled = true }
    }

    func execute(_ task: @escaping () -> Void) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func schedule(after seconds: TimeInterval, _ task: @escaping () -> Void) -> DakCancelable {
        lock.lock()
        defer { lock.unlock() }
        seq += 1
        let t = Timer(at: now.addingTimeInterval(seconds), seq: seq, task: task)
        timers.append(t)
        return t
    }

    /// Runs the queued tasks, and those they queue, until none is left.
    func runUntilIdle() {
        while true {
            lock.lock()
            guard !tasks.isEmpty else {
                lock.unlock()
                return
            }
            let t = tasks.removeFirst()
            lock.unlock()
            t()
        }
    }

    /// Moves the clock by [seconds], firing the timers that come due on the way.
    func advance(_ seconds: TimeInterval) {
        let end = now.addingTimeInterval(seconds)
        runUntilIdle()
        while true {
            lock.lock()
            let due = timers.filter { !$0.cancelled && $0.at <= end }.min { ($0.at, $0.seq) < ($1.at, $1.seq) }
            if let due {
                timers.removeAll { $0 === due }
                now = max(now, due.at)
            }
            lock.unlock()
            guard let due else { break }
            due.task()
            runUntilIdle()
        }
        lock.lock()
        now = end
        lock.unlock()
    }

    var pendingTimers: Int {
        lock.lock()
        defer { lock.unlock() }
        return timers.filter { !$0.cancelled }.count
    }

    /// The next live timer's wait from now.
    var nextTimer: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return timers.filter { !$0.cancelled }.map { $0.at.timeIntervalSince(now) }.min()
    }
}

final class MemoryStateStore: DakStateStore {
    var value: Data?
    /// Thrown by reads and writes while set.
    var failure: Error?
    var writes = 0

    func read() throws -> Data? {
        if let failure { throw failure }
        return value
    }

    func write(_ data: Data) throws {
        if let failure { throw failure }
        value = data
        writes += 1
    }

    var json: [String: JSON] { value.flatMap(JSON.decodeObject) ?? [:] }
}

final class MemorySecretStore: DakSecretStore {
    var value: DakDeviceSecret?
    var failure: Error?

    func read() throws -> DakDeviceSecret? {
        if let failure { throw failure }
        return value
    }

    func write(_ secret: DakDeviceSecret) throws {
        if let failure { throw failure }
        value = secret
    }

    func delete() throws {
        if let failure { throw failure }
        value = nil
    }
}

final class FakePlatform: DakPlatformInfo {
    var appVersionValue = "1.2.0+7"
    var osVersionValue = "26.1"
    var languageValue = "bn"
    var offset = 360
    var permission = true
    var protectedDataAvailable = true

    func appVersion() -> String { appVersionValue }
    func osVersion() -> String { osVersionValue }
    func language() -> String { languageValue }
    func utcOffsetMinutes() -> Int { offset }
    func notificationsEnabled() -> Bool { permission }
}

final class RecordingEvents: DakClientEvents {
    var deviceIds: [String] = []
    var errors: [DakError] = []

    func deviceId(_ id: String) { deviceIds.append(id) }
    func error(_ error: DakError) { errors.append(error) }
}

/// A made-up APNs token: 32 bytes in hex.
func apnsToken(_ n: Int = 1) -> String {
    String(repeating: String(format: "%02x", n % 256), count: 32)
}

extension XCTestCase {
    /// Waits for [condition] on the main run loop (listeners run on main).
    func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end {
                XCTFail("timed out", file: file, line: line)
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
