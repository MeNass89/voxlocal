import AppKit
import Combine
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var state: AppState?
    private var mainWindow: NSWindow?
    private var floatingPanel: FloatingPanelController?
    private var remoteMenu: RemoteScribeStatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let state = AppState(); self.state = state
        let view = MainView(state: state).preferredColorScheme(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "VoxLocal"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false; window.center(); window.delegate = self
        window.contentViewController = NSHostingController(rootView: view)
        window.makeKeyAndOrderFront(nil); mainWindow = window
        let panel = FloatingPanelController(state: state); panel.show(); floatingPanel = panel
        remoteMenu = RemoteScribeStatusMenu(state: state)
        configureMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { mainWindow?.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { state?.shutdown() }

    private func configureMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos de VoxLocal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Masquer VoxLocal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quitter VoxLocal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = main
    }
}

@MainActor
private final class RemoteScribeStatusMenu: NSObject, NSMenuDelegate {
    private let state: AppState
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observation: AnyCancellable?

    init(state: AppState) {
        self.state = state
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoxLocal")
        statusItem.button?.toolTip = "VoxLocal"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        observation = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let vox = NSMenuItem(title: "VoxLocal", action: #selector(selectBackend(_:)), keyEquivalent: "")
        vox.target = self; vox.tag = 0; vox.state = state.remoteBackend == .voxLocal ? .on : .off; menu.addItem(vox)
        let superwhisper = NSMenuItem(title: "SuperWhisper (temporaire)", action: #selector(selectBackend(_:)), keyEquivalent: "")
        superwhisper.target = self; superwhisper.tag = 1; superwhisper.state = state.remoteBackend == .superwhisper ? .on : .off
        superwhisper.isEnabled = state.remoteScribe.availableBackends.contains(.superwhisper); menu.addItem(superwhisper)

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Ouvrir VoxLocal…", action: #selector(openVoxLocal), keyEquivalent: "")
        open.target = self; menu.addItem(open)
    }

    @objc private func selectBackend(_ sender: NSMenuItem) { state.setRemoteBackend(sender.tag == 0 ? .voxLocal : .superwhisper) }
    @objc private func openVoxLocal() { state.show(.history) }
}
