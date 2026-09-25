import Foundation
import Network
import Security

/// One dictation as served to the local agent harness. Built field by field so
/// the audio path (and anything else in `DictationRecord`) can never leak.
struct LocalAPIDictation: Encodable, Equatable {
    var id: String
    var timestamp: String
    var deviceName: String
    var modeId: String
    var rawTranscription: String
    var finalTranscription: String
    var processingStatus: String
    var duration: Double
    var patientContext: String?

    static let localDeviceName = "Ce Mac"

    init(_ record: DictationRecord, deviceName: String?) {
        id = record.id; timestamp = record.timestamp; self.deviceName = deviceName ?? Self.localDeviceName
        modeId = record.modeId; rawTranscription = record.rawTranscription; finalTranscription = record.finalTranscription
        processingStatus = record.processingStatus; duration = record.duration; patientContext = record.patientContext
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, deviceName, modeId, rawTranscription, finalTranscription, processingStatus, duration, patientContext
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(modeId, forKey: .modeId)
        try container.encode(rawTranscription, forKey: .rawTranscription)
        try container.encode(finalTranscription, forKey: .finalTranscription)
        try container.encode(processingStatus, forKey: .processingStatus)
        try container.encode(duration, forKey: .duration)
        // Explicit null: a harness must see "no patient declared", not a missing key.
        if let patientContext { try container.encode(patientContext, forKey: .patientContext) }
        else { try container.encodeNil(forKey: .patientContext) }
    }
}

/// Loopback HTTP API for the local agent harness (`127.0.0.1:47367`).
///
/// - `GET  /v1/dictations?since=<id>&wait=<s>` records created after `since`
///   (oldest first); with `wait` (≤ 25 s) and nothing to return, the request
///   is held until the history changes or the wait expires.
/// - `GET  /v1/dictations/<id>`
/// - `POST /v1/dictations/<id>/retranscribe`
/// - `GET|POST /v1/patient-context` `{"patientContext": "…" | null}`
///
/// Every route requires `Authorization: Bearer <token>`. Responses use the same
/// envelope as `agent/voxlocal_agent_api.py`. The listener binds 127.0.0.1 only
/// and refuses non-loopback peers.
final class LocalAPIServer {
    static let defaultPort: UInt16 = 47367
    static let maxWait: Double = 25
    static let maxRequestBytes = 64 * 1024
    static let maxPatientContextBytes = 512

    enum Retranscribe { case accepted, busy, notFound }

    var onStateChanged: ((Bool, String) -> Void)?
    var onPatientContextChanged: ((String?) -> Void)?
    /// Called on the main queue; the app decides whether the pipeline is free.
    var retranscribe: ((DictationRecord, @escaping (Retranscribe) -> Void) -> Void)?

    private let history: HistoryRepository
    private let token: String
    private let requestedPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.voxlocal.local-api")
    private var listener: NWListener?
    private var waiters: [UUID: Waiter] = [:]
    private(set) var port: UInt16?

    private struct Waiter {
        let since: String?
        let timer: DispatchSourceTimer
        let respond: (HTTPResponse) -> Void
    }

    init(history: HistoryRepository, token: String, port: UInt16 = LocalAPIServer.defaultPort) {
        self.history = history
        self.token = token
        requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
    }

    /// Blocks up to 3 s for the listener to be ready; returns the bound port.
    @discardableResult func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requestedPort)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = listener?.port?.rawValue
                self.report(true, "Écoute sur 127.0.0.1:\(self.port ?? 0)")
                ready.signal()
            case .failed(let error):
                failure = error
                self.report(false, "API locale arrêtée : \(error.localizedDescription)")
                ready.signal()
            case .cancelled:
                self.report(false, "API locale arrêtée.")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 3) == .timedOut { listener.cancel(); throw VoxError.message("Le port 127.0.0.1:\(requestedPort) ne répond pas.") }
        if let failure { listener.cancel(); self.listener = nil; throw VoxError.message("Port 127.0.0.1:\(requestedPort) indisponible : \(failure.localizedDescription)") }
        return port ?? 0
    }

    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil; port = nil
            for waiter in waiters.values { waiter.timer.cancel(); waiter.respond(Self.ok(["dictations": [LocalAPIDictation]()])) }
            waiters.removeAll()
        }
    }

    /// Wakes long-polls; call after any history change.
    func notifyHistoryChanged() {
        queue.async { [weak self] in self?.wakeWaiters() }
    }

    private func report(_ running: Bool, _ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(running, message) }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        if case .hostPort(let host, _) = connection.endpoint, !Self.isLoopback(host) { connection.cancel(); return }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 10, execute: deadline)
        receive(connection, buffer: Data()) { [weak self] request in
            deadline.cancel()
            guard let self else { connection.cancel(); return }
            self.route(request) { response in self.send(response, on: connection) }
        }
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback || address.asIPv4 == .loopback
        case .name(let name, _): return name == "localhost" || name == "127.0.0.1"
        @unknown default: return false
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data, completion: @escaping (Result<HTTPRequest, HTTPResponse>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard self != nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes { completion(.failure(Self.error(413, "request_too_large", "Requête trop volumineuse."))); return }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request): completion(.success(request))
            case .invalid: completion(.failure(Self.error(400, "invalid_request", "Requête HTTP invalide.")))
            case .incomplete:
                if complete || error != nil { connection.cancel(); return }
                self?.receive(connection, buffer: buffer, completion: completion)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Routing (runs on `queue`)

    private func route(_ parsed: Result<HTTPRequest, HTTPResponse>, respond: @escaping (HTTPResponse) -> Void) {
        let request: HTTPRequest
        switch parsed {
        case .failure(let response): respond(response); return
        case .success(let value): request = value
        }
        guard authorized(request) else { respond(Self.error(401, "unauthorized", "Bearer token requis.")); return }
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch (request.method, parts) {
        case ("GET", ["v1", "dictations"]):
            listDictations(request, respond: respond)
        case ("GET", let p) where p.count == 3 && p[0] == "v1" && p[1] == "dictations":
            guard let record = record(p[2]) else { respond(Self.error(404, "not_found", "Dictée introuvable.")); return }
            respond(Self.ok(serve(record)))
        case ("POST", let p) where p.count == 4 && p[0] == "v1" && p[1] == "dictations" && p[3] == "retranscribe":
            startRetranscription(p[2], respond: respond)
        case ("GET", ["v1", "patient-context"]):
            respond(Self.ok(PatientContextBody(patientContext: history.patientContext)))
        case ("POST", ["v1", "patient-context"]):
            setPatientContext(request.body, respond: respond)
        default:
            respond(Self.error(404, "not_found", "Endpoint inconnu."))
        }
    }

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let supplied = Array(header.dropFirst(7).utf8), expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func listDictations(_ request: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        let since = request.query["since"].flatMap { $0.isEmpty ? nil : $0 }
        var wait = 0.0
        if let raw = request.query["wait"] {
            guard let value = Double(raw), value.isFinite, value >= 0 else { respond(Self.error(400, "invalid_wait", "wait doit être un nombre de secondes ≥ 0.")); return }
            wait = min(value, Self.maxWait)
        }
        let result: [DictationRecord]
        switch newer(than: since) {
        case .failure(let response): respond(response); return
        case .success(let records): result = records
        }
        if !result.isEmpty || wait == 0 { respond(Self.ok(["dictations": result.map(serve)])); return }
        let id = UUID()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + wait)
        timer.setEventHandler { [weak self] in
            guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
            waiter.timer.cancel()
            waiter.respond(self.listing(since: waiter.since))
        }
        waiters[id] = Waiter(since: since, timer: timer, respond: respond)
        timer.resume()
    }

    private func wakeWaiters() {
        for (id, waiter) in waiters {
            guard case .success(let records) = newer(than: waiter.since), !records.isEmpty else { continue }
            waiters.removeValue(forKey: id)
            waiter.timer.cancel()
            waiter.respond(Self.ok(["dictations": records.map(serve)]))
        }
    }

    private func listing(since: String?) -> HTTPResponse {
        switch newer(than: since) {
        case .failure(let response): return response
        case .success(let records): return Self.ok(["dictations": records.map(serve)])
        }
    }

    /// Oldest first. `timestamp` has one-second resolution, so two dictations
    /// created in the same second are ordered by their folder's creation date
    /// (sub-second on APFS), then by id: a cursor never skips a sibling.
    /// `since` must name an existing record.
    private func newer(than since: String?) -> Result<[DictationRecord], HTTPResponse> {
        let all = history.list().map { record -> (key: OrderKey, record: DictationRecord) in
            let folder = history.directory.appendingPathComponent(record.id)
            let created = ((try? FileManager.default.attributesOfItem(atPath: folder.path)[.creationDate]) as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return (OrderKey(timestamp: record.timestamp, created: created, id: record.id), record)
        }.sorted { $0.key < $1.key }
        guard let since else { return .success(all.map(\.record)) }
        guard let anchor = all.first(where: { $0.record.id == since }) else {
            return .failure(Self.error(404, "since_not_found", "Dictée « since » introuvable."))
        }
        return .success(all.filter { $0.key > anchor.key }.map(\.record))
    }

    private struct OrderKey: Comparable {
        let timestamp: String; let created: Double; let id: String
        static func < (a: OrderKey, b: OrderKey) -> Bool { (a.timestamp, a.created, a.id) < (b.timestamp, b.created, b.id) }
    }

    private func record(_ id: String) -> DictationRecord? { history.list().first { $0.id == id } }

    private func serve(_ record: DictationRecord) -> LocalAPIDictation {
        LocalAPIDictation(record, deviceName: VoxLocalRemoteBackend.remoteDevice(of: record))
    }

    private func startRetranscription(_ id: String, respond: @escaping (HTTPResponse) -> Void) {
        guard let record = record(id) else { respond(Self.error(404, "not_found", "Dictée introuvable.")); return }
        guard let retranscribe else { respond(Self.error(503, "capability_unavailable", "Retranscription indisponible.")); return }
        let queue = self.queue
        DispatchQueue.main.async {
            retranscribe(record) { outcome in
                queue.async {
                    switch outcome {
                    case .accepted: respond(Self.ok(["id": id, "status": "processing"], status: 202))
                    case .busy: respond(Self.error(409, "busy", "Un traitement est déjà en cours.", retryable: true))
                    case .notFound: respond(Self.error(404, "not_found", "Audio de la dictée introuvable."))
                    }
                }
            }
        }
    }

    private struct PatientContextBody: Encodable {
        var patientContext: String?
        private enum CodingKeys: String, CodingKey { case patientContext }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let patientContext { try container.encode(patientContext, forKey: .patientContext) } else { try container.encodeNil(forKey: .patientContext) }
        }
    }

    private func setPatientContext(_ body: Data, respond: @escaping (HTTPResponse) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object.keys.contains("patientContext") else {
            respond(Self.error(400, "invalid_json", "JSON {\"patientContext\": \"…\" | null} requis.")); return
        }
        var value: String?
        switch object["patientContext"] {
        case is NSNull: value = nil
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf8.count <= Self.maxPatientContextBytes, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                respond(Self.error(400, "invalid_patient_context", "patientContext : une ligne de 512 octets maximum.")); return
            }
            value = trimmed.isEmpty ? nil : trimmed
        default:
            respond(Self.error(400, "invalid_patient_context", "patientContext doit être une chaîne ou null.")); return
        }
        history.patientContext = value
        DispatchQueue.main.async { [weak self] in self?.onPatientContextChanged?(value) }
        respond(Self.ok(PatientContextBody(patientContext: value)))
    }

    // MARK: Envelope

    private struct Envelope<T: Encodable>: Encodable { let ok = true; let apiVersion = "1"; let data: T }
    private struct ErrorBody: Encodable { let code: String; let message: String; let retryable: Bool }
    private struct ErrorEnvelope: Encodable { let ok = false; let apiVersion = "1"; let error: ErrorBody }

    static func ok<T: Encodable>(_ data: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(Envelope(data: data))) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ code: String, _ message: String, retryable: Bool = false) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(ErrorEnvelope(error: ErrorBody(code: code, message: message, retryable: retryable)))) ?? Data("{}".utf8))
    }

    // MARK: Token

    private static let tokenService = "com.voxlocal.local-api"
    private static let tokenAccount = "token"

    /// 32 random bytes (SecRandomCopyBytes), base64url without padding.
    static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VoxError.message("Générateur aléatoire indisponible : token non créé.")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Reads the Keychain token, creating it on first use. Throws when the
    /// Keychain is locked or denied, so a failure never silently rotates it.
    static func keychainToken() throws -> String {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService, kSecAttrAccount as String: tokenAccount]
        var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty { return token }
        guard status == errSecItemNotFound else { throw VoxError.message("Lecture du token de l’API locale impossible dans le trousseau macOS (OSStatus \(status)).") }
        let token = try generateToken()
        var add = base; add[kSecValueData as String] = Data(token.utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VoxError.message("Impossible d’enregistrer le token de l’API locale dans le trousseau macOS.") }
        return token
    }
}

// MARK: Minimal HTTP/1.1

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    enum Parse { case complete(HTTPRequest), incomplete, invalid }

    static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              let components = URLComponents(string: String(requestLine[1])) else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { return .invalid }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: components.path, query: query, headers: headers, body: Data(body.prefix(length))))
    }
}

struct HTTPResponse: Error {
    var status: Int
    var body: Data

    func serialized() -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n"
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }
}
