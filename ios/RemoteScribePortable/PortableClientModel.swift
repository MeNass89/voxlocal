import Foundation
import Network
import SwiftUI
import UIKit

enum PortablePhase: String {
    case searching, connecting, ready, starting, recording, stopping, processing, completed, failed

    var title: String {
        switch self {
        case .searching: return "Recherche du serveur"
        case .connecting: return "Connexion"
        case .ready: return "Prêt"
        case .starting: return "Démarrage"
        case .recording: return "Enregistrement"
        case .stopping: return "Envoi des derniers morceaux"
        case .processing: return "Traitement"
        case .completed: return "Terminé"
        case .failed: return "Erreur"
        }
    }

    var systemImage: String {
        switch self {
        case .searching: return "wifi"
        case .connecting, .starting, .stopping, .processing: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .recording: return "waveform.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

extension RemoteBackendKind: Identifiable {
    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .superwhisper: return "Superwhisper"
        case .voxLocal: return "Vox Local"
        }
    }
}

struct PortableResult: Codable, Hashable, Identifiable {
    let id: UUID
    let completedAt: Date
    let duration: TimeInterval
    let backend: RemoteBackendKind
    let finalText: String
    let rawText: String?
}

/// SHA-256 of a server's leaf certificate, shown as uppercase hex in groups of
/// four ("AB12 CD34 …"), the same format VoxLocal displays on the Mac.
struct ServerFingerprint: Hashable {
    let data: Data

    var groups: [String] {
        let hex = data.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: min(4, hex.count - offset))])
        }
    }

    var display: String { groups.joined(separator: " ") }
    var shortDisplay: String { groups.prefix(4).joined(separator: " ") }
}

/// A TLS server whose certificate is neither pinned nor trusted by the system.
/// The user compares the fingerprint with the one shown on the server before
/// pinning it (trust on first use).
struct PendingTrust: Identifiable {
    let key: String
    let serverName: String
    let fingerprint: Data
    let reconnect: () -> Void

    var id: String { key }
    var display: String { ServerFingerprint(data: fingerprint).display }
}

/// The pin stored for the server the user last chose.
struct PinnedServerIdentity: Equatable {
    let key: String
    let fingerprint: ServerFingerprint
}

@MainActor
final class PortableClientModel: ObservableObject {
    @Published private(set) var servers: [DiscoveredRemoteScribeServer] = []
    @Published private(set) var phase: PortablePhase = .searching
    @Published private(set) var serverName: String?
    @Published private(set) var connectionMessage = "Recherche sur le réseau local…"
    @Published private(set) var availableBackends = RemoteBackendKind.allCases
    @Published var selectedBackend: RemoteBackendKind {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: Keys.backend) }
    }
    @Published var manualHost: String
    @Published var manualPort: String
    @Published var pairingCode: String
    @Published var useTLS: Bool {
        didSet { UserDefaults.standard.set(useTLS, forKey: Keys.useTLS) }
    }
    @Published private(set) var selectedServerID: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var results: [PortableResult]
    @Published private(set) var errorText: String?
    @Published private(set) var storageMessage: String?
    @Published private(set) var historyPersistenceEnabled: Bool
    @Published private(set) var historyPurgePending: Bool
    @Published private(set) var connectedWithTLS: Bool?
    @Published var pendingTrust: PendingTrust?
    @Published private(set) var pinnedIdentity: PinnedServerIdentity?

    private let browser = RemoteScribeBrowser()
    private let client = RemoteScribeClient()
    private let audio = AudioStreamer()
    private var timer: Timer?
    private var deadline: Timer?
    private var operationID = UUID()
    private var captureStarting = false

    private var startedAt: Date?
    private var activeSessionID: UUID?
    private var connectedEndpoint: NWEndpoint?
    private var isPaired = false
    private var discoveryStarted = false
    // Pin key of the server being connected: Bonjour service name, or host:port.
    private var currentServerKey: String?
    private var currentReconnect: (() -> Void)?
    // Pins the Keychain refused to store; valid for this run only.
    private var memoryPins: [String: Data] = [:]

    private enum Keys {
        static let backend = "portable.backend"
        static let manualHost = "portable.manualHost"
        static let manualPort = "portable.manualPort"
        static let deviceID = "portable.deviceID"
        static let results = "portable.results"
        static let historyKeychainAccount = "transcription-history"
        static let useTLS = "portable.useTLS"
        static let persistHistory = "portable.persistHistory"
        static let purgePending = "portable.historyPurgePending"
        static func pin(_ serverKey: String) -> String { "pin:" + serverKey }
    }

    var elapsedText: String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    var canStart: Bool { isPaired && activeSessionID == nil && [.ready, .completed, .failed].contains(phase) }
    var canStop: Bool { phase == .recording }
    var isBusy: Bool { [.connecting, .starting, .stopping, .processing].contains(phase) }
    var isConnected: Bool { isPaired }

    init() {
        let defaults = UserDefaults.standard
        serverName = nil
        selectedServerID = nil
        errorText = nil
        storageMessage = nil
        connectedWithTLS = nil
        selectedBackend = RemoteBackendKind(rawValue: defaults.string(forKey: Keys.backend) ?? "") ?? .superwhisper
        manualHost = defaults.string(forKey: Keys.manualHost) ?? ""
        manualPort = defaults.string(forKey: Keys.manualPort) ?? String(RemoteScribeProtocol.defaultPort)
        pairingCode = ""
        useTLS = defaults.object(forKey: Keys.useTLS) == nil ? true : defaults.bool(forKey: Keys.useTLS)
        let purgePending = defaults.bool(forKey: Keys.purgePending)
        historyPurgePending = purgePending
        historyPersistenceEnabled = defaults.bool(forKey: Keys.persistHistory) && !purgePending
        results = []
        do { pairingCode = try SecurePairingStore.load() }
        catch { storageMessage = "Code non chargé : \(error.localizedDescription) Saisissez-le pour une connexion en mémoire." }
        // Never migrate legacy patient text into persistent storage implicitly.
        defaults.removeObject(forKey: Keys.results)
        if historyPersistenceEnabled {
            do {
                if let data = try SecurePairingStore.loadData(account: Keys.historyKeychainAccount) {
                    results = try JSONDecoder().decode([PortableResult].self, from: data)
                }
            } catch { storageMessage = "Historique non chargé : \(error.localizedDescription)" }
        } else {
            purgeStoredHistory()
        }
        configureCallbacks()
    }

    #if DEBUG
    // Screenshot hook: `-VoxLocalDebugTrustSheet 1` shows the trust sheet with a
    // synthetic fingerprint, without a server. Seeded once the window is on screen.
    private func seedDebugTrustSheet() {
        guard UserDefaults.standard.bool(forKey: "VoxLocalDebugTrustSheet") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let fingerprint = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            self.serverName = "Poste-Radiologie.local"
            self.phase = .failed
            self.connectionMessage = "Identité du serveur à confirmer."
            self.pendingTrust = PendingTrust(key: "Poste-Radiologie", serverName: "Poste-Radiologie.local", fingerprint: fingerprint, reconnect: {})
        }
    }
    #endif

    func startDiscovery() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        if !isPaired {
            phase = .searching
            connectionMessage = "Recherche sur le réseau local…"
        }
        browser.start()
        #if DEBUG
        seedDebugTrustSheet()
        #endif
    }

    func connect(to server: DiscoveredRemoteScribeServer) {
        guard !isBusy, activeSessionID == nil, validatePairingCode() else { return }
        // The only non-TLS profile supported by the server is the explicit
        // localhost mock. Bonjour can discover a remote service, so never let a
        // stale TCP toggle silently send microphone audio over the LAN.
        guard useTLS else {
            fail("TLS est requis pour un serveur découvert. Pour un test mock local, utilisez la connexion manuelle sur localhost.", connectionLost: true)
            return
        }
        guard let pin = loadPin(for: server.name) else { return }
        savePairingCode()
        selectedServerID = server.id
        connectedEndpoint = server.endpoint
        serverName = server.name
        currentServerKey = server.name
        currentReconnect = { [weak self] in self?.connect(to: server) }
        if !server.availableBackends.isEmpty {
            availableBackends = server.availableBackends
            if !availableBackends.contains(selectedBackend) { selectedBackend = availableBackends[0] }
        }
        beginConnection {
            client.connect(to: server.endpoint, deviceID: deviceID, deviceName: UIDevice.current.name, pairingCode: normalizedPairingCode, tls: useTLS, pinnedFingerprint: pin)
        }
    }

    func connectManually() {
        guard !isBusy, activeSessionID == nil, validatePairingCode() else { return }
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            fail("Indiquez le nom ou l’adresse IP du serveur.", connectionLost: true)
            return
        }
        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            fail("Le port doit être compris entre 1 et 65535.", connectionLost: true)
            return
        }
        if !useTLS && !isLoopbackHost(host) {
            fail("Une connexion sans TLS est réservée à localhost pour les tests synthétiques.", connectionLost: true)
            return
        }
        UserDefaults.standard.set(host, forKey: Keys.manualHost)
        UserDefaults.standard.set(manualPort, forKey: Keys.manualPort)
        connectManual(host: host, port: port)
    }

    private func connectManual(host: String, port: UInt16) {
        guard !isBusy, activeSessionID == nil, validatePairingCode() else { return }
        let key = "\(host):\(port)"
        guard let pin = loadPin(for: key) else { return }
        savePairingCode()
        selectedServerID = nil
        connectedEndpoint = nil
        serverName = host
        currentServerKey = key
        currentReconnect = { [weak self] in self?.connectManual(host: host, port: port) }
        beginConnection {
            do {
                try client.connect(host: host, port: port, deviceID: deviceID, deviceName: UIDevice.current.name, pairingCode: normalizedPairingCode, tls: useTLS, pinnedFingerprint: pin)
            } catch {
                fail(error.localizedDescription, connectionLost: true)
            }
        }
    }

    /// Stores the confirmed fingerprint for the pending server, then reconnects;
    /// from now on only this certificate is accepted for that server.
    func trustPendingServer() {
        guard let trust = pendingTrust else { return }
        pendingTrust = nil
        do {
            try SecurePairingStore.saveData(trust.fingerprint, account: Keys.pin(trust.key))
            memoryPins[trust.key] = nil
        } catch {
            memoryPins[trust.key] = trust.fingerprint
            storageMessage = "Empreinte du serveur conservée en mémoire uniquement : \(error.localizedDescription)"
        }
        refreshPinnedIdentity()
        trust.reconnect()
    }

    /// Also called when the sheet is swiped away; a no-op once trust led to a reconnection.
    func cancelPendingTrust() {
        pendingTrust = nil
        guard phase == .failed else { return }
        connectionMessage = "Connexion annulée : identité du serveur non confirmée."
    }

    /// Deletes the pin; the next connection to this server asks for confirmation again.
    func forgetServerIdentity(key: String) {
        do {
            try SecurePairingStore.deleteData(account: Keys.pin(key))
        } catch {
            storageMessage = "Empreinte non effacée du trousseau : \(error.localizedDescription)"
            return
        }
        memoryPins[key] = nil
        if key == currentServerKey && (isPaired || isBusy) { disconnect() }
        refreshPinnedIdentity()
    }

    /// `nil` stops the connection: an unreadable pin must not degrade to a
    /// first-use prompt. `.some(nil)` means no pin is stored for this server.
    private func loadPin(for key: String) -> Data?? {
        guard useTLS else { return .some(nil) }
        if let pin = memoryPins[key] { return .some(pin) }
        do {
            return .some(try SecurePairingStore.loadData(account: Keys.pin(key)))
        } catch {
            fail("Empreinte du serveur illisible dans le trousseau : \(error.localizedDescription) Déverrouillez l’iPhone puis réessayez.", connectionLost: true)
            return nil
        }
    }

    private func refreshPinnedIdentity() {
        guard let key = currentServerKey else { pinnedIdentity = nil; return }
        let pin = memoryPins[key] ?? (try? SecurePairingStore.loadData(account: Keys.pin(key)) ?? nil)
        pinnedIdentity = pin.map { PinnedServerIdentity(key: key, fingerprint: ServerFingerprint(data: $0)) }
    }

    private func requestTrust(fingerprintBase64: String) {
        guard let key = currentServerKey, let reconnect = currentReconnect,
              let fingerprint = Data(base64Encoded: fingerprintBase64), fingerprint.count == 32 else {
            fail("Certificat du serveur non vérifiable.", connectionLost: true)
            return
        }
        let name = serverName ?? key
        fail("Identité du serveur à confirmer.", connectionLost: true)
        errorText = nil
        pendingTrust = PendingTrust(key: key, serverName: name, fingerprint: fingerprint, reconnect: reconnect)
    }

    func disconnect() {
        operationID = UUID()
        cancelDeadline()
        captureStarting = false
        connectedWithTLS = nil
        stopCapture()
        client.disconnect()
        isPaired = false
        activeSessionID = nil
        connectedEndpoint = nil
        selectedServerID = nil
        currentServerKey = nil
        currentReconnect = nil
        pinnedIdentity = nil
        phase = .searching
        serverName = nil
        connectionMessage = "Déconnecté. Recherche sur le réseau local…"
        errorText = nil
    }

    func retry() {
        disconnect()
        startDiscovery()
    }

    func toggleRecording() {
        if canStop { stop() }
        else if canStart { start() }
    }

    func start() {
        guard canStart else { return }
        operationID = UUID()
        let token = operationID
        phase = .starting
        errorText = nil
        audioLevel = 0
        elapsed = 0
        connectionMessage = "Vérification de l’accès au microphone…"
        audio.requestPermission { [weak self] granted in
            guard let self, self.operationID == token, self.phase == .starting else { return }
            guard granted else {
                self.fail("Autorisation microphone refusée. Activez-la dans Réglages → Confidentialité et sécurité → Microphone.")
                return
            }
            do {
                self.activeSessionID = try self.client.startSession(
                    language: Locale.current.language.languageCode?.identifier ?? "fr",
                    backend: self.selectedBackend
                )
                self.connectionMessage = "Le serveur prépare la session…"
                self.armDeadline(seconds: 30, message: "Le serveur n’a pas démarré la session à temps. Reconnectez-vous.")
            } catch {
                self.activeSessionID = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard phase == .recording, let sessionID = activeSessionID else { return }
        let token = operationID
        phase = .stopping
        connectionMessage = "Envoi des derniers morceaux audio…"
        audioLevel = 0
        stopTimer()
        armDeadline(seconds: 30, message: "L’arrêt audio n’a pas abouti. Reconnectez-vous.")
        audio.stop(drain: true) { [weak self] in
            guard let self, self.operationID == token, self.activeSessionID == sessionID, self.phase == .stopping else { return }
            do {
                try self.client.stopSession()
                self.phase = .processing
                self.connectionMessage = "Traitement sur le serveur…"
                UIApplication.shared.isIdleTimerDisabled = true
                self.armDeadline(seconds: 300, message: "Le traitement dépasse cinq minutes. La connexion a été fermée ; vérifiez le poste avant de recommencer.")
            } catch { self.fail(error.localizedDescription, connectionLost: true) }
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        if scenePhase == .active && historyPurgePending { purgeStoredHistory() }
        // The `audio` background mode keeps AVAudioEngine and the existing LAN
        // connection alive while the screen is locked. Never turn a lock into
        // an implicit STOP: the user remains in control of the clinical session.
        if scenePhase != .active && phase == .recording {
            connectionMessage = "Enregistrement en arrière-plan…"
        } else if scenePhase == .active && phase == .recording {
            connectionMessage = "Enregistrement et envoi vers le serveur…"
        }
    }

    func clearHistory() {
        results = []
        purgeStoredHistory()
    }

    func setHistoryPersistence(_ enabled: Bool) {
        if enabled {
            guard !historyPurgePending else { purgeStoredHistory(); return }
            historyPersistenceEnabled = true
            UserDefaults.standard.set(true, forKey: Keys.persistHistory)
            persistResults()
        } else {
            historyPersistenceEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.persistHistory)
            purgeStoredHistory()
        }
    }

    private func purgeStoredHistory() {
        UserDefaults.standard.removeObject(forKey: Keys.results)
        historyPurgePending = true
        UserDefaults.standard.set(true, forKey: Keys.purgePending)
        do {
            try SecurePairingStore.deleteData(account: Keys.historyKeychainAccount)
            historyPurgePending = false
            UserDefaults.standard.set(false, forKey: Keys.purgePending)
            storageMessage = nil
        } catch {
            // A tombstone prevents reloading erased text after relaunch, even if
            // protected Keychain data cannot be deleted until the next unlock.
            historyPersistenceEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.persistHistory)
            storageMessage = "Effacement du trousseau non confirmé : \(error.localizedDescription) Réessayez après déverrouillage."
        }
    }

    private func configureCallbacks() {
        browser.onServersChanged = { [weak self] servers in
            guard let self else { return }
            self.servers = servers
            // Discovery is untrusted: the user must choose a server explicitly.
        }
        browser.onError = { [weak self] error in
            Task { @MainActor in
                guard let self, !self.isPaired, self.phase == .searching else { return }
                self.connectionMessage = "Découverte locale impossible : \(error.localizedDescription). Utilisez la connexion manuelle."
            }
        }
        client.onStateChanged = { [weak self] state in self?.handleConnectionState(state) }
        client.onPairResponse = { [weak self] response in self?.handlePair(response) }
        client.onSessionStatus = { [weak self] sessionID, status in self?.handleStatus(sessionID: sessionID, status: status) }
        client.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let activePhase = [.connecting, .starting, .recording, .stopping, .processing, .ready, .completed].contains(self.phase)
                guard activePhase, self.isPaired || self.phase == .connecting else { return }
                switch error.code {
                case RemoteErrorPayload.untrustedServerCode where self.phase == .connecting:
                    self.requestTrust(fingerprintBase64: error.message)
                case RemoteErrorPayload.pinMismatchCode:
                    // The message carries the observed fingerprint; never show it as an error text.
                    self.fail("L’identité du serveur a changé. Vérifiez le poste avant de réessayer.", connectionLost: true)
                default:
                    self.fail(error.message, connectionLost: true)
                }
            }
        }
        audio.onError = { [weak self] error in
            guard let self, [.starting, .recording, .stopping].contains(self.phase) else { return }
            self.fail(error.localizedDescription, connectionLost: true)
        }
        audio.onPCM = { [weak self, weak client = client] data in
            guard let client else { return }
            do { try client.sendAudio(data) }
            catch {
                Task { @MainActor in self?.fail(error.localizedDescription, connectionLost: true) }
            }
        }
        audio.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.audioLevel = level
            }
        }
    }

    private func beginConnection(_ action: () -> Void) {
        operationID = UUID()
        captureStarting = false
        connectedWithTLS = useTLS
        stopCapture()
        client.disconnect()
        isPaired = false
        activeSessionID = nil
        pendingTrust = nil
        refreshPinnedIdentity()
        phase = .connecting
        errorText = nil
        connectionMessage = "Connexion et appairage…"
        armDeadline(seconds: 20, message: "Connexion ou appairage sans réponse. Vérifiez le serveur, le réseau et son certificat TLS.")
        action()
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectionMessage = "Connexion établie, appairage…"
        case .waiting(let error):
            if isPaired { fail("Réseau interrompu : \(error.localizedDescription)", connectionLost: true) }
            else { connectionMessage = "Réseau indisponible : \(error.localizedDescription)" }
        case .cancelled:
            if isPaired || phase == .connecting { fail("Connexion fermée. Reconnectez le serveur.", connectionLost: true) }
        case .failed(let error):
            fail("Connexion perdue : \(error.localizedDescription)", connectionLost: true)
        default:
            break
        }
    }

    private func handlePair(_ response: PairResponse) {
        guard phase == .connecting else { return }
        guard response.accepted else {
            fail("Le serveur a refusé l’appairage.", connectionLost: true)
            return
        }
        cancelDeadline()
        isPaired = true
        serverName = response.serverName
        availableBackends = response.availableBackends?.isEmpty == false ? response.availableBackends! : [response.selectedBackend]
        // A reconnection follows a backend change on the server. Adopt the server's
        // current choice instead of restoring a stale preference from the phone.
        selectedBackend = response.selectedBackend
        phase = .ready
        errorText = nil
        connectionMessage = "Connexion locale prête."
    }

    private func handleStatus(sessionID: UUID, status: SessionStatusPayload) {
        if sessionID == RemoteFrame.noSession {
            if status.state == .ready && isPaired && activeSessionID == nil { phase = .ready }
            return
        }
        guard sessionID == activeSessionID else { return }
        connectionMessage = status.message ?? status.state.rawValue
        switch status.state {
        case .recording:
            guard phase == .starting else { return }
            beginCapture()
        case .processing:
            guard phase == .processing || phase == .stopping else {
                fail("Le serveur a interrompu l’enregistrement.", connectionLost: true)
                return
            }
            phase = .processing
        case .completed:
            finishCompleted(sessionID: sessionID, status: status)
        case .failed:
            activeSessionID = nil
            client.abandonSession()
            stopCapture()
            fail(status.message ?? "Le traitement a échoué.")
        default:
            break
        }
    }

    private func beginCapture() {
        guard !captureStarting else { return }
        captureStarting = true
        let token = operationID
        connectionMessage = "Ouverture du microphone…"
        audio.start { [weak self] error in
            guard let self, self.operationID == token, self.phase == .starting else { return }
            if let error {
                self.fail(error.localizedDescription, connectionLost: true)
                return
            }
            self.cancelDeadline()
            self.captureStarting = false
            self.phase = .recording
            self.startedAt = Date()
            self.elapsed = 0
            self.connectionMessage = "Enregistrement et envoi vers le serveur…"
            UIApplication.shared.isIdleTimerDisabled = true
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startedAt = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
        }
    }

    private func finishCompleted(sessionID: UUID, status: SessionStatusPayload) {
        cancelDeadline()
        client.abandonSession()
        let final = nonEmpty(status.finalText) ?? nonEmpty(status.transcription) ?? "Le serveur n’a pas transmis de texte."
        let result = PortableResult(
            id: sessionID,
            completedAt: Date(),
            duration: elapsed,
            backend: status.backend,
            finalText: final,
            rawText: nonEmpty(status.rawTranscription)
        )
        results.removeAll { $0.id == sessionID }
        results.insert(result, at: 0)
        if results.count > 50 { results.removeLast(results.count - 50) }
        persistResults()
        activeSessionID = nil
        stopCapture()
        phase = .completed
        errorText = nil
        connectionMessage = status.message ?? "Dictée terminée."
    }

    private func fail(_ message: String, connectionLost: Bool = false) {
        operationID = UUID()
        captureStarting = false
        cancelDeadline()
        errorText = message
        connectionMessage = message
        phase = .failed
        stopCapture()
        if connectionLost {
            isPaired = false
            activeSessionID = nil
            connectedWithTLS = nil
            client.disconnect()
        }
    }

    private func stopCapture() {
        audio.stop()
        audioLevel = 0
        stopTimer()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
    }

    private func armDeadline(seconds: TimeInterval, message: String) {
        cancelDeadline()
        let token = operationID
        deadline = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.operationID == token else { return }
                self.fail(message, connectionLost: true)
            }
        }
    }

    private func cancelDeadline() { deadline?.invalidate(); deadline = nil }

    private func validatePairingCode() -> Bool {
        guard normalizedPairingCode != nil else {
            errorText = "Saisissez le code d’appairage affiché sur le serveur."
            return false
        }
        return true
    }

    private func savePairingCode() {
        do { try SecurePairingStore.save(pairingCode) }
        catch { storageMessage = "Code utilisé en mémoire uniquement : \(error.localizedDescription)" }
    }

    private var normalizedPairingCode: String? {
        let value = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value == "::1" { return true }
        let octets = value.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.dropFirst().allSatisfy { UInt8($0) != nil }
    }

    private var deviceID: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: Keys.deviceID) { return value }
        let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(value, forKey: Keys.deviceID)
        return value
    }

    private func persistResults() {
        guard historyPersistenceEnabled, !historyPurgePending else { return }
        do {
            try SecurePairingStore.saveData(JSONEncoder().encode(results), account: Keys.historyKeychainAccount)
        } catch {
            historyPersistenceEnabled = false
            UserDefaults.standard.set(false, forKey: Keys.persistHistory)
            purgeStoredHistory()
            if !historyPurgePending {
                storageMessage = "Conservation impossible : \(error.localizedDescription) Textes conservés en mémoire uniquement."
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
