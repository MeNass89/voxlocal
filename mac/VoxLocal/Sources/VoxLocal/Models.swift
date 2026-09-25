import Foundation

enum PipelineStatus: String, Codable {
    case idle, recording, processing, done, error
}

struct Mode: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var prompt: String
    var enabled: Bool = true
    var createdAt: String = ISO8601DateFormatter().string(from: Date())
    var updatedAt: String = ISO8601DateFormatter().string(from: Date())
    var kind: String = "transform"
    var model: String?
    var language: String?
    var temperature: Double = 0.2
    var formatting: [String: String] = [:]

    static let defaults: [Mode] = [
        Mode(id: "default", name: "Default", prompt: "Réécris la transcription en un texte naturel et clair. Préserve exactement le sens, la langue, le vocabulaire et le ton. Supprime les hésitations et répétitions évidentes, puis corrige la ponctuation et la grammaire. Retourne uniquement le texte final."),
        Mode(id: "email", name: "Email", prompt: "Transforme la transcription en un email professionnel, cordial et concis. Préserve tous les faits et la langue du locuteur. Utilise des paragraphes courts et retourne uniquement le contenu de l’email."),
        Mode(id: "medical", name: "Medical", prompt: "Nettoie cette note clinique sans inventer aucun fait. Préserve exactement les termes médicaux, mesures, négations et incertitudes. Structure le texte en paragraphes lisibles et retourne uniquement la note corrigée.", temperature: 0),
        Mode(id: "notes", name: "Notes", prompt: "Transforme la transcription en notes compactes et bien organisées. Préserve chaque information utile. Utilise des puces uniquement lorsqu’elles améliorent la lisibilité. Retourne uniquement les notes."),
        Mode(id: "prompt-corrector", name: "Prompt Corrector", prompt: "Interprète la demande de correction et mets à jour le prompt du mode nommé, sans supprimer les consignes existantes utiles.", kind: "prompt_corrector", temperature: 0.1)
    ]
}

struct AppSettings: Codable, Equatable {
    var activeModeId = "default"
    var selectedSttModel: String?
    var selectedLlmModel: String?
    var floatingX: Double?
    var floatingY: Double?
    var hotkey = "⌘⇧Space"
    var audioDevice: String?
    var autopasteEnabled = true
    var launchAtStartup = false
    var language: String?
    var beamSize = 5
    var llmContextSize = 4096
    var keepClipboardText = true
    /// `nil` keeps existing installations local without requiring a migration.
    var computeLocation: String?
    var cloudBaseUrl: String?
    var cloudWhisperModel: String?
    var cloudLlmModel: String?
    var cloudApiToken: String?
    /// Loopback API for the local agent harness; `nil` (older settings) means off.
    var localApiEnabled: Bool?

    var usesCloud: Bool { computeLocation == "cloud" }
}

struct Segment: Codable, Hashable, Identifiable {
    var id: String { "\(start)-\(end)-\(text)" }
    var start: Double
    var end: Double
    var text: String
}

struct DictationRecord: Codable, Identifiable, Hashable {
    var id: String
    var timestamp: String
    var modeId: String
    var modeName: String
    var audio: String
    var rawTranscription = ""
    var finalTranscription = ""
    var processingStatus = "recording"
    var duration = 0.0
    var selectedSttModel: String?
    var selectedLlm: String?
    var segments: [Segment] = []
    var error: String?
    var targetApplication: String?
    var targetIdentifier: String?
    /// Patient the clinician declared before dictating (loopback API), stamped at creation.
    var patientContext: String?
    var updatedAt: String = ISO8601DateFormatter().string(from: Date())
}

struct ModelInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var url: URL
    var engine: String
    var compatible: Bool
    var detail: String
}

struct AudioDeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
}

struct ActiveTarget: Equatable {
    var name: String?
    var identifier: String?
    var processIdentifier: pid_t?
}

enum VoxError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
