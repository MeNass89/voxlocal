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
            completion(.failure(VoxError.message(ModelCatalog.missingWhisperMessage)))
            return
        }
        queue.async {
            do {
                let result = try WhisperEngine().transcribe(audio: audioURL, model: model.url, language: language ?? current.language, beamSize: current.beamSize)
                completion(.success(TranscriptionResult(text: result.text)))
            } catch { completion(.failure(error)) }
        }
    }
}

final class VoxLocalLLMAdapter: LLMProcessingEngine {
    private let modes: ModeRepository
    private let settings: SettingsRepository
    private let catalog: ModelCatalog
    private let engine: LLMEngine
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.llm", qos: .userInitiated)

    init(modes: ModeRepository, settings: SettingsRepository, catalog: ModelCatalog, llmServer: LLMServerController?) {
        self.modes = modes
        self.settings = settings
        self.catalog = catalog
        engine = LLMEngine(server: llmServer)
    }

    func process(transcription: String, modeIdentifier: String?, completion: @escaping (Result<String, Error>) -> Void) {
        complete(transcription: transcription, modeIdentifier: modeIdentifier) { completion($0.map(\.text)) }
    }

    /// Same as `process`, but keeps the warning raised when the warm server fell
    /// back to llama-cli.
    func complete(transcription: String, modeIdentifier: String?, completion: @escaping (Result<LLMCompletion, Error>) -> Void) {
        let current = settings.load()
        let mode = modes.get(modeIdentifier ?? current.activeModeId) ?? modes.get("default")
        if current.usesCloud, let mode, mode.kind != "verbatim" {
            queue.async {
                do {
                    let system = "Tu es le moteur d’écriture privé d’une application de dictée. N’ajoute aucun fait absent. Suis exactement cette instruction :\n\(mode.prompt)"
                    completion(.success(LLMCompletion(text: try CloudGPUEngine(settings: current).complete(system: system, user: transcription, temperature: mode.temperature))))
                } catch { completion(.failure(error)) }
            }
            return
        }
        guard let mode, mode.kind != "verbatim",
              let model = catalog.selected(catalog.scanLLM(), id: mode.model ?? current.selectedLlmModel) else {
            completion(.success(LLMCompletion(text: transcription))); return
        }
        queue.async {
            do {
                let system = "Tu es le moteur d’écriture privé d’une application de dictée médicale. N’ajoute aucun fait absent. Suis exactement cette instruction :\n\(mode.prompt)"
                completion(.success(try self.engine.complete(model: model.url, system: system, user: transcription, temperature: mode.temperature, context: current.llmContextSize)))
            } catch { completion(.failure(error)) }
        }
    }
}

final class VoxLocalRemoteBackend: RemoteScribeBackend {
    let kind: RemoteBackendKind = .voxLocal
    var onHistoryChanged: (() -> Void)?

    private let transcription: TranscriptionEngine
    private let llm: VoxLocalLLMAdapter
    private let modes: ModeRepository
    private let history: HistoryRepository
    private let settings: SettingsRepository

    init(modes: ModeRepository, history: HistoryRepository, settings: SettingsRepository, catalog: ModelCatalog, llmServer: LLMServerController?) {
        self.modes = modes
        self.history = history
        self.settings = settings
        transcription = VoxLocalTranscriptionAdapter(settings: settings, catalog: catalog)
        llm = VoxLocalLLMAdapter(modes: modes, settings: settings, catalog: catalog, llmServer: llmServer)
    }

    /// Remote dictations carry the sending device's name in a sidecar file next
    /// to their audio, so the history schema stays unchanged.
    static let deviceMarker = "remote-device.txt"

    static func markRemote(_ record: DictationRecord, device: String) {
        let url = URL(fileURLWithPath: record.audio).deletingLastPathComponent().appendingPathComponent(deviceMarker)
        try? device.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Device name for a dictation received over Remote Scribe, nil for local ones.
    static func remoteDevice(of record: DictationRecord) -> String? {
        let url = URL(fileURLWithPath: record.audio).deletingLastPathComponent().appendingPathComponent(deviceMarker)
        if let name = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Appareil appairé" : trimmed
        }
        // The temporary SuperWhisper backend only ever handles remote sessions.
        return record.selectedSttModel == "SuperWhisper" ? "Appareil appairé" : nil
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
            Self.markRemote(record, device: session.deviceName)
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
                    self.llm.complete(transcription: raw.text, modeIdentifier: mode.id) { processed in
                        switch processed {
                        case .failure(let error): self.fail(transcribed, error: error, completion: completion)
                        case .success(let output):
                            let final = output.text
                            var completed = transcribed
                            completed.finalTranscription = final
                            if let warning = output.warning {
                                completed.processingStatus = "completed_with_warning"; completed.error = warning
                            } else {
                                completed.processingStatus = "completed"
                            }
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
    /// Fired when the pairing code or the TLS fingerprint changes.
    var onSecurityChanged: (() -> Void)?
    var onPeersChanged: (([String]) -> Void)?
    private let backend: VoxLocalRemoteBackend
    private let superwhisperBackend: SuperwhisperRemoteBackend?
    private let paths: AppPaths
    private var server: RemoteScribeServer?
    private(set) var running = false
    private(set) var defaultBackend: RemoteBackendKind
    private var tlsIdentity: RemoteScribeTLSIdentity?
    /// Dashless wire value; the UI shows `pairingCodeDisplay` and copies this one.
    private(set) var pairingCode = ""
    var pairingCodeDisplay: String { PlatformServices.displayPairingCode(pairingCode) }
    var tlsFingerprintDisplay: String? { tlsIdentity?.fingerprintDisplay }
    /// Base64 SHA-256, the form the iPhone pins (same as the Bonjour TXT `fp`).
    var tlsFingerprintBase64: String? { tlsIdentity?.fingerprintBase64 }
    let serviceName: String
    /// Payload of the pairing QR code read by the iPhone app.
    var pairingURL: String? {
        guard let fingerprint = tlsFingerprintBase64, !pairingCode.isEmpty else { return nil }
        return Self.pairingURL(name: serviceName, code: pairingCode, fingerprintBase64: fingerprint)
    }
    /// `remotescribe://pair?name=<host>&code=<dashless code>&fp=<base64 SHA-256>`,
    /// every value percent-encoded (base64 contains `+`, `/` and `=`).
    static func pairingURL(name: String, code: String, fingerprintBase64: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        return "remotescribe://pair?name=\(encode(name))&code=\(encode(code))&fp=\(encode(fingerprintBase64))"
    }
    /// Preview renders use a throwaway code and never read or write the Keychain.
    private let ephemeralPairingCode: Bool
    private var tlsDirectory: URL { paths.root.appendingPathComponent("remote-scribe/tls", isDirectory: true) }

    var availableBackends: [RemoteBackendKind] {
        SuperwhisperRemoteBackend.isInstalled ? [.voxLocal, .superwhisper] : [.voxLocal]
    }

    init(paths: AppPaths, modes: ModeRepository, history: HistoryRepository, settings: SettingsRepository, catalog: ModelCatalog, llmServer: LLMServerController? = nil, ephemeralPairingCode: Bool = false, serviceName: String = RemoteScribeServer.defaultServiceName) {
        self.paths = paths
        self.serviceName = serviceName
        self.ephemeralPairingCode = ephemeralPairingCode
        backend = VoxLocalRemoteBackend(modes: modes, history: history, settings: settings, catalog: catalog, llmServer: llmServer)
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
        loadPairingCode()
        // Never fall back to a plaintext listener: without an identity the phone
        // could not verify this Mac, so the server stays off.
        if tlsIdentity == nil {
            do {
                tlsIdentity = try RemoteScribeTLSIdentity.loadOrCreate(in: tlsDirectory, hostname: serviceName)
                onSecurityChanged?()
            } catch {
                onStatus?("TLS indisponible : \(error.localizedDescription)")
                return
            }
        }
        var backends: [RemoteScribeBackend] = [backend]
        if let superwhisperBackend { backends.append(superwhisperBackend) }
        let instance = RemoteScribeServer(backends: backends, defaultBackend: defaultBackend, serviceName: serviceName, sessionsDirectory: paths.remoteSessions, pairingCode: pairingCode, tlsIdentity: tlsIdentity)
        instance.onEvent = { [weak self] message in self?.onStatus?(message) }
        instance.onPeersChanged = { [weak self] names in self?.onPeersChanged?(names) }
        do { try instance.start(); server = instance; running = true; onStatus?("Remote Scribe actif · \(displayName(defaultBackend)).") }
        catch { onStatus?("Remote Scribe indisponible : \(error.localizedDescription)") }
    }

    func stop() { server?.stop(); server = nil; running = false; onPeersChanged?([]); onStatus?("Remote Scribe arrêté.") }

    /// Issues a new code, stores it in the Keychain and restarts the listener so
    /// devices paired with the old code must pair again.
    func regeneratePairingCode() {
        let code = PlatformServices.generatePairingCode()
        do { if !ephemeralPairingCode { try PlatformServices.setRemotePairingCode(code) } }
        catch { onStatus?("\(error.localizedDescription) Le nouveau code reste valable jusqu’à la fermeture de VoxLocal.") }
        pairingCode = code
        onSecurityChanged?()
        if running { stop(); start() }
    }

    private func loadPairingCode() {
        guard pairingCode.isEmpty else { return }
        if ephemeralPairingCode {
            pairingCode = PlatformServices.generatePairingCode()
        } else if let stored = PlatformServices.remotePairingCode() {
            pairingCode = stored
        } else {
            pairingCode = PlatformServices.generatePairingCode()
            do { try PlatformServices.setRemotePairingCode(pairingCode) }
            catch { onStatus?("\(error.localizedDescription) Le code affiché reste valable jusqu’à la fermeture de VoxLocal.") }
        }
        onSecurityChanged?()
    }

    func setDefaultBackend(_ backend: RemoteBackendKind) {
        guard availableBackends.contains(backend) else { onStatus?("SuperWhisper n’est pas installé sur ce Mac."); return }
        defaultBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: "remoteScribe.defaultBackend")
        onBackendChanged?(backend)
        if running { stop(); start() }
    }

    private func displayName(_ backend: RemoteBackendKind) -> String { backend == .voxLocal ? "VoxLocal" : "SuperWhisper temporaire" }
}
