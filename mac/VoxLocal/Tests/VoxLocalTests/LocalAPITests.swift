import XCTest
@testable import VoxLocal

/// Drives the real `NWListener` on an ephemeral loopback port with synthetic history.
final class LocalAPITests: XCTestCase {
    private let token = "test-local-api-token-0123456789abcdef"
    private var directory: URL!
    private var history: HistoryRepository!
    private var server: LocalAPIServer!
    private var base: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxlocal-localapi-\(UUID().uuidString)", isDirectory: true)
        history = HistoryRepository(directory: directory)
        server = LocalAPIServer(history: history, token: token, port: 0)
        let port = try server.start()
        XCTAssertGreaterThan(port, 0)
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func addRecord(_ text: String, status: String = "completed", timestamp: String? = nil) throws -> DictationRecord {
        var record = try history.create(mode: Mode.defaults[2], stt: "ggml-test.bin", llm: nil, target: ActiveTarget())
        if let timestamp { record.timestamp = timestamp }
        record.rawTranscription = text.lowercased()
        record.finalTranscription = text
        record.processingStatus = status
        record.duration = 4.5
        try history.save(record)
        return record
    }

    private func call(_ path: String, method: String = "GET", body: Data? = nil, authorized: Bool = true, timeout: TimeInterval = 5) throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = expectation(description: path)
        var result: (Int, [String: Any])?
        var failure: Error?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error }
            else if let http = response as? HTTPURLResponse, let data {
                result = (http.statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: timeout + 2)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    private func dictations(_ envelope: [String: Any]) -> [[String: Any]] {
        ((envelope["data"] as? [String: Any])?["dictations"] as? [[String: Any]]) ?? []
    }

    func testEveryRouteRequiresTheBearerToken() throws {
        let record = try addRecord("Douleur thoracique.")
        for path in ["/v1/dictations", "/v1/dictations/\(record.id)", "/v1/patient-context"] {
            let (status, body) = try call(path, authorized: false)
            XCTAssertEqual(status, 401, path)
            XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "unauthorized")
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/dictations"))
        request.setValue("Bearer wrong-token-wrong-token-wrong-token-", forHTTPHeaderField: "Authorization")
        let (_, response) = try awaitData(request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    func testSinceReturnsOnlyNewerRecordsOldestFirst() throws {
        let first = try addRecord("Première.", timestamp: "2026-09-25T08:00:00Z")
        let second = try addRecord("Deuxième.", timestamp: "2026-09-25T08:05:00Z")
        let third = try addRecord("Troisième.", timestamp: "2026-09-25T08:10:00Z")
        var (status, body) = try call("/v1/dictations")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(dictations(body).compactMap { $0["id"] as? String }, [first.id, second.id, third.id])
        (status, body) = try call("/v1/dictations?since=\(first.id)")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(dictations(body).compactMap { $0["id"] as? String }, [second.id, third.id])
        (status, body) = try call("/v1/dictations?since=\(third.id)")
        XCTAssertEqual(dictations(body).count, 0)
        (status, body) = try call("/v1/dictations?since=unknown-id")
        XCTAssertEqual(status, 404)
        XCTAssertEqual((body["error"] as? [String: Any])?["code"] as? String, "since_not_found")
    }

    func testJSONShapeExcludesTheAudioPath() throws {
        let record = try addRecord("Tension 14/8.")
        let (status, body) = try call("/v1/dictations/\(record.id)")
        XCTAssertEqual(status, 200)
        let served = try XCTUnwrap(body["data"] as? [String: Any])
        XCTAssertEqual(Set(served.keys), ["id", "timestamp", "deviceName", "modeId", "rawTranscription", "finalTranscription", "processingStatus", "duration", "patientContext"])
        XCTAssertNil(served["audio"])
        XCTAssertEqual(served["finalTranscription"] as? String, "Tension 14/8.")
        XCTAssertEqual(served["deviceName"] as? String, LocalAPIDictation.localDeviceName)
        XCTAssertTrue(served["patientContext"] is NSNull)
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("audio.wav"))
        var exact = URLRequest(url: base.appendingPathComponent("v1/dictations/\(record.id)"))
        exact.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, _) = try awaitData(exact)
        let servedJSON = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(servedJSON.contains("audio"))
        print("LocalAPI served: \(servedJSON)")
        XCTAssertFalse(raw.contains(directory.path))
    }

    func testLongPollReturnsEarlyWhenARecordArrives() throws {
        let anchor = try addRecord("Ancre.", timestamp: "2026-09-25T08:00:00Z")
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [history, server] in
            var record = try! history!.create(mode: Mode.defaults[0], stt: nil, llm: nil, target: ActiveTarget())
            record.timestamp = "2026-09-25T09:00:00Z"; record.finalTranscription = "Nouvelle dictée."; record.processingStatus = "completed"
            try! history!.save(record)
            server!.notifyHistoryChanged()
        }
        let (status, body) = try call("/v1/dictations?since=\(anchor.id)&wait=20", timeout: 22)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(dictations(body).first?["finalTranscription"] as? String, "Nouvelle dictée.")
        XCTAssertLessThan(elapsed, 5, "the long-poll must return as soon as the history changes")
    }

    func testLongPollTimesOutEmpty() throws {
        let anchor = try addRecord("Ancre.")
        let started = Date()
        let (status, body) = try call("/v1/dictations?since=\(anchor.id)&wait=1")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(dictations(body).count, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
    }

    func testPatientContextIsStampedOnNewDictations() throws {
        let before = try addRecord("Avant.")
        var (status, body) = try call("/v1/patient-context", method: "POST", body: Data(#"{"patientContext":"Patient fictif, chambre 12"}"#.utf8))
        XCTAssertEqual(status, 200)
        XCTAssertEqual((body["data"] as? [String: Any])?["patientContext"] as? String, "Patient fictif, chambre 12")
        let after = try addRecord("Après.")
        (_, body) = try call("/v1/dictations/\(after.id)")
        XCTAssertEqual((body["data"] as? [String: Any])?["patientContext"] as? String, "Patient fictif, chambre 12")
        (_, body) = try call("/v1/dictations/\(before.id)")
        XCTAssertTrue((body["data"] as? [String: Any])?["patientContext"] is NSNull)
        (status, body) = try call("/v1/patient-context", method: "POST", body: Data(#"{"patientContext":null}"#.utf8))
        XCTAssertEqual(status, 200)
        XCTAssertNil(history.patientContext)
        (status, _) = try call("/v1/patient-context", method: "POST", body: Data(#"{"patientContext":42}"#.utf8))
        XCTAssertEqual(status, 400)
    }

    private func awaitData(_ request: URLRequest) throws -> (Data, URLResponse) {
        let done = expectation(description: "request")
        var output: (Data, URLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response { output = (data, response) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(output)
    }
}
