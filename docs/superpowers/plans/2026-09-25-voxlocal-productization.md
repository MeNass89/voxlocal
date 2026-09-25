# VoxLocal productization — close the code-closable release gates

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every task ends with the listed verification commands passing and one commit on the current branch. Never push. Never touch files outside the task's "Files" list unless a compile error forces it (then say so in your report).

**Goal:** Make the iPhone → Mac / Windows dictation path actually work end to end (wire contract aligned with the shipped product), close the transport-identity gate (TLS identity on hosts, certificate pinning on iOS), prove the Windows path in CI, and leave a public repository that CodeRabbit and a hospital security reviewer can read.

**Architecture:** One wire protocol (Remote Scribe v1, binary frames over TCP/TLS 1.3) shared by three hosts: the real Swift `RemoteScribeCore` (used by `VoxLocal.app` on macOS), the Python reference host (`server/voxlocal_server.py`, Windows/macOS), and a Python test-only compat host (`windows/remotescribe_host.py`). One client: the iOS app in `ios/`, built on a hardened copy of the Core client (`ios/Core/Sources`). The shipped Swift Core is the source of truth for the wire contract; the two Python hosts and the iOS client must match it byte for byte.

**Tech stack:** Swift 5.9 / SwiftPM / Network.framework / Security.framework (macOS 13+, iOS 16+, Xcode 26.6 on CI, Xcode 27.0 locally), Python 3.11+ stdlib only (no third-party runtime deps), PowerShell 5.1+/7, GitHub Actions (`ubuntu-latest`, `windows-latest`, `macos-26`).

**Spec:** this file plus `docs/final-hard-review.md` (P0/P1 findings), `docs/release-readiness.md` (gates), `docs/adversarial-product-review-2026-09-25.md`. The investigation that produced this plan is summarised in "Findings" below.

## Findings that drive this plan (verified 2026-09-25 on the MBA)

1. **Sequence-number contract mismatch (blocking).** The real `RemoteScribe/Core/Sources/RemoteClient.swift` resets `sequence = 0` in `startSession`, numbers only AUDIO_CHUNK frames (0,1,2… per session), sends PAIR/START/STOP with sequence 0, and counts `framesSent` in PCM sample frames (`bytes / 2`). The real server (`SessionHandler.swift` + `AudioReceiver.swift`) checks only audio-chunk contiguity per session and sends every frame with sequence 0. The reconstructed iOS client (`ios/Core/Sources/RemoteClient.swift`) uses one connection-wide counter for every frame, counts `framesSent` in chunks, and rejects server frames whose sequence is not contiguous. The Python reference host enforces connection-wide contiguity and chunk-count `framesSent`. Probe against the real `RemoteScribeHost` binary: connection-wide numbering → `RemoteScribeError` at the first audio chunk; per-session numbering → `completed`. **The iPhone app cannot dictate to VoxLocal.app today.**
2. **VoxLocal.app listens in plaintext with no pairing code.** `RemoteScribeServer.start` uses `NWParameters.tcp`; `VoxLocalRemoteServerController.start()` passes `pairingCode: nil`, so any device on the LAN pairs. The iOS client now refuses plaintext except to localhost. Demo path iPhone → Mac is therefore broken twice.
3. **Certificate pinning is feasible without an iOS SDK test.** On macOS, `SecPKCS12Import` with `kSecImportToMemoryOnly` loads an RSA-2048 identity exported with `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` (LibreSSL 3.3.6 in `/usr/bin/openssl`); `sec_identity_create` works; `sec_protocol_options_set_verify_block` is available; SHA-256 of the DER certificate computed in Swift equals `openssl x509 -outform der | sha256`. EC keys fail the memory-only import on this macOS; use RSA 2048.
4. Python server TLS 1.3 context works with the stdlib; the repo has no third-party Python dependency and must stay that way.
5. Test counts in docs are stale (server suite is 13, agent suite is 9). Release checksums and the source zip are stale; they are not part of the repo (artefacts live outside git).
6. The repo layout was rebuilt from the iCloud folder: `ios/` (canonical iOS project + hardened Core copy at `ios/Core`), `RemoteScribe/` (real Core package: server, backends, CLI host, menu-bar app, web client), `mac/VoxLocal/` (macOS app; `Vendor/src/*` are git submodules pinned to the exact vendored snapshots: whisper.cpp `v1.9.3`, llama.cpp `a298422d`), `server/`, `agent/`, `windows/`, `cloud/runpod/`, `tests/`, `scripts/`, `docs/`, `website/`. `mac/VoxLocal/Vendor/bin/*` (prebuilt x86_64 runtimes) is git-ignored.

## Global constraints

- Wire contract source of truth: `RemoteScribe/Core/Sources/{RemoteProtocol,FrameCodec,RemoteClient,SessionHandler,AudioReceiver}.swift`. Do not change frame layout (UInt32 BE length, UInt8 kind, 36-byte UUID, UInt64 BE sequence, payload; body 45..1_048_576 bytes), message kinds 1..7, port `47365`, Bonjour type `_remotescribe._tcp`, PCM s16le mono 16 kHz.
- Python: stdlib only, `requires-python >= 3.11`, `python3 -m unittest` runners, no `pytest` dependency, no `cryptography` import.
- Swift: keep `swift-tools-version: 5.9`, macOS 13 / iOS 16 deployment targets, `#available` guards for newer APIs.
- Secrets never enter argv, logs, git, or error messages. Tokens/pairing codes: Keychain on Apple platforms, process environment elsewhere.
- No clinical data anywhere in tests: synthetic PCM only (zeros or a deterministic tone).
- French UI copy in the apps, French user-facing docs; code comments and this plan in English.
- Zero persistence by default on the Python hosts (unchanged). The Mac app keeps its local history feature (by design; unchanged).
- Nothing in this plan requires an Apple developer account, a RunPod account, a hospital CA, or a physical device. Those gates stay external and are listed in `docs/release-readiness.md`.
- Commits: one per task, conventional prefix (`fix:`, `feat:`, `ci:`, `docs:`, `chore:`), message body explains the why. Do not push.

## Review focus (inputs the spec implies but no existing test exercised)

1. iPhone connects to the real Mac app and completes two consecutive dictations on one connection → Task 2 adds `tests/test_real_host_interop.py` against the compiled `RemoteScribeHost`.
2. A STOP whose `framesSent` disagrees with the received sample count is rejected by every host, including the real Swift Core → Task 2 tests in Swift Testing and Python.
3. A server whose certificate changed after the phone pinned it is refused with an explicit French message and no audio is sent → Task 4 TLS fixture test "wrong pin".
4. Five wrong pairing codes from one peer lock that peer for 60 s while other peers still pair → Task 3 `RemotePairingGate` tests.
5. The Windows installer really runs on Windows (creates a venv, imports the agent, writes a manifest) and the uninstaller removes exactly that directory → Task 6 job on `windows-latest`.

---

## Task 1: Repository hygiene, licence, CodeRabbit configuration, README for the new layout

**Files:**
- Create: `LICENSE`, `.coderabbit.yaml`, `CONTRIBUTING.md`
- Modify: `README.md`, `mac/VoxLocal/README.md`, `RemoteScribe/README.md`, `RemoteScribe/WebClient/README.md`, `RemoteScribe/CAHIER_DES_CHARGES.txt`, `docs/install-and-test.md`, `docs/desktop-source-integration.md`, `docs/architecture.md`, `mac/LISEZ-MOI-OUVRIR-DANS-XCODE.md`, `windows/remotescribe_host.py` (docstring only)
- Delete: `docs/docs-audit.md` (describes a layout that no longer exists), `UI_AUDIT.md` at root only if identical to `ios/UI_AUDIT.md` (it is not present there; keep root copy and move it to `docs/ui-audit-ios.md`)

**Steps:**

- [ ] **Step 1: LICENSE.** Write a proprietary notice (the product is meant to be sold to hospitals; the source is public for review only):

```text
Copyright (c) 2026 VoxLocal contributors. All rights reserved.

This source code is published for review, security audit and evaluation.
No licence is granted to use, copy, modify, distribute or deploy it, in
whole or in part, for any purpose other than reading and reviewing it,
without prior written permission from the copyright holder.

Third-party components under mac/VoxLocal/Vendor/src keep their own
licences (whisper.cpp and llama.cpp: MIT, The ggml authors).
```

- [ ] **Step 2: `.coderabbit.yaml`.** Model it on the validated one in `~/Projects/stock-tracker/.coderabbit.yaml` (profile `assertive`, no poem, `auto_review.enabled: true`, `drafts: false`). Path filters: exclude `mac/VoxLocal/Vendor/**`, `website/**`, `docs/superpowers/**`, `**/*.lock`, `**/pnpm-lock.yaml`. Path instructions:
  - `RemoteScribe/Core/**`, `ios/Core/**`, `server/**`, `windows/**`: "This is the Remote Scribe v1 wire protocol. Flag any divergence between implementations (frame layout, sequence numbering, framesSent semantics, state machine), any path that could persist audio or text on the Python hosts, and any unbounded read or buffer."
  - `agent/**`, `cloud/**`: "Loopback agent API and GPU runtime. Flag any way a secret can reach argv, logs, error bodies, or a non-HTTPS remote; any missing timeout; any JSON parsing that accepts duplicates or non-finite numbers."
  - `ios/RemoteScribePortable/**`, `mac/VoxLocal/Sources/**`: "Hospital dictation UI. Flag state-machine races, stale-callback bugs, Keychain error handling that silently succeeds, and any state encoded by colour alone."
  - `windows/*.ps1`, `agent/*.ps1`, `server/*.ps1`: "PowerShell launchers/installers. Flag argument injection, secrets on the command line, and paths that could escape the install root."
  - `tone_instructions`: "Be direct. Flag real bugs, protocol divergences, security issues and races. Skip style nitpicks unless they affect correctness."

- [ ] **Step 3: `CONTRIBUTING.md`.** Short. Layout table (one line per top-level dir), the verification commands (below), the rule "the shipped Swift Core is the wire-contract source of truth", and "no third-party Python deps".

```bash
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 -m unittest discover -s agent -p 'test_*.py' -v
python3 -m py_compile server/voxlocal_server.py windows/*.py agent/*.py cloud/runpod/*.py
(cd RemoteScribe && swift test)
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 4: README.md rewrite.** Keep it French. Sections: what it is (3 lines), layout table, how to run the demo (Mac app from `mac/VoxLocal`, Python host, agent API mock, iOS via Xcode Personal Team), verification commands, security position (copy the existing "Position sécurité" paragraph, updated after Tasks 3–4 by Task 7). Remove every reference to `desktop-source/`, `source/`, `RemoteScribePortable/` mirror, the zips, the DMG and checksum files (artefacts are not in git). Link `docs/release-readiness.md`, `docs/protocol-reconstruction.md`, `docs/agent-api.md`, `docs/windows-deployment.md`, `docs/runpod-runtime.md`.

- [ ] **Step 5: Sanitize personal paths.** Replace every `/Users/nawfel/...` with a relative path or `~/Library/Application Support/...`. `grep -rn "/Users/nawfel" --include='*.md' --include='*.txt' --include='*.sh' --include='*.py' --include='*.swift' .` must return nothing outside `mac/VoxLocal/Vendor/`.

- [ ] **Step 6: Fix path references in docs** that still name the old tree: `docs/install-and-test.md` (iOS project is `ios/RemoteScribePortable.xcodeproj`; Core is `ios/Core`), `docs/desktop-source-integration.md` (rename to `docs/mac-build.md`, content: `mac/VoxLocal` + `RemoteScribe` side by side, submodules, `git submodule update --init`, `./build-runtimes.sh` to rebuild `Vendor/bin` natively, `scripts/build-macos.sh` env vars), `docs/architecture.md` (add `ios/` and `mac/` names), `mac/LISEZ-MOI-OUVRIR-DANS-XCODE.md` (paths). Also fix the `SyntaxWarning: "\w" is an invalid escape sequence` in `windows/remotescribe_host.py:12` by making that docstring a raw string.

- [ ] **Step 7: Verify.**

```bash
python3 -W error -m py_compile windows/remotescribe_host.py   # no warning
grep -rn "desktop-source\|source/PortableClient\|source/Core\|RemoteScribePortable/PortableClient" --include='*.md' --include='*.sh' --include='*.py' . | grep -v Vendor | grep -v docs/superpowers   # empty
grep -rln "/Users/nawfel" . | grep -v Vendor   # empty
```

- [ ] **Step 8: Commit** `chore: public-repo hygiene, licence, CodeRabbit config, README for new layout`.

---

## Task 2: Align the wire contract on the shipped Core (sequence numbers, framesSent) and prove interop against the real host

**Files:**
- Modify: `ios/Core/Sources/RemoteClient.swift`, `server/voxlocal_server.py`, `windows/remotescribe_host.py`, `windows/test_remotescribe_host.py`, `tests/test_server.py`, `tests/swift_core_regression.swift`, `tests/test_swift_core.py`, `RemoteScribe/Core/Sources/SessionHandler.swift`, `RemoteScribe/Core/Tests/RemoteScribeCoreTests.swift`, `docs/protocol-reconstruction.md`, `docs/decision-log.md`
- Create: `tests/test_real_host_interop.py`

**Interfaces (the canonical contract, write it verbatim into `docs/protocol-reconstruction.md` §"Séquence et états attendus"):**
- `sequence` is meaningful only on AUDIO_CHUNK frames: per session, first chunk 0, strictly contiguous. On every other frame (PAIR, START_SESSION, STOP_SESSION, PING, SESSION_STATUS, ERROR) the sender writes 0 and the receiver ignores the field.
- `StopSessionRequest.framesSent` = total PCM sample frames of the session = `bytesReceived / 2` (mono, 16-bit). Servers reject a STOP whose `framesSent` differs from `bytesReceived / 2` with `protocolViolation`.
- PAIR must be the first frame of a connection, with session UUID `00000000-0000-0000-0000-000000000000`; a second PAIR is a protocol violation. START_SESSION before PAIR is `notPaired`.

**Steps:**

- [ ] **Step 1: Real Core — validate framesSent.** In `RemoteScribe/Core/Sources/SessionHandler.swift` `stop(_:)`, replace `_ = try frame.decode(StopSessionRequest.self)` with:

```swift
let request = try frame.decode(StopSessionRequest.self)
```
and after `let session = try receiver.finish()` add:
```swift
let expectedFrames = session.bytesReceived / 2
guard request.framesSent == expectedFrames else {
    throw RemoteScribeError.protocolViolation("framesSent \(request.framesSent) ≠ échantillons reçus \(expectedFrames)")
}
```
Order matters: finish the receiver first so the WAV is closed even when STOP is rejected (the session is already cleared on the handler). Add a Swift Testing test `stopWithWrongFramesSentIsRejected` in `RemoteScribeCoreTests.swift`: pair, start, one 320-byte chunk, STOP with `framesSent: 999` → the replies contain an `.error` frame whose `RemoteErrorPayload.message` contains `framesSent`, and no `.completed` status.

- [ ] **Step 2: iOS hardened client.** In `ios/Core/Sources/RemoteClient.swift`:
  - Replace the single `sequence` counter with `audioSequence: UInt64` reset to 0 in `startSession` and in `resetSession()`.
  - `send(kind:sessionID:payload:)`: sequence written = `kind == .audioChunk ? audioSequence : 0`; increment `audioSequence` only for audio chunks.
  - `sendAudio`: `framesSent += UInt64(data.count / 2)` (samples), keep the even-length and empty checks.
  - Remove `expectedServerSequence` and the "Séquence serveur non contiguë ou rejouée" check entirely (the real server always sends 0). Keep the session-UUID checks.
  - Keep backpressure, generation guard, STOP ordering, EOF handling as they are.
- [ ] **Step 3: Python reference host.** In `server/voxlocal_server.py`:
  - `RemoteScribeConnection.run`: stop comparing every frame to `expected_client_sequence`. Replace with: PAIR must be the first frame (`self.paired is False` and no frame seen before; keep a `frames_seen` counter), and `handle_audio` checks `sequence == session.frames_received` (per-session contiguity) else `ProtocolError("protocolViolation", "Séquence audio non contiguë ou rejouée.")`. `handle()` signature gains the `sequence` argument.
  - `handle_stop`: `frames != session.bytes_received // 2` → protocolViolation "framesSent incohérent avec les échantillons reçus."
  - `send_json`: always write sequence 0; delete `self.sequence`.
  - Update `tests/test_server.py::_handshake_and_mock_session` to send PAIR seq 0, START seq 0, audio seq 0, STOP seq 0 with `framesSent: 100` (100 samples for 200 bytes), and add `test_stop_with_wrong_frames_sent_is_rejected` (expect an `error` frame, code `protocolViolation`) and `test_audio_sequence_must_be_contiguous` (send chunk seq 1 first → `error`).
- [ ] **Step 4: Windows compat host.** Same three rules in `windows/remotescribe_host.py` (it already checks per-session audio contiguity via `FrameDecoder`? verify; if it enforces connection-wide anything, remove). `test_stop_rejects_incorrect_chunk_count` becomes `test_stop_rejects_incorrect_frames_sent` using sample counts.
- [ ] **Step 5: Swift regression driver and fixture.** `tests/swift_core_regression.swift`: after the 20 concurrent 4-byte chunks, `framesSent` must be 40. `tests/test_swift_core.py` fixture: expect PAIR seq 0, START seq 0, audio seqs 0..19 (in order, any interleaving of producers still yields a contiguous set), STOP seq 0 with `framesSent == 40`; the fixture sends every frame with sequence 0. Keep the reconnect-after-truncated-frame case.
- [ ] **Step 6: Real-host interop test.** Create `tests/test_real_host_interop.py` (skip unless `sys.platform == "darwin"` and `shutil.which("swift")`):
  1. `swift build -c release --product RemoteScribeHost --scratch-path <ROOT>/.build/remotescribe-host` from `RemoteScribe/` (timeout 900 s; the scratch path is git-ignored by `.build/`).
  2. Pick a free port with `socket.bind(("127.0.0.1", 0))`, close it, launch `RemoteScribeHost --backend voxlocal --pairing-code test-code --port <P> --sessions <tmpdir>`; poll `socket.create_connection` up to 15 s.
  3. Compile the driver as `test_swift_core.py` does and run it with a third argument `realhost`; in the driver, mode `realhost` means: after `completed == 2`, call `client.disconnect()` and `exit(0)` instead of waiting for EOF.
  4. Assert exit code 0 and that `<tmpdir>` contains two `*/remote.wav` files of 44 + 80 bytes each (20 chunks × 4 bytes).
  5. Terminate the host in `finally`.
- [ ] **Step 7: Docs.** Rewrite the sequence paragraph in `docs/protocol-reconstruction.md` (the previous text claimed a global client sequence; state that the reconstruction was wrong and the shipped source proved it). Add a dated entry in `docs/decision-log.md`: "2026-09-25 — Contrat de séquence aligné sur le Core Swift livré" with the three rules and the probe result.
- [ ] **Step 8: Verify.**

```bash
(cd RemoteScribe && swift test)                                   # 5 tests pass
python3 -m unittest discover -s tests -p 'test_*.py' -v           # includes swift core + real host interop
python3 -m unittest discover -s windows -p 'test_*.py' -v
python3 -m unittest discover -s agent -p 'test_*.py' -v
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 9: Commit** `fix(protocol): align sequence numbering and framesSent on the shipped Core; add real-host interop test`.

---

## Task 3: TLS identity, mandatory pairing code and pairing lockout on the Swift server; surface them in VoxLocal.app

**Files:**
- Create: `RemoteScribe/Core/Sources/TLSIdentity.swift`, `RemoteScribe/Core/Sources/PairingGate.swift`
- Modify: `RemoteScribe/Core/Sources/RemoteServer.swift`, `RemoteScribe/Core/Sources/SessionHandler.swift`, `RemoteScribe/Core/Tests/RemoteScribeCoreTests.swift`, `RemoteScribe/MacServer/Sources/main.swift`, `mac/VoxLocal/Sources/VoxLocal/RemoteScribeIntegration.swift`, `mac/VoxLocal/Sources/VoxLocal/PlatformServices.swift`, `mac/VoxLocal/Sources/VoxLocal/AppState.swift`, `mac/VoxLocal/Sources/VoxLocal/MainView.swift`, `mac/VoxLocal/App/Info.plist` (bump to 2.2.0 build 4)

**Interfaces (produced, used by Tasks 4–5–7):**

```swift
public struct RemoteScribeTLSIdentity {
    public let identity: sec_identity_t
    public let certificateDER: Data
    public var fingerprintSHA256: Data            // SHA-256 of certificateDER
    public var fingerprintBase64: String          // canonical, published in Bonjour TXT "fp"
    public var fingerprintDisplay: String         // "AB12 CD34 …" uppercase hex, groups of 4, for humans
    /// Loads server.key.pem + server.cert.pem from `directory` (0700) or generates an RSA-2048
    /// self-signed certificate valid 3650 days with SAN DNS:<hostname>.local, DNS:localhost, IP:127.0.0.1.
    public static func loadOrCreate(in directory: URL, hostname: String) throws -> RemoteScribeTLSIdentity
}
public final class RemotePairingGate {
    public init(maxFailures: Int = 5, window: TimeInterval = 600, lockout: TimeInterval = 60, now: @escaping () -> Date = Date.init)
    public func isLocked(peer: String) -> Bool
    public func recordFailure(peer: String)
    public func recordSuccess(peer: String)
}
// RemoteScribeServer
public init(backends:defaultBackend:serviceName:sessionsDirectory:pairingCode:tlsIdentity: RemoteScribeTLSIdentity?)
```
Bonjour TXT record gains `tls` = `"1"` when an identity is set and `fp` = `fingerprintBase64`.

**Steps:**

- [ ] **Step 1: TLSIdentity.swift.** Generation uses `/usr/bin/openssl` through `Process` (fail with `RemoteScribeError.transport("openssl introuvable")` if missing):
  1. `openssl req -x509 -newkey rsa:2048 -nodes -keyout server.key.pem -out server.cert.pem -days 3650 -subj "/CN=<hostname>.local/O=VoxLocal" -addext "subjectAltName=DNS:<hostname>.local,DNS:localhost,IP:127.0.0.1"`; set POSIX permissions 0600 on the key, 0700 on the directory.
  2. Each load: export a transient PKCS#12 to a temporary file (0600) with `openssl pkcs12 -export -inkey server.key.pem -in server.cert.pem -out <tmp>.p12 -passout env:VOXLOCAL_P12_PASS -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`, passphrase = 32 random bytes base64 passed through the child environment (never argv); import with `SecPKCS12Import(data, [kSecImportExportPassphrase: pass, kSecImportToMemoryOnly: true])`; delete the temp file in `defer`. Take `kSecImportItemIdentity`, `SecIdentityCopyCertificate` → `SecCertificateCopyData` → `certificateDER`; `sec_identity_create(identity)`.
  3. `fingerprintSHA256 = SHA256(certificateDER)` (CryptoKit). `fingerprintDisplay`: hex uppercase in groups of 4 separated by spaces.
  Read `import Security`, `import CryptoKit`, `import Network`. Guard everything with `#if os(macOS)` (the file is compiled into a package that also targets iOS 16 for the Core library; iOS never generates identities).
- [ ] **Step 2: PairingGate.swift.** Sliding-window counter per peer string; `isLocked` true while `lockedUntil > now`. Tests: five failures lock, sixth attempt refused, `recordSuccess` clears, another peer unaffected, lock expires after `lockout` (inject `now`).
- [ ] **Step 3: SessionHandler.** Add `pairingGate: RemotePairingGate?` and `peer: String` init parameters (defaults `nil` / `""` so existing tests compile). In `pair(_:)`: if `pairingGate?.isLocked(peer:) == true` throw `RemoteScribeError.protocolViolation("trop de tentatives d’appairage, réessayez dans une minute")`; compare codes in constant time (`pairingCode.utf8` vs `request.pairingCode?.utf8` via a manual XOR loop over equal-length buffers; unequal length → false but still spend the loop); on failure `recordFailure`, on success `recordSuccess`.
- [ ] **Step 4: RemoteServer.** New initialiser parameter `tlsIdentity: RemoteScribeTLSIdentity? = nil`. In `start`: when set, build `NWProtocolTLS.Options()`, `sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity.identity)`, `sec_protocol_options_set_min_tls_protocol_version(…, .TLSv13)`, `NWParameters(tls: options, tcp: NWProtocolTCP.Options())`; else keep `.tcp`. Add `"tls"` and `"fp"` to the TXT record when set. Create one `RemotePairingGate` per server, pass it and `String(describing: connection.endpoint)` to each `Peer`/handler. Expose `public var fingerprintDisplay: String? { tlsIdentity?.fingerprintDisplay }`.
- [ ] **Step 5: Core tests.** Add: `tlsIdentityIsGeneratedAndStable` (skip if `/usr/bin/openssl` missing; generate into a temp dir, load twice, same fingerprint, key file mode 0600), `pairingGateLocksAfterFiveFailures`, and `pairLockedPeerIsRefused` (handler with a gate pre-locked for peer "x" → `.error` reply). Existing `sessionStateMachineTriggersBackend` must keep passing unchanged.
- [ ] **Step 6: CLI host.** `RemoteScribe/MacServer/Sources/main.swift`: add `--tls-dir DIR` (calls `loadOrCreate`, prints `Empreinte TLS: <display>`), and `--insecure-plaintext`. Without either flag, exit 2 with a usage message saying TLS is required. `--pairing-code` becomes mandatory unless `--insecure-plaintext`.
- [ ] **Step 7: VoxLocal.app.**
  - `PlatformServices`: add `remotePairingCode() -> String?` / `setRemotePairingCode(_:)` on Keychain service `com.voxlocal.remote-scribe`, account `pairing-code` (same pattern as `cloudAPIToken`). Add `static func generatePairingCode() -> String`: 8 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` using `SecRandomCopyBytes`, formatted `XXXX-XXXX` for display, stored without the dash. The wire value is the dashless string; the UI shows it with the dash and copies the dashless value.
  - `VoxLocalRemoteServerController.start()`: load or create the code (persist on first run), load or create the TLS identity in `paths.root.appendingPathComponent("remote-scribe/tls")` with `Host.current().localizedName`-derived hostname (fallback `"voxlocal"`), pass both to `RemoteScribeServer`. On identity failure: call `onStatus?("TLS indisponible : …")` and do **not** start a plaintext listener. Add `func regeneratePairingCode()` (new code, Keychain, restart server) and published-through-AppState `pairingCodeDisplay: String`, `tlsFingerprintDisplay: String?`.
  - `AppState`: `@Published var remotePairingCode = ""`, `@Published var remoteTLSFingerprint: String?`, wired from the controller.
  - `MainView.RemoteScribeView`: replace the "Réseau" section with: `LabeledContent("Port") { Text("47365") }`, `LabeledContent("Code d’appairage") { HStack { Text(code).font(.system(.body, design: .monospaced)); Button("Copier") {…}; Button("Régénérer") {…} } }`, `LabeledContent("Empreinte TLS (SHA-256)") { Text(fp).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }`, and one explanatory `Text`: "Sur l’iPhone, saisissez le code puis comparez l’empreinte affichée lors de la première connexion." Keep the existing Toggle, Picker, État rows.
  - `mac/VoxLocal/App/Info.plist`: `CFBundleShortVersionString` 2.2.0, `CFBundleVersion` 4.
- [ ] **Step 8: Verify.**

```bash
(cd RemoteScribe && swift test)                                                  # 8 tests
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
(cd RemoteScribe && swift build -c release --product RemoteScribeHost && .build/release/RemoteScribeHost --backend voxlocal --pairing-code test-code-1234 --tls-dir /tmp/vox-tls --port 47391 --sessions /tmp/vox-sess & sleep 3; openssl s_client -connect 127.0.0.1:47391 -tls1_3 </dev/null 2>&1 | grep -E "Protocol|subject=" ; kill %1)
python3 -m unittest discover -s tests -p 'test_*.py' -v                          # interop test still passes with --insecure-plaintext (update the test to pass that flag)
```

- [ ] **Step 9: Commit** `feat(mac): TLS 1.3 identity, mandatory pairing code with lockout, fingerprint shown in VoxLocal`.

---

## Task 4: iOS certificate pinning with trust-on-first-use confirmation

**Files:**
- Modify: `ios/Core/Sources/RemoteClient.swift`, `ios/Core/Sources/RemoteProtocol.swift` (error codes), `ios/RemoteScribePortable/PortableClientModel.swift`, `ios/RemoteScribePortable/ContentView.swift`, `ios/RemoteScribePortable/SecurePairingStore.swift` (no API change expected; reuse `saveData/loadData/deleteData`), `ios/RemoteScribePortable/Info.plist` (1.2, build 3), `tests/swift_core_regression.swift`, `tests/test_swift_core.py`, `docs/ios-stability.md`

**Interfaces:**

```swift
// RemoteScribeClient
var onServerIdentity: ((Data) -> Void)?        // SHA-256 of the leaf DER cert, delivered once per TLS connection, before PAIR
func connect(to endpoint: NWEndpoint, deviceID: String, deviceName: String, pairingCode: String?, tls: Bool = false, pinnedFingerprint: Data? = nil)
func connect(host: String, port: UInt16, …, tls: Bool = false, pinnedFingerprint: Data? = nil) throws
// error codes delivered via onError (RemoteErrorPayload.code):
//   "untrustedServer"  message = fingerprint base64  (no pin stored and system trust failed → TOFU needed)
//   "pinMismatch"      message = fingerprint base64  (stored pin differs)
```

**Trust decision inside `sec_protocol_options_set_verify_block` (runs on `queue`):**
1. `trust = sec_trust_copy_ref(trustRef).takeRetainedValue()`, `chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]`, leaf = `chain.first`; if absent → `complete(false)`.
2. `observed = SHA256(SecCertificateCopyData(leaf) as Data)`; deliver `onServerIdentity(observed)` once.
3. If `pinnedFingerprint != nil`: `complete(observed == pinnedFingerprint)`; on mismatch `failLocked(code: "pinMismatch", message: observed.base64EncodedString())`.
4. Else evaluate system trust (`SecTrustEvaluateWithError`); if it succeeds (MDM-provisioned CA) → `complete(true)`; else `complete(false)` and `failLocked(code: "untrustedServer", message: observed.base64EncodedString())`.
Requires `import CryptoKit` and `import Security` in `RemoteClient.swift`; the file must still compile with `swiftc` on macOS (the regression test compiles it) — both frameworks exist on macOS.

**Steps:**

- [ ] **Step 1: Client changes** as above. `failLocked` for `untrustedServer`/`pinMismatch` must cancel the connection before any PAIR is sent (the verify block runs before `.ready`, so PAIR is never sent; assert this in the test).
- [ ] **Step 2: Model.** Pins live in Keychain via `SecurePairingStore.saveData(fingerprint, account: "pin:" + key)` where `key` = the Bonjour service name for discovered servers, `host + ":" + port` for manual ones. New published state: `pendingTrust: PendingTrust?` with `struct PendingTrust { let key: String; let fingerprint: Data; var display: String { hex groups of 4 } ; let reconnect: () -> Void }`. On `onError` code `untrustedServer`: set `pendingTrust` (phase `.failed`, `connectionMessage` = "Identité du serveur à confirmer."). On `pinMismatch`: `fail("L’identité du serveur a changé. Vérifiez le poste avant de réessayer.", connectionLost: true)` and expose `func forgetServerIdentity(key:)`. `func trustPendingServer()` saves the pin then calls `reconnect()`. Pass `pinnedFingerprint` (loaded from Keychain for the key) into both `connect` calls.
- [ ] **Step 3: UI.** In `ContentView`, a `.sheet(item: $model.pendingTrust)` (make `PendingTrust: Identifiable` by `key`): title "Vérifier l’identité du serveur", body text: "Comparez cette empreinte avec celle affichée dans VoxLocal sur le poste. Ne validez pas si elles diffèrent.", the fingerprint in `.system(.title3, design: .monospaced)` selectable, buttons "Faire confiance et connecter" (`.borderedProminent`, min height 44) and "Annuler" (`.bordered`). Both `GlassEffectContainer`-wrapped under `#available(iOS 26.0, *)` per `docs/ios-liquid-glass.md`. In the connection sheet, when a pin exists for the current server, show a row "Identité épinglée · <first 4 groups>" with a destructive "Oublier ce serveur" button (confirmation dialog). VoiceOver labels on every new control.
- [ ] **Step 4: Regression fixture with TLS.** In `tests/test_swift_core.py` add a TLS fixture: generate a self-signed RSA cert with `openssl` into a temp dir (skip if missing), `ssl.SSLContext(PROTOCOL_TLS_SERVER)` min TLS 1.3, `wrap_socket` the accepted peer. Driver gains modes: `tls-nopin` → expect the driver to exit 3 after `onError` code `untrustedServer` with message == base64 of the cert's DER SHA-256 (the test computes it with `hashlib` on `ssl.PEM_cert_to_DER_cert`), and assert the fixture received **zero** bytes of application data; `tls-pin:<base64>` → full two-session run completes; `tls-pin:<wrong base64>` → exit 4 after `pinMismatch`. Three new test methods.
- [ ] **Step 5: Docs.** `docs/ios-stability.md`: add a "Confiance serveur" section (pin storage, TOFU flow, MDM CA path, forget). Bump `ios/RemoteScribePortable/Info.plist` to 1.2 (3).
- [ ] **Step 6: Verify.**

```bash
python3 -m unittest tests.test_swift_core -v          # 5 tests
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 7: Commit** `feat(ios): certificate pinning with trust-on-first-use confirmation`.

---

## Task 5: Python hosts publish their fingerprint; identity generation scripts for macOS/Linux and Windows

**Files:**
- Modify: `server/voxlocal_server.py`, `tests/test_server.py`, `server/README.md`, `docs/windows-deployment.md`, `docs/install-and-test.md`, `windows/install-runtime.ps1` (accept `-TlsDir` that runs the generator when `-TlsCert/-TlsKey` are absent)
- Create: `scripts/make-tls-identity.sh`, `windows/new-tls-identity.ps1`

**Steps:**

- [ ] **Step 1: Fingerprint in the Python server.** Add `def certificate_fingerprint(cert_path: Path) -> bytes` (read PEM, `ssl.PEM_cert_to_DER_cert`, `hashlib.sha256`). In `RemoteScribeServer.start`, when TLS is configured: log `server_ready … tls_fingerprint_sha256=<base64>` and add `tls=1`, `fp=<base64>` to the zeroconf TXT properties in `_publish_service`. Add `test_certificate_fingerprint_matches_openssl` (skip without openssl): generate a cert, compare with `openssl x509 -outform der | sha256`.
- [ ] **Step 2: `scripts/make-tls-identity.sh`.** `set -euo pipefail`; args: output dir, hostname (default `$(scutil --get LocalHostName 2>/dev/null || hostname -s)`); same openssl command as Task 3 step 1; `chmod 700 dir`, `600 key`; prints the base64 and grouped-hex fingerprints. Idempotent (refuses to overwrite unless `--force`).
- [ ] **Step 3: `windows/new-tls-identity.ps1`.** Locates `openssl.exe` (`Get-Command openssl`, then `C:\Program Files\Git\usr\bin\openssl.exe`, then `$env:OPENSSL_EXE`); same command; ACL: `icacls <key> /inheritance:r /grant:r "$env:USERNAME:(R)"`; prints fingerprints. `Set-StrictMode -Version Latest`.
- [ ] **Step 4: Installer.** `install-runtime.ps1`: new `[string]$TlsDir`; when `-ScheduledTask Server` and no `-TlsCert`, require `-TlsDir`, run `new-tls-identity.ps1` into it and use its outputs. Write the fingerprint into the manifest (`tlsFingerprintSha256`).
- [ ] **Step 5: Docs.** `docs/windows-deployment.md` and `server/README.md`: replace the "certificats gérés à fournir" prose with the concrete generation step and the fingerprint comparison on the iPhone. `docs/install-and-test.md`: update the "GPU loué"/Windows example to include `-TlsDir`.
- [ ] **Step 6: Verify.**

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash scripts/make-tls-identity.sh /tmp/vox-tls-test testhost && ls -l /tmp/vox-tls-test
python3 server/voxlocal_server.py --tls-cert /tmp/vox-tls-test/server.cert.pem --tls-key /tmp/vox-tls-test/server.key.pem --mock --pairing-code test-only-123456 --port 47392 & sleep 2; kill %1   # log line shows tls_fingerprint_sha256
```

- [ ] **Step 7: Commit** `feat(server): publish TLS fingerprint; identity generation scripts for macOS and Windows`.

---

## Task 6: Continuous integration on ubuntu, windows and macOS

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `scripts/build-ios.sh` (use `-target RemoteScribePortable -sdk iphoneos` instead of `-scheme`; keep `DESTINATION` only when `TEAM_ID` is set), `docs/install-and-test.md` (CI section)

**Steps:**

- [ ] **Step 1: Workflow.** Triggers: `push` to `main`, `pull_request`. Concurrency group per ref. Jobs:
  - `python-linux` (`ubuntu-latest`, `actions/setup-python@v5` 3.11 and 3.12 matrix): the three `unittest discover` commands and `py_compile`. `tests/test_swift_core.py` and `tests/test_real_host_interop.py` self-skip off macOS.
  - `python-windows` (`windows-latest`, Python 3.12): same unittest commands; then `pwsh -NoProfile -Command` that parses every `*.ps1` with `[System.Management.Automation.Language.Parser]::ParseFile` and fails on errors; then a real run: `pwsh -File windows/install-runtime.ps1 -InstallRoot "$env:RUNNER_TEMP\voxlocal" -MockTask` (no scheduled task registration), assert `windows-runtime.manifest.json` exists and `"$env:RUNNER_TEMP\voxlocal\.venv\Scripts\python.exe -c 'import agent.voxlocal_agent_api'"` succeeds; then `pwsh -File windows/uninstall-runtime.ps1 -InstallRoot "$env:RUNNER_TEMP\voxlocal" -Confirm:$false` and assert the directory is gone. Also run `windows/new-tls-identity.ps1` into `$env:RUNNER_TEMP\tls` (Git for Windows openssl is on the runner) and assert two files.
  - `macos` (`macos-26`, `actions/checkout@v4` with `submodules: false` — the Swift builds do not need the vendored C sources): `sudo xcode-select -s /Applications/Xcode_26.6.app`; `(cd RemoteScribe && swift test)`; `(cd mac/VoxLocal && swift build -c release --product VoxLocal)`; the three Python suites (this is where the Swift regression, TLS fixture and real-host interop actually run); `xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`. Cache `RemoteScribe/.build` and `mac/VoxLocal/.build` with `actions/cache@v4` keyed on `Package.swift` hashes.
  Set `timeout-minutes: 30` on macos, 15 on the others.
- [ ] **Step 2: Local dry run.** You cannot run Actions locally; instead run each macOS step here and each Python step here, and `pwsh` is not installed on this Mac, so validate the Windows job by reading it twice against the installer's parameter list (`[CmdletBinding()] param(...)` in `windows/install-runtime.ps1`). The first real run happens when the branch is pushed; Task 7's owner (the controller) fixes red jobs.
- [ ] **Step 3: Commit** `ci: test on ubuntu, windows and macOS; run the Windows installer for real`.

---

## Task 7: Documentation truth pass and release readiness

**Files:**
- Modify: `docs/release-readiness.md`, `docs/process-log.md`, `docs/final-hard-review.md` (status lines only), `docs/adversarial-product-review-2026-09-25.md` (append "Suivi"), `docs/demo-runbook.md`, `docs/agent-api.md` (test count), `README.md` (security paragraph), `MEMORY.md` (Polaroid)
- Delete: nothing

**Steps:**

- [ ] **Step 1: release-readiness.** Rewrite the table: test counts from the actual suites (run them and count), iPhone/Mac row now "TLS 1.3 + pinning TOFU, code d’appairage obligatoire, interop prouvée contre RemoteScribeHost", Windows row "installateur exécuté en CI sur windows-latest". Gates section: remove pinning and Windows execution; keep Personal Team device install (user action, 5 minutes in Xcode), RunPod account + benchmark, mTLS/enrolment via MDM, DPA/ZDR/DPO, clinical validation, notarisation/signing. Remove all mentions of the stale zip/DMG checksums (artefacts are built by `scripts/build-macos.sh` on demand and are not in git).
- [ ] **Step 2: process-log.** Append "25 septembre 2026 — dépôt public, contrat de séquence, TLS/pinning, CI": what was found (the two probes), what changed, what was verified, with the commands.
- [ ] **Step 3: final-hard-review.** Under P0-1 add "État 2026-09-25 : identité TLS serveur, pinning iOS TOFU et code d’appairage obligatoire livrés ; mTLS/enrôlement MDM restent une porte pilote." Under P0-3 add the lockout. Under "Vérifications exécutées" replace the block with the current commands and counts.
- [ ] **Step 4: demo-runbook.** Section 3 becomes the real flow: open VoxLocal.app → Remote Scribe screen shows code + fingerprint → iPhone: select server, enter code, confirm fingerprint once → dictate. Keep sections 1–2.
- [ ] **Step 5: MEMORY.md** Polaroid: status, what is verified (with counts), the remaining external gates, next action = "signer sur l’iPhone avec la Personal Team et faire une dictée réelle contre VoxLocal.app 2.2.0".
- [ ] **Step 6: Verify.** Every command quoted in the docs runs as written from the repo root. `grep -rn "12 tests\|8 tests\|d9400e33\|9b70a4a1\|22792f90" docs README.md` returns nothing.
- [ ] **Step 7: Commit** `docs: release readiness after protocol alignment, TLS identity and CI`.

---

## Self-review (done by the plan author)

- Spec coverage: finding 1 → Task 2; finding 2 → Tasks 3–4; finding 3–4 → Tasks 3–5 use only proven APIs; finding 5 → Task 7; finding 6 → Task 1. External gates deliberately out of scope and listed in Task 7.
- Type consistency: `RemoteScribeTLSIdentity.fingerprintBase64` (Task 3) is what the Python server also publishes as `fp` (Task 5) and what the iOS client compares after base64-decoding the stored pin (Task 4). All three hash the DER certificate, not the SPKI.
- Review focus 1–5 each map to a named test in Tasks 2, 3, 4, 6.
- Known follow-up not in this plan: unify `ios/Core` and `RemoteScribe/Core` into one SwiftPM target consumed by the Xcode project; rebuild `Vendor/bin` runtimes for arm64; website CI.
