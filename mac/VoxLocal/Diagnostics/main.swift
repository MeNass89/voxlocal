import Foundation

@main
struct Diagnostics {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoxLocalDiagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root); try paths.ensure()

        let modes = ModeRepository(directory: paths.modes); modes.seedDefaults()
        try require(modes.list().count == 5, "default modes")
        var mode = try modes.create(); mode.name = "Test clinique"; mode.prompt = "Préserver les négations"; _ = try modes.save(mode)
        try require(modes.get(mode.id)?.name == "Test clinique", "mode persistence")
        let copy = try modes.duplicate(mode.id); try require(copy.prompt == mode.prompt, "mode duplication"); try modes.delete(copy.id)

        let settingsRepo = SettingsRepository(url: paths.settings); var settings = settingsRepo.load(); settings.activeModeId = "email"; try settingsRepo.save(settings)
        try require(settingsRepo.load() == settings, "settings persistence")
        let rawSettings = try String(contentsOf: paths.settings, encoding: .utf8); try require(rawSettings.contains("active_mode_id"), "snake_case compatibility")

        let history = HistoryRepository(directory: paths.history)
        let record = try history.create(mode: Mode.defaults[0], stt: nil, llm: nil, target: ActiveTarget())
        FileManager.default.createFile(atPath: record.audio, contents: Data([1, 2, 3]))
        history.markInterrupted(); let saved = history.list().first
        try require(saved?.processingStatus == "interrupted" && FileManager.default.fileExists(atPath: record.audio), "history recovery")

        let llm = paths.llmModels.appendingPathComponent("test.gguf"); try (Data("GGUF".utf8) + Data(repeating: 0, count: 32)).write(to: llm)
        try require(ModelCatalog(paths: paths).scanLLM().first?.compatible == true, "GGUF model scan")
        let whisper = paths.whisperModels.appendingPathComponent("ggml-test.bin"); try (Data([0x6c, 0x6d, 0x67, 0x67]) + Data(repeating: 0, count: 1_000_001)).write(to: whisper)
        try require(ModelCatalog(paths: paths).scanWhisper().first?.compatible == true, "Whisper GGML model scan")
        print("VoxLocal native diagnostics: PASS (modes, settings, history, recovery, model scan)")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        if !condition() { throw VoxError.message("Diagnostic failed: \(name)") }
    }
}
