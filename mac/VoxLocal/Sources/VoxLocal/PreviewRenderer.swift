import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = AppState(paths: AppPaths(root: directory.appendingPathComponent("PreviewData", isDirectory: true)))
        try render(view: NSHostingView(rootView: MainView(state: state)), size: NSSize(width: 1080, height: 700), to: directory.appendingPathComponent("main-window.png"))
        let button = MicrophoneButtonView(frame: NSRect(x: 0, y: 0, width: 60, height: 60), state: state)
        try render(view: button, size: NSSize(width: 60, height: 60), to: directory.appendingPathComponent("floating-button.png"))
        state.shutdown()
        print("Rendered VoxLocal previews to \(directory.path)")
    }

    private static func render(view: NSView, size: NSSize, to url: URL) throws {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; window.layoutIfNeeded(); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw VoxError.message("Impossible de produire la preview.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw VoxError.message("Impossible d’encoder la preview PNG.") }
        try png.write(to: url, options: .atomic)
    }
}
