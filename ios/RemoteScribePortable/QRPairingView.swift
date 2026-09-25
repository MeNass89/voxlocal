import AVFoundation
import SwiftUI
import UIKit

/// Reads the pairing QR code that VoxLocal shows in Remote Scribe on the poste,
/// then hands the `PairingLink` to the model. Without a usable camera (simulator,
/// permission refused) the same link can be pasted.
struct QRPairingView: View {
    @ObservedObject var model: PortableClientModel
    var onPaired: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera = CameraAvailability.current
    @State private var pastedLink = ""
    @State private var feedback: String?
    @FocusState private var linkFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteScribePalette.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scanner le code du poste")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(RemoteScribePalette.primaryText)
                                .accessibilityAddTraits(.isHeader)
                            Text("Sur le poste, ouvrez VoxLocal › Remote Scribe. Le code contient le nom du poste, le code d’appairage et l’empreinte de son certificat.")
                                .font(.body)
                                .foregroundStyle(RemoteScribePalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        cameraArea

                        if let feedback {
                            Label(feedback, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(RemoteScribePalette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Erreur")
                                .accessibilityValue(feedback)
                        }

                        pasteArea
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .frame(minHeight: 44)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: requestCameraIfNeeded)
    }

    @ViewBuilder
    private var cameraArea: some View {
        switch camera {
        case .authorized:
            QRCameraPreview { value in apply(value, fromCamera: true) }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(RemoteScribePalette.separator, lineWidth: 1)
                }
                .accessibilityLabel("Aperçu de la caméra")
                .accessibilityHint("Visez le code affiché sur le poste ; l’appairage démarre dès qu’il est lu")
        case .notDetermined:
            cameraMessage(symbol: "camera", title: "Accès à la caméra", message: "Autorisez la caméra pour lire le code affiché sur le poste.")
        case .denied:
            VStack(alignment: .leading, spacing: 14) {
                cameraMessage(symbol: "camera.fill", title: "Caméra refusée", message: "Autorisez la caméra pour Remote Scribe dans Réglages, ou collez le lien d’appairage ci-dessous.")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Ouvrir Réglages", systemImage: "gear")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .voxGlassButton()
                .accessibilityHint("Ouvre les réglages de Remote Scribe pour autoriser la caméra")
            }
        case .unavailable:
            cameraMessage(
                symbol: "video.slash",
                title: CameraAvailability.isSimulator ? "Caméra indisponible dans le simulateur" : "Caméra indisponible",
                message: "Collez le lien d’appairage copié depuis VoxLocal sur le poste."
            )
        }
    }

    private func cameraMessage(symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(RemoteScribePalette.secondaryText)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(RemoteScribePalette.primaryText)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(RemoteScribePalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .voxContentSurface(cornerRadius: 24)
        .accessibilityElement(children: .combine)
    }

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coller un lien d’appairage")
                .font(.headline)
                .foregroundStyle(RemoteScribePalette.primaryText)
                .accessibilityAddTraits(.isHeader)

            TextField("remotescribe://pair?…", text: $pastedLink, axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .focused($linkFieldFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .voxContentSurface(cornerRadius: 16)
                .accessibilityLabel("Lien d’appairage")
                .accessibilityHint("Collez le lien copié depuis VoxLocal sur le poste")
                .onSubmit { apply(pastedLink, fromCamera: false) }

            VoxGlassControls {
                HStack(spacing: 12) {
                    PasteButton(payloadType: String.self) { values in
                        guard let value = values.first else { return }
                        Task { @MainActor in
                            pastedLink = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            apply(pastedLink, fromCamera: false)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityHint("Colle et applique le lien présent dans le presse-papier")

                    Button {
                        apply(pastedLink, fromCamera: false)
                    } label: {
                        Text("Appairer")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .voxGlassProminentButton(tint: RemoteScribePalette.action)
                    .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Enregistre le code et l’empreinte du poste, puis se connecte")
                }
            }
        }
    }

    private func requestCameraIfNeeded() {
        guard camera == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { camera = granted ? CameraAvailability.current : .denied }
        }
    }

    private func apply(_ value: String, fromCamera: Bool) {
        guard let link = PairingLink(string: value) else {
            // A camera sees many unrelated codes; only a pasted value earns an error.
            if !fromCamera { feedback = "Ce lien n’est pas un code d’appairage VoxLocal. Copiez-le de nouveau depuis Remote Scribe sur le poste." }
            return
        }
        if let message = model.applyPairingLink(link) {
            feedback = message
            return
        }
        feedback = nil
        linkFieldFocused = false
        if fromCamera { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        dismiss()
        onPaired()
    }
}

private enum CameraAvailability: Equatable {
    case authorized, notDetermined, denied, unavailable

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static var current: CameraAvailability {
        guard !isSimulator, AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

/// Camera preview that reports each QR payload once per distinct value.
private struct QRCameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = context.coordinator.session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        var onCode: (String) -> Void
        private let queue = DispatchQueue(label: "com.voxlocal.remotescribe.qr-camera")
        private var lastValue: String?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            super.init()
        }

        func start() {
            queue.async { [session] in
                if session.inputs.isEmpty {
                    session.beginConfiguration()
                    if let device = AVCaptureDevice.default(for: .video),
                       let input = try? AVCaptureDeviceInput(device: device),
                       session.canAddInput(input) {
                        session.addInput(input)
                        let output = AVCaptureMetadataOutput()
                        if session.canAddOutput(output) {
                            session.addOutput(output)
                            output.setMetadataObjectsDelegate(self, queue: .main)
                            if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
                        }
                    }
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
            }
        }

        func stop() {
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr }),
                  let value = code.stringValue, value != lastValue else { return }
            lastValue = value
            onCode(value)
        }
    }
}
