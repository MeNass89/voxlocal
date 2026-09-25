import Foundation

/// Pairing payload that VoxLocal shows as a QR code on the poste:
/// `remotescribe://pair?name=<Bonjour service name>&code=<dashless code>&fp=<base64 SHA-256 of the DER certificate>`.
///
/// A valid link pins the certificate without the first-use confirmation, because
/// the user read it from the poste's own screen. Parsing is therefore strict: any
/// link that is not exactly this shape is rejected rather than repaired.
struct PairingLink: Equatable {
    let serverName: String
    let code: String
    let fingerprint: Data

    static let scheme = "remotescribe"
    static let action = "pair"
    static let codeLengths = 6...64
    /// Bonjour instance names are limited to 63 UTF-8 bytes.
    static let maximumNameBytes = 63
    /// The Mac draws codes from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`; the Python host
    /// accepts an operator-chosen code, so ASCII letters, digits, `-` and `_` are allowed.
    static let codeAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.action,
              url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        // URLComponents percent-decodes each value. A repeated key is ambiguous,
        // so it invalidates the whole link; unknown keys are ignored.
        var values: [String: String] = [:]
        for item in items where ["name", "code", "fp"].contains(item.name) {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }

        guard let name = values["name"], Self.isValidName(name),
              let code = values["code"], Self.codeLengths.contains(code.count),
              code.allSatisfy({ Self.codeAlphabet.contains($0) }),
              let encoded = values["fp"],
              let fingerprint = Data(base64Encoded: encoded), fingerprint.count == 32
        else { return nil }

        serverName = name
        self.code = code
        self.fingerprint = fingerprint
    }

    /// Accepts a pasted link; surrounding whitespace and new lines are ignored.
    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        self.init(url: url)
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name.utf8.count <= maximumNameBytes
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
