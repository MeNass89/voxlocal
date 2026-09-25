import Darwin
import Foundation

/// Address and credential of a running `llama-server`.
struct LLMServerEndpoint: Equatable {
    var baseURL: URL
    var apiKey: String

    /// `POST /v1/chat/completions`, non-streaming. Blocking: call it off the main thread.
    func chat(system: String, user: String, temperature: Double, maxTokens: Int = 2048, timeout: TimeInterval = 300) throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
            "temperature": temperature,
            "max_tokens": maxTokens
        ] as [String: Any])
        let (data, status) = try Self.send(request)
        guard status == 200 else {
            let detail = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw VoxError.message("llama-server a répondu HTTP \(status)\(detail.isEmpty ? "" : " : \(detail)")")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw VoxError.message("llama-server a renvoyé une réponse illisible.")
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoxError.message("Le LLM local a retourné une réponse vide.") }
        return cleaned
    }

    static func send(_ request: URLRequest) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, Int), Error> = .failure(VoxError.message("Requête interrompue."))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { outcome = .failure(error) }
            else { outcome = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)) }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try outcome.get()
    }
}

/// Keeps one `llama-server` warm for the selected GGUF so consecutive dictations
/// do not reload the model. State lives on the main actor; callers on the
/// pipeline queues use `endpointBlocking`, which never blocks the main thread.
@MainActor
final class LLMServerController {
    private struct Configuration: Equatable { var model: URL; var context: Int }

    private let paths: AppPaths
    private var process: Process?
    private var configuration: Configuration?
    private var endpoint: LLMServerEndpoint?
    /// PID whose listener `listenerOwned` confirmed for `endpoint`. The endpoint (and
    /// its API key) is handed out only while that same process is still running:
    /// once it dies, its port is free for any local process to take.
    private var verifiedPID: pid_t?
    private var starting: (configuration: Configuration, task: Task<LLMServerEndpoint, Error>)?
    private var generation = 0
    private var pidFile: URL { paths.root.appendingPathComponent("run/llama-server.pid") }

    static let healthPollInterval: UInt64 = 250_000_000
    static let startupTimeout: TimeInterval = 60

    init(paths: AppPaths) {
        self.paths = paths
        killOrphan()
    }

    /// Blocking bridge for the pipeline queues. Returns a failure (never blocks)
    /// when called from the main thread, so the caller falls back to `llama-cli`.
    nonisolated func endpointBlocking(model: URL, context: Int) -> Result<LLMServerEndpoint, Error> {
        guard !Thread.isMainThread else { return .failure(VoxError.message("appel depuis le fil principal")) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<LLMServerEndpoint, Error> = .failure(VoxError.message("démarrage interrompu"))
        Task { @MainActor in
            do { outcome = .success(try await self.ensure(model: model, context: context)) }
            catch { outcome = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return outcome
    }

    /// Starts the server in the background so the first dictation finds it ready.
    func prewarm(model: URL, context: Int) {
        Task { @MainActor in _ = try? await self.ensure(model: model, context: context) }
    }

    /// Returns the running endpoint for this model and context, starting or
    /// restarting `llama-server` when the model or context changed.
    func ensure(model: URL, context: Int) async throws -> LLMServerEndpoint {
        let wanted = Configuration(model: model.standardizedFileURL, context: max(1024, context))
        if wanted == configuration, let endpoint, let process, process.isRunning,
           process.processIdentifier == verifiedPID { return endpoint }
        if let starting, starting.configuration == wanted { return try await starting.task.value }
        stop()
        generation += 1
        let current = generation
        let task = Task { @MainActor in try await self.launch(wanted, generation: current) }
        starting = (wanted, task)
        defer { if generation == current { starting = nil } }
        return try await task.value
    }

    func stop() {
        starting?.task.cancel(); starting = nil
        generation += 1
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil; endpoint = nil; configuration = nil; verifiedPID = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func launch(_ wanted: Configuration, generation current: Int) async throws -> LLMServerEndpoint {
        guard generation == current else { throw CancellationError() }
        let runtime = try RuntimeLocator.executable("llama-server")
        let port = try Self.freeLoopbackPort()
        let apiKey = UUID().uuidString + UUID().uuidString
        let child = Process()
        child.executableURL = runtime
        child.arguments = ["--host", "127.0.0.1", "--port", String(port), "--model", wanted.model.path,
                           "-ngl", "99", "-fa", "on", "-c", String(wanted.context), "--no-webui", "--log-disable"]
        // The key travels through the environment, not argv, so `ps` does not show it.
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "en_US.UTF-8", "LLAMA_API_KEY": apiKey]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw VoxError.message("lancement de llama-server impossible : \(error.localizedDescription)") }
        process = child
        try? FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(child.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            // Superseded by a newer model/context or by stop(): never leave this child behind.
            guard generation == current, !Task.isCancelled else {
                if child.isRunning { child.terminate() }
                if process === child { process = nil }
                throw CancellationError()
            }
            guard child.isRunning else {
                process = nil
                throw VoxError.message("llama-server s’est arrêté (code \(child.terminationStatus)) avant d’être prêt")
            }
            if await Self.isHealthy(base) {
                // Race: stop() or a newer ensure() may have run while the probe was in
                // flight; a stale launch must not publish its endpoint.
                try abandonIfSuperseded(child, generation: current)
                // freeLoopbackPort() releases the port before llama-server binds it, so
                // another local process could have answered /health. Only hand the
                // endpoint (and its API key) to a listener owned by our child.
                let pid = child.processIdentifier
                let owned = await Task.detached { Self.listenerOwned(by: pid, port: port) }.value
                try abandonIfSuperseded(child, generation: current)
                guard owned else {
                    child.terminate()
                    process = nil
                    throw VoxError.message("le port de llama-server a été pris par un autre processus")
                }
                let ready = LLMServerEndpoint(baseURL: base, apiKey: apiKey)
                endpoint = ready; configuration = wanted; verifiedPID = pid
                return ready
            }
            try await Task.sleep(nanoseconds: Self.healthPollInterval)
        }
        // Timed out, possibly after a newer launch took over during the last probe
        // or sleep: end only this child, and leave the newer server and its state alone.
        guard generation == current else {
            if child.isRunning { child.terminate() }
            if process === child { process = nil }
            throw CancellationError()
        }
        stop()
        throw VoxError.message("llama-server n’a pas répondu à /health en \(Int(Self.startupTimeout)) s")
    }

    /// Throws and cleans up this child when it is no longer the launch in charge.
    private func abandonIfSuperseded(_ child: Process, generation current: Int) throws {
        guard generation == current, !Task.isCancelled, process === child, child.isRunning else {
            if child.isRunning { child.terminate() }
            if process === child { process = nil }
            throw CancellationError()
        }
    }

    /// True when `lsof` shows a TCP listener on `port` held by `pid` and named
    /// `llama-server` (lsof truncates COMMAND to `llama-ser`). Blocking, bounded
    /// to 2 s; a timeout or any lsof failure counts as "not owned".
    nonisolated static func listenerOwned(by pid: pid_t, port: UInt16) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN"]
        let output = Pipe()
        lsof.standardOutput = output
        lsof.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        lsof.terminationHandler = { _ in finished.signal() }
        do { try lsof.run() } catch { return false }
        guard finished.wait(timeout: .now() + 2) == .success else {
            lsof.terminate()
            return false
        }
        guard lsof.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return false }
        return text.split(separator: "\n").dropFirst().contains { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            return columns.count > 1 && columns[0].hasPrefix("llama-ser") && columns[1] == Substring(String(pid))
        }
    }

    private static func isHealthy(_ base: URL) async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 1)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Asks the kernel for a free port on 127.0.0.1, then releases it for llama-server.
    static func freeLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VoxError.message("socket indisponible") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { throw VoxError.message("aucun port local libre") }
        return UInt16(bigEndian: address.sin_port)
    }

    /// A crash of VoxLocal leaves its llama-server running with a model in memory.
    /// Kill it on the next launch, but only if that PID is still a llama-server.
    private func killOrphan() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           URL(fileURLWithPath: String(cString: buffer)).lastPathComponent == "llama-server" {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }
}
