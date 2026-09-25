# Astra review 1 — fix plan

Raw: `docs/superpowers/notes/2026-09-25-astra-review-1-raw.md` (final message at the end; 14 findings on `d789759`). Each item below records my own verification and decision. "Preserved decisions" from the CodeRabbit plan still apply.

## Accepted (fix)

### A1 · iOS, QR link may overwrite a different pin through the case-insensitive Bonjour match
`ios/RemoteScribePortable/PortableClientModel.swift` `connectPendingLinkServerIfFound()`. Before copying the pin under `server.name`, load the existing pin for `server.name`; if it exists and differs from the link's fingerprint, do NOT copy, clear `pendingLinkServerName`, set `errorText` to the same "Ce poste a déjà une empreinte différente…" message with the discovered name, and return without connecting. Add a `pinConflict` check there. XCTest: extend `PairingLinkTests` with a pure-function test if the logic is factored (`static func resolvePinForDiscoveredName(existing: Data?, linked: Data) -> Data?` returning nil on conflict).

### A2 · Mac, CloudGPU follows redirects
`mac/VoxLocal/Sources/VoxLocal/CloudGPU.swift` `perform`: give the `URLSession` a delegate object that implements `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` and calls `completionHandler(nil)`; treat a 3xx as failure "GPU cloud : redirection refusée (HTTP \(code))". Keep the ephemeral configuration.

### A3 · Mac, llama-cli fallback keeps banner when the prompt echo is truncated (> 500 bytes)
`mac/VoxLocal/Sources/VoxLocal/Engines.swift` `answer(fromCLIOutput:user:)`: match the echo on `"> " + prefix` where `prefix` is the first 500 bytes of the prompt (UTF-8 safe boundary) followed by either `"\n"` or `" ... (truncated)\n"`; if no echo marker is found at all, return "" so the caller raises the empty-answer error instead of pasting a banner. Unit test in a new `mac/VoxLocal/Tests/`? The package has no test target; add `Tests/VoxLocalTests/CLIOutputTests.swift` with a `testTarget` in `Package.swift` covering: short prompt, prompt > 500 bytes, no echo. Verify `swift test` in `mac/VoxLocal` passes (the executable target must stay buildable; if `@testable import` of an executable target fails under SwiftPM 5.9, move `answer(fromCLIOutput:)` into a tiny library target `VoxLocalCore` that the executable depends on).

### A4 · Mac, LLMServer port reuse after verification (Astra: PLAUSIBLE; I accept because the fix is cheap)
`LLMServer.swift`: store the verified `processIdentifier` with the endpoint; in the accessor used by `LLMEngine.complete` (`currentEndpoint()` or equivalent), re-check `process?.isRunning == true && process?.processIdentifier == verifiedPID` before returning it; otherwise return nil so the caller falls back to `llama-cli`.

### A5 · Cloud, signed model URLs in argv
`cloud/runpod/deploy.sh` and `entrypoint.sh`: pass `WHISPER_MODEL_URL`/`LLM_MODEL_URL` through environment only (`runpodctl … --env` receives the variable NAME with value from a file or secret, never inline; if `runpodctl` only supports inline `KEY=VALUE`, document that the URL must be unsigned/public and refuse URLs containing `?` or `token` with a clear error). In `entrypoint.sh`, call `curl --config <(printf 'url = "%s"\n' "$url")` so the URL is not in argv.

### A6 · Swift server stop() may never run
`RemoteScribe/Core/Sources/RemoteServer.swift` `stop()`: capture `self` strongly inside the block (`queue.async { [self] in … }`) or make `stop()` synchronous with `queue.sync`. Add a Swift Testing test: start on port 0, stop, assert a new listener can bind the same port immediately (or assert `listener == nil` after `stop()` returns when using sync).

### A7 · Cloud, present models skip the SHA-256 check
`entrypoint.sh`: verify SHA-256 of an existing model file when `*_SHA256` is set; on mismatch, rename to `.corrupt-<ts>` and re-download.

### A10 · Cloud, SAN IP substring match
`entrypoint.sh` and `deploy.sh`: match `IP Address:$ip` followed by end-of-string, `,` or whitespace (use a regex `(^|, )IP Address:${ip}(,|$)` on the SAN line).

### A11 · Pairing code typed with the dash is refused
iOS `normalizedPairingCode`: strip `-` and whitespace, uppercase. Mac side unchanged (stores dashless). Also accept the dashed form in the Python host? No: the Python host uses free-form codes; leave it. Update `docs/faq-hospital-it.md` if it mentions typing the code.

### A12 · Windows, `.pth` written as ASCII breaks accented install paths
`windows/install-runtime.ps1`: write `voxlocal.pth` as UTF-8 without BOM (`[IO.File]::WriteAllText($path, $src, (New-Object Text.UTF8Encoding($false)))`). CPython reads `.pth` as UTF-8.

### A13 · Swift server does not enforce "PAIR first, once, with the zero UUID"
`SessionHandler.swift`: add `private var pairedOnce = false`; in `handle`, if `frame.kind != .pair && pairedDeviceName == nil` → throw `notPaired`; in `pair`, if `pairedOnce` → throw `protocolViolation("PAIR déjà reçu")`; if `frame.sessionID != RemoteFrame.noSession` → `protocolViolation("PAIR sans session")`. Swift Testing tests for the three cases. Keep `tests/test_real_host_interop.py` green.

### A14 · Mac, GPU token optional
`CloudGPU.swift` `authorizedRequest`: throw `VoxError.message("Configurez le jeton du GPU cloud dans l’écran Calcul.")` when the token is empty (the loopback-HTTP test path may keep an exception: allow empty token only when the URL host is loopback).

## Documentation-only

### D8 · Whitepaper overstates the 4 MiB cap
`docs/security-whitepaper.md` "Fournisseur GPU": say the response is rejected above 4 MiB after reception (not streamed), so it bounds what is parsed, not memory.

### D9 · PowerShell 5.1 argument quoting (Astra: PLAUSIBLE)
Not changed: CI parses under 5.1 and executes under pwsh 7; scheduled tasks call `powershell.exe -File`, which uses file-mode parsing, not argument passing. Record in `docs/windows-deployment.md`: "les lanceurs sont testés sous PowerShell 7 ; sous Windows PowerShell 5.1, ils sont analysés mais pas exécutés en CI".

## Verification
Same block as the CodeRabbit plan, plus `(cd mac/VoxLocal && swift test)` if a test target is added, plus `python3 -m unittest tests.test_runpod_runtime -v`. One commit: `fix: address Astra review 1 (12 accepted, 2 doc-only)`.
