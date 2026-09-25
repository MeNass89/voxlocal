import Foundation

final class ModelCatalog {
    let paths: AppPaths
    init(paths: AppPaths) { self.paths = paths }

    func scanWhisper() -> [ModelInfo] {
        scanFiles(in: paths.whisperModels, extensions: ["bin"]).map { url in
            let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let header = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
                defer { try? handle.close() }; return try? handle.read(upToCount: 4)
            }
            let compatible = size > 1_000_000 && header == Data([0x6c, 0x6d, 0x67, 0x67])
            return ModelInfo(id: relative(url, to: paths.whisperModels), name: url.deletingPathExtension().lastPathComponent, url: url, engine: "whisper.cpp", compatible: compatible, detail: compatible ? "Modèle whisper.cpp GGML" : "En-tête GGML invalide ou fichier incomplet")
        }
    }

    func scanLLM() -> [ModelInfo] {
        scanFiles(in: paths.llmModels, extensions: ["gguf"]).map { url in
            let header = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
                defer { try? handle.close() }; return try? handle.read(upToCount: 4)
            }
            let compatible = header == Data("GGUF".utf8)
            return ModelInfo(id: relative(url, to: paths.llmModels), name: url.deletingPathExtension().lastPathComponent, url: url, engine: "llama.cpp", compatible: compatible, detail: compatible ? "Modèle GGUF" : "En-tête GGUF invalide")
        }
    }

    func selected(_ models: [ModelInfo], id: String?) -> ModelInfo? {
        let good = models.filter(\.compatible)
        if let id, let match = good.first(where: { $0.id == id }) { return match }
        return good.count == 1 ? good[0] : nil
    }

    private func scanFiles(in root: URL, extensions: Set<String>) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    private func relative(_ url: URL, to root: URL) -> String {
        String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
