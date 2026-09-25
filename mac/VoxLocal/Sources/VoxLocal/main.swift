import AppKit

let application = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.indices.contains(index + 1) {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    do { try MainActor.assumeIsolated { try PreviewRenderer.render(to: output) } }
    catch { fputs("Preview error: \(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let delegate = MainActor.assumeIsolated { ApplicationDelegate() }
    application.delegate = delegate
    application.run()
}
