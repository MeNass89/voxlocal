import Foundation

public struct RemoteBackendResult: Equatable {
    public var transcription: String?
    public var finalText: String?
    public var resultLocation: String?
    public var message: String?

    public init(transcription: String? = nil, finalText: String? = nil, resultLocation: String? = nil, message: String? = nil) {
        self.transcription = transcription
        self.finalText = finalText
        self.resultLocation = resultLocation
        self.message = message
    }
}

public protocol RemoteScribeBackend: AnyObject {
    var kind: RemoteBackendKind { get }
    func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void)
}

public struct TranscriptionResult: Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// Stable seam used by Remote Scribe. Local Whisper and OVH implementations can
/// replace one another without changing capture, framing, sessions or UI.
public protocol TranscriptionEngine: AnyObject {
    func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<TranscriptionResult, Error>) -> Void)
}

public protocol LLMProcessingEngine: AnyObject {
    func process(transcription: String, modeIdentifier: String?, completion: @escaping (Result<String, Error>) -> Void)
}

public final class MockTranscriptionEngine: TranscriptionEngine {
    public init() {}

    public func transcribe(audioURL: URL, language: String?, completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        completion(.success(TranscriptionResult(text: "[Mock Remote Scribe] Audio reçu et pipeline déclenché (\(byteCount) octets).")))
    }
}

public final class PassthroughLLMEngine: LLMProcessingEngine {
    public init() {}
    public func process(transcription: String, modeIdentifier: String?, completion: @escaping (Result<String, Error>) -> Void) {
        completion(.success(transcription))
    }
}

public final class VoxLocalBackend: RemoteScribeBackend {
    public let kind: RemoteBackendKind = .voxLocal
    private let transcriptionEngine: TranscriptionEngine
    private let llmEngine: LLMProcessingEngine

    public init(transcriptionEngine: TranscriptionEngine = MockTranscriptionEngine(), llmEngine: LLMProcessingEngine = PassthroughLLMEngine()) {
        self.transcriptionEngine = transcriptionEngine
        self.llmEngine = llmEngine
    }

    public func process(session: RemoteScribeSession, completion: @escaping (Result<RemoteBackendResult, Error>) -> Void) {
        transcriptionEngine.transcribe(audioURL: session.audioURL, language: session.language) { [llmEngine] result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let transcription):
                llmEngine.process(transcription: transcription.text, modeIdentifier: session.modeIdentifier) { processed in
                    switch processed {
                    case .failure(let error): completion(.failure(error))
                    case .success(let finalText):
                        completion(.success(RemoteBackendResult(
                            transcription: transcription.text,
                            finalText: finalText,
                            resultLocation: session.audioURL.path,
                            message: "Pipeline VoxLocal terminé."
                        )))
                    }
                }
            }
        }
    }
}
