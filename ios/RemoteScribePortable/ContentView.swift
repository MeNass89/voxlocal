import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Main dictation surface for hospital use.
///
/// The view keeps one clear primary action, describes every network/audio state in
/// text, and uses the same semantic colors for the icon, status and action. It is
/// intentionally built with native SwiftUI controls so Dynamic Type keeps working.
/// A regular width (iPad, large split screen) switches to a split view: history in
/// the sidebar, recorder in the detail column. The first launch shows the
/// onboarding instead of the recorder.
struct ContentView: View {
    @ObservedObject var model: PortableClientModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(OnboardingView.doneKey) private var onboardingDone = false
    @State private var showingConnections = false
    @State private var showingScanner = false
    @State private var showingClearHistory = false

    var body: some View {
        Group {
            if onboardingDone {
                mainLayout
            } else {
                OnboardingView(
                    onScan: {
                        onboardingDone = true
                        // Present once the main layout, which owns the sheet, is on screen.
                        DispatchQueue.main.async { showingScanner = true }
                    },
                    onLater: { onboardingDone = true }
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: onboardingDone)
        .tint(RemoteScribePalette.action)
        .preferredColorScheme(.dark)
    }

    private var mainLayout: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitLayout
            } else {
                NavigationStack {
                    dashboard(showsHistory: true)
                        .navigationTitle("Remote Scribe")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { connectionToolbarItem }
                }
            }
        }
        .onAppear {
            model.startDiscovery()
            #if DEBUG
            // Screenshot hook: `-VoxLocalDebugScanner 1` opens the pairing scanner.
            if UserDefaults.standard.bool(forKey: "VoxLocalDebugScanner") { showingScanner = true }
            #endif
        }
        .onChange(of: scenePhase) { model.handleScenePhase($0) }
        .sheet(isPresented: $showingConnections) {
            ConnectionSheet(model: model)
        }
        .sheet(isPresented: $showingScanner) {
            QRPairingView(model: model)
        }
        .sheet(item: $model.pendingTrust, onDismiss: model.cancelPendingTrust) { trust in
            TrustServerSheet(trust: trust, onTrust: model.trustPendingServer, onCancel: model.cancelPendingTrust)
        }
        .confirmationDialog(
            "Effacer l’historique ?",
            isPresented: $showingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Effacer les transcriptions", role: .destructive) {
                model.clearHistory()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les transcriptions enregistrées sur cet appareil seront supprimées.")
        }
    }

    private var splitLayout: some View {
        NavigationSplitView {
            historySidebar
                .navigationTitle("Historique")
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            dashboard(showsHistory: false)
                .navigationTitle("Remote Scribe")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { connectionToolbarItem }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var connectionToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { showingConnections = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Connexion au poste")
            .accessibilityHint("Ouvre les réglages de connexion")
        }
    }

    private func dashboard(showsHistory: Bool) -> some View {
        ZStack {
            RemoteScribePalette.background
                .ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.showsNoServerHelp {
                        noServerCard
                    } else {
                        connectionCard
                    }

                    if let errorText = model.errorText, model.phase == .failed {
                        errorBanner(errorText)
                    }

                    enginePicker
                    recorderCard

                    if showsHistory && !model.results.isEmpty {
                        historySection
                    }

                    privacyNote
                    historySettings
                    if let storageMessage = model.storageMessage {
                        Text(storageMessage)
                            .font(.footnote)
                            .foregroundStyle(RemoteScribePalette.warning)
                            .frame(maxWidth: 600, alignment: .leading)
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.highlightedResultID) { id in
                if showsHistory { reveal(id, with: proxy) }
            }
            }
        }
    }

    /// Brings the text that just came back into view so it can be read at once.
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private var connectionCard: some View {
        Button { showingConnections = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(phaseColor.opacity(0.16))
                        .frame(width: 48, height: 48)
                    if model.isBusy {
                        ProgressView()
                            .tint(phaseColor)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: model.phase.systemImage)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(phaseColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.serverName ?? "Aucun poste connecté")
                        .font(.headline)
                        .foregroundStyle(RemoteScribePalette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(connectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(RemoteScribePalette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(RemoteScribePalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .voxGlassButton()
        .buttonBorderShape(.roundedRectangle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("État de la connexion")
        .accessibilityValue("\(model.serverName ?? "Aucun poste connecté"). \(connectionSummary)")
        .accessibilityHint("Ouvre les réglages de connexion")
    }

    /// Shown after `PortableClientModel.noServerDelay` without any discovered poste:
    /// says what is missing and offers the two ways to pair.
    private var noServerCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(RemoteScribePalette.warning.opacity(0.16))
                        .frame(width: 48, height: 48)
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(RemoteScribePalette.warning)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Aucun poste trouvé sur ce Wi-Fi")
                        .font(.headline)
                        .foregroundStyle(RemoteScribePalette.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("Sur le poste, ouvrez VoxLocal › Remote Scribe, puis scannez le code affiché.")
                        .font(.subheadline)
                        .foregroundStyle(RemoteScribePalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            VoxGlassControls {
                VStack(spacing: 12) {
                    Button { showingScanner = true } label: {
                        Label("Scanner le code du poste", systemImage: "qrcode.viewfinder")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .voxGlassProminentButton(tint: RemoteScribePalette.action)
                    .accessibilityHint("Ouvre la caméra pour lire le code d’appairage affiché sur le poste")

                    Button { showingConnections = true } label: {
                        Label("Saisir l’adresse", systemImage: "keyboard")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .voxGlassButton()
                    .accessibilityHint("Ouvre la connexion manuelle par nom ou adresse IP")
                }
            }
        }
        .padding(16)
        .voxContentSurface(cornerRadius: 24)
    }

    /// Hidden while disconnected: the list of engines belongs to the poste and is
    /// only known once it has accepted the pairing.
    @ViewBuilder
    private var enginePicker: some View {
        if model.isConnected && model.availableBackends.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("MOTEUR DE TRANSCRIPTION")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.1)
                    .foregroundStyle(RemoteScribePalette.secondaryText)

                Picker("Moteur de transcription", selection: $model.selectedBackend) {
                    ForEach(model.availableBackends) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.phase == .recording || model.isBusy)
                .accessibilityLabel("Moteur de transcription sur le poste")
                .accessibilityHint("Le moteur peut être modifié lorsque le poste est prêt")

                Text("Le choix s’applique à la prochaine dictée.")
                    .font(.footnote)
                    .foregroundStyle(RemoteScribePalette.secondaryText)
            }
            .padding(.horizontal, 2)
        } else if model.isConnected, let backend = model.availableBackends.first {
            Label("Transcription par \(backend.displayName) sur le poste", systemImage: "cpu")
                .font(.footnote)
                .foregroundStyle(RemoteScribePalette.secondaryText)
                .padding(.horizontal, 2)
        }
    }

    private var recorderCard: some View {
        VStack(spacing: 22) {
            VStack(spacing: 5) {
                Label(model.phase.title, systemImage: model.phase.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(phaseColor)
                    .accessibilityAddTraits(.isHeader)
                Text(model.connectionMessage)
                    .font(.subheadline)
                    .foregroundStyle(RemoteScribePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 440)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("État de la dictée")
            .accessibilityValue("\(model.phase.title). \(model.connectionMessage)")

            ZStack {
                Circle()
                    .stroke(phaseColor.opacity(0.18), lineWidth: 16)
                    .frame(width: 190, height: 190)
                Circle()
                    .fill(phaseColor.opacity(0.12))
                    .frame(width: 164, height: 164)
                    .scaleEffect(!reduceMotion && model.phase == .recording ? 1 + model.audioLevel * 0.05 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.audioLevel)
                Image(systemName: model.phase == .recording ? "mic.fill" : model.phase.systemImage)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(RemoteScribePalette.primaryText)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(model.elapsedText)
                    .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(RemoteScribePalette.primaryText)
                    .accessibilityLabel("Durée")
                    .accessibilityValue(model.elapsedText)

                LevelMeter(level: model.audioLevel, active: model.phase == .recording, color: phaseColor)
                    .frame(height: 32)
                    .padding(.horizontal, 18)
                    .accessibilityLabel("Niveau sonore")
                    .accessibilityValue(model.phase == .recording ? "Actif" : "Inactif")
            }

            VoxGlassControls {
                VStack(spacing: 12) {
                    Button(action: model.toggleRecording) {
                        HStack(spacing: 10) {
                            Image(systemName: model.canStop ? "stop.fill" : "mic.fill")
                            Text(model.canStop ? "Arrêter la dictée" : "Démarrer la dictée")
                        }
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .voxGlassProminentButton(tint: buttonColor)
                    .disabled(!model.canStart && !model.canStop)
                    .accessibilityLabel(model.canStop ? "Arrêter la dictée" : "Démarrer la dictée")
                    .accessibilityHint(model.canStop
                                       ? "Envoie les derniers morceaux et lance le traitement"
                                       : "Commence une nouvelle dictée sur le poste")

                    if model.phase == .failed && !model.isConnected {
                        Button("Rechercher un poste à nouveau", action: model.retry)
                            .font(.subheadline.weight(.semibold))
                            .voxGlassButton()
                            .frame(minHeight: 44)
                            .accessibilityHint("Relance la recherche sur le réseau local")
                    }
                }
            }

            if model.isConnected && model.results.isEmpty && !model.canStop {
                Label("Maintenez l’\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") à 20 cm, parlez normalement.", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(RemoteScribePalette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .voxContentSurface(cornerRadius: 28)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Historique")
                        .font(.title3.weight(.semibold))
                    Text(historyCountText)
                        .font(.footnote)
                        .foregroundStyle(RemoteScribePalette.secondaryText)
                }
                Spacer(minLength: 12)
                Button("Effacer", role: .destructive) { showingClearHistory = true }
                    .font(.subheadline.weight(.semibold))
                    .voxGlassButton()
                    .frame(minHeight: 44)
                    .accessibilityHint("Supprime toutes les transcriptions locales")
            }

            resultList
        }
    }

    private var historySidebar: some View {
        ZStack {
            RemoteScribePalette.background
                .ignoresSafeArea()

            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.results.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 34, weight: .regular))
                                .foregroundStyle(RemoteScribePalette.secondaryText)
                                .accessibilityHidden(true)
                            Text("Aucune dictée pour l’instant")
                                .font(.headline)
                                .foregroundStyle(RemoteScribePalette.primaryText)
                            Text("Les textes transcrits par le poste s’affichent ici pour être relus, copiés ou partagés.")
                                .font(.subheadline)
                                .foregroundStyle(RemoteScribePalette.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                        .accessibilityElement(children: .combine)
                    } else {
                        Text(historyCountText)
                            .font(.footnote)
                            .foregroundStyle(RemoteScribePalette.secondaryText)
                        resultList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.highlightedResultID) { reveal($0, with: proxy) }
            }
        }
        .toolbar {
            if !model.results.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Effacer", role: .destructive) { showingClearHistory = true }
                        .frame(minHeight: 44)
                        .accessibilityHint("Supprime toutes les transcriptions locales")
                }
            }
        }
    }

    private var resultList: some View {
        LazyVStack(spacing: 12) {
            ForEach(model.results) { result in
                ResultCard(result: result, highlighted: model.highlightedResultID == result.id)
                    .id(result.id)
            }
        }
    }

    private var historyCountText: String {
        "\(model.results.count) transcription\(model.results.count == 1 ? "" : "s") sur cet appareil"
    }

    private var privacyNote: some View {
        Label {
            Text(model.historyPersistenceEnabled
                 ? "Traitement sur l’infrastructure configurée par votre établissement. Les textes conservés restent chiffrés sur cet appareil."
                 : "Traitement sur l’infrastructure configurée par votre établissement. Les textes restent en mémoire et ne sont pas conservés après la fermeture de l’app.")
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "lock.shield.fill")
        }
        .font(.footnote)
        .foregroundStyle(RemoteScribePalette.secondaryText)
        .frame(maxWidth: 600, alignment: .leading)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Confidentialité")
        .accessibilityValue(model.historyPersistenceEnabled
                           ? "Traitement sur l’infrastructure configurée par votre établissement. Les textes conservés restent chiffrés sur cet appareil."
                           : "Traitement sur l’infrastructure configurée par votre établissement. Les textes restent en mémoire et ne sont pas conservés après la fermeture de l’app.")
    }

    private var historySettings: some View {
        Toggle(isOn: Binding(get: { model.historyPersistenceEnabled }, set: { model.setHistoryPersistence($0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Conserver l’historique sur cet appareil")
                    .font(.subheadline.weight(.semibold))
                Text(model.historyPersistenceEnabled ? "Activé volontairement. Les transcriptions sont chiffrées dans le trousseau local." : "Désactivé par défaut. Les transcriptions restent en mémoire jusqu’à la fermeture de l’app.")
                    .font(.footnote)
                    .foregroundStyle(RemoteScribePalette.secondaryText)
            }
        }
        .tint(RemoteScribePalette.action)
        .padding(14)
        .voxContentSurface(cornerRadius: 18)
        .accessibilityHint("Active ou désactive la conservation locale des textes")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RemoteScribePalette.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Action requise")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(RemoteScribePalette.secondaryText)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RemoteScribePalette.error.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Erreur")
        .accessibilityValue(message)
    }

    private var connectionSummary: String {
        if model.isConnected { return model.connectionMessage }
        return model.phase == .searching ? "Recherche sur le réseau local…" : model.connectionMessage
    }

    private var phaseColor: Color {
        switch model.phase {
        case .recording, .failed: return RemoteScribePalette.error
        case .completed, .ready: return RemoteScribePalette.success
        case .processing, .starting, .stopping, .connecting: return RemoteScribePalette.warning
        case .searching: return RemoteScribePalette.action
        }
    }

    private var buttonColor: Color {
        model.canStop ? RemoteScribePalette.error : RemoteScribePalette.action
    }
}

enum RemoteScribePalette {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.075)
    static let surface = Color.white.opacity(0.07)
    static let surfaceStrong = Color.white.opacity(0.085)
    static let separator = Color.white.opacity(0.11)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.68)
    static let action = Color(red: 0.39, green: 0.36, blue: 1.0)
    static let success = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.05)
    static let error = Color(red: 1.0, green: 0.27, blue: 0.23)
}

// Liquid Glass is available from iOS 26. These wrappers preserve the iOS 16
// deployment target while using the native material whenever it is present.
extension View {
    func voxContentSurface(cornerRadius: CGFloat) -> some View {
        self
            .background(RemoteScribePalette.surfaceStrong, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(RemoteScribePalette.separator, lineWidth: 1)
            }
    }

    @ViewBuilder
    func voxGlassButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func voxGlassProminentButton(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            self.buttonStyle(.borderedProminent)
                .tint(tint)
        }
    }
}

struct VoxGlassControls<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                content
            }
        } else {
            content
        }
    }
}

private struct LevelMeter: View {
    let level: Double
    let active: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<15, id: \.self) { index in
                let distance = abs(Double(index) - 7)
                let value = active ? max(0.08, level * (1 - distance * 0.075)) : 0.08
                Capsule()
                    .fill(active ? color.opacity(0.76) : Color.white.opacity(0.2))
                    .frame(maxWidth: .infinity)
                    .frame(height: 5 + value * 23)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityElement(children: .ignore)
    }
}

private struct ResultCard: View {
    let result: PortableResult
    /// Set for 1.5 s after the dictée completes.
    let highlighted: Bool
    @State private var showsRaw = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.backend.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RemoteScribePalette.action)
                    Text(result.completedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(RemoteScribePalette.secondaryText)
                }
                Spacer(minLength: 12)
                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RemoteScribePalette.secondaryText)
            }

            if let delivery = result.posteDelivery {
                Label(delivery == .pasted ? "Collé sur le poste" : "Copié sur le poste",
                      systemImage: delivery == .pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RemoteScribePalette.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RemoteScribePalette.success.opacity(0.14), in: Capsule())
                    .accessibilityLabel(delivery == .pasted
                                        ? "Texte collé automatiquement sur le poste"
                                        : "Texte copié dans le presse-papier du poste")
            }

            Text(showsRaw ? (result.rawText ?? result.finalText) : result.finalText)
                .font(.body)
                .foregroundStyle(RemoteScribePalette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .privacySensitive()

            VoxGlassControls {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { rawToggle; copyButton; shareButton }
                    VStack(alignment: .leading, spacing: 10) {
                        rawToggle
                        HStack(spacing: 10) { copyButton; shareButton }
                    }
                    VStack(alignment: .leading, spacing: 10) { rawToggle; copyButton; shareButton }
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .voxContentSurface(cornerRadius: 18)
        .overlay {
            // Reduce Motion: the outline appears and disappears without the fade.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RemoteScribePalette.success, lineWidth: 2)
                .opacity(highlighted ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: highlighted)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private var displayedText: String { showsRaw ? (result.rawText ?? result.finalText) : result.finalText }

    // The glass capsule adds about 12 pt around its label: 32 pt labels give 44 pt targets.
    @ViewBuilder
    private var rawToggle: some View {
        if result.rawText != nil {
            Button {
                showsRaw.toggle()
            } label: {
                Text(showsRaw ? "Texte final" : "Transcription brute")
                    .frame(minHeight: 32)
            }
            .voxGlassButton()
            .accessibilityHint("Change le texte affiché dans cette transcription")
        }
    }

    private var copyButton: some View {
        Button {
            // Local only, expires after two minutes: clinical text must not linger
            // on the clipboard or travel to other devices.
            UIPasteboard.general.setItems(
                [[UTType.utf8PlainText.identifier: displayedText]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
            )
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                .frame(minHeight: 32)
        }
        .voxGlassButton()
        .accessibilityLabel(copied ? "Texte copié" : "Copier")
        .accessibilityHint("Copie le texte affiché sur cet appareil pendant deux minutes")
    }

    private var shareButton: some View {
        ShareLink(item: displayedText) {
            Label("Partager", systemImage: "square.and.arrow.up")
                .frame(minHeight: 32)
        }
        .voxGlassButton()
        .accessibilityHint("Partage le texte actuellement affiché")
    }

    private var durationText: String {
        let seconds = max(0, Int(result.duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ConnectionSheet: View {
    @ObservedObject var model: PortableClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var forgettingIdentity: PinnedServerIdentity?
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    connectionStateRow
                }

                Section {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scanner le code du poste", systemImage: "qrcode.viewfinder")
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("Lit le code d’appairage affiché dans VoxLocal › Remote Scribe")
                } footer: {
                    Text("Le code du poste contient son nom, le code d’appairage et l’empreinte de son certificat.")
                }

                Section("Postes détectés") {
                    if model.servers.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Recherche sur le réseau local…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.servers, id: \.id) { server in
                            Button {
                                model.connect(to: server)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: model.selectedServerID == server.id ? "checkmark.circle.fill" : "desktopcomputer")
                                        .foregroundStyle(model.selectedServerID == server.id ? .green : .indigo)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(server.name)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(backendNames(server.availableBackends))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    if model.selectedServerID == server.id {
                                        Text("Connecté")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.green)
                                    }
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }

                Section {
                    TextField("Nom ou adresse IP du poste", text: $model.manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    TextField("Port (47365 par défaut)", text: $model.manualPort)
                        .keyboardType(.numberPad)
                    SecureField("Code d’appairage requis", text: $model.pairingCode)
                        .textContentType(.password)
                    Button("Rejoindre ce poste") {
                        model.connectManually()
                        dismiss()
                    }
                    .frame(minHeight: 44)
                } header: {
                    Text("Connexion manuelle")
                } footer: {
                    Text("L’appareil et le poste doivent être sur le même réseau local. Le code est conservé dans le trousseau sécurisé de l’appareil.")
                }

                Section("Transport") {
                    Toggle("Activer TLS", isOn: $model.useTLS)
                        .disabled(model.isConnected || model.isBusy)
                    Text(model.useTLS
                         ? "À la première connexion, comparez l’empreinte du certificat avec celle affichée sur le poste. Un certificat approuvé par l’établissement est accepté directement."
                         : "Le mode TCP historique est réservé à un VLAN ou tunnel WireGuard contrôlé.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let pinned = model.pinnedIdentity {
                    Section {
                        Label {
                            Text("Identité épinglée · \(pinned.fingerprint.shortDisplay)")
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.green)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Identité du poste épinglée")
                        .accessibilityValue(pinned.fingerprint.shortDisplay)
                        Button("Oublier ce poste", role: .destructive) {
                            forgettingIdentity = pinned
                        }
                        .frame(minHeight: 44)
                        .accessibilityHint("Efface l’empreinte enregistrée ; la prochaine connexion demandera une nouvelle vérification")
                    } header: {
                        Text("Identité du poste")
                    } footer: {
                        Text("Seul le certificat dont l’empreinte a été vérifiée est accepté pour ce poste.")
                    }
                }

                if model.isConnected {
                    Section {
                        Button("Se déconnecter", role: .destructive) {
                            model.disconnect()
                            dismiss()
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .navigationTitle("Connexion au poste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                        .frame(minHeight: 44)
                }
            }
            .presentationDetents([.medium, .large])
            .sheet(isPresented: $showingScanner) {
                QRPairingView(model: model, onPaired: { dismiss() })
            }
            .confirmationDialog(
                "Oublier ce poste ?",
                isPresented: Binding(get: { forgettingIdentity != nil }, set: { if !$0 { forgettingIdentity = nil } }),
                titleVisibility: .visible,
                presenting: forgettingIdentity
            ) { pinned in
                Button("Oublier l’identité", role: .destructive) {
                    model.forgetServerIdentity(key: pinned.key)
                }
                Button("Annuler", role: .cancel) { }
            } message: { _ in
                Text("L’empreinte enregistrée sera effacée. À la prochaine connexion, vous devrez la comparer de nouveau avec celle affichée sur le poste.")
            }
        }
    }

    private var connectionStateRow: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.serverName ?? "Aucun poste connecté")
                    .font(.subheadline.weight(.semibold))
                Text(model.connectionMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        } icon: {
            Image(systemName: model.phase.systemImage)
                .foregroundStyle(connectionColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("État de la connexion")
        .accessibilityValue("\(model.serverName ?? "Aucun poste connecté"). \(model.connectionMessage)")
    }

    private var connectionColor: Color {
        switch model.phase {
        case .ready, .completed: return .green
        case .failed: return .red
        default: return .indigo
        }
    }

    private func backendNames(_ backends: [RemoteBackendKind]) -> String {
        guard !backends.isEmpty else { return "Remote Scribe" }
        return backends.map(\.displayName).joined(separator: " · ")
    }
}

/// Trust-on-first-use confirmation. The only moment the user can detect a
/// server impersonation, so the fingerprint is large, monospaced and grouped
/// exactly as VoxLocal shows it on the Mac.
private struct TrustServerSheet: View {
    let trust: PendingTrust
    let onTrust: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteScribePalette.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(RemoteScribePalette.warning)
                                .accessibilityHidden(true)
                            Text("Vérifier l’identité du poste")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(RemoteScribePalette.primaryText)
                                .accessibilityAddTraits(.isHeader)
                            Text("Comparez cette empreinte avec celle affichée dans VoxLocal sur le poste. Ne validez pas si elles diffèrent.")
                                .font(.body)
                                .foregroundStyle(RemoteScribePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Label(trust.serverName, systemImage: "desktopcomputer")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RemoteScribePalette.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("EMPREINTE TLS (SHA-256)")
                                .font(.caption2.weight(.semibold))
                                .tracking(1.1)
                                .foregroundStyle(RemoteScribePalette.secondaryText)
                            Text(fingerprintLines)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
                                .foregroundStyle(RemoteScribePalette.primaryText)
                                .lineSpacing(6)
                                .lineLimit(4)
                                .minimumScaleFactor(0.5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("Empreinte TLS SHA-256")
                                .accessibilityValue(Text(trust.display).speechSpellsOutCharacters())
                        }
                        .padding(18)
                        .voxContentSurface(cornerRadius: 20)
                        .accessibilityElement(children: .contain)

                        VoxGlassControls {
                            VStack(spacing: 12) {
                                Button(action: onTrust) {
                                    Text("Faire confiance et connecter")
                                        .font(.headline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .voxGlassProminentButton(tint: RemoteScribePalette.action)
                                .accessibilityHint("Enregistre cette empreinte sur l’appareil et relance la connexion")

                                Button(action: onCancel) {
                                    Text("Annuler")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .voxGlassButton()
                                .accessibilityHint("Ne se connecte pas à ce poste")
                            }
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
    }

    /// Four groups of four hex digits per line, sixteen groups in total.
    private var fingerprintLines: String {
        let groups = ServerFingerprint(data: trust.fingerprint).groups
        return stride(from: 0, to: groups.count, by: 4)
            .map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }
            .joined(separator: "\n")
    }
}
