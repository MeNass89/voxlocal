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
- Verified: `windows/` 5 tests; `tests/` 24 (16 off macOS); `agent/` 9; `RemoteScribe` `swift test` 8; iOS XCTest 8 on the iPhone 18 Pro simulator; `swift build` of VoxLocal and unsigned `iphoneos` build pass. CI run 36127942402 on commit `ac5d15c`: four jobs green. Interop proven against the real `RemoteScribeHost`. Mac bench with tiny models only (Whisper 0.657 s for 19.8 s audio, warm LLM 1.203 s vs cold 2.048 s).
- Open external gates: Personal Team install on a physical iPhone; RunPod account + real GPU benchmark (no Pod provisioned); hospital CA/MDM enrolment (mTLS); DPA/ZDR/DPO; Mac history retention policy; clinical validation; Windows on a real hospital workstation and signed service; Apple notarisation and distribution signing.
- Next action: sign the iPhone app with the Personal Team and run a real dictation against VoxLocal.app 2.3.0.
