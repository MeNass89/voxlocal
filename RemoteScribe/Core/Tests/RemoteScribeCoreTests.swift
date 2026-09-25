import Foundation
import Testing
@testable import RemoteScribeCore

@Test func frameRoundTripAndPartialReads() throws {
    let session = UUID()
    let first = RemoteFrame(kind: .audioChunk, sessionID: session, sequence: 42, payload: Data([1, 2, 3, 4]))
    let second = try RemoteFrame.json(kind: .ping, value: PingPayload(timestamp: 123))
    let bytes = try RemoteFrameEncoder.encode(first) + RemoteFrameEncoder.encode(second)
    let decoder = RemoteFrameDecoder()
    #expect(try decoder.append(bytes.prefix(7)).isEmpty)
    #expect(try decoder.append(bytes.dropFirst(7)) == [first, second])
}

@Test func wavReceiverFinalizesHeader() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("audio.wav")
    let session = RemoteScribeSession(id: UUID(), deviceName: "test", audioURL: url, format: RemoteAudioFormat())
    let receiver = try WAVRemoteAudioReceiver(session: session)
    try receiver.receive(Data(repeating: 1, count: 320), sequence: 0)
    let finished = try receiver.finish()
    let data = try Data(contentsOf: url)
    #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
    #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
    #expect(data.count == 364)
    #expect(finished.bytesReceived == 320)
}

@Test func sessionStateMachineTriggersBackend() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = VoxLocalBackend()
    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(backend: backend, serverName: "test", sessionsDirectory: root) { replies.append($0) }
    handler.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone")))
    let id = UUID()
    handler.handle(try .json(kind: .startSession, sessionID: id, value: StartSessionRequest()))
    handler.handle(RemoteFrame(kind: .audioChunk, sessionID: id, sequence: 0, payload: Data(repeating: 0, count: 320)))
    handler.handle(try .json(kind: .stopSession, sessionID: id, value: StopSessionRequest(framesSent: 160)))
    let states = try replies.filter { $0.kind == .sessionStatus }.map { try $0.decode(SessionStatusPayload.self).state }
    #expect(states == [.ready, .recording, .processing, .completed])
}

@Test func stopWithWrongFramesSentIsRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(backend: VoxLocalBackend(), serverName: "test", sessionsDirectory: root) { replies.append($0) }
    handler.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone")))
    let id = UUID()
    handler.handle(try .json(kind: .startSession, sessionID: id, value: StartSessionRequest()))
    handler.handle(RemoteFrame(kind: .audioChunk, sessionID: id, sequence: 0, payload: Data(repeating: 0, count: 320)))
    handler.handle(try .json(kind: .stopSession, sessionID: id, value: StopSessionRequest(framesSent: 999)))
    let errors = try replies.filter { $0.kind == .error }.map { try $0.decode(RemoteErrorPayload.self) }
    #expect(errors.contains { $0.message.contains("framesSent") })
    let states = try replies.filter { $0.kind == .sessionStatus }.map { try $0.decode(SessionStatusPayload.self).state }
    #expect(!states.contains(.completed))
}

@Test func sessionCanSelectAnAdvertisedBackend() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let vox = VoxLocalBackend()
    let superwhisper = ImmediateBackend(kind: .superwhisper)
    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(
        backends: [.voxLocal: vox, .superwhisper: superwhisper],
        defaultBackend: .superwhisper,
        serverName: "test",
        sessionsDirectory: root
    ) { replies.append($0) }

    handler.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone")))
    let pairFrame = try #require(replies.first { $0.kind == .pair })
    let pair = try pairFrame.decode(PairResponse.self)
    #expect(pair.selectedBackend == .superwhisper)
    #expect(pair.availableBackends == [.voxLocal, .superwhisper])

    let id = UUID()
    handler.handle(try .json(kind: .startSession, sessionID: id, value: StartSessionRequest(backend: .voxLocal)))
    handler.handle(RemoteFrame(kind: .audioChunk, sessionID: id, sequence: 0, payload: Data(repeating: 0, count: 320)))
    handler.handle(try .json(kind: .stopSession, sessionID: id, value: StopSessionRequest(framesSent: 160)))
    let statuses = try replies.filter { $0.kind == .sessionStatus && $0.sessionID == id }.map { try $0.decode(SessionStatusPayload.self) }
    #expect(statuses.map(\.state) == [.recording, .processing, .completed])
    #expect(statuses.allSatisfy { $0.backend == .voxLocal })
}

private final class ImmediateBackend: RemoteScribeBackend {
    let kind: RemoteBackendKind
    init(kind: RemoteBackendKind) { self.kind = kind }
    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        completion(.success(RemoteBackendResult(transcription: "ok", finalText: "ok")))
    }
}
