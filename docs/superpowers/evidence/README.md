# Evidence index

Every file here was produced by a command in the repository, not drawn by hand.
PNG = rendered UI (macOS: `VoxLocal --render-preview <dir>`; iOS: simulator
screenshot; web: Playwright headless shell against `pnpm run start`). JSON =
measurement written by a script. Demo data is synthetic (no real names, no
patient data). Dates in the macOS previews are rendered in French (`fr_FR`,
forced by `PreviewRenderer` for previews only).

| File | Date | Task | What it proves |
| --- | --- | --- | --- |
| `2026-09-25-mac-main-before.png` | 2026-09-25 | Baseline | Mac main window before wave 2 (reference for the redesign). |
| `2026-09-25-ios-home-before.png` | 2026-09-25 | Baseline | iPhone home before wave 2. |
| `2026-09-25-web-hero-before.png` | 2026-09-25 | Baseline | Website hero before wave 2. |
| `2026-09-25-mac-main-window.png` | 2026-09-25 | W2-1, W2-6 | Mac history with three synthetic dictations, active mode, "Importer un audio" and "Dicter depuis ce Mac"; dates in French. |
| `2026-09-25-mac-history-detail.png` | 2026-09-25 | W2-1, W2-6 | Detail of a clinical dictation: final text, raw transcript, timed segments, models used. |
| `2026-09-25-mac-history-empty.png` | 2026-09-25 | W2-1 | First launch, no dictation yet: the empty state explains what to do. |
| `2026-09-25-mac-models-empty.png` | 2026-09-25 | W2-1 | No model installed: the AI settings say where to get a model, so the first dictation does not fail silently (review focus 2). |
| `2026-09-25-mac-modes.png` | 2026-09-25 | W2-1 | Mode editor (Medical mode selected). |
| `2026-09-25-mac-settings-general.png` | 2026-09-25 | W2-1 | General settings page. |
| `2026-09-25-mac-settings-iphone.png` | 2026-09-25 | W2-1 | iPhone settings page (Remote Scribe server). |
| `2026-09-25-mac-settings-ai.png` | 2026-09-25 | W2-1 | AI settings with one Whisper and one LLM model installed. |
| `2026-09-25-mac-remote-scribe.png` | 2026-09-25 | W2-1, W2-6 | Pairing screen: QR code, pairing code, TLS fingerprint, connected device, last dictations received (French dates). |
| `2026-09-25-mac-remote-scribe-after-t3.png` | 2026-09-25 | Wave 1, task 3 | Remote Scribe settings after TLS identity (fingerprint shown beside the pairing code). |
| `2026-09-25-mac-bench.json` | 2026-09-25 | W2-1 | `scripts/bench-mac-inference.sh`, M2 16 GB, tiny models: Whisper p50 0.657 s for 19.8 s of audio (RTF 0.033); LLM cold `llama-cli` p50 2.048 s vs warm `llama-server` p50 1.203 s (×1.7); server start 0.547 s paid once (review focus 3). Production models not measured. |
| `2026-09-25-ios-onboarding.png` | 2026-09-25 | W2-2 | First-run screen: "Votre iPhone devient le micro du poste". |
| `2026-09-25-ios-home-no-server.png` | 2026-09-25 | W2-2 | No host on the Wi-Fi: the app says so and offers "Scanner le code du poste" or "Saisir l’adresse" (review focus 1). |
| `2026-09-25-ios-qr-pairing.png` | 2026-09-25 | W2-2 | QR pairing sheet, with the pairing-link fallback when the camera is unavailable. |
| `2026-09-25-ios-trust-sheet.png` | 2026-09-25 | Wave 1 | Trust-on-first-use sheet: compare the TLS fingerprint with the one shown on the host. |
| `2026-09-25-ios-home-connected.png` | 2026-09-25 | W2-2 | Connected to a host over TLS, "Prêt", "Démarrer la dictée". |
| `2026-09-25-ios-result.png` | 2026-09-25 | W2-2 | Result card after a dictation: text, raw transcript, Copier / Partager. |
| `2026-09-25-ios-ipad-split.png` | 2026-09-25 | W2-2 | iPad split view: history beside the dictation panel. |
| `2026-09-25-cloud-bench-local.json` | 2026-09-25 | W2-3 | `cloud/runpod/benchmark.py` through the Caddy edge (TLS 1.3, Bearer token) to `whisper-server` and `llama-server` started by `entrypoint.sh` + `start-all.sh`, Metal, tiny models. Proves the harness and the edge; not GPU numbers. |
| `2026-09-25-web-hero.png` | 2026-09-25 | W2-5, W2-6 | Website hero at 1440×900, reduced motion. |
| `2026-09-25-web-full.png` | 2026-09-25 | W2-5, W2-6 | Full page at a 1440×900 viewport: product shots (Mac history, iPhone connected, Mac pairing screen), how it works, security grid, deployment, pilot offer. Home page weight 573,315 bytes transferred (budget 600 kB). |
| `2026-09-25-web-mobile.png` | 2026-09-25 | W2-5 | Website at 390×844. |

## Release 2.3.0 (W2-6)

`./scripts/release.sh` builds into `dist/` (git-ignored) and prints the GitHub
release body (also written to `dist/RELEASE-NOTES-<version>.md`).
`--publish-draft` creates a GitHub draft; it is off by default and was not run.

Run of 2026-09-25 on the MacBook Air M2 (Apple M2, 16 GB, macOS 27.0, Xcode 27.0):

| Artefact | Checked |
| --- | --- |
| `VoxLocal-2.3.0.dmg` (18 MB) | app 2.3.0 (build 5), arm64, `codesign --verify --deep --strict` OK, `hdiutil verify` OK; mounted: `whisper-cli`, `llama-cli`, `llama-server` (llama.cpp `a298422`) present |
| `RemoteScribe-1.3-unsigned.xcarchive.zip` (1.8 MB) | Remote Scribe 1.3 (build 4), `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`, app "not signed at all"; to be signed in Xcode |
| `VoxLocal-Windows-Runtime-2.3.0.zip` (51 kB) | `agent/`, `server/`, `windows/`, `pyproject.toml`, `setup.py`: what `windows/install-runtime.ps1` copies; `unzip -t` OK |
| `VoxLocal-Source-2.3.0.zip` (6.7 MB) | `git archive HEAD`, tracked files only; `unzip -t` OK |
| `RELEASE-CHECKSUMS-2.3.0.txt` | SHA-256 of the four files; `shasum -a 256 -c` OK |

SHA-256 values live only in `dist/RELEASE-CHECKSUMS-<version>.txt` and in the
printed release body: the two zips are `git archive HEAD` and the DMG embeds a
fresh build, so every commit changes them and a hash written here would be stale.

Still external: Developer ID signing and notarisation of the DMG, Apple Team
signing of the iOS archive, a RunPod account for GPU numbers, hospital CA/MDM,
DPA/DPO and clinical validation.
