import Foundation
import Network

public final class RemoteScribeServer {
    public var onEvent: ((String) -> Void)?
    public var onReady: ((UInt16) -> Void)?

    private let backends: [RemoteBackendKind: RemoteScribeBackend]
    private let defaultBackend: RemoteBackendKind
    private let serviceName: String
    private let sessionsDirectory: URL
    private let pairingCode: String?
    private let tlsIdentity: RemoteScribeTLSIdentity?
    private let pairingGate = RemotePairingGate()
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.server")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]

    public init(backend: RemoteScribeBackend, serviceName: String = Host.current().localizedName ?? "Mac", sessionsDirectory: URL, pairingCode: String? = nil, tlsIdentity: RemoteScribeTLSIdentity? = nil) {
        self.backends = [backend.kind: backend]
        self.defaultBackend = backend.kind
        self.serviceName = serviceName
        self.sessionsDirectory = sessionsDirectory
        self.pairingCode = pairingCode
        self.tlsIdentity = tlsIdentity
    }

    public init(backends: [RemoteScribeBackend], defaultBackend: RemoteBackendKind, serviceName: String = Host.current().localizedName ?? "Mac", sessionsDirectory: URL, pairingCode: String? = nil, tlsIdentity: RemoteScribeTLSIdentity? = nil) {
        self.backends = Dictionary(uniqueKeysWithValues: backends.map { ($0.kind, $0) })
        self.defaultBackend = defaultBackend
        self.serviceName = serviceName
        self.sessionsDirectory = sessionsDirectory
        self.pairingCode = pairingCode
        self.tlsIdentity = tlsIdentity
    }

    /// Fingerprint shown to the user so they can compare it with the one the phone displays.
    public var fingerprintDisplay: String? { tlsIdentity?.fingerprintDisplay }

    public func start(port: UInt16 = RemoteScribeProtocol.defaultPort) throws {
        guard listener == nil else { return }
        let parameters: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity.identity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteScribeError.transport("Port TCP invalide.")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        guard backends[defaultBackend] != nil else {
            throw RemoteScribeError.transport("Le moteur par défaut n’est pas configuré.")
        }
        let available = RemoteBackendKind.allCases.filter { backends[$0] != nil }
        var entries = [
            "version": "\(RemoteScribeProtocol.version)",
            "backend": defaultBackend.rawValue,
            "backends": available.map(\.rawValue).joined(separator: ",")
        ]
        if let tlsIdentity {
            entries["tls"] = "1"
            entries["fp"] = tlsIdentity.fingerprintBase64
        }
        let txt = NWTXTRecord(entries)
        listener.service = NWListener.Service(name: serviceName, type: RemoteScribeProtocol.serviceType, domain: nil, txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actual = listener.port?.rawValue ?? port
                let names = available.map(\.rawValue).joined(separator: ", ")
                let transport = self.tlsIdentity == nil ? "TCP sans chiffrement" : "TLS 1.3"
                self.event("Remote Scribe écoute sur le port \(actual) (\(transport)), moteurs \(names), défaut \(self.defaultBackend.rawValue).")
                self.onReady?(actual)
            case .failed(let error): self.event("Serveur en erreur : \(error.localizedDescription)")
            case .cancelled: self.event("Serveur arrêté.")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.peers.values.forEach { $0.cancel() }
            self.peers.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(
            connection: connection,
            backends: backends,
            defaultBackend: defaultBackend,
            serverName: serviceName,
            sessionsDirectory: sessionsDirectory,
            pairingCode: pairingCode,
            pairingGate: pairingGate,
            peer: Self.peerKey(connection.endpoint),
            queue: queue,
            event: { [weak self] in self?.event($0) },
            disconnected: { [weak self] identifier in self?.peers.removeValue(forKey: identifier) }
        )
        peers[peer.identifier] = peer
        peer.start()
    }

    /// Lockout key: the remote host only, so a new ephemeral source port does not
    /// reset the failure counter.
    static func peerKey(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return String(describing: host) }
        return String(describing: endpoint)
    }

    private func event(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(message) }
    }
}

private final class Peer {
    let identifier: ObjectIdentifier
    private let connection: NWConnection
    private let decoder = RemoteFrameDecoder()
    private let queue: DispatchQueue
    private let event: (String) -> Void
    private let disconnected: (ObjectIdentifier) -> Void
    private var handler: RemoteSessionHandler!
    private var didDisconnect = false

    init(connection: NWConnection, backends: [RemoteBackendKind: RemoteScribeBackend], defaultBackend: RemoteBackendKind, serverName: String, sessionsDirectory: URL, pairingCode: String?, pairingGate: RemotePairingGate, peer: String, queue: DispatchQueue, event: @escaping (String) -> Void, disconnected: @escaping (ObjectIdentifier) -> Void) {
        self.connection = connection
        self.identifier = ObjectIdentifier(connection)
        self.queue = queue
        self.event = event
        self.disconnected = disconnected
        handler = RemoteSessionHandler(backends: backends, defaultBackend: defaultBackend, serverName: serverName, sessionsDirectory: sessionsDirectory, pairingCode: pairingCode, pairingGate: pairingGate, peer: peer) { [weak self] frame in
            self?.send(frame)
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.event("Client connecté : \(self.connection.endpoint)"); self.receive()
            case .failed(let error): self.event("Connexion perdue : \(error.localizedDescription)"); self.disconnect()
            case .cancelled: self.disconnect()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { connection.cancel(); disconnect() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do { try self.decoder.append(data).forEach(self.handler.handle) }
                catch { self.event("Trame rejetée : \(error.localizedDescription)"); self.connection.cancel() }
            }
            if complete || error != nil { self.disconnect(); return }
            self.receive()
        }
    }

    private func send(_ frame: RemoteFrame) {
        do {
            connection.send(content: try RemoteFrameEncoder.encode(frame), completion: .contentProcessed { [weak self] error in
                if let error { self?.event("Envoi impossible : \(error.localizedDescription)") }
            })
        } catch { event("Encodage impossible : \(error.localizedDescription)") }
    }

    private func disconnect() {
        guard !didDisconnect else { return }
        didDisconnect = true
        handler.disconnect()
        disconnected(identifier)
    }
}
