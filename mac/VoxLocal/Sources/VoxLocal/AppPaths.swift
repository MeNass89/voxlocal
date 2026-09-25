import Foundation

struct AppPaths {
    let root: URL

    init(root: URL? = nil) {
        if let root { self.root = root }
        else if let override = ProcessInfo.processInfo.environment["VOXLOCAL_DATA_DIR"], !override.isEmpty {
            self.root = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoxLocal", isDirectory: true)
        }
    }

    var modes: URL { root.appendingPathComponent("data/modes", isDirectory: true) }
    var history: URL { root.appendingPathComponent("data/history", isDirectory: true) }
    var recovery: URL { root.appendingPathComponent("data/recovery", isDirectory: true) }
    var settings: URL { root.appendingPathComponent("data/settings.json") }
    var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    var remoteSessions: URL { root.appendingPathComponent("remote-scribe/sessions", isDirectory: true) }
    var whisperModels: URL { root.appendingPathComponent("models/whisper", isDirectory: true) }
    var llmModels: URL { root.appendingPathComponent("models/llm", isDirectory: true) }

    func ensure() throws {
        for directory in [modes, history, recovery, logs, remoteSessions, whisperModels, llmModels] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try note(in: whisperModels, named: "PLACER_MODELE_WHISPER_ICI.txt", text: "Placez ici un modèle whisper.cpp au format GGML .bin, par exemple ggml-small.bin.\n")
        try note(in: llmModels, named: "PLACER_MODELE_LLM_ICI.txt", text: "Placez ici un modèle llama.cpp au format GGUF .gguf, par exemple qwen2.5-3b-instruct-q4_k_m.gguf.\n")
    }

    private func note(in directory: URL, named name: String, text: String) throws {
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}

enum JSONStore {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }
}
