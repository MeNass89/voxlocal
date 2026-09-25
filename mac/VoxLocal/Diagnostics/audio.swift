import Foundation

@main
struct AudioDiagnostics {
    static func main() async throws {
        let recorder = AudioRecorder()
        let devices = recorder.devices()
        print("Microphones: \(devices.map(\.name).joined(separator: ", "))")
        guard !devices.isEmpty else { throw VoxError.message("Aucun microphone détecté.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxlocal-swift-audio-diagnostic.wav")
        try await recorder.start(destination: url, deviceID: nil)
        try await Task.sleep(nanoseconds: 900_000_000)
        let duration = try recorder.stop()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? NSNumber ?? 0
        guard duration > 0.5, size.intValue > 1_000 else { throw VoxError.message("Le WAV de diagnostic est vide.") }
        print(String(format: "Audio capture: PASS (%.2f s, %@ bytes, %@)", duration, size, url.path))
        try? FileManager.default.removeItem(at: url)
    }
}
