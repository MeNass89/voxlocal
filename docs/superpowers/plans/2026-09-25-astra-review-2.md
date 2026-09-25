# Astra review 2 (harness) + CodeRabbit review 2 leftovers — fix plan

Source: `.superpowers/sdd/astra/harness-final/review.md` (11 findings, all CONFIRMED by Astra, all re-verified in code by Fable) and the 7 unresolved CodeRabbit threads on PR #1.
Rule: CodeRabbit is a filter, Fable judges. Every ruling below carries its reason.

## Part A — harness (Astra 1–11): ALL ACCEPTED

### A1 · P1 · Approval keyed by `callId` alone crosses sessions
`harness/plugins/scribe-approval/src/index.ts`. dsh `callId` is the model's tool-call id (`call_1`…), not unique across sessions; `ApprovalRequest` carries `agent.session.id`.
Fix: key `pending` and `grants` by `${sessionId}\u0000${callId}` where `sessionId = exec.agent?.session.id ?? 'no-session'`. In `approval/request`, look up with `req.agent.session.id` + `req.callId`; if the found pending's `sessionId` differs → `return next()` (do not relay). Guard and `tools/result` use the same composite key. Vitest: two fake sessions, same `callId`, approval on A must not grant B (guard refuses B).

### A2 · P1 · Real adapter: check and write are two reads
`RealPortal.apply` checks the digest on one read, `Record.append/replace` re-reads. Fix in two layers:
- `RealPortal.apply`: after the write, if `res.old_digest != base_digest` → restore `res.backup` via `Record.restore`, raise `DigestMismatch("la section a changé entre la vérification et l'écriture ; sauvegarde restaurée", expected=base_digest, live=res.old_digest, backup_id=res.backup.name)`.
- `Bridge._write` (backend-agnostic): after `write()`, if `result["readback_digest"] != rec["final_text_digest"]` → journal `failed` with `{"status": 409, "message": "relecture différente du texte approuvé"}`, call `self.backend.restore(result["backup_id"])` when a backup id is present (best effort, audited `restore-after-mismatch`), audit `error` reason `final-readback-mismatch`, raise `VerificationFailed`. Unit test with a fake backend whose `apply` returns a foreign `readback_digest`.

### A3 · P1 · Quotes and patient binding accepted unverified in permissive mode
`portail_bridge.py` `_check_quotes` + `build_bridge_from_env`; `index.ts` `approvalPrompt`.
Fix:
- Bridge: if `self.dictations is None` → `draft_create` raises `EditRefused("aucune source de dictées : citations invérifiables ; définir PORTAIL_DICTATION_DIR ou VOXLOCAL_API_URL")`. No permissive switch (fail closed).
- Bridge: a dictation whose `patient_id` or `encounter_id` is None → `Forbidden("la dictée citée ne déclare pas de patient/rencontre : brouillon refusé")`.
- Prompt: the line "patient de la dictée = patient du brouillon, vérifié par le pont" only when every quote `verified`; otherwise the line reads "Citations NON VÉRIFIÉES par le pont" (and with A3 the bridge never creates such a draft anyway; keep the branch for old drafts).
- Tests for both bridge refusals; prompt snapshot test updated.

### A4 · P1 · `run-web.sh` and `run-demo.sh --provider pod` accept plaintext remote LLM URL
Fix: a shared bash check (function in `run-web.sh`, duplicated in `run-demo.sh` — no new file): scheme must be `https`, or `http` with host in `127.0.0.1|localhost|[::1]`; no userinfo. Exit 2 with the same French message as the PowerShell launcher. Shell test in `harness/tests/test_launchers.py` (spawn `bash -n` + run with a bad URL, expect exit 2 and message).

### A5 · P2 · Feeder SDK backend targets profile `sdk`
`dictation_feeder.py`. Fix: default `--dsh-profile scribe`; `SdkClient` sets `DSH_AGENTS_HOME` (`<dsh_home>/agents`) if unset and refuses to start if `<dsh_home>/profiles/<profile>` does not exist (message: run `harness/run-web.sh` once to create the profile link). Test on the argument defaults and the refusal.

### A6 · P2 · Feeder can replay a dictation after a crash (send before save)
Fix: at-least-once made explicit. Before sending, write `state.inflight = [dictation_ids]` and save; after the send, move them to `delivered`, clear `inflight`, save. On start, if `inflight` is non-empty, re-send them with the prefix `« Renvoi possible après interruption (même identifiant de dictée ; ignorer si déjà reçu) »` and log it. Persona: one sentence in `scribe-persona` telling the agent a repeated dictation id is a re-delivery, not a new dictation. Tests: crash between save and send, restart → resend with prefix, then delivered.

### A7 · P2 · `_items()` swallows every `APIError`
Fix: only `status == 404` is skipped (logged); any other `APIError`/`OSError` propagates so `run_forever` retries and `pending` is kept (the `pending = []` line must run only after a successful followup). Test: 503 on relecture → exception, pending intact, second pass delivers.

### A8 · P2 · Bridge reads only `dictation-*.json` files, never the VoxLocal API
Fix: `ApiDictationSource(base_url, token)` in `portail_bridge.py`: `GET /v1/dictations/<id>` on the VoxLocal loopback API (loopback host only, token from `VOXLOCAL_API_TOKEN`, 5 s timeout). Patient binding from the record's `patientContext`: accepted forms are a JSON object `{"patient_id":…, "encounter_id":…}` or the compact `patient=<id> rencontre=<id>`; anything else → `patient_id=None` (refused by A3). Text = `finalTranscription` collapsed. `ChainedDictationSource([dir, api])` tries in order. `build_bridge_from_env`: dir source if `PORTAIL_DICTATION_DIR`, API source if `VOXLOCAL_API_URL` + `VOXLOCAL_API_TOKEN`, fixtures dir in mock mode; chained when several. Update `run-demo.sh` step 3 to stop hand-copying when the API source is configured (keep the copy as fallback), and the README launch line. Tests with a stub HTTP server.

### A9 · P2 · `_recover()` drops backup id / versions
Fix: add optional `PortalBackend.find_backup(item_id, attribute, current_digest) -> BackupInfo | None` (mock: scan `self.backups`; real: scan `records.DATA/*.json` matching item/attr/current_digest, newest). `_recover`: when the live digest equals the final digest, fill `apply` with `{ts, recovered: True, readback_digest, item_id, attribute, mode, backup_id (or None), version_after: section.version}`; audit `apply ok recovered=True backup_id=…`. `draft_restore` origin lookup keeps working through `apply.backup_id`. Test: crash simulation then restore succeeds.

### A10 · P2 · Model-supplied strings reach `approvals.jsonl`
Fix in `index.ts`: audit `key` only if it matches `^(drf|bak)-[A-Za-z0-9._-]{1,80}$`, otherwise `key_digest: sha256(key)[:16]` and `key_valid: false`. Error paths log `error_code`/`status` (from `RpcError.code`, `.status`) and never `error.message`. Same rule in `tools/result`. Vitest: an invalid key containing prose never appears in the audit file.

### A11 · P2 · Demo tokens in process arguments
`run-demo.sh`, `drive-ui.mjs`. Fix: `wait_http` passes the header through `curl -K -` (config on stdin: `header = "Authorization: Bearer …"`); `drive-ui.mjs` takes `--url` without the token and reads `DSH_WEB_TOKEN` from the environment, appending `?token=` itself. Any other `curl -H "Authorization…"` in the demo follows the same pattern.

### Docs
After A1–A11: re-read `harness/README.md` §Sécurité, `docs/security-whitepaper.md` §Agent et portail, `docs/faq-hospital-it.md` Q16–18; keep every claim true (patient/quote check now fail-closed; approval bound to session+call; real adapter restores on mismatch; audit never carries model strings; feeder at-least-once with explicit re-delivery marker). Add the at-least-once note to FAQ Q18.

## Part B — CodeRabbit review 2 unresolved threads

| Thread | Ruling | Reason |
|---|---|---|
| `SessionHandler.swift:149` delete WAV on mismatch | REJECT (again) | Product keeps the WAV so the operator can retry from history; documented in `docs/protocol-reconstruction.md`. Reply on thread, resolve. |
| `windows/install-runtime.ps1:122` TLS dir under InstallRoot | REJECT (again) | External TLS dir is deliberate so a reinstall keeps the pinned fingerprint. Reply, resolve. |
| `PortableClientModel.swift:292` fail closed on Keychain read error | ACCEPT | `try?` turns a read error into "first use" and pins the link. Fix: on read error, set `errorText` "Impossible de lire l’empreinte enregistrée ; réessayez." and return without pinning or connecting. Unit test if factored. |
| `LLMServer.swift:180` stale launch timeout kills newer server | ACCEPT | Cheap and real: on timeout, terminate only this launch's child and only `stop()`/throw when `generation == current`. |
| `PairingGate.swift:46` unbounded `records` | ACCEPT | Bound to 1024 like the Python host (`pairing_blocked`): refuse new peers when full, evict expired entries first. Swift Testing test. |
| `scripts/release.sh:115` `unzip -Z1 A B` never scans B | ACCEPT | Real unzip semantics. Loop `for z in …; do unzip -Z1 "$z"; done` piped to the grep. |
| `server/run-windows.ps1:32` + `install-runtime.ps1:33,92,115` python `-c` quoting on PS 5.1 | ACCEPT | Hospital posts run 5.1. Rewrite snippets so they contain no embedded double quotes (single quotes inside Python), or pass code via `-` on stdin. Keep windows CI green. |

## Dispatch
- Agent H (worktree `fix/astra-2-harness`): Part A + docs. Run `harness/tests`, all four plugin vitest suites, `pnpm install --frozen-lockfile` untouched.
- Agent C (worktree `fix/coderabbit-2`): Part B accepted rows. Run RemoteScribe swift tests, VoxLocal build, `tests/`, `windows/` suite.
- Fable: merge both into `feat/productization`, CI green, reply to the 7 threads, merge PR #1.
