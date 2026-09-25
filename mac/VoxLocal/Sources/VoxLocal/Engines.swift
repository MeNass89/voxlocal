import Foundation

struct STTResult { var text: String; var segments: [Segment] }

enum RuntimeLocator {
    static func executable(_ name: String) throws -> URL {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Runtimes/\(name)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)")
        ].compactMap { $0 }
        if let url = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) { return url }
        throw VoxError.message("Le moteur natif \(name) est absent du paquet de l’application.")
    }
}

enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String]) throws -> (String, String) {
        // Drain both streams after the child exits via temporary files. Reading one
        // pipe to EOF before the other can deadlock a verbose native runtime when
        // its stderr pipe fills while stdout is still open.
        let process = Process()
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("voxlocal-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin", "LC_ALL": "en_US.UTF-8"]
        do { try process.run() } catch { throw VoxError.message("Impossible de lancer \(executable.lastPathComponent) : \(error.localizedDescription)") }
        process.waitUntilExit()
        try? stdout.close(); try? stderr.close()
        let out = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let err = (try? Data(contentsOf: stderrURL)) ?? Data()
        let output = String(data: out, encoding: .utf8) ?? ""
        let errors = String(data: err, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(errors.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4_000))
            throw VoxError.message("\(executable.lastPathComponent) a échoué\(detail.isEmpty ? "." : " : \(detail)")")
        }
        return (output, errors)
    }
}

final class WhisperEngine {
    func transcribe(audio: URL, model: URL, language: String?) throws -> STTResult {
        guard FileManager.default.fileExists(atPath: audio.path) else { throw VoxError.message("Le fichier audio est introuvable.") }
        let runtime = try RuntimeLocator.executable("whisper-cli")
        let outputBase = audio.deletingPathExtension().appendingPathExtension("whisper-result")
        let jsonURL = URL(fileURLWithPath: outputBase.path + ".json")
        try? FileManager.default.removeItem(at: jsonURL)
        _ = try ProcessRunner.run(runtime, ["-m", model.path, "-f", audio.path, "-l", language ?? "auto", "-oj", "-of", outputBase.path, "-np"])
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any], let items = root["transcription"] as? [[String: Any]] else {
            throw VoxError.message("Whisper n’a pas produit de transcription JSON valide.")
        }
        let segments: [Segment] = items.compactMap { item in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let offsets = item["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? NSNumber)?.doubleValue ?? 0
            let to = (offsets?["to"] as? NSNumber)?.doubleValue ?? from
            return Segment(start: from / 1000, end: to / 1000, text: text)
        }
        try? FileManager.default.removeItem(at: jsonURL)
        let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoxError.message("Whisper a retourné une transcription vide.") }
        return STTResult(text: text, segments: segments)
    }
}

final class LLMEngine {
    func complete(model: URL, system: String, user: String, temperature: Double, context: Int) throws -> String {
        let runtime = try RuntimeLocator.executable("llama-cli")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voxlocal-\(UUID().uuidString)")
        let systemURL = scratch.appendingPathExtension("system.txt")
        let promptURL = scratch.appendingPathExtension("prompt.txt")
        try system.write(to: systemURL, atomically: true, encoding: .utf8)
        try user.write(to: promptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: systemURL); try? FileManager.default.removeItem(at: promptURL) }
        let (output, _) = try ProcessRunner.run(runtime, ["-m", model.path, "-sysf", systemURL.path, "-f", promptURL.path, "-c", String(max(1024, context)), "-n", "2048", "--temp", String(temperature), "--single-turn", "--no-display-prompt", "--no-show-timings", "--log-disable"])
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoxError.message("Le LLM local a retourné une réponse vide.") }
        return cleaned
    }
}
