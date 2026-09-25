/**
 * Approval gate of the VoxLocal scribe (plan H4 as amended by Amendment 1).
 *
 * The portal bridge is the security boundary: it refuses `apply` and `restore` until a draft was
 * approved over the separate approver credential. This plugin is how a human decision gets there:
 *
 *   model calls record_apply(draft_id) / record_restore(backup_id)
 *     -> `tools/pre-execute` (this plugin): fetch the draft from the bridge (tool token), build the
 *        French approval prompt (patient, encounter, section, exact diff, source quotes), return `ask`
 *     -> dsh `ctx.approval` (policy `ask` | `never`) -> `approval/request` answerers (the Web chat)
 *     -> on `allowed-once`, this plugin's pass-through answerer calls bridge `approve_draft` with
 *        PORTAIL_BRIDGE_APPROVER_TOKEN before the tool may run; a failed relay becomes `unavailable`
 *     -> `ctx.tools.guard()`: monotonic deny unless THIS call id holds a relayed grant for THIS draft
 *     -> tool body (portail-tools) asks the bridge to write; the bridge re-checks everything
 *     -> `tools/post-execute`: a call that ran without a grant, or was denied, reaches the model as
 *        « Application refusée : aucun feu vert. »
 *
 * Every decision is appended to `harness/audit/approvals.jsonl` (ids and digests, no prose).
 * @module @voxlocal/scribe-approval
 */

import { createHash } from 'node:crypto'
import { appendFileSync, mkdirSync } from 'node:fs'
import { userInfo } from 'node:os'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import type { PreToolDecision, PostToolDecision, ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import type { ApprovalOutcome } from '@deepseek-ai/dsh-user-approval'
import type {} from '@deepseek-ai/dsh-session'

export const name = 'scribe-approval'
export const inject = ['tools', 'approval']

/** The model-facing refusal, verbatim (the persona quotes it). */
export const REFUSAL = 'Application refusée : aucun feu vert.'

/** Tools that mutate the record (portail-tools `TOOL_NAMES.apply` / `.restore`). */
export const GATED_TOOLS = ['record_apply', 'record_restore'] as const
type GatedTool = typeof GATED_TOOLS[number]

const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]'])
const DEFAULT_AUDIT = fileURLToPath(new URL('../../../audit/approvals.jsonl', import.meta.url))

/** Plugin configuration. */
export interface Config {
  /** Bridge endpoint; must be loopback. */
  bridgeUrl?: string
  /** Environment variable holding the tool-side token (reads drafts to render the prompt). */
  tokenEnv?: string
  /** Environment variable holding the approver token (relays the human decision). */
  approverTokenEnv?: string
  /** Who answers in the dsh chat on this workstation (dsh outcomes carry no identity). */
  answerer?: string
  /** Append-only JSONL audit of every decision. */
  auditPath?: string
  /** Per-call deadline for bridge calls, in milliseconds. */
  timeoutMs?: number
}

export const Config: z<Config> = z.object({
  bridgeUrl: z.string().default('http://127.0.0.1:47368/'),
  tokenEnv: z.string().default('PORTAIL_BRIDGE_TOKEN'),
  approverTokenEnv: z.string().default('PORTAIL_BRIDGE_APPROVER_TOKEN'),
  answerer: z.string(),
  auditPath: z.string(),
  timeoutMs: z.natural().default(15_000),
})

// ------------------------------------------------------------------------ bridge
/** The draft fields the prompt and the audit need (bridge `draft_get` public view). */
export interface Draft {
  draft_id: string
  kind: 'edit' | 'restore'
  status: string
  patient_id: string
  encounter_id: string
  item_id: string
  attribute: string
  mode: string
  new_text: string
  rationale: string
  quotes: Array<{ dictation_id: string, offset: number | null, text: string, verified: boolean }>
  quotes_verified: boolean
  base_digest: string
  base_text: string
  final_text: string
  final_text_digest: string
  backup_id: string | null
}

class RpcError extends Error {
  readonly code: number
  constructor(code: number, message: string) {
    super(message)
    this.code = code
  }
}

async function rpc<T>(url: string, token: string | undefined, method: string, params: Record<string, unknown>,
  timeoutMs: number, signal?: AbortSignal): Promise<T> {
  if (token === undefined || token === '') throw new RpcError(401, `jeton absent pour ${method}`)
  const timeout = AbortSignal.timeout(timeoutMs)
  let response: Response
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
      signal: signal === undefined ? timeout : AbortSignal.any([signal, timeout]),
    })
  } catch (error) {
    throw new RpcError(503, `pont portail injoignable : ${(error as Error).message}`)
  }
  const body = await response.json().catch(() => undefined) as
    | { result?: T, error?: { code: number, message: string } } | undefined
  if (body?.error !== undefined) throw new RpcError(body.error.code, body.error.message)
  if (!response.ok || body === undefined || !('result' in body)) {
    throw new RpcError(response.status || 502, `réponse invalide du pont (HTTP ${response.status})`)
  }
  return body.result as T
}

// ------------------------------------------------------------------------ prompt
const SECTION_LABELS: Record<string, string> = {
  'current-affliction': 'anamnèse / histoire de la maladie actuelle',
  'main-problem-history': 'histoire du problème principal',
  'physical-exam-text': 'examen clinique',
  'systematic-review-text': 'revue des systèmes',
  'text-conclusion': 'conclusion',
  'text-evolution': 'évolution',
  'disposition': 'orientation / suite à donner',
  'other-risk-text': 'facteurs de risque',
}

/** Line diff (LCS) of two short texts: `- ` removed, `+ ` added, `  ` unchanged. */
export function lineDiff(before: string, after: string): string[] {
  const a = before === '' ? [] : before.split('\n')
  const b = after === '' ? [] : after.split('\n')
  const lcs: number[][] = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0))
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i]![j] = a[i] === b[j] ? lcs[i + 1]![j + 1]! + 1 : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!)
    }
  }
  const out: string[] = []
  let i = 0
  let j = 0
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { out.push(`  ${a[i]}`); i++; j++ } else if (lcs[i + 1]![j]! >= lcs[i]![j + 1]!) { out.push(`- ${a[i]}`); i++ } else { out.push(`+ ${b[j]}`); j++ }
  }
  while (i < a.length) out.push(`- ${a[i++]}`)
  while (j < b.length) out.push(`+ ${b[j++]}`)
  return out
}

/** The French approval prompt shown in the dsh chat. Pure: draft + patient label in, text out. */
export function approvalPrompt(tool: GatedTool, draft: Draft, patientLabel: string | undefined): string {
  const section = `${draft.attribute} (${SECTION_LABELS[draft.attribute] ?? 'section narrative'})`
  const action = tool === 'record_restore'
    ? `Annuler une modification (restauration de la sauvegarde ${draft.backup_id ?? '?'})`
    : `Écrire dans le dossier patient (${draft.mode === 'replace' ? 'remplacement' : 'ajout en fin de section'})`
  const quotes = draft.quotes.length === 0
    ? ['  (aucune : restauration du texte d\'origine)']
    : draft.quotes.map(q => `  « ${q.text} » (dictée ${q.dictation_id}${q.offset === null ? '' : `, car. ${q.offset}`}`
      + `${q.verified ? ', retrouvée dans la dictée' : ', NON VÉRIFIÉE'})`)
  const dictations = [...new Set(draft.quotes.map(q => q.dictation_id))]
  return [
    `Feu vert demandé : ${action}.`,
    `Patient : ${draft.patient_id}${patientLabel === undefined ? '' : ` (${patientLabel})`}`,
    `Rencontre : ${draft.encounter_id}`,
    `Document : ${draft.item_id}`,
    `Section : ${section}`,
    ...(dictations.length === 0 ? [] : [`Dictée : ${dictations.join(', ')} (patient de la dictée = patient du brouillon, vérifié par le pont)`]),
    `Brouillon : ${draft.draft_id}`,
    'Modification exacte :',
    ...lineDiff(draft.base_text, draft.final_text).map(line => `  ${line}`),
    'Citations de la dictée :',
    ...quotes,
    `Motif : ${draft.rationale}`,
  ].join('\n')
}

// ------------------------------------------------------------------------ plugin
interface Pending {
  tool: GatedTool
  draft: Draft
  argsDigest: string
  sessionId: string | undefined
  /** Set once the approval seam consulted the answerers (never set under policy `never`). */
  outcome?: ApprovalOutcome
  audited?: boolean
}

interface Grant {
  tool: GatedTool
  draftId: string
  key: string
  approvalId: string
}

function argsDigest(args: unknown): string {
  return createHash('sha256').update(JSON.stringify(args)).digest('hex').slice(0, 16)
}

function isGated(name: string): name is GatedTool {
  return (GATED_TOOLS as readonly string[]).includes(name)
}

/** The argument that names what a gated call writes: draft id or backup id. */
function keyOf(tool: GatedTool, args: unknown): string | undefined {
  const field = tool === 'record_apply' ? 'draft_id' : 'backup_id'
  const value = (args as Record<string, unknown> | null)?.[field]
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

const OUTCOME_FR: Record<string, string> = {
  'rejected': 'refusé par le clinicien, ou politique d\'approbation « never »',
  'cancelled': 'demande annulée',
  'unavailable': 'aucun canal d\'approbation disponible',
  'relay-failed': 'le pont n\'a pas enregistré le feu vert',
  'no-grant': 'appel sans feu vert enregistré',
}

export function apply(ctx: Context, config: Config = {}) {
  const url = config.bridgeUrl ?? 'http://127.0.0.1:47368/'
  const host = new URL(url).hostname
  if (!LOOPBACK.has(host)) throw new Error(`le pont portail doit être en boucle locale, reçu ${host}`)
  const tokenEnv = config.tokenEnv ?? 'PORTAIL_BRIDGE_TOKEN'
  const approverTokenEnv = config.approverTokenEnv ?? 'PORTAIL_BRIDGE_APPROVER_TOKEN'
  const answerer = config.answerer ?? `poste:${process.env.SCRIBE_CLINICIAN ?? userInfo().username}`
  const auditPath = config.auditPath ?? DEFAULT_AUDIT
  const timeoutMs = config.timeoutMs ?? 15_000

  const pending = new Map<string, Pending>()
  const grants = new Map<string, Grant>()

  function audit(entry: Record<string, unknown>): void {
    mkdirSync(dirname(auditPath), { recursive: true })
    appendFileSync(auditPath, `${JSON.stringify({ ts: new Date().toISOString(), plugin: name, ...entry })}\n`)
  }

  function auditDecision(callId: string, p: Pending, decision: string, extra: Record<string, unknown> = {}): void {
    audit({
      event: 'decision', decision, tool: p.tool, call_id: callId, session_id: p.sessionId,
      draft_id: p.draft.draft_id, kind: p.draft.kind, backup_id: p.draft.backup_id,
      patient_id: p.draft.patient_id, encounter_id: p.draft.encounter_id, item_id: p.draft.item_id,
      attribute: p.draft.attribute, mode: p.draft.mode, base_digest: p.draft.base_digest,
      final_digest: p.draft.final_text_digest, args_digest: p.argsDigest, ...extra,
    })
  }

  async function loadDraft(tool: GatedTool, key: string, signal: AbortSignal): Promise<Draft> {
    const token = process.env[tokenEnv]
    return tool === 'record_apply'
      ? rpc<Draft>(url, token, 'draft_get', { draft_id: key }, timeoutMs, signal)
      // A restore is a draft too (bridge `draft_restore`, idempotent per backup).
      : rpc<Draft>(url, token, 'draft_restore', { backup_id: key }, timeoutMs, signal)
  }

  async function patientLabel(patientId: string, signal: AbortSignal): Promise<string | undefined> {
    try {
      const data = await rpc<{ patient?: { display_name?: string, birth_date?: string } }>(
        url, process.env[tokenEnv], 'read_patient', { patient_id: patientId }, timeoutMs, signal)
      const p = data.patient
      return p?.display_name === undefined ? undefined : `${p.display_name}${p.birth_date ? `, né·e le ${p.birth_date}` : ''}`
    } catch {
      return undefined
    }
  }

  // 1. Ask: render the draft and route the question through ctx.approval.
  ctx.on('tools/pre-execute', async (exec: ToolExecution, next: () => Promise<PreToolDecision>): Promise<PreToolDecision> => {
    if (!isGated(exec.name)) return next()
    // Later policy (sandbox, presets) may still deny or cancel; only an allow becomes a question.
    const downstream = await next()
    if (downstream.kind === 'deny' || downstream.kind === 'cancel') return downstream
    const tool = exec.name
    const key = keyOf(tool, exec.arguments)
    const base = { tool, call_id: exec.callId, session_id: exec.agent?.session.id, args_digest: argsDigest(exec.arguments) }
    if (key === undefined) {
      audit({ event: 'decision', decision: 'refused-before-ask', reason: 'identifiant manquant', ...base })
      return { kind: 'deny', reason: `${REFUSAL} (${tool === 'record_apply' ? 'draft_id' : 'backup_id'} manquant)` }
    }
    let draft: Draft
    try {
      draft = await loadDraft(tool, key, exec.signal)
    } catch (error) {
      const e = error as RpcError
      audit({ event: 'decision', decision: 'refused-before-ask', reason: `pont ${e.code ?? '?'}`, key, ...base })
      return { kind: 'deny', reason: `${REFUSAL} Brouillon illisible sur le pont (${e.code ?? '?'}) : ${e.message}` }
    }
    if (draft.status !== 'drafted' && draft.status !== 'approved') {
      audit({ event: 'decision', decision: 'refused-before-ask', reason: `statut ${draft.status}`, draft_id: draft.draft_id, ...base })
      return {
        kind: 'deny',
        reason: draft.status === 'applied'
          ? `Brouillon ${draft.draft_id} déjà appliqué : rien à refaire.`
          : `${REFUSAL} Brouillon ${draft.draft_id} au statut « ${draft.status} » : préparer un nouveau brouillon.`,
      }
    }
    pending.set(exec.callId, { tool, draft, argsDigest: base.args_digest, sessionId: base.session_id })
    const text = approvalPrompt(tool, draft, await patientLabel(draft.patient_id, exec.signal))
    return {
      kind: 'ask',
      // The audited reason stays prose-free; the full prompt is presentation only.
      reason: `feu vert requis : ${tool} ${draft.draft_id} (${draft.patient_id}, ${draft.encounter_id}, ${draft.attribute})`,
      displayReason: { en: text, fr: text, zh: text },
    }
  }, { prepend: true })

  // 2. Relay: wrap the answerers; a human `allowed-once` reaches the bridge before the tool runs.
  ctx.on('approval/request', async (req, next) => {
    const p = req.callId === undefined ? undefined : pending.get(req.callId)
    if (p === undefined || req.toolName !== p.tool) return next()
    const callId = req.callId as string
    const outcome = await next()
    p.outcome = outcome
    p.audited = true
    if (outcome !== 'allowed-once') {
      auditDecision(callId, p, outcome)
      return outcome
    }
    try {
      // A draft already approved on the bridge (human decision whose write did not complete)
      // keeps its single-use grant there; asking again only re-confirms it.
      const approvalId = p.draft.status === 'approved'
        ? 'approuvé-antérieurement'
        : (await rpc<{ approval_id: string }>(url, process.env[approverTokenEnv], 'approve_draft',
            { draft_id: p.draft.draft_id, answerer }, timeoutMs, req.signal)).approval_id
      grants.set(callId, { tool: p.tool, draftId: p.draft.draft_id, key: p.tool === 'record_apply' ? p.draft.draft_id : p.draft.backup_id!, approvalId })
      auditDecision(callId, p, 'allowed', { answerer, approval_id: approvalId })
      return outcome
    } catch (error) {
      auditDecision(callId, p, 'relay-failed', { answerer, error: (error as Error).message })
      return 'unavailable'
    }
  }, { prepend: true })

  // 3. Belt and braces: whatever allowed it, a gated call runs only with a relayed grant for its target.
  ctx.effect(() => ctx.tools.guard((exec) => {
    if (!isGated(exec.name)) return undefined
    const grant = grants.get(exec.callId)
    const key = keyOf(exec.name, exec.arguments)
    if (grant === undefined || grant.tool !== exec.name || key === undefined || grant.key !== key) {
      return `${REFUSAL} (${OUTCOME_FR['no-grant']})`
    }
    return undefined
  }), 'scribe-approval: guard')

  // 4. What the model reads when an asked call did not run. Denials before the question keep
  //    their own explanation (missing id, unreadable or already applied draft).
  ctx.on('tools/post-execute', async (exec, result: Readonly<ToolExecutionResult>, next): Promise<PostToolDecision> => {
    const p = pending.get(exec.callId)
    if (!isGated(exec.name) || !result.isError || grants.has(exec.callId) || p === undefined) return next()
    if (!p.audited) auditDecision(exec.callId, p, 'rejected', { reason: 'politique never : aucun clinicien consulté' })
    const why = p.outcome === undefined ? 'rejected' : p.outcome === 'allowed-once' ? 'relay-failed' : p.outcome
    return {
      kind: 'block',
      feedback: [{ type: 'text', text: `${REFUSAL} (${OUTCOME_FR[why] ?? why}) Rien n'a été écrit dans le dossier.` }],
    }
  })

  // 5. Close the loop: the write outcome, then forget the call.
  ctx.on('tools/result', (exec, result) => {
    if (!isGated(exec.name)) return
    const grant = grants.get(exec.callId)
    if (grant !== undefined) {
      audit({ event: 'result', tool: exec.name, call_id: exec.callId, draft_id: grant.draftId, approval_id: grant.approvalId,
        ok: !result.isError, ...(result.isError ? { error: result.error.message } : {}) })
    }
    pending.delete(exec.callId)
    grants.delete(exec.callId)
  })
}
