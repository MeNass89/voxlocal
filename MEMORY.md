# VoxLocal productization memory

## Tatouages

- 2026-09-25 — User wants the whole project iterated toward a sellable hospital product and a YC-ready demonstration, across Mac, iPhone, Windows, local agent harnesses and RunPod. Keep claims evidence-based; do not call the prototype RGPD-compliant until hospital/DPO controls, provider DPA/ZDR, transport identity and deployment tests are complete.
- 2026-09-25 — Use Astra for hard architecture/security work and Luna for simple inventory/research. Keep a written process trail in `docs/process-log.md` and focused decision documents.
- 2026-09-24 — RunPod bootstrap used during tests was `bash /workspace/voxlocal/start-all.sh`; the token stays inside the Pod at `/workspace/voxlocal/api-token` and must never enter the repository, workstation, prompt or logs.
- 2026-09-25 — Artefacts (DMG, zips, checksum files) are rebuilt from git and never quoted with a checksum in the docs. The security whitepaper H2 headings are a contract with the website anchors (`flux-de-données`, `transport`, `données-au-repos`, `secrets`, `journalisation`, `fournisseur-gpu`): do not rename them.

## Polaroid

- Project: VoxLocal / Remote Scribe hospital prototype, public repo `MeNass89/voxlocal`, branch `feat/productization`.
- Status (2026-09-25): wave 1 (protocol alignment, TLS identity, pinning, CI) and wave 2 W2-1…W2-5 plus CodeRabbit review 1 merged; product docs rewritten (README with hero image, security whitepaper, pitch, IT FAQ, roadmap, 90 s demo script).
- Versions: VoxLocal.app 2.3.0 (build 5), macOS 15+; Remote Scribe iOS 1.3 (build 4).
- Verified: `windows/` 5 tests; `tests/` 55 on macOS (1 skipped without caddy); `agent/` 15; `RemoteScribe` `swift test` 8; iOS XCTest 8 on the iPhone 18 Pro simulator; `swift build` of VoxLocal and unsigned `iphoneos` build pass. CI run 36130936691 on commit `766015b`: four jobs green (counts above re-run locally 2026-09-25). Interop proven against the real `RemoteScribeHost`. Mac bench with tiny models only (Whisper 0.657 s for 19.8 s audio, warm LLM 1.203 s vs cold 2.048 s).
- Open external gates: Personal Team install on a physical iPhone; RunPod account + real GPU benchmark (no Pod provisioned); hospital CA/MDM enrolment (mTLS); DPA/ZDR/DPO; Mac history retention policy; clinical validation; Windows on a real hospital workstation and signed service; Apple notarisation and distribution signing.
- Wave 3 (2026-09-25), clinical agent harness under `harness/`: dsh 0.1.7-rc.2 profile « scribe », four plugins, portal bridge (approval owned by the bridge, two tokens) over a recorded mock, dictation feeder; H1–H4 merged, H6 adds `harness/run-web.ps1`, `harness/ingest/run-feeder.ps1` and a CI `harness` job (ubuntu + macos-26). Verified locally: `harness/tests/` 58 tests (~18 s, scripted model, real dsh + bridge); vitest 41 (portail-tools 13, scribe-approval 12, scribe-persona 7, voxlocal-tools 9); both `.ps1` parsed and run under pwsh 7.6.6 on macOS. The `harness` CI job has not run on GitHub yet. H5 (demo + evidence) in parallel.
- Harness gates: portal access (locked; real client never executed); Qwen3.8-27B never measured on the Pod (bench only against local Qwen2.5-0.5B); harness never executed on Windows; approver token still in the dsh process (move it out before any generic tool). Wave 4 = medical toolbox (protocols, INAMI, xCare), not started.
- Next action: sign the iPhone app with the Personal Team and run a real dictation against VoxLocal.app 2.3.0.
