import Foundation
import Network

public struct DiscoveredRemoteScribeServer: Hashable {
    public var name: String
    public var endpoint: NWEndpoint
    public var availableBackends: [RemoteBackendKind]
    public var protocolVersion: Int?

    public init(name: String, endpoint: NWEndpoint, availableBackends: [RemoteBackendKind] = [], protocolVersion: Int? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.availableBackends = availableBackends
        self.protocolVersion = protocolVersion
    }

    public var id: String { "\(name)|\(String(describing: endpoint))" }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name && String(describing: lhs.endpoint) == String(describing: rhs.endpoint) }
    public func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(String(describing: endpoint)) }
}

public final class RemoteScribeBrowser {
    public var onServersChanged: (([DiscoveredRemoteScribeServer]) -> Void)?
    public var onError: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.browser")
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: RemoteScribeProtocol.serviceType, domain: nil)
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let servers = results.map { result -> DiscoveredRemoteScribeServer in
                let name: String
                if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
                else { name = String(describing: result.endpoint) }
                let record: NWTXTRecord?
                if case .bonjour(let value) = result.metadata { record = value } else { record = nil }
                let backends = (record?["backends"] ?? record?["backend"] ?? "")
                    .split(separator: ",")
                    .compactMap { RemoteBackendKind(rawValue: String($0)) }
                let version = record?["version"].flatMap(Int.init)
                return DiscoveredRemoteScribeServer(
                    name: name,
                    endpoint: result.endpoint,
                    availableBackends: backends,
                    protocolVersion: version
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.onServersChanged?(servers) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { DispatchQueue.main.async { self?.onError?(error) } }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() { browser?.cancel(); browser = nil }
}

public final class RemoteScribeClient {
    public var onStateChanged: ((NWConnection.State) -> Void)?
    public var onPairResponse: ((PairResponse) -> Void)?
    public var onSessionStatus: ((UUID, SessionStatusPayload) -> Void)?
    public var onError: ((RemoteErrorPayload) -> Void)?

    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.client")
    private var decoder = RemoteFrameDecoder()
    private var connection: NWConnection?
    private var sessionID: UUID?
    private var sequence: UInt64 = 0
    private var framesSent: UInt64 = 0

    public init() {}

    public func connect(to endpoint: NWEndpoint, deviceID: String, deviceName: String, pairingCode: String? = nil) {
        disconnect()
        decoder = RemoteFrameDecoder()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.onStateChanged?(state) }
            if case .ready = state {
                let request = PairRequest(deviceID: deviceID, deviceName: deviceName, pairingCode: pairingCode)
                try? self?.send(.json(kind: .pair, value: request))
                self?.receive()
            }
        }
        connection.start(queue: queue)
    }

    public func connect(host: String, port: UInt16 = RemoteScribeProtocol.defaultPort, deviceID: String, deviceName: String, pairingCode: String? = nil) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw RemoteScribeError.transport("Port invalide.") }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: nwPort), deviceID: deviceID, deviceName: deviceName, pairingCode: pairingCode)
    }

    @discardableResult
    public func startSession(format: RemoteAudioFormat = RemoteAudioFormat(), modeIdentifier: String? = nil, language: String? = nil, backend: RemoteBackendKind? = nil) throws -> UUID {
        guard sessionID == nil else { throw RemoteScribeError.alreadyRecording }
        let id = UUID(); sessionID = id; sequence = 0; framesSent = 0
        try send(.json(kind: .startSession, sessionID: id, value: StartSessionRequest(format: format, modeIdentifier: modeIdentifier, language: language, backend: backend)))
        return id
    }

    public func sendAudio(_ pcmBytes: Data) throws {
        guard let id = sessionID else { throw RemoteScribeError.noActiveSession }
        guard pcmBytes.count <= RemoteScribeProtocol.maximumFrameSize - 45 else { throw RemoteScribeError.protocolViolation("chunk audio trop grand") }
        try send(RemoteFrame(kind: .audioChunk, sessionID: id, sequence: sequence, payload: pcmBytes))
        sequence += 1
        framesSent += UInt64(pcmBytes.count / 2)
    }

    public func stopSession() throws {
        guard let id = sessionID else { throw RemoteScribeError.noActiveSession }
        try send(.json(kind: .stopSession, sessionID: id, value: StopSessionRequest(framesSent: framesSent)))
        sessionID = nil
    }

    public func ping() throws { try send(.json(kind: .ping, value: PingPayload())) }

    public func disconnect() {
        connection?.cancel(); connection = nil; sessionID = nil
    }

    /// Clears a locally pending session after the server rejected its start.
    public func abandonSession() { sessionID = nil }

    private func send(_ frame: RemoteFrame) throws {
        guard let connection else { throw RemoteScribeError.transport("Le client n’est pas connecté.") }
        connection.send(content: try RemoteFrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do { try self.decoder.append(data).forEach(self.handle) }
                catch {
                    let payload = RemoteErrorPayload(code: "decode", message: error.localizedDescription)
                    DispatchQueue.main.async { self.onError?(payload) }
                }
            }
            if !complete && error == nil { self.receive() }
        }
    }

    private func handle(_ frame: RemoteFrame) {
        do {
            switch frame.kind {
            case .pair:
                let response = try frame.decode(PairResponse.self)
                DispatchQueue.main.async { self.onPairResponse?(response) }
            case .sessionStatus:
                let status = try frame.decode(SessionStatusPayload.self)
                DispatchQueue.main.async { self.onSessionStatus?(frame.sessionID, status) }
            case .error:
                let error = try frame.decode(RemoteErrorPayload.self)
                DispatchQueue.main.async { self.onError?(error) }
            case .ping: break
            default: throw RemoteScribeError.protocolViolation("message serveur inattendu")
            }
        } catch {
            let payload = RemoteErrorPayload(code: "decode", message: error.localizedDescription)
            DispatchQueue.main.async { self.onError?(payload) }
        }
    }
}
