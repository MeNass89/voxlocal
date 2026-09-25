import AVFoundation
import Foundation

final class AudioStreamer {
    var onPCM: ((Data) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((Error) -> Void)?
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.voxlocal.remote-scribe.portable.audio")
    // This lock orders tap admission with STOP, including a tap already copying.
    private let admission = NSLock()
    private var generation: UInt64 = 0
    private var accepting = false
    private var deliveryEnabled = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.reportInterruption()
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.reportInterruption()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self?.reportInterruption()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: DispatchQueue.main.async { completion(true) }
        case .denied: DispatchQueue.main.async { completion(false) }
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        @unknown default: DispatchQueue.main.async { completion(false) }
        }
    }

    func start(completion: @escaping (Error?) -> Void) {
        admission.lock()
        generation &+= 1
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.stopLocked()
                guard self.isCurrent(token) else { throw AudioStreamError.cancelled }
                guard AVAudioSession.sharedInstance().recordPermission == .granted else { throw AudioStreamError.permissionDenied }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: [])
                try session.setPreferredSampleRate(48_000)
                try session.setPreferredIOBufferDuration(0.02)
                try session.setActive(true)
                let input = self.engine.inputNode
                let source = input.outputFormat(forBus: 0)
                guard source.sampleRate > 0, source.channelCount > 0,
                      let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
                      let converter = AVAudioConverter(from: source, to: target) else { throw AudioStreamError.unsupportedFormat }
                self.converter = converter
                self.targetFormat = target
                input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] buffer, _ in
                    guard let self else { return }
                    self.admission.lock()
                    defer { self.admission.unlock() }
                    guard self.accepting, self.generation == token else { return }
                    guard let copied = self.copy(buffer) else {
                        self.accepting = false
                        self.report(AudioStreamError.conversionFailed)
                        return
                    }
                    self.queue.async { [weak self] in self?.convert(copied, target: target) }
                }
                self.tapInstalled = true
                self.engine.prepare()
                self.admission.lock()
                let current = self.generation == token
                self.accepting = current
                self.deliveryEnabled = current
                self.admission.unlock()
                guard current else { throw AudioStreamError.cancelled }
                try self.engine.start()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.stopLocked()
                DispatchQueue.main.async { completion(error) }
            }
        }
        admission.unlock()
    }

    /// Closes admission synchronously; the queued operation follows every accepted
    /// buffer. Completion runs only after conversion, converter tail and PCM sends.
    func stop(drain: Bool = false, completion: (() -> Void)? = nil) {
        admission.lock()
        accepting = false
        if !drain { deliveryEnabled = false }
        generation &+= 1
        queue.async { [weak self] in
            guard let self else { return }
            if drain { self.flushConverter() }
            self.stopLocked()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
        admission.unlock()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        admission.lock(); defer { admission.unlock() }
        return generation == token
    }

    private func convert(_ input: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { report(AudioStreamError.conversionFailed); return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { report(error ?? AudioStreamError.conversionFailed as NSError); return }
        emit(output)
    }

    private func flushConverter() {
        guard let converter, let targetFormat else { return }
        // Bound a broken converter; normal 48→16 kHz conversion drains in one call.
        for _ in 0..<32 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { report(AudioStreamError.conversionFailed); return }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else { report(error ?? AudioStreamError.conversionFailed as NSError); return }
            emit(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
        report(AudioStreamError.conversionFailed)
    }

    private func emit(_ output: AVAudioPCMBuffer) {
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        var squareSum = 0.0
        for index in 0..<count {
            let normalized = Double(samples[index]) / Double(Int16.max)
            squareSum += normalized * normalized
        }
        admission.lock()
        defer { admission.unlock() }
        guard deliveryEnabled else { return }
        onLevel?(min(1, sqrt(squareSum / Double(count)) * 5))
        onPCM?(Data(bytes: samples, count: count * MemoryLayout<Int16>.size))
    }

    private func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(source, destination) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { return nil }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
        }
        return copy
    }

    private func reportInterruption() {
        admission.lock()
        let wasActive = accepting
        accepting = false
        admission.unlock()
        if wasActive { report(AudioStreamError.interrupted) }
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    private func stopLocked() {
        admission.lock()
        deliveryEnabled = false
        admission.unlock()
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        converter = nil
        targetFormat = nil
        // Deactivation is cleanup; it cannot invalidate a completed dictation.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum AudioStreamError: LocalizedError {
    case permissionDenied, unsupportedFormat, conversionFailed, cancelled, interrupted
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Autorisation microphone refusée."
        case .unsupportedFormat: return "Le microphone ne peut pas être converti en PCM mono 16 kHz."
        case .conversionFailed: return "La conversion audio a échoué. Reconnectez le serveur avant de réessayer."
        case .cancelled: return "Démarrage du microphone annulé."
        case .interrupted: return "Microphone interrompu ou débranché. La dictée a été interrompue ; reconnectez le serveur."
        }
    }
}
