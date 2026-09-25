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

@Test func tlsIdentityIsGeneratedAndStable() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("tls", isDirectory: true)
    let first = try RemoteScribeTLSIdentity.loadOrCreate(in: directory, hostname: "Mac de Clément")
    let second = try RemoteScribeTLSIdentity.loadOrCreate(in: directory, hostname: "Mac de Clément")
    #expect(first.certificateDER == second.certificateDER)
    #expect(first.fingerprintSHA256 == second.fingerprintSHA256)
    #expect(first.fingerprintSHA256.count == 32)
    #expect(Data(base64Encoded: first.fingerprintBase64) == first.fingerprintSHA256)
    let groups = first.fingerprintDisplay.split(separator: " ")
    #expect(groups.count == 16)
    #expect(groups.allSatisfy { $0.count == 4 && $0.allSatisfy { "0123456789ABCDEF".contains($0) } })
    let keyMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("server.key.pem").path)[.posixPermissions] as? NSNumber
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(keyMode?.intValue == 0o600)
    #expect(directoryMode?.intValue == 0o700)
    // No transient PKCS#12 may survive a load.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".p12") }
    #expect(leftovers.isEmpty)
    let tempLeftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
    #expect(!tempLeftovers.contains { $0.hasPrefix("remotescribe-identity-") })
}

@Test func pairingGateLocksAfterFiveFailures() {
    var clock = Date(timeIntervalSince1970: 1_000)
    let gate = RemotePairingGate(maxFailures: 5, window: 600, lockout: 60, now: { clock })
    for _ in 0..<4 { gate.recordFailure(peer: "a") }
    #expect(!gate.isLocked(peer: "a"))
    gate.recordFailure(peer: "a")
    #expect(gate.isLocked(peer: "a"))
    #expect(!gate.isLocked(peer: "b"))
    clock += 59
    #expect(gate.isLocked(peer: "a"))
    clock += 2
    #expect(!gate.isLocked(peer: "a"))

    // Failures outside the sliding window do not accumulate.
    for _ in 0..<4 { gate.recordFailure(peer: "c") }
    clock += 601
    gate.recordFailure(peer: "c")
    #expect(!gate.isLocked(peer: "c"))

    // A success clears the counter.
    for _ in 0..<4 { gate.recordFailure(peer: "d") }
    gate.recordSuccess(peer: "d")
    gate.recordFailure(peer: "d")
    #expect(!gate.isLocked(peer: "d"))
}

@Test func pairLockedPeerIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var clock = Date(timeIntervalSince1970: 1_000)
    let gate = RemotePairingGate(now: { clock })
    func handler(peer: String, into replies: @escaping (RemoteFrame) -> Void) -> RemoteSessionHandler {
        RemoteSessionHandler(backend: VoxLocalBackend(), serverName: "test", sessionsDirectory: root, pairingCode: "ABCD2345", pairingGate: gate, peer: peer, sender: replies)
    }
    var attacker: [RemoteFrame] = []
    let wrong = handler(peer: "x") { attacker.append($0) }
    for _ in 0..<5 { wrong.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone", pairingCode: "WRONG999"))) }
    #expect(attacker.filter { $0.kind == .error }.count == 5)
    #expect(gate.isLocked(peer: "x"))

    // The sixth attempt from the locked peer is refused even with the right code.
    attacker.removeAll()
    let retry = handler(peer: "x") { attacker.append($0) }
    retry.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone", pairingCode: "ABCD2345")))
    let refusal = try #require(attacker.first { $0.kind == .error }).decode(RemoteErrorPayload.self)
    #expect(refusal.message.contains("trop de tentatives"))
    #expect(!attacker.contains { $0.kind == .pair })

    // Another peer still pairs while "x" is locked.
    var other: [RemoteFrame] = []
    handler(peer: "y") { other.append($0) }.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id2", deviceName: "tablet", pairingCode: "ABCD2345")))
    #expect(other.contains { $0.kind == .pair })
    #expect(!other.contains { $0.kind == .error })

    // A missing or shorter code is rejected, not accepted.
    var missing: [RemoteFrame] = []
    handler(peer: "z") { missing.append($0) }.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id3", deviceName: "phone")))
    handler(peer: "z") { missing.append($0) }.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id3", deviceName: "phone", pairingCode: "ABCD")))
    #expect(missing.filter { $0.kind == .error }.count == 2)
    #expect(!missing.contains { $0.kind == .pair })

    // After the lockout the right code pairs again.
    clock += 61
    var later: [RemoteFrame] = []
    handler(peer: "x") { later.append($0) }.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone", pairingCode: "ABCD2345")))
    #expect(later.contains { $0.kind == .pair })
}

@Test func frameBeforePairIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(backend: VoxLocalBackend(), serverName: "test", sessionsDirectory: root) { replies.append($0) }
    handler.handle(try .json(kind: .ping, value: PingPayload(timestamp: 1)))
    #expect(!replies.contains { $0.kind == .ping })
    let error = try #require(replies.first { $0.kind == .error }).decode(RemoteErrorPayload.self)
    #expect(error.message == RemoteScribeError.notPaired.localizedDescription)
}

@Test func secondPairIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(backend: VoxLocalBackend(), serverName: "test", sessionsDirectory: root) { replies.append($0) }
    handler.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "phone")))
    #expect(replies.filter { $0.kind == .pair }.count == 1)
    replies.removeAll()
    handler.handle(try .json(kind: .pair, value: PairRequest(deviceID: "id", deviceName: "other")))
    #expect(!replies.contains { $0.kind == .pair })
    let error = try #require(replies.first { $0.kind == .error }).decode(RemoteErrorPayload.self)
    #expect(error.message.contains("PAIR déjà reçu"))
}

@Test func pairWithASessionIDIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var replies: [RemoteFrame] = []
    let handler = RemoteSessionHandler(backend: VoxLocalBackend(), serverName: "test", sessionsDirectory: root) { replies.append($0) }
    handler.handle(try .json(kind: .pair, sessionID: UUID(), value: PairRequest(deviceID: "id", deviceName: "phone")))
    #expect(!replies.contains { $0.kind == .pair })
    let error = try #require(replies.first { $0.kind == .error }).decode(RemoteErrorPayload.self)
    #expect(error.message.contains("PAIR sans session"))
    // Nothing else is accepted on this connection afterwards.
    replies.removeAll()
    handler.handle(try .json(kind: .startSession, sessionID: UUID(), value: StartSessionRequest()))
    #expect(replies.allSatisfy { $0.kind == .error })
}

/// The controller drops its reference right after `stop()`; the listener must
/// still be torn down so the port can be bound again.
@Test func stoppedServerReleasesItsPort() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var server: RemoteScribeServer? = RemoteScribeServer(backend: VoxLocalBackend(), serviceName: "stop-test-\(UUID().uuidString.prefix(8))", sessionsDirectory: root)
    let ready = DispatchSemaphore(value: 0)
    var port: UInt16 = 0
    server?.onReady = { actual in port = actual; ready.signal() }
    try server?.start(port: 0)
    #expect(ready.wait(timeout: .now() + 5) == .success)
    #expect(port != 0)
    server?.stop()
    server = nil
    var bound = false
    let deadline = Date().addingTimeInterval(3)
    while !bound && Date() < deadline {
        bound = canBind(port: port)
        if !bound { usleep(50_000) }
    }
    #expect(bound)
}

/// Dual-stack wildcard bind without SO_REUSEADDR: fails while any listener holds the port.
private func canBind(port: UInt16) -> Bool {
    let fd = socket(AF_INET6, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var off: Int32 = 0
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = port.bigEndian
    address.sin6_addr = in6addr_any
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
    }
}

private final class ImmediateBackend: RemoteScribeBackend {
    let kind: RemoteBackendKind
    init(kind: RemoteBackendKind) { self.kind = kind }
    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        completion(.success(RemoteBackendResult(transcription: "ok", finalText: "ok")))
    }
}
