import Foundation
import Network

// Executed by test_swift_core.py against a socket fixture; no iOS SDK needed.
let client = RemoteScribeClient()
let port = UInt16(CommandLine.arguments[1])!
let reconnect = CommandLine.arguments[2] == "reconnect"
var reconnectDone = false
var completed = 0
var session: UUID?

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
func connect() {
    do { try client.connect(host: "127.0.0.1", port: port, deviceID: "test", deviceName: "Swift regression", pairingCode: "test-code") }
    catch { fail("connect: \(error)") }
}
func start() {
    do { session = try client.startSession(language: "fr", backend: .voxLocal) }
    catch { fail("start: \(error)") }
}
client.onPairResponse = { response in
    guard response.accepted else { fail("pair rejected") }
    start()
}
client.onSessionStatus = { id, status in
    if id == RemoteFrame.noSession { return }
    guard id == session else { fail("stale session callback") }
    switch status.state {
    case .recording:
        // Several producers must preserve a single contiguous wire sequence.
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { try client.sendAudio(Data([0, 0, 1, 0])) }
            catch { fail("audio: \(error)") }
        }
        do { try client.stopSession() }
        catch { fail("stop: \(error)") }
        do { try client.sendAudio(Data([0, 0])); fail("audio accepted after STOP") }
        catch {}
        do { try client.stopSession(); fail("duplicate STOP accepted") }
        catch {}
    case .completed:
        completed += 1
        if completed == 1 { start() } // Requires terminal session release.
    default:
        break
    }
}
client.onError = { error in
    guard error.code == "transport" else { fail("unexpected error: \(error)") }
    if reconnect && !reconnectDone {
        reconnectDone = true
        connect() // First peer ended a partial frame; decoder must be reset.
        return
    }
    guard completed == 2 else { fail("EOF before two sessions: \(completed)") }
    do { _ = try client.startSession(language: "fr", backend: .voxLocal); fail("start accepted after EOF") }
    catch {}
    print("two sessions, ordered concurrent audio, STOP barrier, EOF/reconnect OK")
    exit(0)
}
connect()
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { fail("test timeout") }
dispatchMain()
