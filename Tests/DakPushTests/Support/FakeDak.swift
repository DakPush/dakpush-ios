import CryptoKit
import Foundation

@testable import DakPush

/// Dak's SDK endpoints as the real server answers them, behind URLProtocol:
/// registration takes over the row of a known token, PATCH needs the device
/// secret, identity verification checks the auth hash, tags are validated,
/// and opens and receipts are recorded. Each instance has a host of its own
/// (https://<id>.dak.test), so tests never see each other's calls.
final class FakeDak: @unchecked Sendable {
    struct Device {
        let id: String
        var secret: String
        var fields: [String: JSON]
    }

    struct Call {
        let method: String
        let path: String
        let headers: [String: String]
        let body: [String: JSON]?

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    /// An answer given instead of the normal one.
    enum Answer {
        case status(Int, body: String = "", headers: [String: String] = [:])
        /// The request fails as if the network were down.
        case fail(URLError.Code)
        /// Headers come, the body never does.
        case stall
        /// The server's normal answer (to queue one between others).
        case normal
    }

    let host = "fake-\(UUID().uuidString.lowercased()).dak.test"
    let appId: String
    private let lock = NSLock()
    private var devicesStore: [String: Device] = [:]
    private var callsStore: [Call] = []
    private var queuedStore: [Answer] = []
    var opens: [(id: String, action: String?)] { locked { opensStore } }
    var receipts: [String] { locked { receiptsStore } }
    private var opensStore: [(id: String, action: String?)] = []
    private var receiptsStore: [String] = []
    private var identitySecretStore: String?
    private var inAppStore: [JSON] = []
    private var inAppEtagStore = "\"v1\""
    private var inAppEventsStore: [[String: JSON]] = []
    private var offlineStore = false
    private var interceptStore: ((String, String) -> Answer?)?

    var baseURL: String { "https://\(host)" }

    init(appId: String = "01a1-test-app") {
        self.appId = appId
        FakeDakProtocol.register(self)
    }

    deinit {
        FakeDakProtocol.unregister(host)
    }

    /// Like `dak app set --identity-verification`; nil leaves it off.
    var identitySecret: String? {
        get { locked { identitySecretStore } }
        set { locked { identitySecretStore = newValue } }
    }

    var devices: [String: Device] { locked { devicesStore } }
    var calls: [Call] { locked { callsStore } }

    /// The in-app messages every device gets.
    var inApp: [JSON] {
        get { locked { inAppStore } }
        set { locked { inAppStore = newValue } }
    }

    /// The ETag of the in-app list; If-None-Match with it gets a 304.
    var inAppEtag: String {
        get { locked { inAppEtagStore } }
        set { locked { inAppEtagStore = newValue } }
    }

    /// In-app events as they came, in order.
    var inAppEvents: [[String: JSON]] { locked { inAppEventsStore } }

    /// Every call fails as if the phone had no network.
    var offline: Bool {
        get { locked { offlineStore } }
        set { locked { offlineStore = newValue } }
    }

    /// Answers instead of the normal one when it returns one (method, path).
    var intercept: ((String, String) -> Answer?)? {
        get { locked { interceptStore } }
        set { locked { interceptStore = newValue } }
    }

    /// A device known to the server, as if it had registered.
    func addDevice(_ id: String, secret: String) {
        locked { devicesStore[id] = Device(id: id, secret: secret, fields: ["tags": .object([:])]) }
    }

    /// Answers to give before the normal ones, in order.
    func queue(_ answers: Answer...) {
        locked { queuedStore.append(contentsOf: answers) }
    }

    func forget(_ deviceId: String) {
        locked { _ = devicesStore.removeValue(forKey: deviceId) }
    }

    func calls(_ method: String, _ suffix: String = "") -> [Call] {
        calls.filter { $0.method == method && $0.path.hasSuffix(suffix) }
    }

    var registrations: [Call] { calls("POST", "/devices") }
    var patches: [Call] { calls.filter { $0.method == "PATCH" } }

    /// The device of [token], if registered.
    func device(token: String) -> Device? {
        devices.values.first { $0.fields["token"]?.string == token }
    }

    func device(_ id: String?) -> Device? {
        id.flatMap { devices[$0] }
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    // MARK: - Answers

    fileprivate func answer(_ request: URLRequest, body: Data?) -> Answer {
        lock.lock()
        defer { lock.unlock() }
        let path = request.url?.path ?? ""
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let js = body.flatMap(JSON.decodeObject)
        callsStore.append(Call(method: request.httpMethod ?? "GET", path: path, headers: headers, body: js))
        if offlineStore { return .fail(.notConnectedToInternet) }
        if let answer = interceptStore?(request.httpMethod ?? "GET", path) { return answer }
        if !queuedStore.isEmpty {
            let next = queuedStore.removeFirst()
            if case .normal = next {} else { return next }
        }

        let prefix = "/v1/apps/\(appId)/devices"
        guard path.hasPrefix(prefix) else { return error(404, "not_found", "unknown app") }
        let rest = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        switch (method, rest.count) {
        case ("POST", 0):
            return register(js ?? [:])
        case ("PATCH", 1):
            return withDevice(rest[0], headers) { update(&$0, js ?? [:]) }
        case ("POST", 2) where rest[1] == "opened":
            return withDevice(rest[0], headers) { _ in
                opensStore.append((js?["message_id"]?.string ?? "", js?["action_id"]?.string))
                return .status(204)
            }
        case ("POST", 2) where rest[1] == "delivered":
            return withDevice(rest[0], headers, receipts: true) { _ in
                let ids = js?["message_ids"]?.array?.compactMap(\.string) ?? js?["message_id"]?.string.map { [$0] } ?? []
                receiptsStore.append(contentsOf: ids)
                return .status(204)
            }
        case ("GET", 2) where rest[1] == "in-app":
            return withDevice(rest[0], headers) { _ in
                if headers["if-none-match"] == inAppEtagStore {
                    return .status(304, headers: ["ETag": inAppEtagStore])
                }
                let body = String(decoding: JSON.encode(["messages": .array(inAppStore)]), as: UTF8.self)
                return .status(200, body: body, headers: ["ETag": inAppEtagStore])
            }
        case ("POST", 3) where rest[1] == "in-app" && rest[2] == "events":
            return withDevice(rest[0], headers) { _ in
                let events = js?["events"]?.array?.compactMap(\.object) ?? []
                if events.count > 100 { return error(422, "invalid", "at most 100 events per request", field: "events") }
                inAppEventsStore.append(contentsOf: events)
                return .status(200, body: "{\"accepted\":\(events.count)}")
            }
        default:
            return error(404, "not_found", "no route")
        }
    }

    private func register(_ body: [String: JSON]) -> Answer {
        guard let token = body["token"]?.string else {
            return error(422, "invalid", "token and platform are required", field: "token")
        }
        let existing = devicesStore.values.first { $0.fields["token"]?.string == token }
        var fields = existing?.fields ?? ["tags": .object([:]), "subscribed": .bool(true)]
        if let refusal = apply(&fields, body) { return refusal }
        let secret = UUID().uuidString
        var device = existing ?? Device(id: UUID().uuidString.lowercased(), secret: secret, fields: fields)
        device.fields = fields
        device.secret = secret
        devicesStore[device.id] = device
        let out = JSON.encode(["device_id": .string(device.id), "device_secret": .string(secret)])
        return .status(existing == nil ? 201 : 200, body: String(decoding: out, as: UTF8.self))
    }

    private func update(_ device: inout Device, _ body: [String: JSON]) -> Answer {
        var fields = device.fields
        if let refusal = apply(&fields, body) { return refusal }
        device.fields = fields
        return .status(200, body: String(decoding: JSON.encode(["device": .object(fields)]), as: UTF8.self))
    }

    /// Validates and copies [body] onto [fields], or returns the refusal.
    private func apply(_ fields: inout [String: JSON], _ body: [String: JSON]) -> Answer? {
        if body["token_type"] != nil && body["token"] == nil {
            return error(422, "invalid", "send token_type together with token", field: "token_type")
        }
        if let token = body["token"]?.string {
            let type = body["token_type"]?.string ?? "token"
            if type == "apns" && (body["platform"]?.string ?? fields["platform"]?.string) != "ios" {
                return error(422, "invalid", "apns tokens are for ios", field: "token_type")
            }
            fields["token"] = .string(type == "apns" ? token.lowercased() : token)
            fields["token_type"] = .string(type)
        }
        for k in ["platform", "app_version", "os_version", "sdk_version", "language", "push_permission", "subscribed"] {
            if let v = body[k] { fields[k] = v }
        }
        if let v = body["external_id"] {
            if let id = v.string, !id.isEmpty {
                if let secret = identitySecretStore, body["auth_hash"]?.string != Self.hmac(secret, id) {
                    return error(403, "identity_verification_failed", "auth_hash does not match external_id")
                }
                fields["external_id"] = .string(id)
            } else {
                fields["external_id"] = .null
            }
        }
        if let v = body["utc_offset_minutes"] { fields["utc_offset_minutes"] = v }
        if let tags = body["tags"]?.object {
            var merged = fields["tags"]?.object ?? [:]
            for (k, v) in tags {
                if v == .null || v == .string("") {
                    merged.removeValue(forKey: k)
                } else {
                    let text = v.string ?? "\(v.any)"
                    if text.utf8.count > 255 { return error(422, "invalid", "tag \(k) is too long", field: "tags") }
                    merged[k] = .string(text)
                }
            }
            fields["tags"] = .object(merged)
        }
        return nil
    }

    private func withDevice(
        _ id: String, _ headers: [String: String], receipts: Bool = false, _ then: (inout Device) -> Answer
    ) -> Answer {
        guard var device = devicesStore[id] else { return unauthorized() }
        let auth = headers["authorization"]
        let ok = auth == "Device \(device.secret)" || (receipts && auth == "Receipt \(receiptToken(device.secret))")
        guard ok else { return unauthorized() }
        let out = then(&device)
        devicesStore[id] = device
        return out
    }

    private func unauthorized() -> Answer {
        error(401, "unauthorized", "unknown device or wrong device secret; register again")
    }

    func error(_ status: Int, _ code: String, _ message: String, field: String? = nil) -> Answer {
        var err: [String: JSON] = ["code": .string(code), "message": .string(message)]
        if let field { err["field"] = .string(field) }
        return .status(status, body: String(decoding: JSON.encode(["error": .object(err)]), as: UTF8.self))
    }

    static func hmac(_ secret: String, _ message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Hands requests for *.dak.test to their FakeDak.
final class FakeDakProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: FakeDak] = [:]
    private var stalled = false

    static func register(_ server: FakeDak) {
        lock.lock()
        servers[server.host] = server
        lock.unlock()
    }

    static func unregister(_ host: String) {
        lock.lock()
        servers.removeValue(forKey: host)
        lock.unlock()
    }

    private static func server(_ host: String?) -> FakeDak? {
        lock.lock()
        defer { lock.unlock() }
        return host.flatMap { servers[$0] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".dak.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server(request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch server.answer(request, body: Self.body(of: request)) {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .normal:
            preconditionFailure("answered above")
        case .stall:
            stalled = true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        case .status(let status, let body, let headers):
            var all = headers
            if !body.isEmpty { all["Content-Type"] = all["Content-Type"] ?? "application/json" }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands the body over as a stream.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
