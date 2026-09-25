import Foundation

final class CloudGPUEngine {
    private let settings: AppSettings
    private let timeout: TimeInterval = 300
    private let maxResponseBytes = 4 * 1024 * 1024

    init(settings: AppSettings) { self.settings = settings }

    func transcribe(audio: URL, language: String?) throws -> STTResult {
        let endpoint = try url("v1/audio/transcriptions")
        let boundary = "VoxLocal-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", try required(settings.cloudWhisperModel, label: "modèle Whisper cloud"))
        if let language, !language.isEmpty, language != "auto" { field("language", language) }
        field("response_format", "json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: audio)); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = authorizedRequest(url: endpoint); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let data = try perform(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoxError.message("Le serveur Whisper cloud a renvoyé une réponse invalide.")
        }
        return STTResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: [])
    }

    func complete(system: String, user: String, temperature: Double) throws -> String {
        let payload: [String: Any] = ["model": try required(settings.cloudLlmModel, label: "modèle LLM cloud"), "temperature": temperature, "store": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        var request = authorizedRequest(url: try url("v1/chat/completions")); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try perform(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoxError.message("Le serveur LLM cloud a renvoyé une réponse invalide.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testConnection() throws -> [String] {
        var request = authorizedRequest(url: try url("v1/models")); request.httpMethod = "GET"; request.timeoutInterval = 15
        let data = try perform(request, timeout: 15)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    private func url(_ path: String) throws -> URL {
        let base = try required(settings.cloudBaseUrl, label: "adresse du GPU cloud").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let value = URL(string: "\(base)/\(path)"), let scheme = value.scheme?.lowercased(),
              ["http", "https"].contains(scheme), value.user == nil, value.password == nil,
              value.query == nil, value.fragment == nil else {
            throw VoxError.message("L’adresse du GPU cloud est invalide.")
        }
        if scheme == "http" {
            let host = value.host?.lowercased() ?? ""
            let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            guard loopback else {
                throw VoxError.message("Le GPU cloud doit utiliser HTTPS. HTTP est réservé à un test sur localhost.")
            }
        }
        return value
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        let token = (settings.cloudApiToken ?? PlatformServices.cloudAPIToken())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("required", forHTTPHeaderField: "X-Remote-Scribe-ZDR")
        return request
    }

    private func perform(_ request: URLRequest, timeout requestTimeout: TimeInterval? = nil) throws -> Data {
        let effectiveTimeout = requestTimeout ?? timeout
        let semaphore = DispatchSemaphore(value: 0); var result: Result<Data, Error>?
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = effectiveTimeout; configuration.timeoutIntervalForResource = effectiveTimeout
        URLSession(configuration: configuration).dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let http = response as? HTTPURLResponse, let data else { result = .failure(VoxError.message("Aucune réponse du GPU cloud.")); return }
            guard data.count <= self.maxResponseBytes else { result = .failure(VoxError.message("La réponse du GPU cloud est trop volumineuse.")); return }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(VoxError.message("GPU cloud : erreur HTTP \(http.statusCode).")); return
            }
            result = .success(data)
        }.resume()
        guard semaphore.wait(timeout: .now() + effectiveTimeout + 2) == .success, let result else { throw VoxError.message("Le GPU cloud n’a pas répondu dans le délai prévu.") }
        return try result.get()
    }

    private func required(_ value: String?, label: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoxError.message("Configurez le \(label) dans l’écran Calcul.")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
