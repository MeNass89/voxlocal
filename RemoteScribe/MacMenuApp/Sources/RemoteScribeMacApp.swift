import AppKit
import ServiceManagement
import SwiftUI
import RemoteScribeCore

@MainActor
final class MacServerModel: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); applyServerState() } }
    @Published var stationName: String { didSet { defaults.set(stationName, forKey: "stationName") } }
    @Published var defaultBackend: RemoteBackendKind { didSet { defaults.set(defaultBackend.rawValue, forKey: "backend") } }
    @Published var launchAtLogin = false
    @Published private(set) var status = "Démarrage…"
    @Published private(set) var running = false
    @Published private(set) var superwhisperInstalled = false

    let pairingCode: String
    private let defaults = UserDefaults.standard
    private var server: RemoteScribeServer?

    init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        stationName = defaults.string(forKey: "stationName") ?? (Host.current().localizedName ?? "Poste Remote Scribe")
        defaultBackend = RemoteBackendKind(rawValue: defaults.string(forKey: "backend") ?? "") ?? .voxLocal
        if let saved = defaults.string(forKey: "pairingCode"), saved.count == 6 {
            pairingCode = saved
        } else {
            let generated = String(format: "%06d", Int.random(in: 0...999_999))
            pairingCode = generated
            defaults.set(generated, forKey: "pairingCode")
        }
        superwhisperInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superduper.superwhisper") != nil
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if defaultBackend == .superwhisper && !superwhisperInstalled { defaultBackend = .voxLocal }
        DispatchQueue.main.async { self.applyServerState() }
    }

    var availableBackends: [RemoteBackendKind] {
        superwhisperInstalled ? [.voxLocal, .superwhisper] : [.voxLocal]
    }

    func restart() {
        server?.stop()
        server = nil
        running = false
        if enabled { start() }
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = value
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            status = "Ouverture automatique impossible : \(error.localizedDescription)"
        }
    }

    private func applyServerState() {
        if enabled && !running { start() }
        if !enabled && running {
            server?.stop(); server = nil; running = false; status = "Serveur désactivé"
        }
    }

    private func start() {
        let sessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemoteScribe/sessions", isDirectory: true)
        var backends: [RemoteScribeBackend] = [VoxLocalBackend()]
        if superwhisperInstalled { backends.append(TemporarySuperwhisperBackend()) }
        let chosen = availableBackends.contains(defaultBackend) ? defaultBackend : .voxLocal
        let instance = RemoteScribeServer(
            backends: backends,
            defaultBackend: chosen,
            serviceName: stationName,
            sessionsDirectory: sessions,
            pairingCode: pairingCode
        )
        instance.onReady = { [weak self] port in
            self?.running = true
            self?.status = "Disponible sur le Wi-Fi · port \(port)"
        }
        instance.onEvent = { [weak self] event in
            if event.contains("erreur") || event.contains("indisponible") { self?.status = event }
        }
        do { try instance.start(); server = instance }
        catch { status = "Serveur indisponible : \(error.localizedDescription)" }
    }
}

@main
struct RemoteScribeMacApp: App {
    @StateObject private var model = MacServerModel()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.running ? "Poste disponible" : model.status,
                      systemImage: model.running ? "checkmark.circle.fill" : "exclamationmark.triangle")
                Text(model.stationName).font(.headline)
                Divider()
                Toggle("Serveur actif", isOn: $model.enabled)
                Text("Code d’appairage : \(model.pairingCode)")
                Divider()
                if #available(macOS 14.0, *) {
                    SettingsLink { Text("Réglages…") }
                } else {
                    Button("Réglages…") {
                        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                Button("Quitter Remote Scribe") { NSApplication.shared.terminate(nil) }
            }
            .padding(12)
            .frame(width: 280)
        } label: {
            Label("Remote Scribe", systemImage: model.running ? "waveform.circle.fill" : "waveform.circle")
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: MacServerModel
    @State private var editedName = ""

    var body: some View {
        Form {
            TextField("Nom du poste", text: $editedName)
            Picker("Moteur par défaut", selection: $model.defaultBackend) {
                ForEach(model.availableBackends, id: \.rawValue) { backend in
                    Text(backend == .voxLocal ? "VoxLocal" : "SuperWhisper (temporaire)").tag(backend)
                }
            }
            Text("Code d’appairage : \(model.pairingCode)")
                .textSelection(.enabled)
            Toggle("Ouvrir automatiquement à la connexion", isOn: Binding(
                get: { model.launchAtLogin }, set: model.setLaunchAtLogin
            ))
            HStack {
                Text(model.status).foregroundStyle(.secondary)
                Spacer()
                Button("Appliquer et relancer") {
                    let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { model.stationName = trimmed }
                    model.restart()
                }
            }
            Text("VoxLocal est le moteur cible. SuperWhisper n’est proposé que comme passerelle temporaire lorsqu’il est installé.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { editedName = model.stationName }
    }
}
