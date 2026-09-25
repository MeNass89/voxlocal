import Foundation
import RemoteScribeCore

struct Options {
    var backend: RemoteBackendKind = .superwhisper
    var port: UInt16 = RemoteScribeProtocol.defaultPort
    var pairingCode: String?
    var tlsDirectory: URL?
    var insecurePlaintext = false
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
            case "--tls-dir":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                tlsDirectory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true)
            case "--insecure-plaintext":
                insecurePlaintext = true
            case "--sessions":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                sessionsDirectory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath, isDirectory: true)
            case "--help", "-h": throw CLIError.usage
            default: throw CLIError.usage
            }
            index += 1
        }
        if insecurePlaintext && tlsDirectory != nil { throw CLIError.usage }
        guard insecurePlaintext || tlsDirectory != nil else { throw CLIError.tlsRequired }
        guard insecurePlaintext || !(pairingCode ?? "").isEmpty else { throw CLIError.pairingCodeRequired }
    }
}

enum CLIError: Error { case usage, tlsRequired, pairingCodeRequired }

let usage = """
Usage: RemoteScribeHost --tls-dir DIR --pairing-code CODE [--backend voxlocal|superwhisper] [--port 47365] [--sessions DIR]
       RemoteScribeHost --insecure-plaintext [--pairing-code CODE] [--backend …] [--port …] [--sessions DIR]
  --tls-dir DIR          identité TLS 1.3 (server.key.pem + server.cert.pem), créée si absente
  --pairing-code CODE    code exigé à l’appairage (obligatoire avec TLS)
  --insecure-plaintext   TCP sans chiffrement, réservé aux tests locaux
"""

// Line-buffer stdout so the fingerprint and events reach a log file even when the host is killed.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    let options = try Options(arguments: CommandLine.arguments)
    let backends: [RemoteScribeBackend] = [SuperwhisperBackend(), VoxLocalBackend()]
    var tlsIdentity: RemoteScribeTLSIdentity?
    if let directory = options.tlsDirectory {
        let identity = try RemoteScribeTLSIdentity.loadOrCreate(in: directory, hostname: Host.current().localizedName ?? "remote-scribe")
        print("Empreinte TLS: \(identity.fingerprintDisplay)")
        tlsIdentity = identity
    } else {
        print("Attention : --insecure-plaintext, le trafic n’est pas chiffré.")
    }
    let server = RemoteScribeServer(
        backends: backends,
        defaultBackend: options.backend,
        serviceName: Host.current().localizedName ?? "Remote Scribe",
        sessionsDirectory: options.sessionsDirectory,
        pairingCode: options.pairingCode,
        tlsIdentity: tlsIdentity
    )
    server.onEvent = { print("[RemoteScribe] \($0)") }
    try server.start(port: options.port)
    print("Remote Scribe actif. Moteur par défaut: \(options.backend.rawValue). Choix distant: superwhisper, voxlocal. Ctrl-C pour arrêter.")
    RunLoop.main.run()
} catch CLIError.usage {
    print(usage)
    exit(2)
} catch CLIError.tlsRequired {
    fputs("Remote Scribe: TLS obligatoire. Passez --tls-dir DIR (ou --insecure-plaintext pour un test local).\n\(usage)\n", stderr)
    exit(2)
} catch CLIError.pairingCodeRequired {
    fputs("Remote Scribe: --pairing-code est obligatoire avec TLS.\n\(usage)\n", stderr)
    exit(2)
} catch {
    fputs("Remote Scribe: \(error.localizedDescription)\n", stderr)
    exit(1)
}
