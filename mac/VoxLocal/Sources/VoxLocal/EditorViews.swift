import AppKit
import SwiftUI
import RemoteScribeCore
import UniformTypeIdentifiers

struct ModesView: View {
    @ObservedObject var state: AppState
    private var selected: Mode? { state.modes.first { $0.id == state.selectedModeID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageTitle(title: "Modes", subtitle: "Définissez la façon dont vos dictées sont réécrites.")
                Spacer()
                Button { importMode() } label: { Label("Importer", systemImage: "square.and.arrow.down") }
                Button { state.createMode() } label: { Label("Nouveau mode", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(Color(red: 0.48, green: 0.35, blue: 0.96))
            }.padding(28)
            Divider()
            HSplitView { modeList.frame(minWidth: 235, idealWidth: 270, maxWidth: 320); if let selected { ModeEditor(state: state, mode: selected).id(selected.id) } else { EmptyState(title: "Sélectionnez un mode", subtitle: "Choisissez un mode dans la liste pour le modifier.", icon: "wand.and.stars") } }
        }
    }
    private var modeList: some View {
        List(selection: $state.selectedModeID) {
            ForEach(state.modes) { mode in HStack(spacing: 10) { Image(systemName: mode.kind == "prompt_corrector" ? "sparkles" : "text.badge.checkmark").foregroundStyle(mode.id == state.settings.activeModeId ? .purple : .secondary); VStack(alignment: .leading) { Text(mode.name); if mode.id == state.settings.activeModeId { Text("Actif").font(.caption2).foregroundStyle(.purple) } }; Spacer(); if !mode.enabled { Image(systemName: "eye.slash").foregroundStyle(.tertiary) } }.padding(.vertical, 5).tag(mode.id) }
        }.listStyle(.sidebar)
    }
    private func importMode() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choisissez un mode VoxLocal exporté au format JSON."
        if panel.runModal() == .OK, let url = panel.url { state.importMode(from: url) }
    }
}

private struct ModeEditor: View {
    @ObservedObject var state: AppState
    @State var draft: Mode
    init(state: AppState, mode: Mode) { self.state = state; _draft = State(initialValue: mode) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { VStack(alignment: .leading, spacing: 4) { Text(draft.name).font(.title2.bold()); Text(draft.kind == "prompt_corrector" ? "Mode système de correction" : "Mode de transformation").font(.caption).foregroundStyle(.secondary) }; Spacer(); Toggle("Activé", isOn: $draft.enabled).toggleStyle(.switch) }
                field("Nom") { TextField("Nom du mode", text: $draft.name).textFieldStyle(.roundedBorder) }
                field("Prompt") { TextEditor(text: $draft.prompt).font(.body).scrollContentBackground(.hidden).padding(10).frame(minHeight: 230).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.65))) }
                HStack { field("Température") { HStack { Slider(value: $draft.temperature, in: 0...2, step: 0.1); Text(draft.temperature.formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 28) }.frame(maxWidth: 260) }; Spacer() }
                HStack {
                    Button("Définir comme actif") { state.setActiveMode(draft.id) }.disabled(state.settings.activeModeId == draft.id)
                    Button("Dupliquer") { state.duplicateMode(draft.id) }
                    Button { exportMode() } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                    if !["default", "prompt-corrector"].contains(draft.id) { Button("Supprimer", role: .destructive) { state.deleteMode(draft.id) } }
                    Spacer(); Button("Enregistrer") { state.saveMode(draft) }.buttonStyle(.borderedProminent).tint(.purple)
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 8) { Text(label).font(.headline); content() } }
    private func exportMode() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFilename(draft.name) + ".json"
        panel.message = "Enregistrez ce mode pour le transférer vers un autre Mac."
        if panel.runModal() == .OK, let url = panel.url { state.exportMode(draft, to: url) }
    }
    private func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let parts = value.components(separatedBy: forbidden).filter { !$0.isEmpty }
        let result = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Mode VoxLocal" : result
    }
}

struct ModelsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { PageTitle(title: "Calcul", subtitle: "Choisissez où Whisper et le LLM sont exécutés."); Spacer(); Button { state.rescanModels() } label: { Label("Rescanner", systemImage: "arrow.clockwise") } }
                Picker("Lieu de calcul", selection: Binding(get: { state.settings.usesCloud ? "cloud" : "local" }, set: { state.settings.computeLocation = $0; state.saveSettings() })) {
                    Text("Local sur ce Mac").tag("local"); Text("GPU cloud").tag("cloud")
                }.pickerStyle(.segmented)
                if state.settings.usesCloud { CloudConfigurationView(state: state) } else {
                    ModelCard(state: state, title: "Speech-to-Text", subtitle: "whisper.cpp · GGML .bin", icon: "waveform", models: state.whisperModels, selection: Binding(get: { state.settings.selectedSttModel }, set: { state.settings.selectedSttModel = $0; state.saveSettings() }), folder: state.paths.whisperModels, recommended: .whisper)
                    ModelCard(state: state, title: "LLM local", subtitle: "llama.cpp · GGUF .gguf", icon: "brain.head.profile", models: state.llmModels, selection: Binding(get: { state.settings.selectedLlmModel }, set: { state.settings.selectedLlmModel = $0; state.saveSettings() }), folder: state.paths.llmModels, recommended: .llm)
                }
            }.padding(28).frame(maxWidth: 880, alignment: .leading)
        }
    }
}

private struct CloudConfigurationView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("GPU cloud · API compatible OpenAI", systemImage: "cloud.fill").font(.headline).foregroundStyle(.purple)
            TextField("https://gpu.example.com", text: optional($state.settings.cloudBaseUrl)).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Modèle Whisper (ex. large-v3)", text: optional($state.settings.cloudWhisperModel)).textFieldStyle(.roundedBorder)
                TextField("Modèle LLM", text: optional($state.settings.cloudLlmModel)).textFieldStyle(.roundedBorder)
            }
            SecureField("Token API", text: $state.cloudToken).textFieldStyle(.roundedBorder)
            HStack {
                if state.cloudTestRunning { ProgressView().controlSize(.small) }
                if let message = state.cloudTestMessage { Text(message).font(.caption).foregroundStyle(message.hasPrefix("GPU connecté") ? .green : .secondary).lineLimit(2) }
                Spacer()
                Button("Enregistrer") { state.saveCloudSettings() }
                Button(state.cloudTestRunning ? "Test en cours…" : "Tester la connexion") { state.testCloudConnection() }
                    .buttonStyle(.borderedProminent).tint(.purple).disabled(state.cloudTestRunning)
            }
            Text("VoxLocal utilise /v1/audio/transcriptions, /v1/chat/completions et /v1/models. HTTPS est requis pour un GPU distant ; HTTP reste réservé à localhost. L’iPhone et Remote Scribe ne changent pas.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(.separator.opacity(0.35)))
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0 })
    }
}

private struct ModelCard: View {
    @ObservedObject var state: AppState
    let title: String; let subtitle: String; let icon: String; let models: [ModelInfo]; @Binding var selection: String?; let folder: URL
    let recommended: RecommendedModel
    private var compatible: [ModelInfo] { models.filter(\.compatible) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { ZStack { RoundedRectangle(cornerRadius: 11).fill(.purple.opacity(0.13)); Image(systemName: icon).foregroundStyle(.purple).font(.title3) }.frame(width: 44, height: 44); VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Label(compatible.isEmpty ? "Non détecté" : "Détecté", systemImage: compatible.isEmpty ? "xmark.circle.fill" : "checkmark.circle.fill").font(.caption.bold()).foregroundStyle(compatible.isEmpty ? .orange : .green) }
            Divider()
            if compatible.isEmpty { onboarding }
            else { Picker("Modèle sélectionné", selection: Binding(get: { selection ?? "" }, set: { selection = $0.isEmpty ? nil : $0 })) { Text("Aucun").tag(""); ForEach(models) { model in Text(model.compatible ? model.name : "\(model.name) — incompatible").tag(model.id).disabled(!model.compatible) } }.pickerStyle(.menu) }
            if let hash = state.downloadedHashes[recommended.fileName] {
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(recommended.fileName) installé, empreinte vérifiée", systemImage: "checkmark.seal.fill").font(.caption.bold()).foregroundStyle(.green)
                    Text("SHA-256 \(hash)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack { VStack(alignment: .leading, spacing: 3) { Text("DOSSIER").font(.caption2.bold()).foregroundStyle(.tertiary); Text(folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }; Spacer(); Button("Ouvrir le dossier") { PlatformServices.openFolder(folder) } }
        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(.separator.opacity(0.35)))
    }

    /// Shown while no compatible file is in the folder: what to install, its
    /// size, and a one-click download checked against its SHA-256.
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(models.isEmpty ? "Aucun modèle installé." : "Aucun modèle compatible : les fichiers présents sont incomplets ou d’un autre format.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Recommandé").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                        Text(recommended.fileName).font(.callout.monospaced()).lineLimit(1)
                    }
                    Text("\(recommended.sizeLabel) · \(recommended.summary)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let progress = state.downloads[recommended.fileName] {
                    VStack(alignment: .trailing, spacing: 6) {
                        ProgressView(value: progress).frame(width: 150)
                        HStack(spacing: 8) {
                            Text("\(Int(progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Annuler") { state.cancelDownload(recommended) }.controlSize(.small)
                        }
                    }
                } else {
                    Button { state.download(recommended) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
                        .buttonStyle(.borderedProminent).tint(.purple)
                }
            }
            .padding(14).background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            Text("Ou placez un autre fichier \(recommended.kind == .whisper ? "GGML .bin" : "GGUF .gguf") dans le dossier ci-dessous, puis touchez Rescanner.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    private typealias SettingsPage = AppState.SettingsPage
    private var page: SettingsPage { state.settingsPage }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Réglages", subtitle: subtitle)
                Picker("Rubrique", selection: $state.settingsPage) {
                    ForEach(SettingsPage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(28)
            Divider()
            ScrollView {
                Group {
                    switch page {
                    case .general: generalSettings
                    case .iphone: iphoneSettings
                    case .intelligence: intelligenceSettings
                    }
                }
                .padding(28)
                .frame(maxWidth: 800, alignment: .leading)
            }
        }
    }

    private var subtitle: String {
        switch page {
        case .general: return "Microphone, collage et comportement de l’application."
        case .iphone: return "Connexion et traitement des dictées reçues depuis l’iPhone."
        case .intelligence: return "Choisissez où Whisper et le LLM sont exécutés."
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 26) {
                group("Dictée") {
                    Picker("Microphone", selection: Binding(get: { state.settings.audioDevice ?? "" }, set: { state.settings.audioDevice = $0.isEmpty ? nil : $0; state.saveSettings() })) { Text("Microphone système par défaut").tag(""); ForEach(state.microphones) { Text($0.name).tag($0.id) } }
                    Picker("Langue", selection: Binding(get: { state.settings.language ?? "" }, set: { state.settings.language = $0.isEmpty ? nil : $0; state.saveSettings() })) { Text("Détection automatique").tag(""); Text("Français").tag("fr"); Text("English").tag("en"); Text("Español").tag("es"); Text("Deutsch").tag("de") }
                    Toggle("Coller automatiquement dans l’application précédente", isOn: Binding(get: { state.settings.autopasteEnabled }, set: { state.settings.autopasteEnabled = $0; state.saveSettings() }))
                    Toggle("Conserver le texte final dans le presse-papier", isOn: Binding(get: { state.settings.keepClipboardText }, set: { state.settings.keepClipboardText = $0; state.saveSettings() }))
                }
                group("Application") {
                    LabeledContent("Raccourci global") { Text("⌘ ⇧ Espace").padding(.horizontal, 10).padding(.vertical, 5).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6)) }
                    Toggle("Lancer VoxLocal à l’ouverture de session", isOn: Binding(get: { state.settings.launchAtStartup }, set: { state.updateStartup($0) }))
                    LabeledContent("Données locales") { Button("Ouvrir le dossier") { PlatformServices.openFolder(state.paths.root) } }
                    LabeledContent("Autorisations") { Button("Vérifier…") { state.showPermissionSetup = true } }
                }
        }
    }

    private var iphoneSettings: some View {
        VStack(alignment: .leading, spacing: 26) {
            group("Réception des dictées") {
                if state.remoteScribeRunning {
                    Label("Prêt à recevoir depuis l’iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if state.remoteScribeEnabled {
                    Label(state.remoteScribeStatus, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Label("Réception désactivée", systemImage: "pause.circle.fill").foregroundStyle(.orange)
                }
                Text("VoxLocal rend automatiquement ce Mac disponible dans l’application iPhone lorsqu’ils peuvent communiquer.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Appareils connectés") { Text(state.remotePeers.isEmpty ? "Aucun" : state.remotePeers.joined(separator: ", ")).foregroundStyle(.secondary) }
                LabeledContent("Appairage") {
                    Button { state.show(.remote) } label: { Label("Afficher le QR code", systemImage: "qrcode") }
                }
                Picker("Traitement par défaut", selection: Binding(get: { state.remoteBackend }, set: state.setRemoteBackend)) {
                    Text("VoxLocal").tag(RemoteBackendKind.voxLocal)
                    if state.remoteScribe.availableBackends.contains(.superwhisper) {
                        Text("SuperWhisper").tag(RemoteBackendKind.superwhisper)
                    }
                }
            }
            group("Informations avancées") {
                DisclosureGroup("Réseau et diagnostic") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Découverte") { Text("Bonjour") }
                        LabeledContent("Service") { Text("_remotescribe._tcp").textSelection(.enabled) }
                        LabeledContent("État") { Text(state.remoteScribeStatus).multilineTextAlignment(.trailing) }
                    }
                    .padding(.top, 10)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var intelligenceSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            Picker("Lieu de calcul", selection: Binding(get: { state.settings.usesCloud ? "cloud" : "local" }, set: { state.settings.computeLocation = $0; state.saveSettings() })) {
                Text("Local sur ce Mac").tag("local")
                Text("GPU cloud").tag("cloud")
            }
            .pickerStyle(.segmented)
            if state.settings.usesCloud {
                CloudConfigurationView(state: state)
            } else {
                HStack {
                    Text("Modèles installés").font(.headline)
                    Spacer()
                    Button { state.rescanModels() } label: { Label("Rescanner", systemImage: "arrow.clockwise") }
                }
                ModelCard(state: state, title: "Speech-to-Text", subtitle: "whisper.cpp · GGML .bin", icon: "waveform", models: state.whisperModels, selection: Binding(get: { state.settings.selectedSttModel }, set: { state.settings.selectedSttModel = $0; state.saveSettings() }), folder: state.paths.whisperModels, recommended: .whisper)
                ModelCard(state: state, title: "LLM local", subtitle: "llama.cpp · GGUF .gguf", icon: "brain.head.profile", models: state.llmModels, selection: Binding(get: { state.settings.selectedLlmModel }, set: { state.settings.selectedLlmModel = $0; state.saveSettings() }), folder: state.paths.llmModels, recommended: .llm)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 14) { Text(title).font(.headline); VStack(alignment: .leading, spacing: 14) { content() }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13)) } }
}

struct PageTitle: View {
    let title: String; let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 27, weight: .bold)); Text(subtitle).font(.subheadline).foregroundStyle(.secondary) } }
}
