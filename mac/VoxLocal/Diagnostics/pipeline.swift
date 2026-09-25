import Foundation

@main
struct PipelineDiagnostics {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoxLocalPipelineDiagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.ensure()
        let modes = ModeRepository(directory: paths.modes); modes.seedDefaults()
        let history = HistoryRepository(directory: paths.history)
        let settings = SettingsRepository(url: paths.settings)
        let pipeline = DictationPipeline(modes: modes, history: history, settings: settings, catalog: ModelCatalog(paths: paths))
        pipeline.start()
        try await wait(for: pipeline, status: .recording)
        try await Task.sleep(nanoseconds: 800_000_000)
        pipeline.stop()
        try await wait(for: pipeline, status: .error)
        guard let record = history.list().first,
              record.duration > 0.5,
              FileManager.default.fileExists(atPath: record.audio),
              record.error?.contains("Whisper") == true else {
            throw VoxError.message("Le pipeline sans modèle n’a pas préservé correctement l’audio.")
        }
        print(String(format: "Pipeline without models: PASS (%.2f s WAV preserved, expected Whisper error)", record.duration))
    }

    static func wait(for pipeline: DictationPipeline, status: PipelineStatus) async throws {
        for _ in 0..<100 {
            if pipeline.status == status { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw VoxError.message("Timeout en attendant l’état \(status.rawValue).")
    }
}
