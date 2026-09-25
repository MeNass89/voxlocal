import AVFoundation
import SwiftUI

struct PermissionSetupView: View {
    @ObservedObject var state: AppState
    @State private var microphoneAuthorized = PlatformServices.microphoneAuthorized
    @State private var accessibilityAuthorized = PlatformServices.accessibilityAuthorized
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34)).foregroundStyle(.purple)
                Text("Autoriser VoxLocal").font(.system(size: 25, weight: .bold))
                Text("Ces autorisations permettent de dicter, de coller le résultat et de recevoir l’audio de l’iPhone.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                permissionRow(
                    title: "Microphone",
                    explanation: "Dicter directement depuis ce Mac.",
                    authorized: microphoneAuthorized,
                    button: microphoneAuthorized ? "Autorisé" : "Autoriser"
                ) {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                        PlatformServices.openPrivacySettings(.microphone)
                    } else {
                        PlatformServices.requestMicrophone { microphoneAuthorized = $0 }
                    }
                }
                Divider().padding(.leading, 48)
                permissionRow(
                    title: "Accessibilité",
                    explanation: "Coller automatiquement le texte dans le dossier médical.",
                    authorized: accessibilityAuthorized,
                    button: accessibilityAuthorized ? "Autorisé" : "Ouvrir les réglages"
                ) {
                    PlatformServices.requestAccessibility()
                    PlatformServices.openPrivacySettings(.accessibility)
                }
                Divider().padding(.leading, 48)
                permissionRow(
                    title: "Réseau local",
                    explanation: "Détecter l’iPhone et recevoir ses dictées sur le même Wi-Fi.",
                    authorized: nil,
                    button: "Ouvrir les réglages"
                ) { PlatformServices.openPrivacySettings(.localNetwork) }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))

            HStack {
                Text("Vous pourrez rouvrir cet écran depuis Réglages → Général.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Terminer") { state.finishPermissionSetup() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(.purple)
            }
        }
        .padding(28)
        .frame(width: 570)
        .interactiveDismissDisabled()
        .onAppear {
            refresh()
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in refresh() }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }
        .onDisappear { refreshTimer?.invalidate(); refreshTimer = nil }
    }

    private func permissionRow(title: String, explanation: String, authorized: Bool?, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            Image(systemName: authorized == true ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(authorized == true ? .green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action).disabled(authorized == true)
        }
        .padding(15)
    }

    private func refresh() {
        microphoneAuthorized = PlatformServices.microphoneAuthorized
        accessibilityAuthorized = PlatformServices.accessibilityAuthorized
    }
}
