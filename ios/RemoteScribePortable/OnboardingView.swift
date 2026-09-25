import SwiftUI
import UIKit

/// First launch: three short pages that say what the app does, how to pair it
/// with the poste, and what happens to the text. The last page opens the QR
/// scanner directly; every page can be skipped.
struct OnboardingView: View {
    static let doneKey = "portable.onboardingDone"

    let onScan: () -> Void
    let onLater: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    private var pages: [OnboardingPage] {
        [
            OnboardingPage(
                symbols: [device.lowercased(), "wave.3.right", "desktopcomputer"],
                title: "Votre \(device) devient le micro du poste",
                message: "Vous dictez ici. Le poste transcrit le texte sur l’infrastructure de votre établissement."
            ),
            OnboardingPage(
                symbols: ["desktopcomputer", "qrcode", "qrcode.viewfinder"],
                title: "Sur le poste, ouvrez VoxLocal › Remote Scribe et scannez le code",
                message: "Le code appaire cet \(device) et vérifie l’identité du poste en une seule fois. Aucun code à recopier."
            ),
            OnboardingPage(
                symbols: ["mic.fill", "text.alignleft", "checkmark.circle.fill"],
                title: "Dictez, relisez, le texte est collé sur le poste",
                message: "Le texte revient aussi ici pour être relu, copié ou partagé avant utilisation."
            ),
        ]
    }

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            RemoteScribePalette.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, content in
                        OnboardingPageView(page: content, number: index + 1, total: pages.count)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))

                actions
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Same two slots on every page so the buttons never jump; only the labels change.
    private var actions: some View {
        VoxGlassControls {
            VStack(spacing: 12) {
                Button {
                    if isLastPage { onScan() } else { advance() }
                } label: {
                    Label(isLastPage ? "Scanner le code" : "Continuer",
                          systemImage: isLastPage ? "qrcode.viewfinder" : "arrow.right")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                }
                .voxGlassProminentButton(tint: RemoteScribePalette.action)
                .accessibilityHint(isLastPage
                                   ? "Ouvre la caméra pour lire le code affiché sur le poste"
                                   : "Affiche l’étape suivante")

                Button(action: onLater) {
                    Text(isLastPage ? "Plus tard" : "Passer")
                        .font(.headline)
                        .foregroundStyle(RemoteScribePalette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                }
                .voxGlassButton()
                .accessibilityHint("Ouvre l’écran de dictée ; le poste pourra être appairé depuis les réglages de connexion")
            }
        }
    }

    private func advance() {
        if reduceMotion {
            page += 1
        } else {
            withAnimation(.easeOut(duration: 0.3)) { page += 1 }
        }
    }
}

private struct OnboardingPage {
    /// Left device, link, right device: a small diagram made only of SF Symbols.
    let symbols: [String]
    let title: String
    let message: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let number: Int
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    // Centred when it fits; scrolls at large Dynamic Type sizes.
                    .frame(minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var content: some View {
            VStack(spacing: 32) {
                illustration
                VStack(spacing: 14) {
                    Text(page.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(RemoteScribePalette.primaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.message)
                        .font(.body)
                        .foregroundStyle(RemoteScribePalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Étape \(number) sur \(total). \(page.title)")
                .accessibilityValue(page.message)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity)
    }

    private var illustration: some View {
        HStack(spacing: 18) {
            symbol(page.symbols[0], size: 44, color: RemoteScribePalette.primaryText)
            symbol(page.symbols[1], size: 26, color: RemoteScribePalette.action)
            symbol(page.symbols[2], size: 44, color: number == total ? RemoteScribePalette.success : RemoteScribePalette.primaryText)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .background(RemoteScribePalette.action.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(RemoteScribePalette.separator, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, size: CGFloat, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .frame(width: size * 1.5, height: 64)
    }
}
