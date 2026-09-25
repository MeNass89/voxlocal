# Mac runtime quality record

This note records the Mac-source audit for the September 2026 VoxLocal productization pass. The reviewed implementation is the Swift package in `mac/VoxLocal`; this is source traceability, not a claim that a new DMG was generated.

## Changes shipped in source

- `Sources/VoxLocal/PlatformServices.swift`, `AppState.swift`, and `CloudGPU.swift`: cloud API tokens now use the macOS Keychain (`com.voxlocal.cloud-api-token`) and, after a successful Keychain write, are removed from `settings.json`. Existing installations migrate a legacy JSON token once at startup; a failed Keychain write keeps the legacy value instead of silently losing it. Cloud requests still read the token at request time, so the UI does not need to keep it in the Codable settings model.
- `Sources/VoxLocal/Engines.swift`: native process stdout and stderr are written to temporary files while the child runs. The previous “read stdout to EOF, then read stderr” order could block a verbose Whisper or llama process when stderr filled its pipe. Temporary files are removed on exit and displayed stderr is capped to 4,000 characters.
- `Sources/VoxLocal/RemoteScribeIntegration.swift`: a missing local Whisper model now returns an explicit error while retaining the WAV in history. The prior fallback returned a successful placeholder string (`MockTranscriptionEngine`), which could be mistaken for a real hospital dictation. Remote Scribe also now follows `autopasteEnabled` and `keepClipboardText`, matching the main pipeline.
- `Sources/VoxLocal/CloudGPU.swift`: cloud requests send `Cache-Control: no-store` and `X-Remote-Scribe-ZDR: required`, cap response bodies at 4 MiB and expose only the HTTP status on provider errors, never an arbitrary provider error body.

## Evidence

`swift build` from `mac/VoxLocal` passes on the current machine. The package has no test target (`swift test` reports “no tests found”), so validation here is compile-level and code-path review. No secrets or token values were printed.

## Remaining risks

- `CloudGPUEngine.perform` uses a semaphore around `URLSession`; it has bounded request/resource timeouts but does not retry transient 5xx/network failures. A future change should add one bounded retry with jitter and preserve the current user-facing error.
- Audio and transcripts remain intentionally in the local history directory for recovery. Product packaging should document retention/deletion controls and ensure support bundles exclude this directory by default.

HTTP cloud endpoints are now rejected unless they resolve to localhost/loopback, and LLM requests send `store: false`. The asynchronous microphone start is guarded against duplicate hotkeys and shutdown races. A failed reprocess restores the previous transcript while retaining the new error, so a temporary model or network failure cannot erase the last usable result.
