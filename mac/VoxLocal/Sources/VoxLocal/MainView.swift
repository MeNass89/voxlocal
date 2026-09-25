import AVFoundation
import AppKit
import SwiftUI
import RemoteScribeCore
import UniformTypeIdentifiers

private let accent = Color(red: 0.48, green: 0.35, blue: 0.96)

struct MainView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.45)
            Group {
                switch state.selection {
                case .history: HistoryView(state: state)
                case .modes: ModesView(state: state)
                case .settings: SettingsView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 620)
        .sheet(isPresented: $state.showPermissionSetup) {
            PermissionSetupView(state: state)
        }
        .alert("VoxLocal", isPresented: Binding(get: { state.notice != nil }, set: { if !$0 { state.notice = nil } })) {
            Button("OK") { state.notice = nil }
        } message: { Text(state.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack { RoundedRectangle(cornerRadius: 9).fill(accent.gradient); Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) { Text("VoxLocal").font(.system(size: 13, weight: .semibold)); Text("Dictée locale").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.bottom, 16)

            ForEach(AppState.Section.allCases) { item in
                Button { state.selection = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(item)).frame(width: 17)
                        Text(item.rawValue).lineLimit(1)
                        Spacer()
                    }
                    .font(.system(size: 12, weight: state.selection == item ? .semibold : .regular))
                    .padding(.horizontal, 8).frame(height: 35)
                    .background(state.selection == item ? accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(state.selection == item ? accent : .primary)
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text("MODE ACTIF").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                Menu {
                    ForEach(state.modes.filter(\.enabled)) { mode in Button { state.setActiveMode(mode.id) } label: { if mode.id == state.settings.activeModeId { Label(mode.name, systemImage: "checkmark") } else { Text(mode.name) } } }
                } label: {
                    HStack(spacing: 6) { Circle().fill(accent).frame(width: 6); Text(state.activeMode?.name ?? "Default").font(.system(size: 12)).lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(.secondary) }
                        .padding(.horizontal, 8).frame(height: 35).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
                }.menuStyle(.borderlessButton)
                HStack(spacing: 7) { Circle().fill(statusColor).frame(width: 7); Text(statusLabel).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(14).frame(width: 165).background(.ultraThinMaterial)
    }

    private var statusLabel: String { switch state.pipelineStatus { case .idle: return "Prêt"; case .recording: return "Enregistrement…"; case .processing: return "Traitement local…"; case .done: return "Terminé"; case .error: return "Une erreur est survenue" } }
    private var statusColor: Color { switch state.pipelineStatus { case .recording: return .red; case .processing: return accent; case .done: return .green; case .error: return .orange; default: return .secondary } }
    private func icon(_ section: AppState.Section) -> String { switch section { case .history: return "waveform"; case .modes: return "wand.and.stars"; case .settings: return "gearshape" } }
}

private struct PageHeader: View {
    let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 27, weight: .bold)); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct RemoteScribeView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Remote Scribe", subtitle: "Recevez le microphone d’un iPhone, iPad ou second Mac sur le même Wi-Fi.").padding(28)
            Divider()
            Form {
                Toggle("Serveur Remote Scribe", isOn: Binding(get: { state.remoteScribeEnabled }, set: state.setRemoteScribeEnabled))
                Picker("Moteur par défaut", selection: Binding(get: { state.remoteBackend }, set: state.setRemoteBackend)) {
                    Text("VoxLocal").tag(RemoteBackendKind.voxLocal)
                    if state.remoteScribe.availableBackends.contains(.superwhisper) {
                        Text("SuperWhisper (temporaire)").tag(RemoteBackendKind.superwhisper)
                    }
                }
                LabeledContent("Découverte") { Text("Bonjour · _remotescribe._tcp") }
                LabeledContent("État") { Text(state.remoteScribeStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                Section("Pipeline") {
                    Text("Le WAV PCM 16 kHz est finalisé à STOP, ajouté à l’historique, puis envoyé au moteur Whisper sélectionné et au mode LLM actif. Sans modèle Whisper, le moteur de test valide le pipeline sans bloquer la session.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Réseau") {
                    LabeledContent("Port") { Text("47365") }
                    LabeledContent("Code d’appairage") {
                        HStack {
                            Text(state.remotePairingCode.isEmpty ? "—" : state.remotePairingCode)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityLabel("Code d’appairage \(state.remotePairingCode)")
                            Button("Copier") { state.copyRemotePairingCode() }
                                .disabled(state.remotePairingCode.isEmpty)
                                .accessibilityHint("Copie le code sans tiret dans le presse-papier.")
                            Button("Régénérer") { state.regenerateRemotePairingCode() }
                                .accessibilityHint("Crée un nouveau code. Les appareils devront s’appairer de nouveau.")
                        }
                    }
                    LabeledContent("Empreinte TLS (SHA-256)") {
                        Text(state.remoteTLSFingerprint ?? "Indisponible")
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Sur l’iPhone, saisissez le code puis comparez l’empreinte affichée lors de la première connexion.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).padding(10)
        }
    }
}

struct HistoryView: View {
    @ObservedObject var state: AppState
    private var selected: DictationRecord? { state.history.first { $0.id == state.selectedHistoryID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageHeader(title: "Historique", subtitle: "Micro du Mac, iPhone et fichiers audio utilisent le même pipeline.")
                Button { chooseAudio() } label: { Label("Importer un audio", systemImage: "square.and.arrow.down") }
                    .disabled(state.pipelineStatus == .recording || state.pipelineStatus == .processing)
                Button { state.toggleRecording() } label: {
                    Label(state.pipelineStatus == .recording ? "Arrêter" : "Dicter depuis ce Mac", systemImage: state.pipelineStatus == .recording ? "stop.fill" : "mic.fill")
                }.buttonStyle(.borderedProminent).tint(state.pipelineStatus == .recording ? .red : accent).disabled(state.pipelineStatus == .processing)
            }.padding(28)
            Divider()
            if state.history.isEmpty { EmptyState(title: "Aucune dictée", subtitle: "Cliquez sur le bouton flottant pour enregistrer votre première dictée.", icon: "waveform") }
            else { HSplitView { recordList.frame(minWidth: 270, idealWidth: 310, maxWidth: 370); if let selected { HistoryDetail(state: state, record: selected) } else { Color.clear } } }
        }
    }
    private func chooseAudio() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { state.importAudio(url) }
    }
    private var recordList: some View {
        List(selection: $state.selectedHistoryID) {
            ForEach(state.history) { record in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(record.modeName).font(.system(size: 14, weight: .semibold)); Spacer(); Circle().fill(record.processingStatus == "completed" ? .green : record.processingStatus == "error" ? .red : .orange).frame(width: 7) }
                    Text(record.finalTranscription.isEmpty ? (record.rawTranscription.isEmpty ? statusText(record) : record.rawTranscription) : record.finalTranscription).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    HStack { Text(formatDate(record.timestamp)); Spacer(); Text(formatDuration(record.duration)) }.font(.caption2).foregroundStyle(.tertiary)
                }.padding(.vertical, 7).tag(record.id)
            }
        }.listStyle(.sidebar)
    }
    private func statusText(_ r: DictationRecord) -> String { r.error ?? (r.processingStatus == "recording" ? "Enregistrement interrompu" : "En attente de transcription") }
    private func formatDate(_ value: String) -> String { guard let date = ISO8601DateFormatter().date(from: value) else { return value }; return date.formatted(date: .abbreviated, time: .shortened) }
    private func formatDuration(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
}

struct EmptyState: View {
    let title: String; let subtitle: String; let icon: String
    var body: some View { VStack(spacing: 12) { Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tertiary); Text(title).font(.title3.bold()); Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct HistoryDetail: View {
    @ObservedObject var state: AppState
    let record: DictationRecord
    @StateObject private var player = AudioPlayer()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(record.modeName).font(.title2.bold()); Text(record.timestamp).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { state.reprocess(record) } label: { Label("Retranscrire", systemImage: "arrow.clockwise") }
                        .disabled(state.pipelineStatus == .recording || state.pipelineStatus == .processing)
                }
                AudioPlaybackView(player: player)
                if let error = record.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)) }
                textBlock("Texte final", record.finalTranscription)
                textBlock("Transcription brute", record.rawTranscription)
                if !record.segments.isEmpty { VStack(alignment: .leading, spacing: 10) { Text("Segments").font(.headline); ForEach(record.segments) { item in HStack(alignment: .top) { Text(String(format: "%05.1f", item.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .leading); Text(item.text) }.font(.caption) } } }
                HStack { meta("Durée", String(format: "%.1f s", record.duration)); meta("Whisper", record.selectedSttModel ?? "—"); meta("LLM", record.selectedLlm ?? "—") }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { player.load(URL(fileURLWithPath: record.audio)) }
        .onChange(of: record.id) { _ in player.load(URL(fileURLWithPath: record.audio)) }
    }
    private func textBlock(_ title: String, _ text: String) -> some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); Text(text.isEmpty ? "—" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)) } }
    private func meta(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(label.uppercased()).font(.caption2.bold()).foregroundStyle(.tertiary); Text(value).font(.caption).lineLimit(1) }.frame(maxWidth: .infinity, alignment: .leading) }
}

private struct AudioPlaybackView: View {
    @ObservedObject var player: AudioPlayer
    private let rates: [Float] = [0.25, 0.5, 1, 1.5, 1.75, 2, 3]

    var body: some View {
        VStack(spacing: 12) {
            Slider(value: Binding(get: { player.currentTime }, set: player.seek), in: 0...max(0.01, player.duration))
            HStack {
                Text(time(player.currentTime)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }.help("Reculer de 15 secondes")
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 22) }.buttonStyle(.borderedProminent).tint(accent)
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }.help("Avancer de 15 secondes")
                Menu("×\(rateLabel(player.rate))") {
                    ForEach(rates, id: \.self) { rate in
                        Button { player.setRate(rate) } label: {
                            if player.rate == rate { Label("×\(rateLabel(rate))", systemImage: "checkmark") }
                            else { Text("×\(rateLabel(rate))") }
                        }
                    }
                }.frame(width: 72)
                Spacer()
                Text(time(player.duration)).monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func time(_ seconds: TimeInterval) -> String { String(format: "%d:%02d", max(0, Int(seconds)) / 60, max(0, Int(seconds)) % 60) }
    private func rateLabel(_ rate: Float) -> String { rate.rounded() == rate ? String(format: "%.0f", rate) : String(format: "%g", rate) }
}

private final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1
    private var player: AVAudioPlayer?
    private var loadedURL: URL?
    private var timer: Timer?

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        timer?.invalidate(); player?.stop(); playing = false; currentTime = 0; duration = 0
        do {
            let value = try AVAudioPlayer(contentsOf: url); value.delegate = self; value.enableRate = true; value.rate = rate; value.prepareToPlay()
            player = value; loadedURL = url; duration = value.duration
        } catch { player = nil; loadedURL = nil; NSSound.beep() }
    }

    func toggle() {
        guard let player else { NSSound.beep(); return }
        if playing { player.pause(); playing = false; stopTimer() }
        else { player.rate = rate; player.play(); playing = true; startTimer() }
    }

    func seek(_ value: Double) { player?.currentTime = min(max(0, value), duration); currentTime = player?.currentTime ?? value }
    func skip(_ seconds: TimeInterval) { seek(currentTime + seconds) }
    func setRate(_ value: Float) { rate = value; player?.enableRate = true; player?.rate = value }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { playing = false; currentTime = duration; stopTimer() }

    private func startTimer() {
        stopTimer()
        let value = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.currentTime = self?.player?.currentTime ?? 0 }
        RunLoop.main.add(value, forMode: .common); timer = value
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}
