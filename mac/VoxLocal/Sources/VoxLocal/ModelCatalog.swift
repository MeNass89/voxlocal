import Foundation

/// A model VoxLocal proposes to download when a category is empty. The size
/// and SHA-256 come from the Hugging Face `content-length` and `x-linked-etag`
/// headers (checked 2026-09-25); a download that does not match is discarded.
struct RecommendedModel: Identifiable, Hashable {
    enum Kind: Hashable { case whisper, llm }
    var kind: Kind
    var fileName: String
    var summary: String
    var url: URL
    var bytes: Int64
    var sha256: String
    var id: String { fileName }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let whisper = RecommendedModel(
        kind: .whisper,
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        summary: "Whisper large-v3 turbo, quantifié Q5_0 : précis en français, rapide sur Apple Silicon.",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    )
    static let llm = RecommendedModel(
        kind: .llm,
        fileName: "qwen2.5-3b-instruct-q4_k_m.gguf",
        summary: "Qwen2.5 3B Instruct, Q4_K_M : réécrit les dictées en local avec environ 3 Go de mémoire.",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
        bytes: 2_104_932_768,
        sha256: "626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d"
    )
}

final class ModelCatalog {
    static let missingWhisperMessage = "Aucun modèle Whisper installé. Ouvrez Réglages › Intelligence artificielle pour télécharger \(RecommendedModel.whisper.fileName) (\(RecommendedModel.whisper.sizeLabel)). L’audio a été conservé : retranscrivez-le ensuite."

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

    func folder(for kind: RecommendedModel.Kind) -> URL { kind == .whisper ? paths.whisperModels : paths.llmModels }

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

    /// Both sides are resolved first: the enumerator returns resolved paths
    /// (`/private/tmp/…`), so a symlinked data folder would otherwise produce
    /// ids that never match the saved selection.
    private func relative(_ url: URL, to root: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
