import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import Foundation
import Security

enum PlatformServices {
    private static let cloudTokenService = "com.voxlocal.cloud-api-token"
    private static let cloudTokenAccount = "default"
    private static let pairingCodeService = "com.voxlocal.remote-scribe"
    private static let pairingCodeAccount = "pairing-code"
    private static let pairingAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessibilityAuthorized: Bool { AXIsProcessTrusted() }

    /// API credentials belong in the macOS Keychain, never in the JSON settings
    /// file (which is routinely copied during support and backup workflows).
    static func cloudAPIToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudTokenService, kSecAttrAccount as String: cloudTokenAccount,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func setCloudAPIToken(_ token: String?) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cloudTokenService, kSecAttrAccount as String: cloudTokenAccount]
        if let token, !token.isEmpty {
            let data = Data(token.utf8)
            let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = base; item[kSecValueData as String] = data
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VoxError.message("Impossible d’enregistrer le token dans le trousseau macOS.") }
            } else if status != errSecSuccess { throw VoxError.message("Impossible de mettre à jour le token dans le trousseau macOS.") }
        } else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VoxError.message("Impossible de supprimer le token du trousseau macOS.") }
        }
    }

    /// Remote Scribe pairing code (dashless wire value), kept in the Keychain like the cloud token.
    static func remotePairingCode() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pairingCodeService, kSecAttrAccount as String: pairingCodeAccount,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let code = String(data: data, encoding: .utf8), !code.isEmpty else { return nil }
        return code
    }

    static func setRemotePairingCode(_ code: String?) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: pairingCodeService, kSecAttrAccount as String: pairingCodeAccount]
        if let code, !code.isEmpty {
            let data = Data(code.utf8)
            let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = base; item[kSecValueData as String] = data
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw VoxError.message("Impossible d’enregistrer le code d’appairage dans le trousseau macOS.") }
            } else if status != errSecSuccess { throw VoxError.message("Impossible de mettre à jour le code d’appairage dans le trousseau macOS.") }
        } else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VoxError.message("Impossible de supprimer le code d’appairage du trousseau macOS.") }
        }
    }

    /// 8 characters from an alphabet without look-alikes (no I, O, 0, 1), drawn with
    /// SecRandomCopyBytes; 256 is a multiple of 32, so the modulo adds no bias.
    /// Returned dashless: that is the wire value. Use `displayPairingCode` for the UI.
    static func generatePairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return String(bytes.map { pairingAlphabet[Int($0) % pairingAlphabet.count] })
    }

    /// "ABCD2345" → "ABCD-2345".
    static func displayPairingCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { completion(granted) } }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings(_ pane: PrivacyPane) {
        let anchor: String
        switch pane {
        case .microphone: anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .localNetwork: anchor = "Privacy_LocalNetwork"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }

    enum PrivacyPane { case microphone, accessibility, localNetwork }

    static func captureTarget() -> ActiveTarget {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return ActiveTarget() }
        return ActiveTarget(name: app.localizedName, identifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
    }

    @discardableResult static func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    static func paste(_ text: String, to target: ActiveTarget) -> (Bool, String?) {
        guard copy(text) else { return (false, "Impossible de copier le texte dans le presse-papier.") }
        guard AXIsProcessTrusted() else {
            return (false, "Texte copié. L’auto-collage nécessite l’autorisation Accessibilité dans Réglages Système → Confidentialité et sécurité.")
        }
        if let pid = target.processIdentifier, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if #available(macOS 14, *) { app.activate() }
            else { app.activate(options: [.activateIgnoringOtherApps]) }
        }
        Thread.sleep(forTimeInterval: 0.15)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return (false, "Texte copié, mais la simulation du collage a échoué.")
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return (true, nil)
    }

    static func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    static func setLaunchAtStartup(_ enabled: Bool) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plist = directory.appendingPathComponent("com.voxlocal.desktop.plist")
        if !enabled { try? FileManager.default.removeItem(at: plist); return }
        guard let executable = Bundle.main.executableURL else { throw VoxError.message("Exécutable VoxLocal introuvable.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = ["Label": "com.voxlocal.desktop", "ProgramArguments": [executable.path], "RunAtLoad": true, "ProcessType": "Interactive"]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
    }
}

final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) {
        unregister(); self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue().action?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x564F584C), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil; action = nil
    }
    deinit { unregister() }
}
