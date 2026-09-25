import AppKit
import Combine
import Foundation
import RemoteScribeCore

@MainActor
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable { case history = "Dictées", modes = "Modes", settings = "Réglages"; var id: String { rawValue } }

    let paths: AppPaths
    let modeRepository: ModeRepository
    let historyRepository: HistoryRepository
    let settingsRepository: SettingsRepository
    let catalog: ModelCatalog
    let pipeline: DictationPipeline
    let remoteScribe: VoxLocalRemoteServerController
    let hotkey = GlobalHotkey()
    private let superwhisperDesktop = SuperwhisperDesktopController()
    private var superwhisperDesktopRecording = false

    @Published var selection: Section = .history
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
    @Published var remoteBackend: RemoteBackendKind = .voxLocal
    @Published var cloudToken = ""
    @Published var cloudTestRunning = false
    @Published var cloudTestMessage: String?
    @Published var showPermissionSetup = !UserDefaults.standard.bool(forKey: "permissions.onboardingCompleted")

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
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
        pipeline = DictationPipeline(modes: modeRepository, history: historyRepository, settings: settingsRepository, catalog: catalog)
        remoteScribe = VoxLocalRemoteServerController(paths: paths, modes: modeRepository, history: historyRepository, settings: settingsRepository, catalog: catalog)
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
        remoteBackend = remoteScribe.defaultBackend
        remoteScribe.start()
    }

    var activeMode: Mode? { modes.first { $0.id == settings.activeModeId } }
    var microphones: [AudioDeviceInfo] { AudioRecorder().devices() }

    func reloadAll() { reloadModes(); reloadHistory(); rescanModels() }
    func reloadModes() { modes = modeRepository.list(); if selectedModeID == nil { selectedModeID = settings.activeModeId } }
    func reloadHistory() { history = historyRepository.list(); if selectedHistoryID == nil { selectedHistoryID = history.first?.id } }

    func rescanModels() {
        whisperModels = catalog.scanWhisper(); llmModels = catalog.scanLLM()
        if settings.selectedSttModel == nil, whisperModels.filter(\.compatible).count == 1 { settings.selectedSttModel = whisperModels.first(where: \.compatible)?.id }
        if settings.selectedLlmModel == nil, llmModels.filter(\.compatible).count == 1 { settings.selectedLlmModel = llmModels.first(where: \.compatible)?.id }
        saveSettings()
    }

    func saveSettings() { do { try settingsRepository.save(settings) } catch { notice = error.localizedDescription } }
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
    func shutdown() { remoteScribe.stop(); pipeline.shutdown(); hotkey.unregister() }
}
