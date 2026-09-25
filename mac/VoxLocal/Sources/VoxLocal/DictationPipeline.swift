import AVFoundation
import Foundation

final class DictationPipeline {
    var onState: ((PipelineStatus, DictationRecord?, String?) -> Void)?

    private let modes: ModeRepository
    private let history: HistoryRepository
    private let settingsRepository: SettingsRepository
    private let catalog: ModelCatalog
    private let recorder: AudioRecorder
    private let whisper = WhisperEngine()
    private let llm: LLMEngine
    private let workQueue = DispatchQueue(label: "com.voxlocal.pipeline", qos: .userInitiated)
    private(set) var status: PipelineStatus = .idle
    private var current: DictationRecord?
    private var target = ActiveTarget()
    private var startInFlight = false
    private var shuttingDown = false

    init(modes: ModeRepository, history: HistoryRepository, settings: SettingsRepository, catalog: ModelCatalog, llmServer: LLMServerController? = nil, recorder: AudioRecorder = AudioRecorder()) {
        self.modes = modes; self.history = history; self.settingsRepository = settings; self.catalog = catalog; self.recorder = recorder
        llm = LLMEngine(server: llmServer)
    }

    func toggle() {
        switch status {
        case .recording: stop()
        case .processing: emit(.processing, current, "Traitement déjà en cours.")
        default: start()
        }
    }

    func start() {
        guard !shuttingDown, !startInFlight, status != .recording && status != .processing else { return }
        let settings = settingsRepository.load()
        guard let mode = modes.get(settings.activeModeId) ?? modes.get("default") else { emit(.error, nil, "Aucun mode valide."); return }
        target = PlatformServices.captureTarget()
        do { current = try history.create(mode: mode, stt: settings.selectedSttModel, llm: settings.selectedLlmModel, target: target) }
        catch { emit(.error, nil, error.localizedDescription); return }
        guard let record = current else { return }
        startInFlight = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(destination: URL(fileURLWithPath: record.audio), deviceID: settings.audioDevice)
                guard !self.shuttingDown else { _ = try? self.recorder.stop(); self.startInFlight = false; return }
                self.startInFlight = false
                self.status = .recording; self.emit(.recording, record, nil)
            } catch {
                self.startInFlight = false
                var failed = record; failed.processingStatus = "error"; failed.error = error.localizedDescription
                try? self.history.save(failed); self.current = failed; self.status = .error; self.emit(.error, failed, error.localizedDescription)
            }
        }
    }

    func stop() {
        guard status == .recording, var record = current else { return }
        do { record.duration = try recorder.stop() }
        catch {
            record.processingStatus = "error"; record.error = error.localizedDescription; try? history.save(record)
            current = record; status = .error; emit(.error, record, error.localizedDescription); return
        }
        record.processingStatus = "processing"; try? history.save(record)
        current = record; status = .processing; emit(.processing, record, nil)
        let savedTarget = target
        workQueue.async { [weak self] in self?.process(record, target: savedTarget) }
    }

    func shutdown() {
        shuttingDown = true
        if recorder.isRecording { _ = try? recorder.stop() }
    }

    func reprocess(_ input: DictationRecord) {
        guard status != .recording && status != .processing else { emit(.processing, current, "Un traitement est déjà en cours."); return }
        guard FileManager.default.fileExists(atPath: input.audio) else { emit(.error, input, "Le fichier audio de cette dictée est introuvable."); return }
        let settings = settingsRepository.load()
        guard let mode = modes.get(settings.activeModeId) ?? modes.get("default") else { emit(.error, input, "Aucun mode valide."); return }
        var record = input
        record.modeId = mode.id; record.modeName = mode.name
        record.selectedSttModel = nil; record.selectedLlm = nil; record.error = nil; record.processingStatus = "processing"
        try? history.save(record)
        current = record; status = .processing; target = PlatformServices.captureTarget(); emit(.processing, record, nil)
        let savedTarget = target
        workQueue.async { [weak self] in self?.process(record, target: savedTarget, rollback: input) }
    }

    func importAudio(_ source: URL) {
        guard status != .recording && status != .processing else { emit(.processing, current, "Un traitement est déjà en cours."); return }
        let settings = settingsRepository.load()
        guard let mode = modes.get(settings.activeModeId) ?? modes.get("default") else { emit(.error, nil, "Aucun mode valide."); return }
        target = PlatformServices.captureTarget()
        do {
            var record = try history.create(mode: mode, stt: nil, llm: nil, target: target)
            record.processingStatus = "processing"; try history.save(record)
            current = record; status = .processing; emit(.processing, record, nil)
            let savedTarget = target
            workQueue.async { [weak self] in
                guard let self else { return }
                var imported = record
                do {
                    _ = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, imported.audio])
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: imported.audio))
                    imported.duration = Double(file.length) / file.processingFormat.sampleRate
                    try self.history.save(imported)
                    self.process(imported, target: savedTarget)
                } catch {
                    imported.processingStatus = "error"; imported.error = "Import audio impossible : \(error.localizedDescription)"; try? self.history.save(imported)
                    self.current = imported; self.status = .error; self.emit(.error, imported, imported.error)
                }
            }
        } catch { emit(.error, nil, error.localizedDescription) }
    }

    private func process(_ input: DictationRecord, target: ActiveTarget, rollback: DictationRecord? = nil) {
        var record = input
        do {
            let settings = settingsRepository.load()
            guard let mode = modes.get(record.modeId) else { throw VoxError.message("Le mode de cette dictée n’existe plus.") }
            let result: STTResult
            if settings.usesCloud {
                record.selectedSttModel = settings.cloudWhisperModel
                result = try CloudGPUEngine(settings: settings).transcribe(audio: URL(fileURLWithPath: record.audio), language: settings.language ?? mode.language)
            } else {
                guard let sttModel = catalog.selected(catalog.scanWhisper(), id: settings.selectedSttModel) else {
                    throw VoxError.message(ModelCatalog.missingWhisperMessage)
                }
                record.selectedSttModel = sttModel.id
                result = try whisper.transcribe(audio: URL(fileURLWithPath: record.audio), model: sttModel.url, language: settings.language ?? mode.language, beamSize: settings.beamSize)
            }
            record.rawTranscription = result.text; record.segments = result.segments; try history.save(record)

            let llmModel = settings.usesCloud ? nil : catalog.selected(catalog.scanLLM(), id: mode.model ?? settings.selectedLlmModel)
            var warning: String?
            if mode.kind == "verbatim" { record.finalTranscription = result.text }
            else if settings.usesCloud {
                record.selectedLlm = settings.cloudLlmModel
                let system = "Tu es le moteur d’écriture privé d’une application de dictée. N’ajoute jamais de faits absents de la transcription. Suis exactement l’instruction du mode.\n\nINSTRUCTION DU MODE :\n\(mode.prompt)"
                record.finalTranscription = try CloudGPUEngine(settings: settings).complete(system: system, user: result.text, temperature: mode.temperature)
            }
            else if mode.kind == "prompt_corrector" {
                guard let llmModel else { throw VoxError.message("Prompt Corrector nécessite un modèle LLM local compatible.") }
                record.selectedLlm = llmModel.id
                let corrected = try correctModePrompt(model: llmModel.url, correction: result.text, context: settings.llmContextSize)
                record.finalTranscription = corrected.text; warning = corrected.warning
            } else if let llmModel {
                record.selectedLlm = llmModel.id
                let system = "Tu es le moteur d’écriture privé et hors ligne d’une application de dictée. N’ajoute jamais de faits absents de la transcription. Suis exactement l’instruction du mode.\n\nINSTRUCTION DU MODE :\n\(mode.prompt)"
                let completion = try llm.complete(model: llmModel.url, system: system, user: result.text, temperature: mode.temperature, context: settings.llmContextSize)
                record.finalTranscription = completion.text; warning = completion.warning
            } else {
                record.finalTranscription = result.text
                warning = "Aucun LLM compatible sélectionné : la transcription brute a été utilisée."
            }

            record.processingStatus = warning == nil ? "completed" : "completed_with_warning"
            record.error = warning; try history.save(record)
            if mode.kind != "prompt_corrector" && settings.autopasteEnabled {
                let result = PlatformServices.paste(record.finalTranscription, to: target)
                if !result.0 { warning = result.1; record.processingStatus = "completed_with_warning"; record.error = warning; try history.save(record) }
            } else if settings.keepClipboardText { _ = PlatformServices.copy(record.finalTranscription) }
            current = record; status = .done; emit(.done, record, warning)
        } catch {
            record.processingStatus = "error"; record.error = error.localizedDescription; try? history.save(record)
            if let rollback {
                var restored = rollback
                restored.processingStatus = "error"
                restored.error = record.error
                restored.updatedAt = record.updatedAt
                try? history.save(restored)
                record = restored
            }
            current = record; status = .error; emit(.error, record, error.localizedDescription)
        }
    }

    private func correctModePrompt(model: URL, correction: String, context: Int) throws -> LLMCompletion {
        let editable = modes.list(enabledOnly: true).filter { $0.kind != "prompt_corrector" }
        let catalogue = editable.map { ["id": $0.id, "name": $0.name, "current_prompt": $0.prompt] }
        let data = try JSONSerialization.data(withJSONObject: catalogue)
        let request = "CATALOGUE DES MODES :\n\(String(data: data, encoding: .utf8) ?? "[]")\n\nCORRECTION :\n\(correction)"
        let system = "Mets à jour le prompt d’un mode de dictée à partir d’une correction parlée. Identifie le mode ciblé dans le catalogue, applique seulement les changements demandés et conserve les règles utiles. Retourne uniquement un JSON strict avec target_mode_id et updated_prompt."
        let completion = try llm.complete(model: model, system: system, user: request, temperature: 0.1, context: context)
        let response = completion.text
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end,
              let data = String(response[start...end]).data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["target_mode_id"] as? String, let prompt = json["updated_prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var mode = editable.first(where: { $0.id == id }) else { throw VoxError.message("Prompt Corrector a retourné un JSON invalide.") }
        mode.prompt = prompt; let saved = try modes.save(mode)
        return LLMCompletion(text: "Mode « \(saved.name) » mis à jour avec succès.", warning: completion.warning)
    }

    private func emit(_ value: PipelineStatus, _ record: DictationRecord?, _ message: String?) {
        DispatchQueue.main.async { [weak self] in self?.onState?(value, record, message) }
    }
}
