import Foundation
import Network

// Executed by test_swift_core.py against a socket fixture, and by
// test_real_host_interop.py against the compiled RemoteScribeHost; no iOS SDK
// needed. Modes: "plain", "reconnect" (fixture), "realhost", and the TLS
// fixture modes "tls-nopin" and "tls-pin:<base64 SHA-256 of the leaf DER>".
// TLS trust refusals exit 3 (untrustedServer) or 4 (pinMismatch) after
// printing "<code> <observed fingerprint base64>" on stdout.
let client = RemoteScribeClient()
let port = UInt16(CommandLine.arguments[1])!
let mode = CommandLine.arguments[2]
let reconnect = mode == "reconnect"
let realHost = mode == "realhost"
let tls = mode.hasPrefix("tls-")
let pin: Data? = mode.hasPrefix("tls-pin:") ? Data(base64Encoded: String(mode.dropFirst("tls-pin:".count))) : nil
if mode.hasPrefix("tls-pin:") && pin == nil { fputs("invalid pin\n", stderr); exit(1) }
var reconnectDone = false
var completed = 0
var session: UUID?
var observedIdentity: Data?
var paired = false

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
func connect() {
    do { try client.connect(host: "127.0.0.1", port: port, deviceID: "test", deviceName: "Swift regression", pairingCode: "test-code", tls: tls, pinnedFingerprint: pin) }
    catch { fail("connect: \(error)") }
}
client.onServerIdentity = { fingerprint in
    // Delivered once per TLS connection, before any PAIR response.
    guard tls, observedIdentity == nil, !paired else { fail("unexpected identity callback") }
    observedIdentity = fingerprint
}
func start() {
    do { session = try client.startSession(language: "fr", backend: .voxLocal) }
    catch { fail("start: \(error)") }
}
client.onPairResponse = { response in
    guard response.accepted else { fail("pair rejected") }
    guard !tls || observedIdentity == pin else { fail("pair before a pinned identity") }
    paired = true
    start()
}
client.onSessionStatus = { id, status in
    if id == RemoteFrame.noSession { return }
    guard id == session else { fail("stale session callback") }
    switch status.state {
    case .recording:
        // Several producers must preserve a contiguous per-session audio
        // sequence 0..19. After these 20 chunks of 4 bytes, STOP must carry
        // framesSent == 40 (PCM samples); the fixture and the real host check it.
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
        else if realHost && completed == 2 {
            // The real host keeps the connection open; end the test here.
            client.disconnect()
            print("real host: two sessions completed on one connection")
            exit(0)
        }
    default:
        break
    }
}
client.onError = { error in
    if error.code == "untrustedServer" || error.code == "pinMismatch" {
        guard tls, !paired, completed == 0 else { fail("trust error after pairing: \(error)") }
        guard observedIdentity?.base64EncodedString() == error.message else { fail("identity callback does not match error: \(error)") }
        guard (error.code == "untrustedServer") == (pin == nil) else { fail("wrong trust error: \(error)") }
        print("\(error.code) \(error.message)")
        exit(error.code == "untrustedServer" ? 3 : 4)
    }
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
