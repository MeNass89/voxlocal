import Foundation

public final class RemoteSessionHandler {
    public typealias Sender = (RemoteFrame) -> Void

    private let backends: [RemoteBackendKind: RemoteScribeBackend]
    private let defaultBackend: RemoteBackendKind
    private let serverName: String
    private let sessionsDirectory: URL
    private let pairingCode: String?
    private let pairingGate: RemotePairingGate?
    private let peer: String
    private let sender: Sender
    private var pairedDeviceName: String?
    private var receiver: RemoteAudioReceiver?
    private var activeBackend: RemoteScribeBackend?

    public init(backend: RemoteScribeBackend, serverName: String, sessionsDirectory: URL, pairingCode: String? = nil, pairingGate: RemotePairingGate? = nil, peer: String = "", sender: @escaping Sender) {
        self.backends = [backend.kind: backend]
        self.defaultBackend = backend.kind
        self.serverName = serverName
        self.sessionsDirectory = sessionsDirectory
        self.pairingCode = pairingCode
        self.pairingGate = pairingGate
        self.peer = peer
        self.sender = sender
    }

    public init(backends: [RemoteBackendKind: RemoteScribeBackend], defaultBackend: RemoteBackendKind, serverName: String, sessionsDirectory: URL, pairingCode: String? = nil, pairingGate: RemotePairingGate? = nil, peer: String = "", sender: @escaping Sender) {
        self.backends = backends
        self.defaultBackend = defaultBackend
        self.serverName = serverName
        self.sessionsDirectory = sessionsDirectory
        self.pairingCode = pairingCode
        self.pairingGate = pairingGate
        self.peer = peer
        self.sender = sender
    }

    public func handle(_ frame: RemoteFrame) {
        do {
            switch frame.kind {
            case .pair: try pair(frame)
            case .startSession: try start(frame)
            case .audioChunk: try audio(frame)
            case .stopSession: try stop(frame)
            case .ping: try pong(frame)
            case .sessionStatus, .error:
                throw RemoteScribeError.protocolViolation("message réservé au serveur")
            }
        } catch {
            sendError(error, sessionID: frame.sessionID)
        }
    }

    public func disconnect() {
        receiver?.abort()
        receiver = nil
        activeBackend = nil
    }

    private func pair(_ frame: RemoteFrame) throws {
        let request = try frame.decode(PairRequest.self)
        guard request.protocolVersion == RemoteScribeProtocol.version else {
            throw RemoteScribeError.protocolViolation("version \(request.protocolVersion) non prise en charge")
        }
        if pairingGate?.isLocked(peer: peer) == true {
            throw RemoteScribeError.protocolViolation("trop de tentatives d’appairage, réessayez dans une minute")
        }
        if let pairingCode {
            guard Self.constantTimeEquals(pairingCode, request.pairingCode) else {
                pairingGate?.recordFailure(peer: peer)
                throw RemoteScribeError.protocolViolation("code d’appairage incorrect")
            }
            pairingGate?.recordSuccess(peer: peer)
        }
        pairedDeviceName = request.deviceName
        let available = RemoteBackendKind.allCases.filter { backends[$0] != nil }
        sender(try .json(kind: .pair, value: PairResponse(
            accepted: true,
            serverName: serverName,
            selectedBackend: defaultBackend,
            availableBackends: available
        )))
        sendStatus(.ready, backend: defaultBackend, sessionID: RemoteFrame.noSession, message: "Appareil appairé.")
    }

    /// Compares the expected code with the offered one without an early exit, so the
    /// time spent does not reveal how many leading bytes matched. A missing or
    /// different-length code still walks the full expected buffer and returns false.
    static func constantTimeEquals(_ expected: String, _ offered: String?) -> Bool {
        let lhs = Array(expected.utf8)
        let rhs = Array((offered ?? "").utf8)
        var difference: UInt8 = (offered == nil || lhs.count != rhs.count) ? 1 : 0
        for index in 0..<lhs.count {
            let other: UInt8 = index < rhs.count ? rhs[index] : 0
            difference |= lhs[index] ^ other
        }
        return difference == 0
    }

    private func start(_ frame: RemoteFrame) throws {
        guard let deviceName = pairedDeviceName else { throw RemoteScribeError.notPaired }
        guard receiver == nil else { throw RemoteScribeError.alreadyRecording }
        guard frame.sessionID != RemoteFrame.noSession else { throw RemoteScribeError.protocolViolation("UUID de session absent") }
        let request = try frame.decode(StartSessionRequest.self)
        guard request.format.isSupported else { throw RemoteScribeError.unsupportedAudioFormat }
        let requestedBackend = request.backend ?? defaultBackend
        guard let backend = backends[requestedBackend] else {
            throw RemoteScribeError.transport("Le moteur \(requestedBackend.rawValue) n’est pas disponible sur ce Mac.")
        }
        let directory = sessionsDirectory.appendingPathComponent(frame.sessionID.uuidString, isDirectory: true)
        let session = RemoteScribeSession(
            id: frame.sessionID,
            deviceName: deviceName,
            audioURL: directory.appendingPathComponent("remote.wav"),
            format: request.format,
            modeIdentifier: request.modeIdentifier,
            language: request.language
        )
        receiver = try WAVRemoteAudioReceiver(session: session)
        activeBackend = backend
        sendStatus(.recording, backend: backend.kind, sessionID: frame.sessionID, message: "Session démarrée avec \(backend.kind.rawValue).")
    }

    private func audio(_ frame: RemoteFrame) throws {
        guard let receiver else { throw RemoteScribeError.noActiveSession }
        guard receiver.session.id == frame.sessionID else { throw RemoteScribeError.sessionMismatch }
        try receiver.receive(frame.payload, sequence: frame.sequence)
    }

    private func stop(_ frame: RemoteFrame) throws {
        guard let receiver else { throw RemoteScribeError.noActiveSession }
        guard receiver.session.id == frame.sessionID else { throw RemoteScribeError.sessionMismatch }
        let request = try frame.decode(StopSessionRequest.self)
        guard let backend = activeBackend else { throw RemoteScribeError.noActiveSession }
        self.receiver = nil
        self.activeBackend = nil
        let session = try receiver.finish()
        let expectedFrames = session.bytesReceived / 2
        guard request.framesSent == expectedFrames else {
            throw RemoteScribeError.protocolViolation("framesSent \(request.framesSent) ≠ échantillons reçus \(expectedFrames)")
        }
        sendStatus(.processing, backend: backend.kind, sessionID: session.id, bytes: session.bytesReceived, message: "Audio reçu, traitement en cours.")
        backend.process(session: session) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.sendError(error, sessionID: session.id)
                self.sendStatus(.failed, backend: backend.kind, sessionID: session.id, bytes: session.bytesReceived, message: error.localizedDescription)
            case .success(let output):
                self.sendStatus(
                    .completed,
                    backend: backend.kind,
                    sessionID: session.id,
                    bytes: session.bytesReceived,
                    message: output.message,
                    transcription: output.finalText ?? output.transcription,
                    rawTranscription: output.transcription,
                    finalText: output.finalText ?? output.transcription,
                    audioLocation: session.audioURL.path,
                    resultLocation: output.resultLocation
                )
            }
        }
    }

    private func pong(_ frame: RemoteFrame) throws {
        let ping = try frame.decode(PingPayload.self)
        sender(try .json(kind: .ping, value: ping))
    }

    private func sendStatus(_ state: RemoteSessionState, backend: RemoteBackendKind, sessionID: UUID, bytes: UInt64 = 0, message: String? = nil, transcription: String? = nil, rawTranscription: String? = nil, finalText: String? = nil, audioLocation: String? = nil, resultLocation: String? = nil) {
        let payload = SessionStatusPayload(state: state, backend: backend, bytesReceived: bytes, message: message, transcription: transcription, rawTranscription: rawTranscription, finalText: finalText, audioLocation: audioLocation, resultLocation: resultLocation)
        if let frame = try? RemoteFrame.json(kind: .sessionStatus, sessionID: sessionID, value: payload) { sender(frame) }
    }

    private func sendError(_ error: Error, sessionID: UUID) {
        let payload = RemoteErrorPayload(code: String(describing: type(of: error)), message: error.localizedDescription)
        if let frame = try? RemoteFrame.json(kind: .error, sessionID: sessionID, value: payload) { sender(frame) }
    }
}
