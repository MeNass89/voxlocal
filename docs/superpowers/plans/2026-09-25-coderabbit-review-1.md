# CodeRabbit review 1 — fix plan

Raw review: `docs/superpowers/notes/2026-09-25-coderabbit-review-1-raw.md` (20 findings: 8 Major, 12 Minor, 0 Critical). Reviewed commit `c85bfa2`. Each task below names the finding, the decision, and the exact change. Skipped findings are recorded with the reason so CodeRabbit's next pass can be answered.

## Preserved decisions (must not regress)
- Sequence contract: per-session audio numbering, `framesSent` in samples (Task 2 of wave 1).
- Pin = SHA-256 of the DER certificate; TOFU sheet on first connection; pin mismatch refuses before PAIR.
- Secrets never in argv. Pairing code in Keychain on macOS.
- Python stdlib only. No new SwiftPM/npm deps.
- Windows installer registers the venv with a `.pth`, never pip.

## Fixes (Major)

### F1 `docs/windows-deployment.md:57` — remove `-TlsClientCA` from the first-connection example
Move `-TlsClientCA` to a separate "mTLS (après enrôlement des iPhones, non livré)" paragraph. The iOS client presents no client identity today.

### F2 `ios/RemoteScribePortable/PortableClientModel.swift:283-309` — a pairing link must not silently replace a different existing pin
In `applyPairingLink`, before any mutation: load `previous` for `link.serverName`. If `previous != nil && previous != link.fingerprint`, return the French message `"Ce poste a déjà une empreinte différente. Oubliez d’abord « \(name) » dans les réglages de connexion, puis rescannez."` and change nothing. First-use stays automatic. Add an XCTest in `PairingLinkTests`? No: this is model logic; add a small unit test target-free check by making the guard a pure static function `PortableClientModel.pinConflict(previous: Data?, incoming: Data) -> Bool` and test it in `PairingLinkTests.swift`.

### F3 `mac/VoxLocal/Sources/VoxLocal/LLMServer.swift:125-160` — bind the health check to the launched process
After `isHealthy` returns true: (a) re-check `generation == current` and `child.isRunning`; (b) verify the listener on `port` belongs to `child.processIdentifier`. Implementation without private APIs: run `/usr/sbin/lsof -nP -a -p <pid> -iTCP:<port> -sTCP:LISTEN` through `Process` and require a non-empty stdout whose first column is `llama-ser`; on failure `terminate` the child and throw `VoxError.message("le port de llama-server a été pris par un autre processus")`. Only then set `endpoint`/`configuration`. Also stop passing the API key to a server we did not verify: move `endpoint = …` after the check (already the case once reordered).

### F4 `LLMServer.swift:156` — re-check generation after the async health probe
Covered by F3(a). Add a comment naming the race.

### F5 `RemoteScribe/Core/Sources/TLSIdentity.swift:118` — `kSecImportToMemoryOnly` requires macOS 15
Decision: raise the deployment floor. `mac/VoxLocal/Package.swift` `platforms: [.macOS(.v15)]`, `RemoteScribe/Package.swift` `.macOS(.v15)`, `mac/VoxLocal/App/Info.plist` `LSMinimumSystemVersion` 15.0, and in `TLSIdentity.swift` drop the `#available` guard and always pass `kSecImportToMemoryOnly`. Keep `.iOS(.v16)`. Document in `docs/mac-build.md` and `docs/release-readiness.md`: "macOS 15 ou plus récent".

### F6 `scripts/build-ios.sh:23` — commit a shared scheme
Create `ios/RemoteScribePortable.xcodeproj/xcshareddata/xcschemes/RemoteScribePortable.xcscheme` (Xcode-generated XML: build action for the app target, test action for `RemoteScribePortableTests`, launch action). Generate it with `xcodebuild -project … -list` to confirm the scheme name, and write the XML by hand in Xcode's standard format (copy the structure of any Xcode 16+ generated scheme). Then `xcodebuild -scheme RemoteScribePortable -showBuildSettings` must succeed on a clean clone (`git clone --depth 1 file://$PWD /tmp/clonecheck`).

### F7 `windows/install-runtime.ps1:36` and the two launchers — `py.exe -3.11` fails when only 3.12+ is installed
In all three `Resolve-Python311`: probe `py.exe` with `-3` (not `-3.11`); the `>= 3.11` check already follows.

### F8 `windows/new-tls-identity.ps1:100` — check the private-key ACL before reusing an identity
In the "existing identity kept" branch: run `icacls <key>` and parse; if any ACE grants an account other than `$account` (and not `NT AUTHORITY\SYSTEM` / `BUILTIN\Administrators`) → re-apply `/inheritance:r /grant:r "$account:(R)"` and print a warning line "ACL de la clé privée resserrée". Keep the existing return.

## Fixes (Minor, accepted)
- M1 `PortableClientModel.swift:318` — when the case-insensitive fallback matches, copy the pin under the discovered exact name before `connect(to:)`.
- M2 `mac/VoxLocal/README.md:46` — make the `open` command relative to `mac/VoxLocal` after the `cd`.
- M3 `EditorViews.swift:240` — "Prêt à recevoir" label follows `remoteScribe.running`, not the toggle.
- M4 `PlatformServices.swift:54` — `remotePairingCode()` returns `Result`-like: distinguish `errSecItemNotFound` (nil) from other statuses (throw); caller shows the status message.
- M5 `RemoteScribeIntegration.swift:73` — non-verbatim mode without LLM → return the raw text with a warning message "Aucun LLM compatible : transcription brute" propagated to `RemoteBackendResult.message`.
- M6 `RemoteScribeIntegration.swift:222` — truncate `serviceName` to 63 UTF-8 bytes on a character boundary once in `init`; use it for listener, TLS identity and link.
- M7 `RemoteScribeIntegration.swift:279` — on Keychain write failure during regeneration, delete the stored item so the revoked code cannot come back; status message says the code is temporary until the Keychain works.
- M8 `RemoteScribe/MacServer/Sources/main.swift:46` — add `--pairing-code-file PATH` (0600 required) and `REMOTESCRIBE_PAIRING_CODE` env; keep `--pairing-code` only with `--insecure-plaintext`. Update `tests/test_real_host_interop.py` (already uses `--insecure-plaintext`, unchanged) and the usage text.
- M9 `windows/test_remotescribe_host.py:82` — `_run_bad_stop` must stop on EOF like the success test.
- M10 `docs/final-hard-review.md:41` — update the P0-1 evidence lines to the current code (pinning exists; `tls: false` only to loopback).

## Skipped (with reason, to answer CodeRabbit)
- S1 `windows/install-runtime.ps1:107` "keep TLS dir under InstallRoot": rejected. A hospital may deliberately keep the identity outside so a reinstall preserves the fingerprint every iPhone pinned. Documented in `docs/windows-deployment.md` (already there).
- S2 `RemoteScribe/Core/Sources/SessionHandler.swift:143` "delete the WAV on framesSent mismatch": rejected. Keeping the finalized WAV lets the operator retry the dictation from VoxLocal history, which is the product's stated behaviour ("conservation systématique du WAV si le traitement échoue"). Add one sentence to `docs/protocol-reconstruction.md` §Séquence saying the WAV is kept.

## Verification
```bash
(cd RemoteScribe && swift test)                       # 8 tests
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
python3 -m unittest discover -s tests -p 'test_*.py' -v   # 24
python3 -m unittest discover -s windows -p 'test_*.py' -v # 5
python3 -m unittest discover -s agent -p 'test_*.py' -v   # 9
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -scheme RemoteScribePortable -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/voxlocal-ios-cr1 CODE_SIGNING_ALLOWED=NO build test   # 8 XCTests after F2
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
rm -rf /tmp/clonecheck && git clone -q --depth 1 file://$PWD /tmp/clonecheck && (cd /tmp/clonecheck && xcodebuild -project ios/RemoteScribePortable.xcodeproj -scheme RemoteScribePortable -showBuildSettings >/dev/null && echo SCHEME_OK)
```
One commit: `fix: address CodeRabbit review 1 (8 major, 10 minor)`.
