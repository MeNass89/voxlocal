# VoxLocal product wave 2 — from working prototype to a product you can show and sell

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax. Every task ends with the listed verification commands **and a rendered screenshot or artefact saved under `docs/superpowers/evidence/`** (PNG for UI, JSON for benchmarks, the built file for packages). Reading code is not verification. One commit per task on the current branch. Never push.

**Goal:** After wave 1 (`2026-09-25-voxlocal-productization.md`: protocol alignment, TLS identity, pinning, CI), make each surface feel finished: the Mac app is fast and self-explanatory, the iPhone app guides a nurse through first use in under a minute, the cloud runtime deploys from one command and proves its numbers, the website and docs tell the product story to a hospital buyer and to a YC partner.

**Architecture (unchanged):** iPhone → Remote Scribe v1 over TLS 1.3 → VoxLocal.app (macOS) or Python host (Windows) → whisper.cpp + llama.cpp locally, or private GPU (OpenAI-compatible HTTPS) on RunPod. Loopback agent API for local AI harnesses.

**Baseline evidence (2026-09-25, before this wave):** `docs/superpowers/evidence/2026-09-25-mac-main-before.png`, `…-ios-home-before.png`, `…-web-hero-before.png`.

**Prerequisite:** wave 1 merged on `feat/productization`. Tasks W2-1, W2-2, W2-3, W2-5 are independent of each other; W2-4 (docs) and W2-6 (release) go last.

## Global constraints (in addition to wave 1's)

- Every UI change is judged on a rendered PNG. macOS: `VoxLocal --render-preview <dir>` (extend `PreviewRenderer` to render every screen you touch, with seeded demo data). iOS: build for `iphonesimulator`, `xcrun simctl install/launch booted`, `xcrun simctl io booted screenshot`. Website: `pnpm run build && pnpm run start`, then the Playwright headless shell at `~/Library/Caches/ms-playwright/chromium_headless_shell-1243/…/chrome-headless-shell --headless --screenshot=… --window-size=1440,900 --virtual-time-budget=6000 http://127.0.0.1:3000` (run it with a 60 s `timeout`; it hangs on exit).
- Design tokens are the existing ones (`DESIGN.md`, `RemoteScribePalette`, Mac `accent`). No new colour families. Dark by default on iOS, system on macOS.
- French copy, tutoiement never; "poste" for the host machine; "dictée" not "enregistrement" in user-facing text.
- Performance claims must come from a measurement written to `docs/superpowers/evidence/*.json` by a script in the repo.
- No demo data with real names. Synthetic French clinical sentences only (e.g. "Douleur thoracique apparue ce matin, sans irradiation.").
- Do not add dependencies: no SwiftPM packages, no npm packages beyond what `website/package.json` already has, no Python packages.

## Review focus

1. A nurse opens the iPhone app for the first time with no server on the network: they must understand what to do next without reading docs → W2-2 first-run screen + evidence PNG.
2. The Mac app on a machine with no models installed: the first dictation must explain where to get a model and not silently fail → W2-1 model onboarding.
3. Two dictations in a row on the Mac must not pay the model load twice → W2-1 warm LLM server, measured.
4. A hospital IT reader lands on the README: they must find the security posture, the deployment path, and what is not yet done within one screen → W2-4.
5. A YC partner watches the demo: the flow iPhone → Mac → pasted text must take under 60 s of screen time and every step must be visible → W2-4 demo script + W2-6 recorded evidence.

---

## Task W2-1: Mac app — warm inference, native arm64 runtimes, model onboarding, Remote Scribe screen

**Files:**
- Modify: `mac/VoxLocal/Sources/VoxLocal/Engines.swift`, `DictationPipeline.swift`, `RemoteScribeIntegration.swift`, `AppState.swift`, `EditorViews.swift` (ModelsView, SettingsView), `MainView.swift` (EmptyState, RemoteScribeView), `PreviewRenderer.swift`, `ModelCatalog.swift`, `mac/VoxLocal/build-runtimes.sh`, `mac/VoxLocal/build.sh`, `mac/VoxLocal/App/Info.plist` (2.3.0 build 5)
- Create: `mac/VoxLocal/Sources/VoxLocal/LLMServer.swift`, `scripts/bench-mac-inference.sh`, `docs/mac-performance.md`

**Steps:**

- [ ] **Step 1: Native runtimes.** `build-runtimes.sh` already builds with Metal. Add `-DGGML_NATIVE=ON`, build `llama-server` in addition to `llama-cli` (`--target llama-server`), copy both into `Vendor/bin`. `build.sh`: copy `llama-server` into `Resources/Runtimes/`. Run it on this Mac (needs `git submodule update --init`; cmake 4.4.3 is installed; ~10 min). Verify `lipo -archs Vendor/bin/whisper-cli` prints `arm64`.
- [ ] **Step 2: Warm LLM server.** `LLMServer.swift`: a `@MainActor final class LLMServerController` that starts `llama-server` once per selected model on `127.0.0.1:<random free port>` with `--host 127.0.0.1 --port N --model <gguf> -ngl 99 -fa on -c <context> --no-webui --log-disable`, waits for `GET /health` = 200 (poll 250 ms, 60 s max), restarts when the model or context changes, stops on app quit. `LLMEngine.complete(...)` uses `POST /v1/chat/completions` (`stream: false`, `temperature`, `max_tokens: 2048`) when the server is up, falls back to `llama-cli` if the server fails to start (log the reason in `record.error` as a warning, not a failure). Remove nothing from the CLI path.
- [ ] **Step 3: Whisper flags.** `WhisperEngine`: add `-fa`, `-t <ProcessInfo.processInfo.activeProcessorCount>`, `-bs <settings.beamSize>` (exists in `AppSettings`), keep `-np -oj`.
- [ ] **Step 4: Benchmark script.** `scripts/bench-mac-inference.sh`: takes a whisper model path, a gguf path, generates a 20 s synthetic WAV with `say -v Thomas -o /tmp/vox-bench.aiff "…phrase clinique synthétique…" && afconvert …` (16 kHz mono s16le), runs 3 iterations of cold `llama-cli` vs warm `llama-server` for the "Medical" mode prompt and 3 iterations of whisper, writes `docs/superpowers/evidence/<date>-mac-bench.json` with p50 seconds per stage. Run it if any model is present under `~/Library/Application Support/VoxLocal/models/`; otherwise run it with `ggml-tiny.bin` and the smallest GGUF you can download from Hugging Face over `curl` into `/tmp` (do not commit models) and say so in the JSON `note` field.
- [ ] **Step 5: Model onboarding.** `ModelsView`: when a category has no compatible model, show a card with the folder path, an "Ouvrir le dossier" button, and two recommended files with their sizes (Whisper: `ggml-large-v3-turbo-q5_0.bin` ≈ 574 MB; LLM: `Qwen2.5-3B-Instruct-Q4_K_M.gguf` ≈ 2.0 GB), plus a "Télécharger" button that runs `curl -L -o` into the models folder through `Process` with a progress bar (`AppState.downloads: [String: Double]`), sha256 shown after download. URLs: Hugging Face `ggerganov/whisper.cpp` and `Qwen/Qwen2.5-3B-Instruct-GGUF` official files; verify each URL returns 200 with `curl -I` before committing. The empty-history state on the Dictées screen says "Aucun modèle Whisper installé" with a button to that view when applicable, instead of "Cliquez sur le bouton flottant".
- [ ] **Step 6: Remote Scribe screen.** After wave 1 Task 3, `RemoteScribeView` shows code + fingerprint. Add: a QR code (CoreImage `CIQRCodeGenerator`) encoding `remotescribe://pair?name=<host>&code=<code>&fp=<base64>` for the iPhone (W2-2 reads it), a live list of connected devices (`RemoteScribeServer.onEvent` already emits; add `onPeersChanged: (([String]) -> Void)`), and the last 5 remote dictations with duration and status.
- [ ] **Step 7: PreviewRenderer.** Render `main-window`, `modes`, `settings-general`, `settings-iphone`, `settings-ai`, `remote-scribe`, `models-empty`, `history-detail` (seed 3 synthetic records into the preview data dir before rendering). Output PNGs to the given directory. Copy them to `docs/superpowers/evidence/<date>-mac-<screen>.png`.
- [ ] **Step 8: `docs/mac-performance.md`.** The measurement, the flags, the warm-server design, the fallback.
- [ ] **Step 9: Verify.**

```bash
(cd mac/VoxLocal && swift build -c release --product VoxLocal)
/tmp/…/release/VoxLocal --render-preview /tmp/vox-preview && ls /tmp/vox-preview/*.png   # 8 files
lipo -archs mac/VoxLocal/Vendor/bin/whisper-cli   # arm64
./scripts/build-macos.sh && codesign --verify --deep --strict /tmp/voxlocal-desktop-app/VoxLocal.app
cat docs/superpowers/evidence/*-mac-bench.json
```

- [ ] **Step 10: Commit** `feat(mac): warm llama-server, native arm64 runtimes, model onboarding, Remote Scribe pairing screen`.

---

## Task W2-2: iPhone app — first-run guidance, QR pairing, result flow, iPad layout

**Files:**
- Modify: `ios/RemoteScribePortable/ContentView.swift`, `PortableClientModel.swift`, `Info.plist` (1.3 build 4; add `NSCameraUsageDescription`), `ios/RemoteScribePortable.xcodeproj/project.pbxproj` (only if a new file is added)
- Create: `ios/RemoteScribePortable/OnboardingView.swift`, `ios/RemoteScribePortable/QRPairingView.swift`, `ios/RemoteScribePortable/PairingLink.swift`, `ios/RemoteScribePortableTests/PairingLinkTests.swift` (new XCTest target; add to the project with the same structure as the app target)
- Modify docs: `docs/ios-stability.md`

**Steps:**

- [ ] **Step 1: `PairingLink`.** `struct PairingLink: Equatable { let serverName: String; let code: String; let fingerprint: Data }` with `init?(url: URL)` parsing `remotescribe://pair?name=&code=&fp=` (percent-decoding, base64 validation, code 6–64 chars from the allowed alphabet). XCTest: valid, missing fp, bad base64, wrong scheme.
- [ ] **Step 2: QR scan.** `QRPairingView`: `AVCaptureSession` + `AVCaptureMetadataOutput` (`.qr`), on a valid `PairingLink` call `model.applyPairingLink(_:)`: stores the code in Keychain, stores the pin under key = serverName, selects the discovered server with that name if present, connects. Camera permission denied → explanatory text + "Ouvrir Réglages". Simulator has no camera: the view shows "Caméra indisponible dans le simulateur" and a "Coller un lien d'appairage" field that accepts the same URL (this is also what the evidence screenshot shows).
- [ ] **Step 3: First-run onboarding.** `OnboardingView`, shown when `UserDefaults` `portable.onboardingDone` is false: three pages (Liquid Glass page dots via native `TabView(.page)`): 1 "Votre iPhone devient le micro du poste" (illustration = SF Symbols composition, no assets), 2 "Sur le poste, ouvrez VoxLocal › Remote Scribe et scannez le code", 3 "Dictez, relisez, le texte est collé sur le poste". Last page: "Scanner le code" (opens QR) and "Plus tard". Respect Reduce Motion; VoiceOver labels; min 44 pt targets.
- [ ] **Step 4: Empty states.** When no server is found after 10 s: the connection card says "Aucun poste trouvé sur ce Wi-Fi" with two actions "Scanner le code du poste" and "Saisir l'adresse". When connected and no history: a one-line hint under the recorder "Maintenez l'iPhone à 20 cm, parlez normalement."
- [ ] **Step 5: Result flow.** After `completed`: haptic (`UINotificationFeedbackGenerator.success`), the newest `ResultCard` gets a 1.5 s highlight (respect Reduce Motion), and a "Copié sur le poste" badge when `status.message` contains "collée" (the Mac's message). Add "Copier" next to "Partager".
- [ ] **Step 6: iPad.** `NavigationSplitView` when `horizontalSizeClass == .regular`: sidebar = history, detail = recorder. Verify with `xcrun simctl` on an iPad simulator (`xcrun simctl list devices available | grep iPad`, boot one if none is booted).
- [ ] **Step 7: Evidence.** Screenshots: onboarding page 1, home with no server (after 10 s), QR view (simulator fallback), home connected with one result (drive the Python mock host `python3 server/voxlocal_server.py --mock --insecure-test-only --pairing-code test-only-123456 --host 127.0.0.1` and connect manually to `localhost` in the simulator; use `xcrun simctl` + `osascript`/`simctl ui` is not available for taps, so add a debug-only launch argument `-VoxLocalDemoState connected` that seeds one synthetic result and a connected server name for the screenshot; guard it with `#if DEBUG`). iPad split view. Save all to `docs/superpowers/evidence/<date>-ios-*.png`.
- [ ] **Step 8: Verify.**

```bash
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -scheme RemoteScribePortable -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/voxlocal-ios-sim CODE_SIGNING_ALLOWED=NO build test
xcodebuild -quiet -project ios/RemoteScribePortable.xcodeproj -target RemoteScribePortable -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
ls docs/superpowers/evidence/*-ios-*.png   # ≥ 5 files
```

- [ ] **Step 9: Commit** `feat(ios): onboarding, QR pairing, result feedback, iPad split view`.

---

## Task W2-3: Cloud — one-command RunPod runtime, real OpenAI-compatible servers, benchmark harness

**Files:**
- Create: `cloud/runpod/Dockerfile`, `cloud/runpod/entrypoint.sh`, `cloud/runpod/deploy.sh`, `cloud/runpod/bench-report.py`, `docs/cloud-deployment.md`
- Modify: `cloud/runpod/start-all.sh` (unchanged semantics; add `VOXLOCAL_TLS_CERT/KEY` passthrough), `cloud/runpod/benchmark.py` (add `--iterations`, p50/p95, tokens/s from `usage`), `cloud/runpod/README.md`, `docs/runpod-runtime.md`, `tests/test_runpod_runtime.py`

**Steps:**

- [ ] **Step 1: Image.** `Dockerfile` from `nvidia/cuda:12.4.1-runtime-ubuntu22.04`: installs `python3.11`, builds `whisper.cpp` (`whisper-server`, `-DGGML_CUDA=ON`) and `llama.cpp` (`llama-server`, `-DGGML_CUDA=ON`) at the same pinned commits as the submodules (`git clone --depth 1 … && git checkout <sha>`), copies `cloud/runpod/*.sh *.py` into `/workspace/voxlocal/`. Entry: `entrypoint.sh` generates `api-token` if absent (`openssl rand -hex 32`, mode 600), exports `VOXLOCAL_VOICE_CMD='whisper-server --host 127.0.0.1 --port 8001 -m /models/<WHISPER_MODEL> --request-path /v1/audio/transcriptions --inference-path ""'`, `VOXLOCAL_LLM_CMD='llama-server --host 127.0.0.1 --port 8003 -m /models/<LLM_MODEL> -ngl 99 -fa on --api-key-file /workspace/voxlocal/api-token'`, starts `caddy` (apt) as the only exposed listener on `:8443` with TLS from `VOXLOCAL_TLS_CERT/KEY` (self-signed generated at first boot if absent; fingerprint printed once to the log), reverse-proxying `/voice/*`, `/llm/*` to loopback with `Authorization` required (Caddy `basicauth` is wrong; use a `@auth header Authorization "Bearer {env.VOXLOCAL_API_TOKEN}"` matcher and `respond 401` otherwise), then `exec bash start-all.sh`. Models are pulled at boot from `WHISPER_MODEL_URL`/`LLM_MODEL_URL` into `/models` (RunPod network volume) if absent.
- [ ] **Step 2: `deploy.sh`.** Uses `runpodctl` (documented, not vendored): builds and pushes the image to a registry given by `VOXLOCAL_IMAGE`, creates a Pod template with the volume, GPU type from `VOXLOCAL_GPU` (default `NVIDIA RTX 4090`), exposes 8443, and prints the fingerprint from the Pod log. Every step is guarded: missing `runpodctl` or `RUNPOD_API_KEY` → exit 2 with the exact install line from `docs/runpod-guide-audit.md`. The script never prints the token.
- [ ] **Step 3: Benchmark upgrade.** `benchmark.py --iterations N`: p50/p95 per capability, `tokens_per_second` from `usage.completion_tokens / latency` for LLM, WAV of 10 s (deterministic tone, not silence, so Whisper does real work) in addition to the 250 ms one; JSON schema documented in the docstring. `bench-report.py`: renders the JSON to a Markdown table for the docs.
- [ ] **Step 4: Tests.** `tests/test_runpod_runtime.py`: Dockerfile pins the same commits as `.gitmodules` (parse both), `entrypoint.sh` passes `bash -n`, Caddyfile template contains the auth matcher and no plaintext listener, `benchmark.py` iterations/p95 math on a stubbed server.
- [ ] **Step 5: Local proof.** Without a GPU you cannot run the image, but you can run the two servers locally: build `whisper-server` and `llama-server` from the submodules on this Mac (Metal), start them with the tiny models from W2-1 Step 4, run `benchmark.py --iterations 3` against them over `http://127.0.0.1`, save `docs/superpowers/evidence/<date>-cloud-bench-local.json`. That proves the harness; the GPU numbers come when Nassim has a RunPod account (external gate).
- [ ] **Step 6: `docs/cloud-deployment.md`.** Prereqs, one-command deploy, what is exposed, how the Mac/Windows host is configured (`VOXLOCAL_GPU_URL=https://<pod>:8443/voice`, `VOXLOCAL_LLM_URL=…/llm`, token via Keychain/env), the ZDR/DPA checklist copied from `release-readiness.md` (still external), cost sheet template (GPU $/h × expected hours).
- [ ] **Step 7: Verify.** `python3 -m unittest tests.test_runpod_runtime -v`; `docker build -f cloud/runpod/Dockerfile .` if Docker is available on this Mac (`docker version`), else `hadolint`-style manual review recorded in the report; `bash -n cloud/runpod/*.sh`.
- [ ] **Step 8: Commit** `feat(cloud): RunPod image, one-command deploy, TLS edge, benchmark harness`.

---

## Task W2-4: Product documentation — README as the front door, security whitepaper, pitch, demo script

**Files:**
- Modify: `README.md`, `docs/architecture.md`, `docs/demo-runbook.md`
- Create: `docs/security-whitepaper.md`, `docs/pitch.md`, `docs/faq-hospital-it.md`, `docs/roadmap.md`, `docs/screenshots/` (copies of the wave-2 evidence PNGs, referenced from the README)

**Steps:**

- [ ] **Step 1: README.** Top: one sentence, one hero image (Mac + iPhone side by side: compose from the evidence PNGs with `sips`/ImageMagick if present, else two images stacked), three bullets (local by default, iPhone as microphone, private GPU optional), "Essayer en 5 minutes" (Mac DMG from `scripts/build-macos.sh`, iPhone via Xcode, or the Python host), "Sécurité en une page" (link to the whitepaper), "Ce qui n'est pas encore fait" (the external gates, honest), layout table, verification commands.
- [ ] **Step 2: Security whitepaper** (French, 4–6 pages equivalent): threat model, data flows with the diagram from `architecture.md`, transport (TLS 1.3, pinning, pairing lockout), data at rest (no persistence on Python hosts; Mac history opt-in with retention setting from W2-1 if added, else document the folder), secrets handling, logging without PHI, GPU provider requirements (ZDR, region, DPA), what a DPO must still validate. Every claim links to the file that implements it.
- [ ] **Step 3: Pitch** (`docs/pitch.md`, English): problem (clinicians type; dictation SaaS ships PHI to US clouds), insight (Apple silicon + open models make on-prem dictation good enough), product (what exists today, with screenshots), why now, business model (per-seat licence to hospitals, on-prem; optional private GPU managed), traction/asks (honest: prototype, pilots to sign), team placeholder line for Nassim to fill. One page.
- [ ] **Step 4: FAQ for hospital IT** (`docs/faq-hospital-it.md`): 15 questions with short answers (ports, Bonjour, certificates, MDM, Windows service, updates, audit logs, offline, languages, model sizes, hardware requirements).
- [ ] **Step 5: Roadmap** (`docs/roadmap.md`): now / next / later, each item tied to a gate or a task.
- [ ] **Step 6: Demo script** (`docs/demo-runbook.md` rewrite): 90-second script with timestamps, what is on screen at each second, what to say, fallback if Wi-Fi fails (manual host entry), reset procedure between demos.
- [ ] **Step 7: Verify.** Every relative link resolves (`python3 - <<EOF` that walks `docs/*.md` and `README.md` and checks each `](path)` exists). Every command in the README runs from the repo root.
- [ ] **Step 8: Commit** `docs: product README, security whitepaper, pitch, hospital IT FAQ, demo script`.

---

## Task W2-5: Website — product page that matches the real product

**Files:**
- Modify: `website/app/page.tsx`, `website/app/globals.css`, `website/app/components/ImmersiveScene.tsx` (only if needed for the hero), `website/tests/rendered-html.test.mjs`, `website/README.md`
- Create: `website/public/screenshots/*.png` (from evidence), `website/app/components/{ProductShots,SecurityGrid,PricingCard}.tsx`

**Steps:**

- [ ] **Step 1: Content.** Replace the "8" prototype mark with the VoxLocal waveform glyph used in the Mac app (`assets/VoxLocal.icns` → export PNG with `sips -s format png`). Sections: hero (keep the type scale, the copy stays), "Le produit aujourd'hui" (three real screenshots: Mac, iPhone, Remote Scribe pairing), "Comment ça marche" (existing 4 steps), "Sécurité" (six cards: local, TLS 1.3 + pinning, no persistence, Keychain, no PHI in logs, private GPU optional; each links to the whitepaper section), "Déploiement" (Mac today, Windows host, private GPU), "Tarifs" (one card: "Pilote hospitalier — nous contacter"; no invented prices), contact. Remove "Superwhisper bridge" from public copy.
- [ ] **Step 2: Performance.** Lighthouse-style checks without Lighthouse: total transferred < 600 kB on the home page (`curl -s -o /dev/null -w '%{size_download}'` on each asset listed in the HTML), images as WebP ≤ 200 kB each (`sips`/`cwebp` if present, else PNG optimised with `sips -Z 1600`), `prefers-reduced-motion` respected by the canvas (already), no layout shift on load (reserve image dimensions).
- [ ] **Step 3: Test.** Extend the rendered-HTML test: asserts the new sections' headings, the absence of "Superwhisper", the presence of `<img` with `width`/`height` attributes.
- [ ] **Step 4: Evidence.** Screenshots at 1440×900 (hero) and 390×844 (mobile, use `--window-size=390,844`), plus a full-page 1440×4200. Save to `docs/superpowers/evidence/<date>-web-*.png`.
- [ ] **Step 5: Verify.** `cd website && pnpm test && pnpm run lint`.
- [ ] **Step 6: Commit** `feat(website): product page with real screenshots, security grid, pilot offer`.

---

## Task W2-6: Release — signed-ad-hoc DMG, iOS build, checksums, GitHub release draft, evidence index

**Files:**
- Modify: `scripts/build-macos.sh` (version from Info.plist in the DMG name), `docs/release-readiness.md`, `docs/process-log.md`, `MEMORY.md`
- Create: `scripts/release.sh`, `docs/superpowers/evidence/README.md`

**Steps:**

- [ ] **Step 1: `scripts/release.sh`.** Builds the DMG (W2-1 runtimes required), the unsigned iOS `.xcarchive` (for Nassim to sign in Xcode), the Windows runtime zip (same exclusions as before), the source zip; writes `RELEASE-CHECKSUMS-<version>.txt` next to them in `dist/` (git-ignored); prints a GitHub release body from `docs/release-readiness.md` "État vérifié" table. `gh release create --draft` only when `--publish-draft` is passed; the default is local only.
- [ ] **Step 2: Evidence index.** `docs/superpowers/evidence/README.md`: one table, every PNG/JSON with date, task, what it proves.
- [ ] **Step 3: Docs.** `release-readiness.md`: wave-2 rows (Mac perf numbers, iOS onboarding, cloud harness), gates still external. `process-log.md`: wave-2 entry. `MEMORY.md` Polaroid updated.
- [ ] **Step 4: Verify.** `./scripts/release.sh` completes; `ls dist/`; `shasum -c dist/RELEASE-CHECKSUMS-*.txt`.
- [ ] **Step 5: Commit** `chore(release): release script, evidence index, readiness after wave 2`.

---

## Self-review

- Coverage of the widened goal: Mac (W2-1), iPhone (W2-2), cloud (W2-3), documentation (W2-4), website (W2-5), release (W2-6). "Optimized, fast" → W2-1 measured warm server + native runtimes, W2-5 page weight. "Beautiful" → every UI task ends on a screenshot the controller judges. "Versatile" → iPad, QR or manual pairing, local or GPU.
- External gates stay external and are named in W2-4/W2-6: Apple signing, RunPod account, hospital CA/MDM, DPA/DPO.
- Known risk: W2-1 Step 1 native build time and W2-3 Docker availability. Both have a fallback written in the step.
