import AppKit
import Foundation
import RemoteScribeCore

/// Transitional bridge. VoxLocal remains the target backend and owns the protocol.
final class SuperwhisperRemoteBackend: RemoteScribeBackend {
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superduper.superwhisper") != nil }
    let kind: RemoteBackendKind = .superwhisper
    var onHistoryChanged: (() -> Void)?
    private let recordings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/superwhisper/recordings", isDirectory: true)
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.superwhisper", qos: .userInitiated)
    private let modes: ModeRepository
    private let history: HistoryRepository
    private let settings: SettingsRepository

    init(modes: ModeRepository, history: HistoryRepository, settings: SettingsRepository) {
        self.modes = modes
        self.history = history
        self.settings = settings
    }

    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let appSettings = settings.load()
        guard let mode = modes.get(session.modeIdentifier ?? appSettings.activeModeId) ?? modes.get("default") else {
            completion(.failure(VoxError.message("Aucun mode VoxLocal valide.")))
            return
        }
        let record: DictationRecord
        do {
            var value = try history.create(mode: mode, stt: "SuperWhisper", llm: "SuperWhisper", target: ActiveTarget())
            try FileManager.default.copyItem(at: session.audioURL, to: URL(fileURLWithPath: value.audio))
            value.duration = Double(session.bytesReceived) / Double(session.format.bytesPerSecond)
            value.processingStatus = "processing"
            try history.save(value)
            record = value
            onHistoryChanged?()
        } catch {
            completion(.failure(error))
            return
        }
        let existing = folders()
        DispatchQueue.main.async {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superduper.superwhisper") else {
                self.fail(record, error: VoxError.message("SuperWhisper n’est pas installé."))
                completion(.failure(VoxError.message("SuperWhisper n’est pas installé."))); return
            }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false; configuration.addsToRecentItems = false
            NSWorkspace.shared.open([session.audioURL], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { self.fail(record, error: error); completion(.failure(error)); return }
                self.queue.async {
                    self.wait(existing: existing) { result in
                        switch result {
                        case .success(let output):
                            var completed = record
                            completed.rawTranscription = output.transcription ?? ""
                            completed.finalTranscription = output.finalText ?? output.transcription ?? ""
                            completed.processingStatus = "completed"
                            completed.error = nil
                            try? self.history.save(completed)
                            DispatchQueue.main.async { self.onHistoryChanged?() }
                        case .failure(let error):
                            self.fail(record, error: error)
                        }
                        completion(result)
                    }
                }
            }
        }
    }

    private func fail(_ input: DictationRecord, error: Error) {
        var record = input
        record.processingStatus = "error"
        record.error = error.localizedDescription
        try? history.save(record)
        DispatchQueue.main.async { self.onHistoryChanged?() }
    }

    private func wait(existing: Set<String>, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            for folder in folders().subtracting(existing).sorted(by: >) {
                let metadata = recordings.appendingPathComponent(folder).appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metadata), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let raw = text(json["rawResult"]), llm = text(json["llmResult"]), final = llm ?? text(json["result"]) ?? raw
                let expectsLLM = text(json["languageModelName"]) != nil || text(json["prompt"]) != nil
                if expectsLLM && llm == nil { continue }
                if let final { completion(.success(RemoteBackendResult(transcription: raw, finalText: final, resultLocation: metadata.path, message: "Traitement SuperWhisper terminé."))); return }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        completion(.failure(VoxError.message("SuperWhisper n’a pas produit de résultat dans le délai prévu.")))
    }

    private func folders() -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
    }

    private func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }; let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed
    }
}

/// Controls SuperWhisper when the recording originates directly from this Mac
/// (floating button, global shortcut, or the main window record button).
final class SuperwhisperDesktopController {
    private let recordings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/superwhisper/recordings", isDirectory: true)
    private let queue = DispatchQueue(label: "com.voxlocal.superwhisper.desktop", qos: .utility)
    private var foldersBeforeRecording = Set<String>()

    func toggle(starting: Bool, completion: @escaping (Error?) -> Void) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superduper.superwhisper") != nil else {
            completion(VoxError.message("SuperWhisper n’est pas installé."))
            return
        }
        if starting { foldersBeforeRecording = folders() }
        guard let url = URL(string: "superwhisper://record") else {
            completion(VoxError.message("Impossible d’ouvrir SuperWhisper."))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            if let error { completion(error); return }
            guard !starting, let self else { completion(nil); return }
            self.queue.async { self.waitUntilFinished(completion: completion) }
        }
    }

    private func waitUntilFinished(completion: @escaping (Error?) -> Void) {
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            for folder in folders().subtracting(foldersBeforeRecording) {
                let metadata = recordings.appendingPathComponent(folder).appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metadata),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let raw = nonempty(json["rawResult"])
                let llm = nonempty(json["llmResult"])
                let result = nonempty(json["result"])
                let expectsLLM = nonempty(json["languageModelName"]) != nil || nonempty(json["prompt"]) != nil
                if raw != nil, (!expectsLLM || llm != nil || result != nil) { completion(nil); return }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        completion(VoxError.message("SuperWhisper n’a pas produit de résultat dans le délai prévu."))
    }

    private func folders() -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
    }

    private func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
