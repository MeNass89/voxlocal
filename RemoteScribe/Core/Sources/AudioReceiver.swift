import Foundation

public struct RemoteScribeSession: Equatable {
    public var id: UUID
    public var deviceName: String
    public var audioURL: URL
    public var format: RemoteAudioFormat
    public var modeIdentifier: String?
    public var language: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var bytesReceived: UInt64

    public init(id: UUID, deviceName: String, audioURL: URL, format: RemoteAudioFormat, modeIdentifier: String? = nil, language: String? = nil, startedAt: Date = Date(), endedAt: Date? = nil, bytesReceived: UInt64 = 0) {
        self.id = id
        self.deviceName = deviceName
        self.audioURL = audioURL
        self.format = format
        self.modeIdentifier = modeIdentifier
        self.language = language
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bytesReceived = bytesReceived
    }
}

public protocol RemoteAudioReceiver: AnyObject {
    var session: RemoteScribeSession { get }
    func receive(_ pcmBytes: Data, sequence: UInt64) throws
    func finish() throws -> RemoteScribeSession
    func abort()
}

public final class WAVRemoteAudioReceiver: RemoteAudioReceiver {
    public private(set) var session: RemoteScribeSession
    private let handle: FileHandle
    private var nextSequence: UInt64 = 0
    private var finished = false

    public init(session: RemoteScribeSession) throws {
        guard session.format.isSupported else { throw RemoteScribeError.unsupportedAudioFormat }
        self.session = session
        try FileManager.default.createDirectory(at: session.audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: session.audioURL.path, contents: Data(repeating: 0, count: 44))
        handle = try FileHandle(forWritingTo: session.audioURL)
        try handle.seek(toOffset: 44)
    }

    deinit { try? handle.close() }

    public func receive(_ pcmBytes: Data, sequence: UInt64) throws {
        guard !finished else { throw RemoteScribeError.noActiveSession }
        guard sequence == nextSequence else {
            throw RemoteScribeError.protocolViolation("chunk attendu \(nextSequence), reçu \(sequence)")
        }
        guard pcmBytes.count % 2 == 0 else {
            throw RemoteScribeError.protocolViolation("chunk PCM de taille impaire")
        }
        try handle.write(contentsOf: pcmBytes)
        session.bytesReceived += UInt64(pcmBytes.count)
        nextSequence += 1
    }

    public func finish() throws -> RemoteScribeSession {
        guard !finished else { return session }
        finished = true
        session.endedAt = Date()
        let header = Self.header(format: session.format, dataByteCount: UInt32(clamping: session.bytesReceived))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.synchronize()
        try handle.close()
        return session
    }

    public func abort() {
        guard !finished else { return }
        finished = true
        try? handle.close()
        try? FileManager.default.removeItem(at: session.audioURL)
    }

    static func header(format: RemoteAudioFormat, dataByteCount: UInt32) -> Data {
        var result = Data()
        result.append("RIFF".data(using: .ascii)!)
        appendLE(36 &+ dataByteCount, to: &result)
        result.append("WAVEfmt ".data(using: .ascii)!)
        appendLE(UInt32(16), to: &result)
        appendLE(UInt16(1), to: &result)
        appendLE(UInt16(format.channels), to: &result)
        appendLE(UInt32(format.sampleRate), to: &result)
        appendLE(UInt32(format.bytesPerSecond), to: &result)
        appendLE(UInt16(format.channels * format.bitsPerSample / 8), to: &result)
        appendLE(UInt16(format.bitsPerSample), to: &result)
        result.append("data".data(using: .ascii)!)
        appendLE(dataByteCount, to: &result)
        return result
    }

    private static func appendLE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8((value >> 24) & 0xff))
    }
}
