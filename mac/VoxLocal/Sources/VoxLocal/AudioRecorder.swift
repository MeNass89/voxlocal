import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private let queue = DispatchQueue(label: "com.voxlocal.audio.writer")
    private var captureError: Error?

    var isRecording: Bool { engine.isRunning }

    func devices() -> [AudioDeviceInfo] {
        coreAudioDevices().map { AudioDeviceInfo(id: $0.uid, name: $0.name) }
    }

    func start(destination: URL, deviceID: String?) async throws {
        guard !isRecording else { throw VoxError.message("Un enregistrement est déjà en cours.") }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw VoxError.message("Autorisation microphone refusée. Activez VoxLocal dans Réglages Système → Confidentialité et sécurité → Microphone.") }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        framesWritten = 0; captureError = nil

        let input = engine.inputNode
        if let deviceID, !deviceID.isEmpty { try selectInputDevice(uid: deviceID, input: input) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoxError.message("Le microphone sélectionné ne fournit pas un format audio utilisable.")
        }
        self.converter = converter
        outputFile = try AVAudioFile(forWriting: destination, settings: targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: false)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.queue.async { self?.write(buffer, targetFormat: targetFormat) }
        }
        do {
            engine.prepare(); try engine.start()
        } catch {
            input.removeTap(onBus: 0); outputFile = nil; self.converter = nil
            throw VoxError.message("Impossible de démarrer le microphone : \(error.localizedDescription)")
        }
    }

    func stop() throws -> Double {
        guard isRecording else { throw VoxError.message("Aucun enregistrement en cours.") }
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        queue.sync {}
        outputFile = nil; converter = nil
        if let captureError { throw VoxError.message("Erreur pendant l’enregistrement : \(captureError.localizedDescription)") }
        return Double(framesWritten) / 16_000.0
    }

    func abort() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        queue.sync {}; outputFile = nil; converter = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter, let outputFile else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        if status == .error || error != nil { captureError = error ?? VoxError.message("Conversion audio impossible."); return }
        guard converted.frameLength > 0 else { return }
        do { try outputFile.write(from: converted); framesWritten += AVAudioFramePosition(converted.frameLength) }
        catch { captureError = error }
    }

    private func coreAudioDevices() -> [(id: AudioDeviceID, uid: String, name: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName) else { return nil }
            return (id, uid, name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private func selectInputDevice(uid: String, input: AVAudioInputNode) throws {
        guard let selected = coreAudioDevices().first(where: { $0.uid == uid }) else { throw VoxError.message("Le microphone sélectionné n’est plus disponible.") }
        guard let audioUnit = input.audioUnit else { throw VoxError.message("Impossible d’accéder au périphérique audio.") }
        var id = selected.id
        let result = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw VoxError.message("Impossible de sélectionner « \(selected.name) » (CoreAudio \(result)).") }
    }
}
