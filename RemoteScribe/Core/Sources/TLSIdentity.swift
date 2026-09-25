import CryptoKit
import Foundation
import Network
import Security

/// The TLS identity a Remote Scribe host presents to clients.
///
/// The fingerprint is the SHA-256 of the DER leaf certificate. Clients pin it
/// (trust on first use) after the user compares it with the value shown on the host.
public struct RemoteScribeTLSIdentity {
    public let identity: sec_identity_t
    public let certificateDER: Data

    public init(identity: sec_identity_t, certificateDER: Data) {
        self.identity = identity
        self.certificateDER = certificateDER
    }

    /// SHA-256 of `certificateDER`.
    public var fingerprintSHA256: Data { Data(SHA256.hash(data: certificateDER)) }

    /// Canonical form, published in the Bonjour TXT record under `fp`.
    public var fingerprintBase64: String { fingerprintSHA256.base64EncodedString() }

    /// Human form: uppercase hex in groups of 4 separated by spaces ("AB12 CD34 …").
    public var fingerprintDisplay: String { Self.display(fingerprintSHA256) }

    static func display(_ digest: Data) -> String {
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[start..<end])
        }.joined(separator: " ")
    }
}

#if os(macOS)
extension RemoteScribeTLSIdentity {
    static let keyFileName = "server.key.pem"
    static let certificateFileName = "server.cert.pem"
    private static let opensslPath = "/usr/bin/openssl"
    private static let passphraseVariable = "VOXLOCAL_P12_PASS"

    /// Loads `server.key.pem` + `server.cert.pem` from `directory` (kept at 0700, key at 0600)
    /// or generates an RSA-2048 self-signed certificate valid 3650 days with
    /// SAN DNS:<hostname>.local, DNS:localhost, IP:127.0.0.1.
    ///
    /// iOS never generates identities; this is macOS-only.
    public static func loadOrCreate(in directory: URL, hostname: String) throws -> RemoteScribeTLSIdentity {
        guard FileManager.default.isExecutableFile(atPath: opensslPath) else {
            throw RemoteScribeError.transport("openssl introuvable")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let keyURL = directory.appendingPathComponent(keyFileName)
        let certificateURL = directory.appendingPathComponent(certificateFileName)
        if !fileManager.fileExists(atPath: keyURL.path) || !fileManager.fileExists(atPath: certificateURL.path) {
            try generate(keyURL: keyURL, certificateURL: certificateURL, hostname: dnsLabel(hostname))
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return try importIdentity(keyURL: keyURL, certificateURL: certificateURL)
    }

    /// Reduces a human computer name ("Mac de Clément") to one DNS label ("mac-de-clement").
    static func dnsLabel(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var label = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                label.unicodeScalars.append(scalar)
            } else if !label.isEmpty, !label.hasSuffix("-") {
                label.append("-")
            }
        }
        while label.hasSuffix("-") { label.removeLast() }
        label = String(label.prefix(63))
        while label.hasSuffix("-") { label.removeLast() }
        return label.isEmpty ? "voxlocal" : label
    }

    private static func generate(keyURL: URL, certificateURL: URL, hostname: String) throws {
        try? FileManager.default.removeItem(at: keyURL)
        try? FileManager.default.removeItem(at: certificateURL)
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path, "-out", certificateURL.path, "-days", "3650",
            "-subj", "/CN=\(hostname).local/O=VoxLocal",
            "-addext", "subjectAltName=DNS:\(hostname).local,DNS:localhost,IP:127.0.0.1"
        ], environment: [:])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    private static func importIdentity(keyURL: URL, certificateURL: URL) throws -> RemoteScribeTLSIdentity {
        // Transient PKCS#12 protected by a one-shot random passphrase that only travels
        // through the child environment (never argv) and is dropped after import.
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw RemoteScribeError.transport("Génération aléatoire impossible pour l’identité TLS.")
        }
        let passphrase = Data(random).base64EncodedString()
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("remotescribe-identity-\(UUID().uuidString).p12")
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RemoteScribeError.transport("Fichier temporaire impossible pour l’identité TLS.")
        }
        try runOpenSSL([
            "pkcs12", "-export", "-inkey", keyURL.path, "-in", certificateURL.path, "-out", archiveURL.path,
            "-passout", "env:\(passphraseVariable)",
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"
        ], environment: [passphraseVariable: passphrase])
        let archive = try Data(contentsOf: archiveURL)

        // macOS 15 is the deployment floor, so the identity never lands in the login keychain.
        let options: [String: Any] = [kSecImportExportPassphrase as String: passphrase,
                                      kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(archive as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let entry = entries.first,
              let identityRef = entry[kSecImportItemIdentity as String] else {
            throw RemoteScribeError.transport("Import de l’identité TLS impossible (OSStatus \(status)).")
        }
        let secIdentity = identityRef as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess, let certificate else {
            throw RemoteScribeError.transport("Certificat TLS illisible.")
        }
        let der = SecCertificateCopyData(certificate) as Data
        guard let identity = sec_identity_create(secIdentity) else {
            throw RemoteScribeError.transport("Identité TLS inutilisable par Network.framework.")
        }
        return RemoteScribeTLSIdentity(identity: identity, certificateDER: der)
    }

    private static func runOpenSSL(_ arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { current, _ in current }
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "code \(process.terminationStatus)"
            throw RemoteScribeError.transport("openssl \(arguments.first ?? "") a échoué : \(detail)")
        }
    }
}
#endif
