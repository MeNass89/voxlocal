# VoxLocal wave 3 — the clinical agent harness

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps. Every task ends with the listed verification commands and, for anything a user sees, a screenshot under `docs/superpowers/evidence/`. One commit per task on the current branch. Never push.

**Goal (Nassim, verbatim):** « voxlocal se veut être la couche qui permet à notre médecin de se balader, dicter ce qu'il voit et veut de l'agent sur l'ordi, l'agent reçoit tout ça, le modèle de voix transcrit en temps réel, c'est nettoyé en temps réel, l'agent dans le harness reçoit en temps réel et peut commencer à préparer les modifications nécessaires, sans les pousser sur portail patient, il prépare tout et attend un feu vert explicite. » Triggers: a finished dictation, a clinician command, and a multimodal chat on the workstation.

**Decisions (ratified 2026-09-25):**
- Harness = **DeepSeek Harness** (`dsh`, MIT, Node ≥ 22.19). Pinned to commit `477b4f4` (2026-09-24), package `@deepseek-ai/dsh` 0.1.7-rc.2. Reason: everything is a plugin, custom OpenAI-compatible providers, native approval gate, web/headless/sdk profiles, webhook ingress.
- Model = **Qwen3.8-27B** (Apache 2.0, 262k ctx, tool calling, vision). Served by our RunPod edge (`llama-server`, GGUF `unsloth/Qwen3.8-27B-GGUF` Q4_K_M ≈ 17.1 GB on a 24 GB GPU). No 35B exists in the 3.8 line (35B = Qwen3.6-A3B).
- Portal = **locked down**: no access to `*.hopital.erasme.local` today. All portal tools run against a **recorded mock** built from `MeNass89/portail-med-api` (cloned at `~/Projects/portail-med-api`; read its `CLAUDE.md`, `docs/llm-api-guide.md`, `docs/status-and-roadblocks.md`, `src/portail/records.py`, `samples/transcript_entorse.txt`). The mock must reproduce the real facts: only narrative-section edits of encounter-filed documents are visible; suggestions are invisible; `source-id` = `ERA_EHR`; `getItem` requires `version`; attribute values are `{_value_1: [{text: …}]}`. When portal access returns, the mock is swapped for the real client behind the same interface.
- **Approval lives in our harness**, not in the portal: any tool that mutates the record is gated by dsh `ctx.approval` (`tools/pre-execute` → `ask`), answered in the dsh web chat on the workstation. Nothing reaches the portal (mock or real) without an explicit approval event, and every approval is written to an audit log.
- One repository. Everything lives under `harness/` in `voxlocal`.
- Medical toolbox (protocols like "entorse", INAMI billing, prescriptions via xCare) is **wave 4**; wave 3 leaves clean seams for it.

**Layout to create:**
```
harness/
  README.md                      # what it is, how to run the demo, security posture
  profile/                       # dsh profile "scribe": cordis.patch.yml, package.json (dsh.profile), pinned dsh version
  plugins/
    voxlocal-tools/              # TS plugin: dictation.* tools  (talks to VoxLocal agent API + history)
    portail-tools/               # TS plugin: patient.* record.* tools (talks to the portal bridge)
    scribe-approval/             # TS plugin: approval gate + audit log for record.apply
    scribe-persona/              # TS plugin: system prompt sections (French, clinical, "prepare, never apply")
  bridge/
    portail_bridge.py            # Python JSON-RPC (stdio or loopback HTTP) around portail.records / FhirClient
    portail_mock.py              # recorded EHR: fixtures under harness/bridge/fixtures/*.json, same interface
    fixtures/                    # synthetic patient "entorse" + 2 others, encounter-filed documents with narrative sections
  ingest/
    dictation_feeder.py          # watches VoxLocal history / agent API, chunks, cleans, posts to dsh (webhook or SDK)
  tests/                         # Python + vitest
  bench/                         # tool-calling benchmark for Qwen3.8 through the edge
```

## Global constraints
- Node ≥ 22.19 (installed: 26.8). pnpm. Python 3.11+ stdlib for our code (the bridge may import `portail` from the sibling repo only when the real client is enabled; the mock has no third-party deps).
- No PHI, ever: fixtures are synthetic, French, clinically plausible. The "entorse" transcript in `portail-med-api/samples/` is synthetic and may be copied.
- Secrets: the GPU edge token comes from `VOXLOCAL_LLM_TOKEN` in the environment (dsh `apiKeyEnv`), never in YAML committed to git. Portal credentials are read only by the bridge (Credential Manager / env), never by the harness process.
- The harness must run on the hospital **Windows** workstation eventually; write scripts so they also work on macOS for development. Test on macOS now; PowerShell launcher in Task 6.
- dsh is a developer preview with breaking changes: pin the exact version in `harness/profile/package.json` and in `harness/README.md`; run `pnpm install --frozen-lockfile`.
- French copy for anything the clinician sees (persona, tool descriptions shown in the chat, approval prompts).

## Review focus
1. The agent must never call `record.apply` without an approval event; a test drives a full turn with approval policy `never` and asserts no mutation reached the bridge.
2. A dictation that arrives mid-turn must not be lost: the feeder's `agent.inject`/followup is idempotent per dictation id (test: feed the same dictation twice, one inbox message).
3. The model must produce a **draft** (section → proposed text, with source quotes from the dictation) before asking for approval; the persona and the `record.draft_edit` tool schema enforce it (test: benchmark prompt yields a draft with the four SOAP sections filled from the entorse transcript).
4. The bridge refuses to `apply` when the read-back digest differs from the draft's base digest (concurrent edit); test in `harness/tests/test_bridge.py`.
5. Restart safety: a killed feeder resumes from its last acknowledged dictation id (state file), no replay, no gap.

---

## Task H1: dsh profile "scribe" + GPU provider + tool-calling benchmark

**Files:** `harness/profile/{package.json,cordis.patch.yml,README.md}`, `harness/bench/{tool_calling_bench.py,README.md}`, `harness/README.md` (skeleton), `.gitignore` (add `harness/**/node_modules`, `harness/.dsh-home/`), `docs/superpowers/evidence/2026-09-25-harness-bench.json`.

- [ ] Step 1: `harness/profile/package.json` declares `"dsh": { "profile": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web"] }` (copy the exact shape from `/tmp/dsh/packages/bundle/*/package.json` and the `web` profile), pins `@deepseek-ai/dsh` to `0.1.7-rc.2`. `pnpm install` inside `harness/profile`.
- [ ] Step 2: `cordis.patch.yml` adds the provider row:
```yaml
- id: llm-pi-ai
  config:
    providers:
      voxlocal-gpu:
        apiKeyEnv: VOXLOCAL_LLM_TOKEN
        api: openai-completions
        baseURL: !!js process.env.VOXLOCAL_LLM_URL   # e.g. https://<pod>:8443/llm/v1
        models:
          - id: qwen3.8-27b
            input: [text, image]
- id: agent-default-model
  config: { provider: voxlocal-gpu, model: qwen3.8-27b }
```
  Verify `!!js` env interpolation is allowed in a user patch (search `/tmp/dsh/docs/config-catalog.md` and `packages/boot/app-boot/README.md`); if not, generate the YAML from a small script `harness/profile/render-patch.sh` at launch.
- [ ] Step 3: launcher `harness/run-web.sh`: sets `DSH_HOME=$PWD/harness/.dsh-home`, requires `VOXLOCAL_LLM_URL` and `VOXLOCAL_LLM_TOKEN`, runs `dsh --profile scribe web --no-open`. Smoke: with a **local** `llama-server` (the tiny Qwen2.5-0.5B from `/tmp/vox-models`, `--api-key` set) as the endpoint, open the web UI (Playwright headless shell screenshot at 1440×900 → `evidence/…-harness-web-empty.png`) and send "Bonjour" through the chat via the dsh SDK or `dsh --profile headless` (headless profile also patched with the provider). Read the PNG.
- [ ] Step 4: `harness/bench/tool_calling_bench.py` (stdlib): sends N prompts with 3 tool schemas (`dictation.get`, `patient.read`, `record.draft_edit`) to an OpenAI-compatible `/v1/chat/completions`, measures tool-call validity rate (JSON parses, required args present), p50/p95 latency, tokens/s. Run against the local tiny model (numbers are a harness proof, note it in the JSON) → `evidence/2026-09-25-harness-bench.json`. Document how to run it against the Pod with Qwen3.8-27B.
- [ ] Verify: `dsh --profile scribe --dump-config` shows the `voxlocal-gpu` row; screenshot; bench JSON. Commit `feat(harness): dsh profile scribe with GPU provider and tool-calling benchmark`.

## Task H2: VoxLocal dictation feed (Mac app loopback API + `voxlocal-tools` plugin + feeder)

**Files:** `mac/VoxLocal/Sources/VoxLocal/LocalAPI.swift` (new), `AppState.swift`, `EditorViews.swift` (a "Harness" toggle + token display in Réglages › iPhone), `agent/voxlocal_agent_api.py` (add `GET /v1/dictations?since=<id>` and `GET /v1/dictations/<id>` backed by a pluggable `DictationSource`), `harness/plugins/voxlocal-tools/**`, `harness/ingest/dictation_feeder.py`, `harness/tests/test_feeder.py`, `agent/test_agent_api.py`.

- [ ] Step 1: Mac app: `LocalAPI.swift` serves `127.0.0.1:47367` (Network.framework listener, loopback only) with a Bearer token generated at first run (Keychain, shown in Réglages). Routes: `GET /v1/dictations?since=<id>&wait=<seconds>` (long-poll up to 25 s; returns records newer than `since`, with `id`, `timestamp`, `deviceName`, `modeId`, `rawTranscription`, `finalTranscription`, `processingStatus`, `duration`; **no audio path**), `GET /v1/dictations/<id>`, `POST /v1/dictations/<id>/retranscribe`. Emits from `historyRepository` changes (reuse `onHistoryChanged`). Off by default; toggle in Réglages › iPhone "Exposer les dictées au harness local".
- [ ] Step 2: Python agent API gets the same two GET routes so the Windows host has parity; source = in-memory ring of completed sessions from `server/voxlocal_server.py` is out of scope (that host persists nothing) → for Windows the feeder consumes the **Mac API or the agent API in mock mode**; document the gap honestly.
- [ ] Step 3: `voxlocal-tools` plugin (TS, `defineTool`): `dictation_list({since?, limit?})`, `dictation_get({id})`, `dictation_retranscribe({id})`. Reads `VOXLOCAL_API_URL` + `VOXLOCAL_API_TOKEN` from plugin config (env-interpolated). `output.render` shows French summaries; `presentCall` cards with `kind: 'read'`.
- [ ] Step 4: `dictation_feeder.py`: long-polls the API, keeps `state.json` (last acked id), for each new **completed** dictation posts to the running dsh session via the Python SDK (`DeepSeekHarness(...).run(...)` for a fresh session, or JSON-RPC followup on an existing session id) a message: « Nouvelle dictée <id> (<durée>) : <finalTranscription> ». Idempotent by id. `--once` flag for tests.
- [ ] Step 5: tests: feeder idempotence and resume (stub HTTP server); Mac API unit test in `mac/VoxLocal/Tests` (auth required, `since` filter, no audio path in JSON); agent API tests for the two routes.
- [ ] Verify: `swift build`, `swift test` (mac), `python3 -m unittest harness.tests`, `agent/` suite; render the Réglages screen with the new toggle → evidence PNG. Commit `feat(harness): dictation feed (VoxLocal loopback API, voxlocal-tools plugin, feeder)`.

## Task H3: Portal bridge with recorded mock + `portail-tools` plugin

**Files:** `harness/bridge/{portail_bridge.py,portail_mock.py,interface.py}`, `harness/bridge/fixtures/*.json`, `harness/plugins/portail-tools/**`, `harness/tests/test_bridge.py`, `harness/tests/test_portail_tools.spec.ts`.

- [ ] Step 1: `interface.py`: `class PortalBackend(Protocol)` with `resolve_patient(query) -> [PatientRef]`, `read_patient(patient_id) -> {allergies, conditions, medications}`, `find_sections(patient_id) -> [Location{item_id, attribute, current_text, version, digest}]`, `read_section(item_id, attribute) -> Section`, `apply(item_id, attribute, base_digest, new_text, mode: 'append'|'replace', old?) -> EditResult{version_before, version_after, backup_id}`, `restore(backup_id)`. Mirrors `portail.records.Record` semantics exactly (append/replace only, digest check, backup, read-back verify).
- [ ] Step 2: `portail_mock.py`: implements the interface over JSON fixtures; enforces the real traps (digest mismatch → error; unknown attribute → error listing present ones; `replace` with 0 or >1 occurrences → error). Fixtures: 3 synthetic patients, each with one `out-patient-care-procedure` document carrying the 8 narrative attributes, plus FHIR-like allergies/conditions/meds. Patient 1 = the entorse case matching `samples/transcript_entorse.txt`.
- [ ] Step 3: `portail_bridge.py`: JSON-RPC 2.0 over loopback HTTP (`127.0.0.1:47368`, Bearer from env), methods = the interface; backend selected by `PORTAIL_BACKEND=mock|real` (real imports `portail` from `PORTAIL_MED_API_PATH`; not exercised now). Every `apply` appends a line to `harness/audit/portal-writes.jsonl` (ts, patient, item, attribute, mode, digests, approval id, who).
- [ ] Step 4: `portail-tools` plugin: `patient_resolve`, `patient_read`, `record_find_sections`, `record_read_section`, `record_draft_edit({item_id, attribute, mode, new_text, rationale, quotes[]})` → returns a **draft id** and stores the draft in plugin state (no bridge call), `record_apply({draft_id})` → bridge `apply`, `record_restore({backup_id})`. Tool descriptions in French. `presentCall` for `record_apply` uses the `diff` card (old/new text).
- [ ] Verify: `python3 -m unittest harness.tests.test_bridge` (digest mismatch, append/replace rules, audit line written, restore round-trip); vitest for the plugin against a stub bridge. Commit `feat(harness): portal bridge (recorded mock) and portail-tools plugin`.

## Task H4: Approval gate, audit, persona, and the real-time loop

**Files:** `harness/plugins/scribe-approval/**`, `harness/plugins/scribe-persona/**`, `harness/profile/cordis.patch.yml` (mount the four plugins; approval policy `ask`), `harness/ingest/dictation_feeder.py` (webhook or SDK path finalised), `harness/tests/test_loop.py`, `harness/README.md`.

- [ ] Step 1: `scribe-approval`: `ctx.on('tools/pre-execute', …)` → for `record_apply` and `record_restore` return `{kind:'ask'}` routed to `ctx.approval`; on `deny`/`unavailable` the tool is not executed and the model gets a French message « Application refusée : aucun feu vert. ». On `allow`, write `{approval_id, tool, args_digest, ts, answerer}` to `harness/audit/approvals.jsonl` and pass the `approval_id` to the tool (via `exec` metadata or a plugin-state map keyed by callId). `ctx.tools.guard()` adds a monotonic deny for `record_apply` when no approval id is attached (belt and braces).
- [ ] Step 2: `scribe-persona`: system-prompt sections (French): role (assistant de rédaction clinique, jamais décisionnel), the loop (lire la dictée → lire le dossier → proposer un brouillon par section avec citations → attendre le feu vert → appliquer → relire), hard rules (never invent facts; preserve negations, doses, units; ask when ambiguous; SOAP mapping: subjectif → `current-affliction`, objectif → `physical-exam-text`, évaluation → `text-conclusion`, plan → `disposition`), and the reminder that `record_apply` requires approval.
- [ ] Step 3: mount everything in `cordis.patch.yml` (`insert` rows for the four plugins; `user-approval` policy `ask`); verify `--dump-config`.
- [ ] Step 4: the loop test (`test_loop.py`, uses the Python SDK with the **local tiny model or a scripted fake provider** if Qwen is unavailable): feed the entorse dictation → assert a `record_draft_edit` call happened with `physical-exam-text` and `disposition` populated → assert no bridge `apply` occurred → answer the approval → assert `apply` occurred once and the audit lines exist. If the tiny model cannot follow the tool protocol reliably, implement a **scripted provider** (an OpenAI-compatible stub in tests that returns predetermined tool calls) so the harness wiring is tested independently of model quality; keep the real-model run as a manual bench.
- [ ] Verify: tests green; `harness/README.md` explains architecture, run, security. Commit `feat(harness): approval gate with audit, clinical persona, real-time dictation loop`.

## Task H5: Demo end to end (mock portal) with evidence

**Files:** `harness/demo/{run-demo.sh,README.md}`, `docs/demo-runbook.md` (add "Parcours agent"), evidence PNGs.

- [ ] Step 1: `run-demo.sh` starts (macOS): local `llama-server` with the best available local model (Qwen2.5-0.5B by default; prints how to point at the Pod), the portal bridge in mock mode, the dsh web profile, and the feeder pointed at the **agent API in mock mode** with a `--seed-dictation samples/transcript_entorse.txt` option (so the demo runs without an iPhone). Prints the URLs.
- [ ] Step 2: Drive the web UI with the Playwright headless shell (`--force-prefers-reduced-motion`) or the dsh SDK: capture (a) the chat showing the injected dictation, (b) the draft with sections and quotes, (c) the approval prompt, (d) the applied diff card, (e) `record_restore`. Read every PNG.
- [ ] Step 3: `docs/demo-runbook.md`: a second 90-second script « Parcours agent » after the dictation script.
- [ ] Verify: `bash harness/demo/run-demo.sh --check` exits 0; 5 PNGs. Commit `docs(harness): end-to-end demo on the recorded portal`.

## Task H6: Windows launcher, CI, docs truth pass

**Files:** `harness/run-web.ps1`, `harness/ingest/run-feeder.ps1`, `.github/workflows/ci.yml` (harness tests on ubuntu + macOS; `pnpm install --frozen-lockfile`, `pnpm test` in `harness/plugins/*`, `python3 -m unittest discover -s harness/tests`), `README.md` (harness section), `docs/architecture.md`, `docs/security-whitepaper.md` (new section « Agent et portail » with the approval/audit design and the portal lockdown status), `docs/release-readiness.md`, `docs/roadmap.md` (wave 4 = medical toolbox: protocoles, INAMI, xCare), `MEMORY.md`.

- [ ] Verify: CI YAML valid; all harness tests green locally; link check; stale-string grep. Commit `chore(harness): Windows launchers, CI, docs`.

## Self-review
- Coverage of the mandate: dictation feed (H2), real-time cleaning (existing agent API clean + feeder), agent that prepares (H3 drafts) and never applies without approval (H4), chat UI (H1 web profile), model on rented GPU (H1 provider + bench), portal locked → mock with the same interface (H3). Wave 4 seam: `harness/plugins/` for protocols/INAMI/xCare; the persona lists "toolbox" placeholders explicitly as not yet available.
- Risk: dsh preview API drift → pinned version, all dsh-touching code isolated in `harness/plugins/*` and `harness/profile/`.
- Risk: Qwen3.8 tool-calling quality unknown → scripted-provider tests keep the harness verifiable; the bench measures the real model when the Pod exists.
