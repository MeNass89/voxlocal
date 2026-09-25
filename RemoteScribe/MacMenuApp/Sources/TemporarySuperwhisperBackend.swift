import AppKit
import Foundation
import RemoteScribeCore

final class TemporarySuperwhisperBackend: RemoteScribeBackend {
    let kind: RemoteBackendKind = .superwhisper
    private let recordings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/superwhisper/recordings", isDirectory: true)
    private let queue = DispatchQueue(label: "com.voxlocal.remotescribe.temporary-superwhisper")

    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let existing = folders()
        DispatchQueue.main.async {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superduper.superwhisper") else {
                completion(.failure(BridgeError.notInstalled)); return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open([session.audioURL], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { completion(.failure(error)); return }
                self.queue.async { self.wait(existing: existing, session: session, completion: completion) }
            }
        }
    }

    private func wait(existing: Set<String>, session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            for folder in folders().subtracting(existing).sorted(by: >) {
                let metadata = recordings.appendingPathComponent(folder).appendingPathComponent("meta.json")
                guard let data = try? Data(contentsOf: metadata),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let raw = text(json["rawResult"])
                let llm = text(json["llmResult"])
                let result = llm ?? text(json["result"]) ?? raw
                let expectsLLM = text(json["languageModelName"]) != nil || text(json["prompt"]) != nil
                if expectsLLM && llm == nil { continue }
                if let result {
                    completion(.success(RemoteBackendResult(transcription: raw, finalText: result, resultLocation: metadata.path, message: "Traitement SuperWhisper terminé.")))
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        completion(.failure(BridgeError.timeout))
    }

    private func folders() -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent))
    }

    private func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum BridgeError: LocalizedError {
    case notInstalled, timeout
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "SuperWhisper n’est pas installé."
        case .timeout: return "SuperWhisper n’a pas produit de résultat dans le délai prévu."
        }
    }
}
