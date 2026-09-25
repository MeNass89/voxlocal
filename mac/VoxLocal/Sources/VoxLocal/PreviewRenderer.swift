import AVFoundation
import AppKit
import SwiftUI

/// `VoxLocal --render-preview <dir>` renders every screen to PNG with synthetic
/// data kept under `<dir>/PreviewData*`. It never reads the Keychain pairing
/// code and never starts llama-server.
@MainActor
enum PreviewRenderer {
    /// Neutral host name so a render never shows the real machine name.
    static let hostName = "Mac du poste de soins"
    nonisolated private static let windowSize = NSSize(width: 1080, height: 700)

    static func render(to directory: URL) throws {
        forceFrenchLocale()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Seeded data: 3 dictations, one model per category (header-only files).
        let seededRoot = directory.appendingPathComponent("PreviewData", isDirectory: true)
        try? FileManager.default.removeItem(at: seededRoot)
        let seededPaths = AppPaths(root: seededRoot)
        try seededPaths.ensure()
        try seedModels(seededPaths)
        let records = try seedHistory(seededPaths)
        let state = AppState(paths: seededPaths, preview: true)
        state.showPermissionSetup = false
        settle()
        state.remotePeers = ["iPhone du poste 3"]
        state.historyRepository.patientContext = "Patient fictif — chambre 12, entorse de cheville"
        state.patientContext = state.historyRepository.patientContext

        let main = NSHostingView(rootView: MainView(state: state))
        state.selection = .history; state.selectedHistoryID = records.newest
        try render(view: main, to: directory.appendingPathComponent("main-window.png"))
        state.selectedHistoryID = records.medical
        try render(view: main, to: directory.appendingPathComponent("history-detail.png"))
        state.selection = .modes; state.selectedModeID = "medical"
        try render(view: main, to: directory.appendingPathComponent("modes.png"))
        state.selection = .settings
        for (page, name) in [(AppState.SettingsPage.general, "settings-general"), (.iphone, "settings-iphone"), (.intelligence, "settings-ai")] {
            state.settingsPage = page
            try render(view: main, to: directory.appendingPathComponent("\(name).png"))
        }
        state.selection = .remote
        try render(view: main, to: directory.appendingPathComponent("remote-scribe.png"))
        let button = MicrophoneButtonView(frame: NSRect(x: 0, y: 0, width: 60, height: 60), state: state)
        try render(view: button, size: NSSize(width: 60, height: 60), to: directory.appendingPathComponent("floating-button.png"))
        state.shutdown()
        settle()

        // First launch: no model and no dictation yet.
        let emptyRoot = directory.appendingPathComponent("PreviewDataEmpty", isDirectory: true)
        try? FileManager.default.removeItem(at: emptyRoot)
        let empty = AppState(paths: AppPaths(root: emptyRoot), preview: true)
        empty.showPermissionSetup = false
        settle()
        let emptyView = NSHostingView(rootView: MainView(state: empty))
        empty.selection = .settings; empty.settingsPage = .intelligence
        try render(view: emptyView, to: directory.appendingPathComponent("models-empty.png"))
        empty.selection = .history
        try render(view: emptyView, to: directory.appendingPathComponent("history-empty.png"))
        empty.shutdown()
        settle()
        print("Rendered VoxLocal previews to \(directory.path)")
    }

    /// Previews show the product as a French ward sees it, whatever the build
    /// machine's language: dates read "25 sept. 2026 à 09:42". The argument
    /// domain is volatile (same as launching with `-AppleLanguages (fr_FR)`), so
    /// the real app's saved preferences are never touched.
    private static func forceFrenchLocale() {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = ["fr_FR"]
        arguments["AppleLocale"] = "fr_FR"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// Lets async main-queue work (server status, TLS identity) land before a render.
    private static func settle(_ seconds: TimeInterval = 1.5) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func render(view: NSView, size: NSSize = windowSize, to url: URL) throws {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        settle(0.4)
        window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoxError.message("Impossible de produire la preview.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw VoxError.message("Impossible d’encoder la preview PNG.") }
        try png.write(to: url, options: .atomic)
        window.contentView = nil
    }

    /// Files with a valid header only: enough for the catalogue, useless for inference.
    private static func seedModels(_ paths: AppPaths) throws {
        var whisper = Data([0x6c, 0x6d, 0x67, 0x67]); whisper.append(Data(count: 1_100_000))
        try whisper.write(to: paths.whisperModels.appendingPathComponent(RecommendedModel.whisper.fileName))
        var gguf = Data("GGUF".utf8); gguf.append(Data(count: 1_024))
        try gguf.write(to: paths.llmModels.appendingPathComponent(RecommendedModel.llm.fileName))
        var settings = AppSettings()
        settings.selectedSttModel = RecommendedModel.whisper.fileName
        settings.selectedLlmModel = RecommendedModel.llm.fileName
        settings.activeModeId = "medical"
        settings.language = "fr"
        // Shows the « Harness local » group enabled (ephemeral port, throwaway token).
        settings.localApiEnabled = true
        try JSONStore.write(settings, to: paths.settings)
    }

    private static func seedHistory(_ paths: AppPaths) throws -> (newest: String, medical: String) {
        let modes = ModeRepository(directory: paths.modes); modes.seedDefaults()
        let history = HistoryRepository(directory: paths.history)
        func add(mode id: String, at time: String, duration: Double, raw: String, final: String, segments: [Segment], status: String, error: String? = nil, device: String?) throws -> String {
            guard let mode = modes.get(id) else { throw VoxError.message("Mode \(id) absent") }
            var record = try history.create(mode: mode, stt: RecommendedModel.whisper.fileName, llm: RecommendedModel.llm.fileName, target: ActiveTarget(name: "Dossier patient", identifier: nil))
            record.timestamp = time
            record.duration = duration
            record.rawTranscription = raw
            record.finalTranscription = final
            record.segments = segments
            record.processingStatus = status
            record.error = error
            try writeSilence(to: URL(fileURLWithPath: record.audio), seconds: duration)
            try history.save(record)
            if let device { VoxLocalRemoteBackend.markRemote(record, device: device) }
            return record.id
        }
        let medical = try add(
            mode: "medical", at: "2026-09-25T07:42:10Z", duration: 18.4,
            raw: "douleur thoracique apparue ce matin euh sans irradiation tension à quatorze huit fréquence cardiaque quatre-vingt-douze pas de dyspnée",
            final: "Douleur thoracique apparue ce matin, sans irradiation.\nTension artérielle 14/8, fréquence cardiaque 92/min. Pas de dyspnée.",
            segments: [Segment(start: 0, end: 6.8, text: "Douleur thoracique apparue ce matin, sans irradiation."),
                       Segment(start: 6.8, end: 14.1, text: "Tension à quatorze huit, fréquence cardiaque quatre-vingt-douze."),
                       Segment(start: 14.1, end: 18.4, text: "Pas de dyspnée.")],
            status: "completed", device: "iPhone du poste 3")
        _ = try add(
            mode: "notes", at: "2026-09-25T08:15:32Z", duration: 9.2,
            raw: "transmission chambre douze pansement refait ce matin plaie propre prochaine réfection dans quarante-huit heures",
            final: "• Chambre 12 : pansement refait ce matin, plaie propre.\n• Prochaine réfection dans 48 h.",
            segments: [Segment(start: 0, end: 9.2, text: "Transmission chambre douze, pansement refait ce matin, plaie propre, prochaine réfection dans quarante-huit heures.")],
            status: "completed_with_warning",
            error: "Serveur LLM local non démarré (llama-server n’a pas répondu à /health en 60 s) : llama-cli a été utilisé à la place.",
            device: nil)
        let newest = try add(
            mode: "default", at: "2026-09-25T09:03:47Z", duration: 12.7,
            raw: "patient apyrétique depuis hier soir reprise de l'alimentation bien tolérée",
            final: "Patient apyrétique depuis hier soir. Reprise de l’alimentation bien tolérée.",
            segments: [Segment(start: 0, end: 12.7, text: "Patient apyrétique depuis hier soir, reprise de l’alimentation bien tolérée.")],
            status: "completed", device: "iPad de l’unité B")
        return (newest, medical)
    }

    private static func writeSilence(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(seconds * 16_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }
}
