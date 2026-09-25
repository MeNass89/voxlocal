import Foundation
import RemoteScribeCore

struct Options {
    var backend: RemoteBackendKind = .superwhisper
    var port: UInt16 = RemoteScribeProtocol.defaultPort
    var pairingCode: String?
    var sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RemoteScribe/sessions", isDirectory: true)

    init(arguments: [String]) throws {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--backend":
                index += 1
                guard index < arguments.count, let value = RemoteBackendKind(rawValue: arguments[index]) else { throw CLIError.usage }
                backend = value
            case "--port":
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]) else { throw CLIError.usage }
                port = value
            case "--pairing-code":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                pairingCode = arguments[index]
            case "--sessions":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                sessionsDirectory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true)
            case "--help", "-h": throw CLIError.usage
            default: throw CLIError.usage
            }
            index += 1
        }
    }
}

enum CLIError: Error { case usage }

do {
    let options = try Options(arguments: CommandLine.arguments)
    let backends: [RemoteScribeBackend] = [SuperwhisperBackend(), VoxLocalBackend()]
    let server = RemoteScribeServer(
        backends: backends,
        defaultBackend: options.backend,
        serviceName: Host.current().localizedName ?? "Remote Scribe",
        sessionsDirectory: options.sessionsDirectory,
        pairingCode: options.pairingCode
    )
    server.onEvent = { print("[RemoteScribe] \($0)") }
    try server.start(port: options.port)
    print("Remote Scribe actif. Moteur par défaut: \(options.backend.rawValue). Choix distant: superwhisper, voxlocal. Ctrl-C pour arrêter.")
    RunLoop.main.run()
} catch CLIError.usage {
    print("Usage: RemoteScribeHost [--backend voxlocal|superwhisper] [--port 47365] [--pairing-code CODE] [--sessions DIR]")
    exit(2)
} catch {
    fputs("Remote Scribe: \(error.localizedDescription)\n", stderr)
    exit(1)
}
