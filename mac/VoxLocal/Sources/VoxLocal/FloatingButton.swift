import AppKit
import Combine

struct DragGestureTracker {
    static let defaultThreshold: CGFloat = 5
    let startPoint: NSPoint; let startWindowOrigin: NSPoint; let threshold: CGFloat
    private(set) var exceededThreshold = false
    init(startPoint: NSPoint, startWindowOrigin: NSPoint, threshold: CGFloat = Self.defaultThreshold) { self.startPoint = startPoint; self.startWindowOrigin = startWindowOrigin; self.threshold = threshold }
    mutating func windowOrigin(for currentPoint: NSPoint) -> NSPoint? {
        let dx = currentPoint.x - startPoint.x, dy = currentPoint.y - startPoint.y
        if hypot(dx, dy) >= threshold { exceededThreshold = true }
        return exceededThreshold ? NSPoint(x: startWindowOrigin.x + dx, y: startWindowOrigin.y + dy) : nil
    }
    func isClick(at point: NSPoint) -> Bool { !exceededThreshold && hypot(point.x - startPoint.x, point.y - startPoint.y) < threshold }
}

private final class QuitButton: NSButton { override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true } }

@MainActor
final class MicrophoneButtonView: NSView {
    var onMove: ((NSPoint, NSPoint) -> Void)?; var onMoveEnded: (() -> Void)?
    private let state: AppState
    private let iconView = NSImageView(frame: .zero)
    private let quitButton = QuitButton(frame: .zero)
    private let progress = NSProgressIndicator(frame: .zero)
    private var dragTracker: DragGestureTracker?
    private var trackingAreaReference: NSTrackingArea?
    private var quitRevealWorkItem: DispatchWorkItem?
    private var isPointerInside = false
    private var cancellables: Set<AnyCancellable> = []
    private let idleColor = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.94)
    private let hoverColor = NSColor(calibratedRed: 0.19, green: 0.19, blue: 0.22, alpha: 0.98)

    init(frame: NSRect, state: AppState) {
        self.state = state; super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = idleColor.cgColor; layer?.cornerRadius = frame.width / 2; layer?.masksToBounds = false
        iconView.imageScaling = .scaleProportionallyUpOrDown; iconView.contentTintColor = .white; addSubview(iconView)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; progress.contentFilters = []; addSubview(progress)

        let quitSymbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quitter VoxLocal")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        quitSymbol?.isTemplate = true; quitButton.image = quitSymbol; quitButton.imagePosition = .imageOnly; quitButton.imageScaling = .scaleProportionallyDown; quitButton.contentTintColor = .white; quitButton.isBordered = false; quitButton.wantsLayer = true; quitButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor; quitButton.layer?.cornerRadius = 9; quitButton.target = self; quitButton.action = #selector(quitApplication); quitButton.toolTip = "Quitter"; quitButton.isHidden = true; addSubview(quitButton)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Démarrer ou arrêter la dictée VoxLocal")
        toolTip = "Clic : dicter · Glisser : déplacer · Clic droit : modes · Survol : quitter"
        state.$pipelineStatus.sink { [weak self] value in self?.update(status: value) }.store(in: &cancellables)
        update(status: state.pipelineStatus)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout(); let iconSize: CGFloat = 26
        iconView.frame = NSRect(x: (bounds.width-iconSize)/2, y: (bounds.height-iconSize)/2, width: iconSize, height: iconSize)
        progress.frame = NSRect(x: (bounds.width-20)/2, y: (bounds.height-20)/2, width: 20, height: 20)
        let q: CGFloat = 18; quitButton.frame = NSRect(x: bounds.maxX-q-3, y: bounds.maxY-q-3, width: q, height: q); quitButton.layer?.cornerRadius = q/2; layer?.cornerRadius = min(bounds.width,bounds.height)/2
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }; let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited,.activeAlways], owner: self); addTrackingArea(area); trackingAreaReference = area }
    override func mouseEntered(with event: NSEvent) { isPointerInside = true; if state.pipelineStatus == .idle { layer?.backgroundColor = hoverColor.cgColor }; scheduleQuitButtonReveal() }
    override func mouseExited(with event: NSEvent) { isPointerInside = false; quitRevealWorkItem?.cancel(); quitButton.isHidden = true; update(status: state.pipelineStatus) }
    override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { showContextMenu(event); return }; guard let origin = window?.frame.origin else { return }; dragTracker = DragGestureTracker(startPoint: screenLocation(event), startWindowOrigin: origin) }
    override func mouseDragged(with event: NSEvent) { guard var tracker = dragTracker else { return }; let point = screenLocation(event); let origin = tracker.windowOrigin(for: point); dragTracker = tracker; if let origin { onMove?(origin, point) } }
    override func mouseUp(with event: NSEvent) { guard let tracker = dragTracker else { return }; dragTracker = nil; if tracker.isClick(at: screenLocation(event)) { state.toggleRecording() } else { onMoveEnded?() } }
    override func rightMouseDown(with event: NSEvent) { showContextMenu(event) }

    private func screenLocation(_ event: NSEvent) -> NSPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation }
    private func update(status: PipelineStatus) {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        progress.stopAnimation(nil); progress.isHidden = true; iconView.isHidden = false
        switch status {
        case .idle: layer?.backgroundColor = (isPointerInside ? hoverColor : idleColor).cgColor; iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        case .recording: layer?.backgroundColor = NSColor.systemRed.cgColor; iconView.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        case .processing: layer?.backgroundColor = NSColor.systemPurple.cgColor; iconView.isHidden = true; progress.isHidden = false; progress.startAnimation(nil)
        case .done: layer?.backgroundColor = NSColor.systemGreen.cgColor; iconView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config); DispatchQueue.main.asyncAfter(deadline: .now()+1.1) { [weak self] in if self?.state.pipelineStatus == .done { self?.state.pipelineStatus = .idle } }
        case .error: layer?.backgroundColor = NSColor.systemOrange.cgColor; iconView.image = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?.withSymbolConfiguration(config); DispatchQueue.main.asyncAfter(deadline: .now()+1.4) { [weak self] in if self?.state.pipelineStatus == .error { self?.state.pipelineStatus = .idle } }
        }
        iconView.image?.isTemplate = true; iconView.contentTintColor = .white
    }
    private func scheduleQuitButtonReveal() { quitRevealWorkItem?.cancel(); let item = DispatchWorkItem { [weak self] in guard let self, self.isPointerInside else { return }; self.quitButton.alphaValue=0; self.quitButton.isHidden=false; NSAnimationContext.runAnimationGroup { $0.duration=0.12; self.quitButton.animator().alphaValue=1 } }; quitRevealWorkItem=item; DispatchQueue.main.asyncAfter(deadline:.now()+2.5,execute:item) }
    private func showContextMenu(_ event: NSEvent) { NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self) }
    func makeContextMenu() -> NSMenu {
        let menu=NSMenu(); let title=NSMenuItem(title:"Mode VoxLocal",action:nil,keyEquivalent:""); let submenu=NSMenu(title:"Mode VoxLocal")
        for mode in state.modes.filter(\.enabled) { let item=NSMenuItem(title:mode.name,action:#selector(selectMode(_:)),keyEquivalent:""); item.target=self; item.representedObject=mode.id; item.state = mode.id == state.settings.activeModeId ? .on : .off; submenu.addItem(item) }
        menu.setSubmenu(submenu, for:title); menu.addItem(title); menu.addItem(.separator())
        let open=NSMenuItem(title:"Ouvrir VoxLocal",action:#selector(openApplication),keyEquivalent:""); open.target=self; menu.addItem(open)
        return menu
    }
    @objc private func selectMode(_ sender:NSMenuItem){ if let id=sender.representedObject as? String { state.setActiveMode(id) } }
    @objc private func openApplication(){ state.show(.history) }
    @objc private func quitApplication(){ NSApp.terminate(nil) }
}

final class NonactivatingPanel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }

@MainActor
final class FloatingPanelController: NSWindowController {
    private static let diameter: CGFloat = 60, margin: CGFloat = 16
    private let buttonView: MicrophoneButtonView; private let state: AppState
    init(state: AppState) {
        self.state=state; let size=NSSize(width:Self.diameter,height:Self.diameter)
        let panel=NonactivatingPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        buttonView=MicrophoneButtonView(frame:NSRect(origin:.zero,size:size),state:state)
        panel.contentView = buttonView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        super.init(window:panel)
        buttonView.onMove={ [weak self] origin,point in guard let self else{return}; panel.setFrameOrigin(self.clamped(origin,pointer:point,size:size)) }
        buttonView.onMoveEnded={ [weak self] in self?.savePosition() }
        let saved = state.settings.floatingX.flatMap { x in state.settings.floatingY.map { NSPoint(x:x,y:$0) } }
        panel.setFrameOrigin(clamped(saved ?? defaultOrigin(size),pointer:nil,size:size))
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func show(){window?.orderFrontRegardless()}
    private func defaultOrigin(_ size:NSSize)->NSPoint { let f=(NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900); return NSPoint(x:f.maxX-size.width-Self.margin,y:f.midY-size.height/2) }
    private func clamped(_ origin:NSPoint,pointer:NSPoint?,size:NSSize)->NSPoint { let screens=NSScreen.screens; let screen=pointer.flatMap { p in screens.first{$0.frame.contains(p)} } ?? window?.screen ?? NSScreen.main ?? screens.first; guard let f=screen?.visibleFrame else{return origin}; return NSPoint(x:min(max(origin.x,f.minX),max(f.minX,f.maxX-size.width)),y:min(max(origin.y,f.minY),max(f.minY,f.maxY-size.height))) }
    private func savePosition(){ guard let origin=window?.frame.origin else{return}; state.settings.floatingX=origin.x; state.settings.floatingY=origin.y; state.saveSettings() }
}
