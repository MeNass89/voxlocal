import Foundation

/// Wire constants recovered from the shipped VoxLocal 2.0 binary.
enum RemoteScribeProtocol {
    static let version = 1
    static let serviceType = "_remotescribe._tcp"
    static let defaultPort: UInt16 = 47365
    static let maximumFrameSize = 1_048_576
}

enum RemoteMessageKind: UInt8, CaseIterable, Codable {
    case pair = 1
    case startSession = 2
    case audioChunk = 3
    case stopSession = 4
    case sessionStatus = 5
    case ping = 6
    case error = 7
}

enum RemoteSessionState: String, Codable, Hashable {
    case failed, recording, processing, ready, completed
}

enum RemoteBackendKind: String, Codable, CaseIterable, Hashable {
    case voxLocal = "voxlocal"
    case superwhisper
}

struct RemoteAudioFormat: Codable, Equatable, Hashable {
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let codec: String

    var isSupported: Bool {
        sampleRate == 16_000 && channels == 1 && bitsPerSample == 16 && codec == "pcm_s16le"
    }

    var bytesPerSecond: Int { sampleRate * channels * bitsPerSample / 8 }
}

struct PairRequest: Codable, Equatable {
    let protocolVersion: Int
    let deviceID: String
    let deviceName: String
    let pairingCode: String?
}

struct PairResponse: Codable, Equatable {
    let accepted: Bool
    let serverName: String
    let selectedBackend: RemoteBackendKind
    let protocolVersion: Int
    let availableBackends: [RemoteBackendKind]?
}

struct StartSessionRequest: Codable, Equatable {
    let format: RemoteAudioFormat
    let modeIdentifier: String?
    let language: String?
    let backend: RemoteBackendKind?
}

struct StopSessionRequest: Codable, Equatable {
    let framesSent: UInt64
}

struct SessionStatusPayload: Codable, Equatable {
    let state: RemoteSessionState
    let backend: RemoteBackendKind
    let bytesReceived: UInt64
    let message: String?
    let transcription: String?
    let rawTranscription: String?
    let finalText: String?
    let audioLocation: String?
    let resultLocation: String?
}

struct PingPayload: Codable, Equatable {
    let timestamp: Double
}

struct RemoteErrorPayload: Codable, Equatable, Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }

    /// Client-side trust refusals raised during the TLS handshake. For both,
    /// `message` is the base64 SHA-256 of the server's leaf certificate (DER).
    /// No pin stored and the certificate is not trusted by the system: the user
    /// must confirm the fingerprint (trust on first use).
    static let untrustedServerCode = "untrustedServer"
    /// The server presented a certificate other than the pinned one.
    static let pinMismatchCode = "pinMismatch"
}

/// Client-facing alias retained for the API used by the original portable app.
typealias RemoteScribeError = RemoteErrorPayload

enum RemoteJSON {
    static let encoder: JSONEncoder = {
        JSONEncoder()
    }()

    static let decoder = JSONDecoder()
}

struct RemoteFrame: Equatable {
    let kind: RemoteMessageKind
    let sessionID: UUID
    let sequence: UInt64
    let payload: Data

    static let noSession = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func json<T: Encodable>(kind: RemoteMessageKind, sessionID: UUID, sequence: UInt64, value: T) throws -> RemoteFrame {
        RemoteFrame(kind: kind, sessionID: sessionID, sequence: sequence, payload: try RemoteJSON.encoder.encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try RemoteJSON.decoder.decode(type, from: payload)
    }
}

enum RemoteFrameError: LocalizedError {
    case invalidLength
    case tooLarge(Int)
    case invalidKind(UInt8)
    case invalidUUID
    case truncated
    case invalidAudioChunk

    var errorDescription: String? {
        switch self {
        case .invalidLength: return "Trame Remote Scribe invalide : longueur négative."
        case .tooLarge(let size): return "Trame Remote Scribe trop volumineuse (\(size) octets)."
        case .invalidKind(let kind): return "Type de message Remote Scribe inconnu (\(kind))."
        case .invalidUUID: return "UUID de session Remote Scribe invalide."
        case .truncated: return "Trame Remote Scribe incomplète."
        case .invalidAudioChunk: return "Chunk audio PCM invalide."
        }
    }
}
