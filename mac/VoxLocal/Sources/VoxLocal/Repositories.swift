import Foundation

final class SettingsRepository {
    let url: URL
    init(url: URL) { self.url = url }

    func load() -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let value = AppSettings(); try? save(value); return value
        }
        do { return try JSONStore.read(AppSettings.self, from: url) }
        catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.moveItem(at: url, to: backup)
            let value = AppSettings(); try? save(value); return value
        }
    }

    func save(_ settings: AppSettings) throws { try JSONStore.write(settings, to: url) }
}

final class ModeRepository {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func seedDefaults() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for mode in Mode.defaults where get(mode.id) == nil { _ = try? save(mode) }
    }

    func list(enabledOnly: Bool = false) -> [Mode] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { try? JSONStore.read(Mode.self, from: $0) }
            .filter { !enabledOnly || $0.enabled }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func get(_ id: String) -> Mode? {
        guard valid(id) else { return nil }
        return try? JSONStore.read(Mode.self, from: directory.appendingPathComponent("\(id).json"))
    }

    @discardableResult func save(_ input: Mode) throws -> Mode {
        guard valid(input.id), !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoxError.message("Le mode doit avoir un identifiant et un nom valides.")
        }
        guard ["transform", "prompt_corrector", "verbatim"].contains(input.kind), (0...2).contains(input.temperature) else {
            throw VoxError.message("Paramètres du mode invalides.")
        }
        var mode = input
        mode.updatedAt = ISO8601DateFormatter().string(from: Date())
        try JSONStore.write(mode, to: directory.appendingPathComponent("\(mode.id).json"))
        return mode
    }

    func create() throws -> Mode {
        try save(Mode(id: UUID().uuidString.lowercased(), name: "Nouveau mode", prompt: ""))
    }

    func duplicate(_ id: String) throws -> Mode {
        guard var mode = get(id) else { throw VoxError.message("Mode introuvable.") }
        mode.id = UUID().uuidString.lowercased()
        mode.name += " copie"
        mode.createdAt = ISO8601DateFormatter().string(from: Date())
        return try save(mode)
    }

    func delete(_ id: String) throws {
        guard !["default", "prompt-corrector"].contains(id) else { throw VoxError.message("Ce mode intégré ne peut pas être supprimé.") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    private func valid(_ id: String) -> Bool {
        !id.isEmpty && id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}

final class HistoryRepository {
    let directory: URL
    private let contextLock = NSLock()
    private var currentPatientContext: String?
    init(directory: URL) { self.directory = directory }

    /// Patient context stamped on every dictation created from now on. Memory
    /// only: a restart clears it, so a new shift never inherits the last patient.
    var patientContext: String? {
        get { contextLock.lock(); defer { contextLock.unlock() }; return currentPatientContext }
        set { contextLock.lock(); currentPatientContext = newValue; contextLock.unlock() }
    }

    func create(mode: Mode, stt: String?, llm: String?, target: ActiveTarget) throws -> DictationRecord {
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let id = "\(day)-\(UUID().uuidString.lowercased())"
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = DictationRecord(
            id: id,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            modeId: mode.id,
            modeName: mode.name,
            audio: folder.appendingPathComponent("audio.wav").path,
            selectedSttModel: stt,
            selectedLlm: llm,
            targetApplication: target.name,
            targetIdentifier: target.identifier,
            patientContext: patientContext
        )
        try save(record)
        return record
    }

    func save(_ input: DictationRecord) throws {
        var record = input
        record.updatedAt = ISO8601DateFormatter().string(from: Date())
        try JSONStore.write(record, to: recordURL(record.id))
    }

    func list() -> [DictationRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { try? JSONStore.read(DictationRecord.self, from: $0.appendingPathComponent("record.json")) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func markInterrupted() {
        for var record in list() where ["recording", "processing"].contains(record.processingStatus) {
            record.processingStatus = "interrupted"
            record.error = "L’application s’est arrêtée avant la fin du traitement. L’audio a été conservé."
            try? save(record)
        }
    }

    private func recordURL(_ id: String) -> URL { directory.appendingPathComponent(id).appendingPathComponent("record.json") }
}
