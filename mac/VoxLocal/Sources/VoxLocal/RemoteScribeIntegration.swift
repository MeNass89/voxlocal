import Foundation
import RemoteScribeCore

final class VoxLocalTranscriptionAdapter: TranscriptionEngine {
    private let settings: SettingsRepository
    private let catalog: ModelCatalog
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.transcription", qos: .userInitiated)

    init(settings: SettingsRepository, catalog: ModelCatalog) {
        self.settings = settings
        self.catalog = catalog
    }

    func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
        let current = settings.load()
        if current.usesCloud {
            queue.async {
                do { completion(.success(TranscriptionResult(text: try CloudGPUEngine(settings: current).transcribe(audio: audioURL, language: language).text))) }
                catch { completion(.failure(error)) }
            }
            return
        }
        guard let model = catalog.selected(catalog.scanWhisper(), id: current.selectedSttModel) else {
            // Never report a successful transcription with placeholder text in a
            // production dictation path. The WAV remains in history for retry.
            completion(.failure(VoxError.message("Aucun modèle Whisper local compatible n’est sélectionné. L’audio a été conservé dans l’historique.")))
            return
        }
        queue.async {
            do {
                let result = try WhisperEngine().transcribe(audio: audioURL, model: model.url, language: language ?? current.language)
                completion(.success(TranscriptionResult(text: result.text)))
            } catch { completion(.failure(error)) }
        }
    }
}

final class VoxLocalLLMAdapter: LLMProcessingEngine {
    private let modes: ModeRepository
    private let settings: SettingsRepository
    private let catalog: ModelCatalog
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.llm", qos: .userInitiated)

    init(modes: ModeRepository, settings: SettingsRepository, catalog: ModelCatalog) {
        self.modes = modes
        self.settings = settings
        self.catalog = catalog
    }

    func process(transcription: String, modeIdentifier: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let current = settings.load()
        let mode = modes.get(modeIdentifier ?? current.activeModeId) ?? modes.get("default")
        if current.usesCloud, let mode, mode.kind != "verbatim" {
            queue.async {
                do {
                    let system = "Tu es le moteur d’écriture privé d’une application de dictée. N’ajoute aucun fait absent. Suis exactement cette instruction :\n\(mode.prompt)"
                    completion(.success(try CloudGPUEngine(settings: current).complete(system: system, user: transcription, temperature: mode.temperature)))
                } catch { completion(.failure(error)) }
            }
            return
        }
        guard let mode, mode.kind != "verbatim",
              let model = catalog.selected(catalog.scanLLM(), id: mode.model ?? current.selectedLlmModel) else {
            completion(.success(transcription)); return
        }
        queue.async {
            do {
                let system = "Tu es le moteur d’écriture privé d’une application de dictée médicale. N’ajoute aucun fait absent. Suis exactement cette instruction :\n\(mode.prompt)"
                let final = try LLMEngine().complete(model: model.url, system: system, user: transcription, temperature: mode.temperature, context: current.llmContextSize)
                completion(.success(final))
            } catch { completion(.failure(error)) }
        }
    }
}

final class VoxLocalRemoteBackend: RemoteScribeBackend {
    let kind: RemoteBackendKind = .voxLocal
    var onHistoryChanged: (() -> Void)?

    private let transcription: TranscriptionEngine
    private let llm: LLMProcessingEngine
    private let modes: ModeRepository
    private let history: HistoryRepository
    private let settings: SettingsRepository

    init(modes: ModeRepository, history: HistoryRepository, settings: SettingsRepository, catalog: ModelCatalog) {
        self.modes = modes
        self.history = history
        self.settings = settings
        transcription = VoxLocalTranscriptionAdapter(settings: settings, catalog: catalog)
        llm = VoxLocalLLMAdapter(modes: modes, settings: settings, catalog: catalog)
    }

    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let appSettings = settings.load()
        let pasteTarget: ActiveTarget = Thread.isMainThread
            ? PlatformServices.captureTarget()
            : DispatchQueue.main.sync { PlatformServices.captureTarget() }
        guard let mode = modes.get(session.modeIdentifier ?? appSettings.activeModeId) ?? modes.get("default") else {
            completion(.failure(VoxError.message("Aucun mode VoxLocal valide."))); return
        }
        do {
            var record = try history.create(mode: mode, stt: appSettings.selectedSttModel, llm: appSettings.selectedLlmModel, target: pasteTarget)
            try FileManager.default.copyItem(at: session.audioURL, to: URL(fileURLWithPath: record.audio))
            record.duration = Double(session.bytesReceived) / Double(session.format.bytesPerSecond)
            record.processingStatus = "processing"
            try history.save(record)
            transcription.transcribe(audioURL: URL(fileURLWithPath: record.audio), language: session.language ?? mode.language) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.fail(record, error: error, completion: completion)
                case .success(let raw):
                    var transcribed = record
                    transcribed.rawTranscription = raw.text
                    try? self.history.save(transcribed)
                    self.llm.process(transcription: raw.text, modeIdentifier: mode.id) { processed in
                        switch processed {
                        case .failure(let error): self.fail(transcribed, error: error, completion: completion)
                        case .success(let final):
                            var completed = transcribed
                            completed.finalTranscription = final
                            completed.processingStatus = "completed"
                            try? self.history.save(completed)
                            DispatchQueue.main.async {
                                self.onHistoryChanged?()
                                let message: String
                                if appSettings.autopasteEnabled {
                                    let paste = PlatformServices.paste(final, to: pasteTarget)
                                    message = paste.0
                                        ? "Dictée distante traitée et collée automatiquement."
                                        : (paste.1 ?? "Dictée distante traitée et copiée dans le presse-papier.")
                                } else if appSettings.keepClipboardText {
                                    _ = PlatformServices.copy(final)
                                    message = "Dictée distante traitée et copiée dans le presse-papier."
                                } else {
                                    message = "Dictée distante traitée."
                                }
                                completion(.success(RemoteBackendResult(transcription: raw.text, finalText: final, resultLocation: completed.audio, message: message)))
                            }
                        }
                    }
                }
            }
        } catch { completion(.failure(error)) }
    }

    private func fail(_ input: DictationRecord, error: Error, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        var record = input
        record.processingStatus = "error"
        record.error = error.localizedDescription
        try? history.save(record)
        DispatchQueue.main.async { self.onHistoryChanged?() }
        completion(.failure(error))
    }
}

final class VoxLocalRemoteServerController {
    var onStatus: ((String) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onBackendChanged: ((RemoteBackendKind) -> Void)?
    private let backend: VoxLocalRemoteBackend
    private let superwhisperBackend: SuperwhisperRemoteBackend?
    private let paths: AppPaths
    private var server: RemoteScribeServer?
    private(set) var running = false
    private(set) var defaultBackend: RemoteBackendKind

    var availableBackends: [RemoteBackendKind] {
        SuperwhisperRemoteBackend.isInstalled ? [.voxLocal, .superwhisper] : [.voxLocal]
    }

    init(paths: AppPaths, modes: ModeRepository, history: HistoryRepository, settings: SettingsRepository, catalog: ModelCatalog) {
        self.paths = paths
        backend = VoxLocalRemoteBackend(modes: modes, history: history, settings: settings, catalog: catalog)
        superwhisperBackend = SuperwhisperRemoteBackend.isInstalled
            ? SuperwhisperRemoteBackend(modes: modes, history: history, settings: settings)
            : nil
        defaultBackend = RemoteBackendKind(rawValue: UserDefaults.standard.string(forKey: "remoteScribe.defaultBackend") ?? "") ?? .voxLocal
        if defaultBackend == .superwhisper && !SuperwhisperRemoteBackend.isInstalled { defaultBackend = .voxLocal }
        backend.onHistoryChanged = { [weak self] in self?.onHistoryChanged?() }
        superwhisperBackend?.onHistoryChanged = { [weak self] in self?.onHistoryChanged?() }
    }

    func start() {
        guard !running else { return }
        var backends: [RemoteScribeBackend] = [backend]
        if let superwhisperBackend { backends.append(superwhisperBackend) }
        let instance = RemoteScribeServer(backends: backends, defaultBackend: defaultBackend, serviceName: Host.current().localizedName ?? "VoxLocal", sessionsDirectory: paths.remoteSessions)
        instance.onEvent = { [weak self] message in self?.onStatus?(message) }
        do { try instance.start(); server = instance; running = true; onStatus?("Remote Scribe actif · \(displayName(defaultBackend)).") }
        catch { onStatus?("Remote Scribe indisponible : \(error.localizedDescription)") }
    }

    func stop() { server?.stop(); server = nil; running = false; onStatus?("Remote Scribe arrêté.") }

    func setDefaultBackend(_ backend: RemoteBackendKind) {
        guard availableBackends.contains(backend) else { onStatus?("SuperWhisper n’est pas installé sur ce Mac."); return }
        defaultBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: "remoteScribe.defaultBackend")
        onBackendChanged?(backend)
        if running { stop(); start() }
    }

    private func displayName(_ backend: RemoteBackendKind) -> String { backend == .voxLocal ? "VoxLocal" : "SuperWhisper temporaire" }
}
