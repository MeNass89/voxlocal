# VoxLocal productization memory

## Tatouages

- 2026-09-25 — User wants the whole project iterated toward a sellable hospital product and a YC-ready demonstration, across Mac, iPhone, Windows, local agent harnesses and RunPod. Keep claims evidence-based; do not call the prototype RGPD-compliant until hospital/DPO controls, provider DPA/ZDR, transport identity and deployment tests are complete.
- 2026-09-25 — Use Astra for hard architecture/security work and Luna for simple inventory/research. Keep a written process trail in `docs/process-log.md` and focused decision documents.
- 2026-09-24 — RunPod bootstrap used during tests was `bash /workspace/voxlocal/start-all.sh`; the token stays inside the Pod at `/workspace/voxlocal/api-token` and must never enter the repository, workstation, prompt or logs.

## Polaroid

- Project: VoxLocal / Remote Scribe hospital prototype.
- Status: active, productization in progress.
- Verified: agent API tests 8/8; root/server tests 12/12; Windows tests 5/5; focused Python/static checks and archive integrity pass; desktop Swift package build passes after Keychain, subprocess, cloud transport and reprocess hardening; RunPod supervisor/readiness files are local and synthetic only.
- Delivered: iOS Liquid Glass UI 1.1 (build 2) and unsigned Xcode build; Mac source hardening 2.1.0 (build 3); loopback agent API/CLI; provider-neutral RunPod runtime supervisor and synthetic 3-capability benchmark; regenerated DMG at `VoxLocal-Agent-2026-09-24.dmg`, SHA-256 `d9400e33b7fc6acccfced009f898f2b4e79700da2e15259d1c3ef90dedfcf2c4`; source export `VoxLocal-Product-Source-2026-09-25.zip`, SHA-256 `9b70a4a162dccd19bbac23b053a86ed8005be7e1a3b610e7add8b48f8c3c15af`; Windows runtime `VoxLocal-Windows-Runtime-2026-09-25.zip`, SHA-256 `22792f90624e04d0eca5b7ff38adbe236c167c19d4157a69016a455093dbb123`.
- Open: physical iPhone Personal Team signing; real RunPod account/endpoint and model benchmark; Windows execution/signing and service hardening on an actual hospital workstation; mTLS/pinning/enrollment; provider DPA/ZDR and DPO acceptance; clinical workflow validation.
- Next action: close the external release gates: Personal Team device install, approved RunPod endpoint/model benchmark, Windows execution/signing, mTLS/pinning/enrollment, DPA/ZDR/DPO review and clinical workflow validation.

- 2026-09-25 (reprise Fable, soir) — Vérifié live : windows 5/5, tests 13/13, agent 9/9, py_compile OK, swiftc -parse OK, Xcode 27.0 présent. DMG monté : 2.1.0 (3), arm64, codesign OK. **Dérives trouvées** : (a) SHA-256 réel du DMG = `4554af38ad0bdd36fc6da1ece7fb4eb170f93caef34a1febeaa8f42b5f51cd9b`, pas `d9400e33…` (DMG rebâti 00:43 après le fichier checksums 00:38) ; (b) l'export source zip (00:38) est antérieur aux derniers correctifs : 13 fichiers diffèrent (le refus TCP-sans-TLS pour Bonjour côté iOS, `agent/voxlocal_agent_api.py`, `check-services.py`, docs) et le zip n'embarque ni `tests/` ni `UI_AUDIT.md` ni la revue adversariale ; (c) le DMG n'embarque pas `agent/run-windows.ps1` ; (d) compte de tests dans les docs périmé (12→13, 8→9). Pas de dépôt git dans le dossier. Screenshot Xcode : signature via la Personal Team personnelle, build iOS réussi 08:05.
- Next action (proposée) : refaire zip + checksums depuis l'état disque, corriger les compteurs de tests, puis initialiser git avant tout nouveau travail.
