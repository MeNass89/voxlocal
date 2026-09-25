import AppKit
import Foundation
import RemoteScribeCore

final class SuperwhisperBackend: RemoteScribeBackend {
    let kind: RemoteBackendKind = .superwhisper
    private let bundleIdentifier = "com.superduper.superwhisper"
    private let recordingsDirectory: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.superwhisper", qos: .userInitiated)

    init(recordingsDirectory: URL? = nil, timeout: TimeInterval = 240) {
        self.recordingsDirectory = recordingsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/superwhisper/recordings", isDirectory: true)
        self.timeout = timeout
    }

    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let existing = recordingFolders()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.bundleIdentifier) else {
                completion(.failure(SuperwhisperBridgeError.notInstalled)); return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            NSWorkspace.shared.open([session.audioURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error { completion(.failure(error)); return }
                self.queue.async { self.waitForResult(after: existing, session: session, completion: completion) }
            }
        }
    }

    private func waitForResult(after existing: Set<String>, session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = recordingFolders().subtracting(existing).sorted(by: >)
            for folder in candidates {
                let metadata = recordingsDirectory.appendingPathComponent(folder).appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metadata),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let llm = nonEmpty(json["llmResult"] as? String)
                let modeName = nonEmpty(json["modeName"] as? String)
                let expectsLLM = llm != nil
                    || nonEmpty(json["languageModelName"] as? String) != nil
                    || nonEmpty(json["prompt"] as? String) != nil
                    || (modeName != nil && modeName != "Default")
                if expectsLLM && llm == nil { continue }
                let final = llm ?? nonEmpty(json["result"] as? String)
                let raw = nonEmpty(json["rawResult"] as? String)
                if final != nil || raw != nil {
                    completion(.success(RemoteBackendResult(
                        transcription: raw,
                        finalText: final ?? raw,
                        resultLocation: metadata.path,
                        message: "Superwhisper a importé, transcrit et traité le fichier distant."
                    )))
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        completion(.failure(SuperwhisperBridgeError.processingTimedOut))
    }

    private func recordingFolders() -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SuperwhisperBridgeError: LocalizedError {
    case notInstalled
    case processingTimedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Superwhisper n’est pas installé sur ce Mac."
        case .processingTimedOut: return "Superwhisper a reçu le WAV, mais aucun résultat n’est apparu avant l’expiration du délai."
        }
    }
}
