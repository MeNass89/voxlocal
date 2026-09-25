import Foundation
import Network

struct DiscoveredRemoteScribeServer: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    let availableBackends: [RemoteBackendKind]
    let protocolVersion: Int?

    var id: String { "\(name)-\(endpoint)" }
}

final class RemoteScribeBrowser {
    var onServersChanged: (([DiscoveredRemoteScribeServer]) -> Void)?
    var onError: ((Error) -> Void)?
    private let browser = NWBrowser(for: .bonjour(type: RemoteScribeProtocol.serviceType, domain: nil), using: .tcp)
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.browser")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onError?(error) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let servers = results.compactMap { result -> DiscoveredRemoteScribeServer? in
                guard case let .service(name: name, type: _, domain: _, interface: _) = result.endpoint else { return nil }
                let metadata = self.metadata(from: result.metadata)
                return DiscoveredRemoteScribeServer(name: name, endpoint: result.endpoint, availableBackends: metadata.backends, protocolVersion: metadata.version)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.onServersChanged?(servers) }
        }
        browser.start(queue: queue)
    }

    func cancel() { browser.cancel() }

    private func metadata(from metadata: NWBrowser.Result.Metadata) -> (backends: [RemoteBackendKind], version: Int?) {
        // The current macOS server publishes TXT metadata opportunistically. A
        // plain Bonjour service remains valid, so absence of TXT means both
        // protocol backends are offered until PAIR confirms the real list.
        guard case .bonjour(let txtRecord) = metadata else { return ([], nil) }
        let values = txtRecord.dictionary
        let backends = (values["backends"] ?? "").split(separator: ",").compactMap { RemoteBackendKind(rawValue: String($0)) }
        let version = values["version"].flatMap(Int.init)
        return (backends, version)
    }
}

final class RemoteScribeClient {
    // Install callbacks on the main thread before connecting. All callbacks are
    // delivered on main; all transport/session state belongs to `queue`.
    var onStateChanged: ((NWConnection.State) -> Void)?
    var onPairResponse: ((PairResponse) -> Void)?
    var onSessionStatus: ((UUID, SessionStatusPayload) -> Void)?
    var onError: ((RemoteErrorPayload) -> Void)?

    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.client")
    private let queueKey = DispatchSpecificKey<Void>()
    private let decoder = RemoteFrameDecoder()
    private var connection: NWConnection?
    private var generation: UInt64 = 0
    // Remote Scribe v1 (shipped Core): only AUDIO_CHUNK carries a meaningful
    // sequence, numbered 0, 1, 2… per session. Every other frame carries 0.
    private var audioSequence: UInt64 = 0
    // Total PCM sample frames of the session (bytes / 2, mono 16-bit).
    private var framesSent: UInt64 = 0
    private var sessionID: UUID?
    private var paired = false
    private var stopped = false
    private var pendingBytes = 0
    private let maximumPendingBytes = 1_048_576

    init() { queue.setSpecific(key: queueKey, value: ()) }

    private func synchronized<T>(_ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try action() }
        return try queue.sync(execute: action)
    }

    func connect(to endpoint: NWEndpoint, deviceID: String, deviceName: String, pairingCode: String?, tls: Bool = false) {
        synchronized {
            disconnectLocked()
            let connection = NWConnection(to: endpoint, using: Self.parameters(tls: tls))
            self.connection = connection
            let generation = self.generation
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.deliver { $0.onStateChanged?(state) }
                    do {
                        try self.sendJSON(kind: .pair, sessionID: RemoteFrame.noSession,
                            value: PairRequest(protocolVersion: RemoteScribeProtocol.version, deviceID: deviceID, deviceName: deviceName, pairingCode: pairingCode))
                    } catch { self.failLocked(code: "transport", message: error.localizedDescription) }
                case .failed(let error):
                    self.failLocked(code: "transport", message: error.localizedDescription)
                default:
                    self.deliver { $0.onStateChanged?(state) }
                }
            }
            receive(on: connection)
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.generation == generation, self.connection != nil, !self.paired else { return }
                self.failLocked(code: "transport", message: "Le serveur n’a pas terminé l’appairage dans le délai prévu.")
            }
        }
    }

    func connect(host: String, port: UInt16, deviceID: String, deviceName: String, pairingCode: String?, tls: Bool = false) throws {
        guard !host.isEmpty, port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteScribeError(code: "transport", message: "Port TCP invalide.")
        }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), deviceID: deviceID, deviceName: deviceName, pairingCode: pairingCode, tls: tls)
    }

    func disconnect() { synchronized { disconnectLocked() } }

    private func disconnectLocked() {
        generation &+= 1
        let old = connection
        connection = nil
        old?.cancel()
        resetSession()
        paired = false
        pendingBytes = 0
        decoder.reset()
    }

    private func resetSession() { sessionID = nil; audioSequence = 0; framesSent = 0; stopped = false }

    // Abandon is local bookkeeping after a terminal server status. To cancel
    // a live recording, disconnect so the server also disposes of its session.
    func abandonSession() { synchronized { resetSession() } }

    func startSession(format: RemoteAudioFormat = RemoteAudioFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16, codec: "pcm_s16le"), modeIdentifier: String? = nil, language: String? = nil, backend: RemoteBackendKind? = nil) throws -> UUID {
        try synchronized {
            guard paired else { throw RemoteScribeError(code: "notPaired", message: "Le client doit envoyer PAIR avant toute session.") }
            guard sessionID == nil else { throw RemoteScribeError(code: "alreadyRecording", message: "Une session distante est déjà en cours.") }
            guard format.isSupported else { throw RemoteFrameError.invalidAudioChunk }
            let id = UUID()
            try sendJSON(kind: .startSession, sessionID: id, value: StartSessionRequest(format: format, modeIdentifier: modeIdentifier, language: language, backend: backend))
            sessionID = id
            audioSequence = 0
            framesSent = 0
            stopped = false
            return id
        }
    }

    func startSession(language: String?, backend: RemoteBackendKind?) throws -> UUID {
        try startSession(format: RemoteAudioFormat(sampleRate: 16_000, channels: 1, bitsPerSample: 16, codec: "pcm_s16le"), modeIdentifier: nil, language: language, backend: backend)
    }

    func sendAudio(_ data: Data) throws {
        try synchronized {
            guard let sessionID, !stopped else { throw RemoteScribeError(code: "noActiveSession", message: "Aucune session distante n’est active.") }
            guard !data.isEmpty, data.count % 2 == 0 else { throw RemoteFrameError.invalidAudioChunk }
            try send(kind: .audioChunk, sessionID: sessionID, payload: data)
            framesSent += UInt64(data.count / 2)
        }
    }

    func stopSession() throws {
        try synchronized {
            guard let sessionID, !stopped else { throw RemoteScribeError(code: "noActiveSession", message: "Aucune session distante n’est active.") }
            // Every audio send and this STOP run on the same serial queue;
            // NWConnection preserves their order on its one TCP stream.
            try sendJSON(kind: .stopSession, sessionID: sessionID, value: StopSessionRequest(framesSent: framesSent))
            stopped = true
        }
    }

    func ping() throws {
        try synchronized { try sendJSON(kind: .ping, sessionID: RemoteFrame.noSession, value: PingPayload(timestamp: Date().timeIntervalSince1970)) }
    }

    private func sendJSON<T: Encodable>(kind: RemoteMessageKind, sessionID: UUID, value: T) throws {
        try send(kind: kind, sessionID: sessionID, payload: JSONEncoder().encode(value))
    }

    private func send(kind: RemoteMessageKind, sessionID: UUID, payload: Data) throws {
        guard let connection else { throw RemoteScribeError(code: "transport", message: "Connexion distante absente.") }
        let sequence = kind == .audioChunk ? audioSequence : 0
        let data = try RemoteFrameEncoder.encode(RemoteFrame(kind: kind, sessionID: sessionID, sequence: sequence, payload: payload))
        guard pendingBytes + data.count <= maximumPendingBytes else {
            failLocked(code: "transport", message: "Le réseau ne transmet plus l’audio assez vite. La dictée a été interrompue.")
            throw RemoteScribeError(code: "transport", message: "File d’envoi audio saturée.")
        }
        if kind == .audioChunk { audioSequence += 1 }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.pendingBytes -= data.count
            if let error { self.failLocked(code: "transport", message: "Envoi impossible : \(error.localizedDescription)") }
        })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                do {
                    // Server frames always carry sequence 0; the field is ignored.
                    for frame in try self.decoder.append(data) {
                        try self.handle(frame)
                        if self.connection !== connection { return }
                    }
                } catch {
                    self.failLocked(code: "protocolViolation", message: "Réponse serveur invalide : \(error.localizedDescription)")
                    return
                }
            }
            if let error { self.failLocked(code: "transport", message: "Connexion perdue : \(error.localizedDescription)") }
            else if isComplete { self.failLocked(code: "transport", message: "Le serveur a fermé la connexion.") }
            else { self.receive(on: connection) }
        }
    }

    private func handle(_ frame: RemoteFrame) throws {
        switch frame.kind {
        case .pair:
            guard !paired, frame.sessionID == RemoteFrame.noSession else { throw RemoteFrameError.invalidUUID }
            let response = try frame.decode(PairResponse.self)
            guard response.protocolVersion == RemoteScribeProtocol.version else {
                throw RemoteScribeError(code: "protocolViolation", message: "Version serveur incompatible.")
            }
            paired = response.accepted
            deliver { $0.onPairResponse?(response) }
        case .sessionStatus:
            guard paired else { throw RemoteScribeError(code: "notPaired", message: "Réponse reçue avant appairage.") }
            let status = try frame.decode(SessionStatusPayload.self)
            if frame.sessionID == RemoteFrame.noSession {
                guard status.state == .ready else { throw RemoteFrameError.invalidUUID }
            } else {
                guard frame.sessionID == sessionID else { throw RemoteFrameError.invalidUUID }
                if status.state == .completed || status.state == .failed { resetSession() }
            }
            deliver { $0.onSessionStatus?(frame.sessionID, status) }
        case .error:
            let error = try frame.decode(RemoteErrorPayload.self)
            failLocked(code: error.code, message: error.message)
        case .ping:
            break
        default:
            throw RemoteScribeError(code: "protocolViolation", message: "Message serveur inattendu.")
        }
    }

    private func failLocked(code: String, message: String) {
        let old = connection
        connection = nil
        old?.cancel()
        paired = false
        resetSession()
        pendingBytes = 0
        decoder.reset()
        deliver { $0.onError?(RemoteErrorPayload(code: code, message: message)) }
    }

    private func deliver(_ action: @escaping (RemoteScribeClient) -> Void) {
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.synchronized({ self.generation == generation }) else { return }
            action(self)
        }
    }

    private static func parameters(tls: Bool) -> NWParameters {
        guard tls else { return .tcp }
        // System trust checks are retained; no certificate validation bypass.
        // Pinning/mTLS provisioning remains a deployment prerequisite.
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv13)
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }
}
