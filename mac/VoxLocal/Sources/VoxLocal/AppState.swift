import AppKit
import Combine
import CryptoKit
import Foundation
import RemoteScribeCore

/// A dictation received from a paired device, for the iPhone screen.
struct RemoteDictationSummary: Identifiable, Hashable {
    var id: String
    var deviceName: String
    var timestamp: String
    var duration: Double
    var status: String
}

@MainActor
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable { case history = "Dictées", remote = "iPhone", modes = "Modes", settings = "Réglages"; var id: String { rawValue } }
    enum SettingsPage: String, CaseIterable, Identifiable {
        case general = "Général"
        case iphone = "iPhone"
        case intelligence = "Intelligence artificielle"
        var id: String { rawValue }
    }

    let paths: AppPaths
    let modeRepository: ModeRepository
    let historyRepository: HistoryRepository
    let settingsRepository: SettingsRepository
    let catalog: ModelCatalog
    let pipeline: DictationPipeline
    let remoteScribe: VoxLocalRemoteServerController
    let llmServer: LLMServerController
    let hotkey = GlobalHotkey()
    private let superwhisperDesktop = SuperwhisperDesktopController()
    private var superwhisperDesktopRecording = false

    @Published var selection: Section = .history
    @Published var settingsPage: SettingsPage = .general
    @Published var modes: [Mode] = []
    @Published var history: [DictationRecord] = []
    @Published var whisperModels: [ModelInfo] = []
    @Published var llmModels: [ModelInfo] = []
    @Published var settings: AppSettings
    @Published var pipelineStatus: PipelineStatus = .idle
    @Published var currentRecord: DictationRecord?
    @Published var notice: String?
    @Published var selectedHistoryID: String?
    @Published var selectedModeID: String?
    @Published var remoteScribeStatus = "Démarrage…"
    @Published var remoteScribeEnabled = true
    /// Listener state; the toggle alone does not mean the Mac can receive.
    @Published var remoteScribeRunning = false
    @Published var remoteBackend: RemoteBackendKind = .voxLocal
    /// Display form ("ABCD-2345"); `remoteScribe.pairingCode` is the dashless wire value.
    @Published var remotePairingCode = ""
    @Published var remoteTLSFingerprint: String?
    /// `remotescribe://pair?…` payload shown as a QR code; nil without a TLS identity.
    @Published var remotePairingURL: String?
    @Published var remotePeers: [String] = []
    /// The five most recent dictations received from a paired device.
    @Published var remoteDictations: [RemoteDictationSummary] = []
    /// Download progress (0…1) keyed by file name; absent when idle.
    @Published var downloads: [String: Double] = [:]
    /// SHA-256 of the last completed download, keyed by file name.
    @Published var downloadedHashes: [String: String] = [:]
    private var downloadProcesses: [String: Process] = [:]
    private var downloadTimers: [String: Timer] = [:]
    @Published var cloudToken = ""
    @Published var cloudTestRunning = false
    @Published var cloudTestMessage: String?
    @Published var showPermissionSetup = !UserDefaults.standard.bool(forKey: "permissions.onboardingCompleted")

    /// `preview` renders screens without touching the real Keychain pairing code
    /// and without starting llama-server.
    let preview: Bool

    init(paths: AppPaths = AppPaths(), preview: Bool = false) {
        self.paths = paths
        self.preview = preview
        try? paths.ensure()
        modeRepository = ModeRepository(directory: paths.modes)
        historyRepository = HistoryRepository(directory: paths.history)
        settingsRepository = SettingsRepository(url: paths.settings)
        catalog = ModelCatalog(paths: paths)
        var loadedSettings = settingsRepository.load()
        // Migrate tokens written by older builds, then keep the settings JSON
        // harmless if it is copied or included in a diagnostic bundle.
        if let legacyToken = loadedSettings.cloudApiToken?.trimmingCharacters(in: .whitespacesAndNewlines), !legacyToken.isEmpty {
            if (try? PlatformServices.setCloudAPIToken(legacyToken)) != nil {
                loadedSettings.cloudApiToken = nil
                try? settingsRepository.save(loadedSettings)
            }
        }
        settings = loadedSettings
        modeRepository.seedDefaults(); historyRepository.markInterrupted()
        llmServer = LLMServerController(paths: paths)
        pipeline = DictationPipeline(modes: modeRepository, history: historyRepository, settings: settingsRepository, catalog: catalog, llmServer: llmServer)
        remoteScribe = VoxLocalRemoteServerController(paths: paths, modes: modeRepository, history: historyRepository, settings: settingsRepository, catalog: catalog, llmServer: llmServer, ephemeralPairingCode: preview, serviceName: preview ? PreviewRenderer.hostName : RemoteScribeServer.defaultServiceName)
        cloudToken = PlatformServices.cloudAPIToken() ?? loadedSettings.cloudApiToken ?? ""
        pipeline.onState = { [weak self] status, record, message in
            guard let self else { return }
            self.pipelineStatus = status; self.currentRecord = record; self.notice = message; self.reloadHistory()
            if let record { self.selectedHistoryID = record.id }
            if status == .done { NSSound(named: "Glass")?.play() }
            if status == .error { NSSound.beep() }
        }
        reloadAll()
        hotkey.register { [weak self] in Task { @MainActor in self?.toggleRecording() } }
        remoteScribe.onStatus = { [weak self] message in self?.remoteScribeStatus = message }
        remoteScribe.onBackendChanged = { [weak self] backend in self?.remoteBackend = backend }
        remoteScribe.onHistoryChanged = { [weak self] in self?.reloadHistory() }
        remoteScribe.onSecurityChanged = { [weak self] in
            guard let self else { return }
            self.remotePairingCode = self.remoteScribe.pairingCodeDisplay
            self.remoteTLSFingerprint = self.remoteScribe.tlsFingerprintDisplay
            self.remotePairingURL = self.remoteScribe.pairingURL
        }
        remoteScribe.onPeersChanged = { [weak self] names in self?.remotePeers = names }
        remoteScribe.onRunningChanged = { [weak self] running in self?.remoteScribeRunning = running }
        remoteBackend = remoteScribe.defaultBackend
        remoteScribe.start()
    }

    var activeMode: Mode? { modes.first { $0.id == settings.activeModeId } }
    var hasWhisperModel: Bool { settings.usesCloud || whisperModels.contains(where: \.compatible) }

    var microphones: [AudioDeviceInfo] { AudioRecorder().devices() }

    func reloadAll() { reloadModes(); reloadHistory(); rescanModels() }
    func reloadModes() { modes = modeRepository.list(); if selectedModeID == nil { selectedModeID = settings.activeModeId } }
    func reloadHistory() {
        history = historyRepository.list(); if selectedHistoryID == nil { selectedHistoryID = history.first?.id }
        remoteDictations = Array(history.lazy.compactMap { record -> RemoteDictationSummary? in
            guard let device = VoxLocalRemoteBackend.remoteDevice(of: record) else { return nil }
            return RemoteDictationSummary(id: record.id, deviceName: device, timestamp: record.timestamp, duration: record.duration, status: record.processingStatus)
        }.prefix(5))
    }

    func rescanModels() {
        whisperModels = catalog.scanWhisper(); llmModels = catalog.scanLLM()
        if settings.selectedSttModel == nil, whisperModels.filter(\.compatible).count == 1 { settings.selectedSttModel = whisperModels.first(where: \.compatible)?.id }
        if settings.selectedLlmModel == nil, llmModels.filter(\.compatible).count == 1 { settings.selectedLlmModel = llmModels.first(where: \.compatible)?.id }
        saveSettings()
    }

    func saveSettings() {
        do { try settingsRepository.save(settings) } catch { notice = error.localizedDescription }
        refreshLLMServer()
    }

    /// Keeps llama-server warm for the selected local LLM, or stops it when the
    /// Mac computes in the cloud or no compatible model is selected.
    func refreshLLMServer() {
        guard !preview else { return }
        let mode = activeMode ?? modeRepository.get(settings.activeModeId)
        guard !settings.usesCloud, mode?.kind != "verbatim",
              let model = catalog.selected(llmModels, id: mode?.model ?? settings.selectedLlmModel) else { llmServer.stop(); return }
        llmServer.prewarm(model: model.url, context: settings.llmContextSize)
    }

    func showModelSetup() { settingsPage = .intelligence; show(.settings) }

    /// Downloads a recommended model with curl into the models folder, reports
    /// progress from the partial file size, then checks the SHA-256 before the
    /// file becomes visible to the catalogue.
    func download(_ model: RecommendedModel) {
        guard downloads[model.fileName] == nil else { return }
        let folder = catalog.folder(for: model.kind)
        let destination = folder.appendingPathComponent(model.fileName)
        let partial = folder.appendingPathComponent(model.fileName + ".part")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-L", "--fail", "--silent", "--show-error", "--retry", "3", "-o", partial.path, model.url.absoluteString]
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        downloads[model.fileName] = 0; downloadedHashes[model.fileName] = nil
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor in
                guard let self, self.downloads[model.fileName] != nil else { return }
                self.downloads[model.fileName] = min(0.99, Double(size) / Double(model.bytes))
            }
        }
        RunLoop.main.add(timer, forMode: .common); downloadTimers[model.fileName] = timer
        process.terminationHandler = { [weak self] finished in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let status = finished.terminationStatus
            let digest = status == 0 ? Self.sha256(of: partial) : nil
            Task { @MainActor in
                guard let self else { return }
                self.downloadTimers.removeValue(forKey: model.fileName)?.invalidate()
                self.downloads[model.fileName] = nil; self.downloadProcesses[model.fileName] = nil
                guard status == 0, let digest else {
                    try? FileManager.default.removeItem(at: partial)
                    if finished.terminationReason != .uncaughtSignal {
                        self.notice = "Téléchargement de \(model.fileName) impossible : \(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "code \(status)" : message.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                    return
                }
                guard digest == model.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    self.notice = "Empreinte SHA-256 inattendue pour \(model.fileName) : fichier supprimé. Réessayez."
                    return
                }
                try? FileManager.default.removeItem(at: destination)
                do { try FileManager.default.moveItem(at: partial, to: destination) }
                catch { self.notice = error.localizedDescription; return }
                self.downloadedHashes[model.fileName] = digest
                self.rescanModels()
            }
        }
        do { try process.run(); downloadProcesses[model.fileName] = process }
        catch { downloadTimers.removeValue(forKey: model.fileName)?.invalidate(); downloads[model.fileName] = nil; notice = "curl introuvable : \(error.localizedDescription)" }
    }

    func cancelDownload(_ model: RecommendedModel) { downloadProcesses[model.fileName]?.terminate() }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 * 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func saveCloudSettings() {
        let trimmed = cloudToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try PlatformServices.setCloudAPIToken(trimmed.isEmpty ? nil : trimmed)
            // Only clear the legacy Codable field after the Keychain write has
            // succeeded; a locked/unavailable Keychain must not lose the token.
            settings.cloudApiToken = nil
            saveSettings()
        } catch { notice = error.localizedDescription }
    }
    func testCloudConnection() {
        guard !cloudTestRunning else { return }
        saveCloudSettings(); cloudTestRunning = true; cloudTestMessage = "Connexion au GPU en cours…"
        let snapshot = settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let models = try CloudGPUEngine(settings: snapshot).testConnection()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.settings.cloudWhisperModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        self.settings.cloudWhisperModel = models.first { $0.localizedCaseInsensitiveContains("whisper") }
                    }
                    if self.settings.cloudLlmModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        self.settings.cloudLlmModel = models.first { !$0.localizedCaseInsensitiveContains("whisper") }
                    }
                    self.saveCloudSettings()
                    self.cloudTestRunning = false
                    self.cloudTestMessage = models.isEmpty ? "GPU connecté, mais aucun modèle annoncé." : "GPU connecté · \(models.count) modèle(s) détecté(s)."
                }
            } catch {
                DispatchQueue.main.async { self?.cloudTestRunning = false; self?.cloudTestMessage = error.localizedDescription }
            }
        }
    }
    func setActiveMode(_ id: String) { settings.activeModeId = id; selectedModeID = id; saveSettings(); objectWillChange.send() }
    func toggleRecording() {
        guard remoteBackend == .superwhisper else { pipeline.toggle(); return }
        guard pipelineStatus != .processing else { return }
        let starting = !superwhisperDesktopRecording
        superwhisperDesktop.toggle(starting: starting) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.pipelineStatus = .error
                    self.notice = error.localizedDescription
                    return
                }
                self.superwhisperDesktopRecording = starting
                self.pipelineStatus = starting ? .recording : .done
            }
        }
        if !starting { pipelineStatus = .processing }
    }
    func importAudio(_ url: URL) { pipeline.importAudio(url) }
    func reprocess(_ record: DictationRecord) { pipeline.reprocess(record) }
    func setRemoteScribeEnabled(_ enabled: Bool) { remoteScribeEnabled = enabled; enabled ? remoteScribe.start() : remoteScribe.stop() }
    func setRemoteBackend(_ backend: RemoteBackendKind) { remoteScribe.setDefaultBackend(backend) }
    func copyRemotePairingCode() { if PlatformServices.copy(remoteScribe.pairingCode) { notice = "Code d’appairage copié." } }
    func regenerateRemotePairingCode() { remoteScribe.regeneratePairingCode() }
    func show(_ section: Section) { selection = section; NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil) }

    func createMode() { do { let mode = try modeRepository.create(); reloadModes(); selectedModeID = mode.id } catch { notice = error.localizedDescription } }
    func duplicateMode(_ id: String) { do { let mode = try modeRepository.duplicate(id); reloadModes(); selectedModeID = mode.id } catch { notice = error.localizedDescription } }
    func deleteMode(_ id: String) { do { try modeRepository.delete(id); if settings.activeModeId == id { setActiveMode("default") }; reloadModes(); selectedModeID = settings.activeModeId } catch { notice = error.localizedDescription } }
    func saveMode(_ mode: Mode) { do { _ = try modeRepository.save(mode); reloadModes(); selectedModeID = mode.id } catch { notice = error.localizedDescription } }
    func importMode(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var mode = try JSONStore.read(Mode.self, from: url)
            if modeRepository.get(mode.id) != nil {
                mode.id = UUID().uuidString.lowercased()
                mode.name += " — importé"
                mode.createdAt = ISO8601DateFormatter().string(from: Date())
            }
            let saved = try modeRepository.save(mode)
            reloadModes()
            selectedModeID = saved.id
            notice = "Mode « \(saved.name) » importé."
        } catch {
            notice = "Import impossible : \(error.localizedDescription)"
        }
    }

    func exportMode(_ mode: Mode, to url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try JSONStore.write(mode, to: url)
            notice = "Mode « \(mode.name) » exporté."
        } catch {
            notice = "Export impossible : \(error.localizedDescription)"
        }
    }

    func updateStartup(_ enabled: Bool) { do { try PlatformServices.setLaunchAtStartup(enabled); settings.launchAtStartup = enabled; saveSettings() } catch { notice = error.localizedDescription } }
    func finishPermissionSetup() {
        UserDefaults.standard.set(true, forKey: "permissions.onboardingCompleted")
        showPermissionSetup = false
    }
    func shutdown() {
        remoteScribe.stop(); pipeline.shutdown(); hotkey.unregister(); llmServer.stop()
        downloadProcesses.values.forEach { $0.terminate() }
    }
}
