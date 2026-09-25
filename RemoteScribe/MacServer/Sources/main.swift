import Foundation
import RemoteScribeCore

struct Options {
    var backend: RemoteBackendKind = .superwhisper
    var port: UInt16 = RemoteScribeProtocol.defaultPort
    var pairingCode: String?
    var pairingCodeFile: URL?
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
            case "--pairing-code-file":
                index += 1
                guard index < arguments.count else { throw CLIError.usage }
                pairingCodeFile = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
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
        // `ps` shows argv to every local user: the secret travels in argv only for plaintext tests.
        if pairingCode != nil {
            guard insecurePlaintext else { throw CLIError.pairingCodeInArgv }
            guard pairingCodeFile == nil else { throw CLIError.usage }
        }
        if let pairingCodeFile {
            pairingCode = try Self.readPairingCode(from: pairingCodeFile)
        } else if pairingCode == nil,
                  let value = ProcessInfo.processInfo.environment["REMOTESCRIBE_PAIRING_CODE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty {
            pairingCode = value
        }
        guard insecurePlaintext || !(pairingCode ?? "").isEmpty else { throw CLIError.pairingCodeRequired }
    }

    /// The file must be readable by its owner only (0600 or stricter).
    static func readPairingCode(from url: URL) throws -> String {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw CLIError.pairingCodeFile("\(url.path) illisible") }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else {
            throw CLIError.pairingCodeFile("\(url.path) doit être en 0600 (actuel : \(String(mode & 0o777, radix: 8)))")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CLIError.pairingCodeFile("\(url.path) illisible") }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw CLIError.pairingCodeFile("\(url.path) est vide") }
        return code
    }
}

enum CLIError: Error { case usage, tlsRequired, pairingCodeRequired, pairingCodeInArgv, pairingCodeFile(String) }

let usage = """
Usage: RemoteScribeHost --tls-dir DIR --pairing-code-file PATH [--backend voxlocal|superwhisper] [--port 47365] [--sessions DIR]
       REMOTESCRIBE_PAIRING_CODE=CODE RemoteScribeHost --tls-dir DIR [--backend …] [--port …] [--sessions DIR]
       RemoteScribeHost --insecure-plaintext [--pairing-code CODE] [--backend …] [--port …] [--sessions DIR]
  --tls-dir DIR             identité TLS 1.3 (server.key.pem + server.cert.pem), créée si absente
  --pairing-code-file PATH  fichier contenant le code exigé à l’appairage, en 0600 (code obligatoire avec TLS)
  REMOTESCRIBE_PAIRING_CODE variable d’environnement, alternative au fichier
  --pairing-code CODE       réservé à --insecure-plaintext : argv est visible de tous les comptes (ps)
  --insecure-plaintext      TCP sans chiffrement, réservé aux tests locaux
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
    fputs("Remote Scribe: un code d’appairage est obligatoire avec TLS (--pairing-code-file ou REMOTESCRIBE_PAIRING_CODE).\n\(usage)\n", stderr)
    exit(2)
} catch CLIError.pairingCodeInArgv {
    fputs("Remote Scribe: --pairing-code est refusé avec TLS (visible dans ps) ; utilisez --pairing-code-file ou REMOTESCRIBE_PAIRING_CODE.\n\(usage)\n", stderr)
    exit(2)
} catch CLIError.pairingCodeFile(let reason) {
    fputs("Remote Scribe: code d’appairage : \(reason).\n", stderr)
    exit(2)
} catch {
    fputs("Remote Scribe: \(error.localizedDescription)\n", stderr)
    exit(1)
}
