import Foundation
import RemoteScribeCore

struct TestClientOptions {
    var host = "127.0.0.1"
    var port = RemoteScribeProtocol.defaultPort
    var audioURL: URL?
    var pairingCode: String?
    var backend: RemoteBackendKind?
    var discover = false

    init(_ arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--host": index += 1; if index < arguments.count { host = arguments[index] }
            case "--port": index += 1; if index < arguments.count { port = UInt16(arguments[index]) ?? port }
            case "--audio": index += 1; if index < arguments.count { audioURL = URL(fileURLWithPath: arguments[index]) }
            case "--pairing-code": index += 1; if index < arguments.count { pairingCode = arguments[index] }
            case "--backend": index += 1; if index < arguments.count { backend = RemoteBackendKind(rawValue: arguments[index]) }
            case "--discover": discover = true
            default: break
            }
            index += 1
        }
    }
}

let options = TestClientOptions(CommandLine.arguments)
let client = RemoteScribeClient()
var started = false
var done = false
var exitCode: Int32 = 1

func pcmData() throws -> Data {
    guard let url = options.audioURL else { return Data(repeating: 0, count: 32_000) }
    let data = try Data(contentsOf: url)
    guard data.count > 44, String(data: data.prefix(4), encoding: .ascii) == "RIFF" else {
        throw RemoteScribeError.unsupportedAudioFormat
    }
    var offset = 12
    while offset + 8 <= data.count {
        let name = String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii)
        let sizeBytes = data.subdata(in: (offset + 4)..<(offset + 8))
        let size = sizeBytes.enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        let content = offset + 8
        if name == "data", content + size <= data.count { return data.subdata(in: content..<(content + size)) }
        offset = content + size + (size % 2)
    }
    throw RemoteScribeError.unsupportedAudioFormat
}

client.onStateChanged = { state in
    if case .failed(let error) = state { print("Connexion échouée: \(error)"); done = true }
}
client.onPairResponse = { response in
    let available = (response.availableBackends ?? [response.selectedBackend]).map(\.rawValue).joined(separator: ", ")
    print("PAIR: \(response.serverName), défaut \(response.selectedBackend.rawValue), disponibles \(available)")
    guard !started else { return }; started = true
    do {
        let id = try client.startSession(language: "fr", backend: options.backend)
        print("START_SESSION \(id.uuidString)")
        let pcm = try pcmData()
        for offset in stride(from: 0, to: pcm.count, by: 16_000) {
            try client.sendAudio(pcm.subdata(in: offset..<min(offset + 16_000, pcm.count)))
        }
        try client.stopSession()
        print("STOP_SESSION")
    } catch { print("Client: \(error.localizedDescription)"); done = true }
}
client.onSessionStatus = { id, status in
    print("SESSION_STATUS \(id.uuidString) \(status.state.rawValue): \(status.message ?? "")")
    if let text = status.transcription { print("RESULT: \(text)") }
    if status.state == .completed { exitCode = 0; done = true }
    if status.state == .failed { done = true }
}
client.onError = { error in print("ERROR \(error.code): \(error.message)") }

let deviceID = "cli-\(UUID().uuidString)"
let deviceName = Host.current().localizedName ?? "CLI Test"
var browser: RemoteScribeBrowser?
if options.discover {
    let discovery = RemoteScribeBrowser(); browser = discovery
    discovery.onServersChanged = { servers in
        guard let server = servers.first else { return }
        print("BONJOUR: \(server.name)")
        discovery.stop()
        client.connect(to: server.endpoint, deviceID: deviceID, deviceName: deviceName, pairingCode: options.pairingCode)
    }
    discovery.onError = { error in print("Bonjour: \(error.localizedDescription)"); done = true }
    discovery.start()
} else {
    do { try client.connect(host: options.host, port: options.port, deviceID: deviceID, deviceName: deviceName, pairingCode: options.pairingCode) }
    catch { print(error.localizedDescription); exit(1) }
}

let deadline = Date().addingTimeInterval(300)
while !done && RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) && Date() < deadline {}
client.disconnect()
exit(exitCode)
