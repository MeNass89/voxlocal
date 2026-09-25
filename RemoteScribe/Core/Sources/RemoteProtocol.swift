import Foundation

public enum RemoteScribeProtocol {
    public static let version = 1
    public static let serviceType = "_remotescribe._tcp"
    public static let defaultPort: UInt16 = 47_365
    public static let maximumFrameSize = 1_048_576
}

public enum RemoteMessageKind: UInt8, Codable, CaseIterable {
    case pair = 1
    case startSession = 2
    case audioChunk = 3
    case stopSession = 4
    case sessionStatus = 5
    case ping = 6
    case error = 7
}

public struct RemoteFrame: Equatable {
    public var kind: RemoteMessageKind
    public var sessionID: UUID
    public var sequence: UInt64
    public var payload: Data

    public init(kind: RemoteMessageKind, sessionID: UUID = RemoteFrame.noSession, sequence: UInt64 = 0, payload: Data = Data()) {
        self.kind = kind
        self.sessionID = sessionID
        self.sequence = sequence
        self.payload = payload
    }

    public static let noSession = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public static func json<T: Encodable>(kind: RemoteMessageKind, sessionID: UUID = noSession, sequence: UInt64 = 0, value: T) throws -> RemoteFrame {
        RemoteFrame(kind: kind, sessionID: sessionID, sequence: sequence, payload: try RemoteJSON.encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try RemoteJSON.decoder.decode(type, from: payload)
    }
}

public enum RemoteSessionState: String, Codable {
    case paired, ready, recording, processing, completed, failed
}

public enum RemoteBackendKind: String, Codable, CaseIterable {
    case voxLocal = "voxlocal"
    case superwhisper
}

public struct RemoteAudioFormat: Codable, Equatable {
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var codec: String

    public init(sampleRate: Int = 16_000, channels: Int = 1, bitsPerSample: Int = 16, codec: String = "pcm_s16le") {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        self.codec = codec
    }

    public var bytesPerSecond: Int { sampleRate * channels * bitsPerSample / 8 }

    public var isSupported: Bool {
        codec == "pcm_s16le" && sampleRate == 16_000 && channels == 1 && bitsPerSample == 16
    }
}

public struct PairRequest: Codable, Equatable {
    public var protocolVersion: Int
    public var deviceID: String
    public var deviceName: String
    public var pairingCode: String?

    public init(protocolVersion: Int = RemoteScribeProtocol.version, deviceID: String, deviceName: String, pairingCode: String? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairingCode = pairingCode
    }
}

public struct PairResponse: Codable, Equatable {
    public var accepted: Bool
    public var serverName: String
    public var selectedBackend: RemoteBackendKind
    public var protocolVersion: Int
    public var availableBackends: [RemoteBackendKind]?

    public init(accepted: Bool, serverName: String, selectedBackend: RemoteBackendKind, protocolVersion: Int = RemoteScribeProtocol.version, availableBackends: [RemoteBackendKind]? = nil) {
        self.accepted = accepted
        self.serverName = serverName
        self.selectedBackend = selectedBackend
        self.protocolVersion = protocolVersion
        self.availableBackends = availableBackends
    }
}

public struct StartSessionRequest: Codable, Equatable {
    public var format: RemoteAudioFormat
    public var modeIdentifier: String?
    public var language: String?
    public var backend: RemoteBackendKind?

    public init(format: RemoteAudioFormat = RemoteAudioFormat(), modeIdentifier: String? = nil, language: String? = nil, backend: RemoteBackendKind? = nil) {
        self.format = format
        self.modeIdentifier = modeIdentifier
        self.language = language
        self.backend = backend
    }
}

public struct StopSessionRequest: Codable, Equatable {
    public var framesSent: UInt64
    public init(framesSent: UInt64) { self.framesSent = framesSent }
}

public struct SessionStatusPayload: Codable, Equatable {
    public var state: RemoteSessionState
    public var backend: RemoteBackendKind
    public var bytesReceived: UInt64
    public var message: String?
    public var transcription: String?
    public var rawTranscription: String?
    public var finalText: String?
    public var audioLocation: String?
    public var resultLocation: String?

    public init(state: RemoteSessionState, backend: RemoteBackendKind, bytesReceived: UInt64 = 0, message: String? = nil, transcription: String? = nil, rawTranscription: String? = nil, finalText: String? = nil, audioLocation: String? = nil, resultLocation: String? = nil) {
        self.state = state
        self.backend = backend
        self.bytesReceived = bytesReceived
        self.message = message
        self.transcription = transcription
        self.rawTranscription = rawTranscription
        self.finalText = finalText
        self.audioLocation = audioLocation
        self.resultLocation = resultLocation
    }
}

public struct PingPayload: Codable, Equatable {
    public var timestamp: TimeInterval
    public init(timestamp: TimeInterval = Date().timeIntervalSince1970) { self.timestamp = timestamp }
}

public struct RemoteErrorPayload: Codable, Equatable {
    public var code: String
    public var message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public enum RemoteJSON {
    public static let encoder = JSONEncoder()
    public static let decoder = JSONDecoder()
}

public enum RemoteScribeError: LocalizedError {
    case protocolViolation(String)
    case unsupportedAudioFormat
    case sessionMismatch
    case notPaired
    case alreadyRecording
    case noActiveSession
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .protocolViolation(let message): return "Protocole Remote Scribe invalide : \(message)"
        case .unsupportedAudioFormat: return "Le format requis est PCM signé 16 bits, mono, 16 kHz."
        case .sessionMismatch: return "L’UUID de session ne correspond pas à la session active."
        case .notPaired: return "Le client doit envoyer PAIR avant toute session."
        case .alreadyRecording: return "Une session distante est déjà en cours."
        case .noActiveSession: return "Aucune session distante n’est active."
        case .transport(let message): return message
        }
    }
}
