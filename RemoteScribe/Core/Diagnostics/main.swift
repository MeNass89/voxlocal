import Foundation
import RemoteScribeCore

enum CheckError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckError.failed(message) }
    print("PASS: \(message)")
}

do {
    let sessionID = UUID()
    let first = RemoteFrame(kind: .audioChunk, sessionID: sessionID, sequence: 42, payload: Data([1, 2, 3, 4]))
    let second = try RemoteFrame.json(kind: .ping, value: PingPayload(timestamp: 123))
    let bytes = try RemoteFrameEncoder.encode(first) + RemoteFrameEncoder.encode(second)
    let decoder = RemoteFrameDecoder()
    let partial = try decoder.append(bytes.prefix(7))
    let decoded = try decoder.append(bytes.dropFirst(7))
    try check(partial.isEmpty, "décodage incrémental")
    try check(decoded == [first, second], "aller-retour de deux trames")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-scribe-diagnostics-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let audioURL = root.appendingPathComponent("audio.wav")
    let session = RemoteScribeSession(id: sessionID, deviceName: "diagnostic", audioURL: audioURL, format: RemoteAudioFormat())
    let receiver = try WAVRemoteAudioReceiver(session: session)
    try receiver.receive(Data(repeating: 1, count: 320), sequence: 0)
    let finished = try receiver.finish()
    let wav = try Data(contentsOf: audioURL)
    try check(String(data: wav.prefix(4), encoding: .ascii) == "RIFF" && wav.count == 364 && finished.bytesReceived == 320, "finalisation WAV PCM")

    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(backend: VoxLocalBackend(), serverName: "diagnostic", sessionsDirectory: root) { replies.append($0) }
    handler.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone")))
    let secondID = UUID()
    handler.handle(try .json(kind: .startSession, sessionID: secondID, value: StartSessionRequest()))
    handler.handle(RemoteFrame(kind: .audioChunk, sessionID: secondID, sequence: 0, payload: Data(repeating: 0, count: 320)))
    handler.handle(try .json(kind: .stopSession, sessionID: secondID, value: StopSessionRequest(framesSent: 160)))
    let states = try replies.filter { $0.kind == .sessionStatus }.map { try $0.decode(SessionStatusPayload.self).state }
    print("États observés: \(states.map(\.rawValue).joined(separator: " → "))")
    try check(states == [.ready, .recording, .processing, .completed], "PAIR → START → AUDIO → STOP → pipeline")
    print("RemoteScribeDiagnostics: OK")
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
