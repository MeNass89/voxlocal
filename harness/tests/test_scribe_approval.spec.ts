/**
 * scribe-approval: the dsh approval gate in front of record_apply / record_restore, relayed to
 * the real Python bridge (mock backend) over the approver credential.
 *
 * Every test runs the real dsh tool pipeline (pre-execute -> ctx.approval -> guard -> tool ->
 * post-execute), the real portail-tools plugin and a fresh bridge process on its own temp dir.
 *
 * Run: cd harness/plugins/scribe-approval && pnpm test
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ApprovalOutcome } from '@deepseek-ai/dsh-user-approval'
import { mount, ScribeApproval } from '../plugins/scribe-approval/tests/runtime.ts'

const TOKEN_ENV = 'SCRIBE_APPROVAL_TEST_TOKEN'
const APPROVER_ENV = 'SCRIBE_APPROVAL_TEST_APPROVER_TOKEN'
const TOOL_TOKEN = 'tool-token-for-approval-tests-0123456789'
const APPROVER_TOKEN = 'approver-token-for-approval-tests-9876543210'
const ITEM = '1f19a001-aaaa-4000-8000-000000000101'
const EXAM_QUOTE = 'douleur à la palpation du ligament talo-fibulaire antérieur'

type Line = Record<string, unknown>

class BridgeProcess {
  dir = mkdtempSync(join(tmpdir(), 'scribe-approval-'))
  proc!: ChildProcess
  url = ''

  async start() {
    this.proc = spawn('python3', ['-m', 'harness.bridge.portail_bridge', '--port', '0', '--backend', 'mock'], {
      cwd: resolve(import.meta.dirname, '../..'),
      env: {
        ...process.env,
        PORTAIL_BRIDGE_TOKEN: TOOL_TOKEN,
        PORTAIL_BRIDGE_APPROVER_TOKEN: APPROVER_TOKEN,
        PYTHONUNBUFFERED: '1',
        PORTAIL_BRIDGE_DRAFTS: join(this.dir, 'drafts.jsonl'),
        PORTAIL_BRIDGE_AUDIT: join(this.dir, 'portal-writes.jsonl'),
        PORTAIL_BRIDGE_STATE_DIR: join(this.dir, 'state'),
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    })
    this.url = await new Promise<string>((ok, fail) => {
      let err = ''
      this.proc.stderr!.on('data', (c: Buffer) => {
        err += c.toString()
        const m = /http:\/\/127\.0\.0\.1:(\d+)/.exec(err)
        if (m) ok(`http://127.0.0.1:${m[1]}/`)
      })
      this.proc.on('exit', code => fail(new Error(`bridge exited ${code}: ${err}`)))
    })
  }

  stop() {
    this.proc?.kill()
    rmSync(this.dir, { recursive: true, force: true })
  }

  lines(file: string): Line[] {
    const path = join(this.dir, file)
    return existsSync(path) ? readFileSync(path, 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l) as Line) : []
  }

  writes() {
    return this.lines('portal-writes.jsonl').filter(l => l.result === 'ok')
  }

  async rpc(method: string, params: Record<string, unknown>, token = TOOL_TOKEN) {
    const res = await fetch(this.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    })
    return res.json() as Promise<{ result?: Record<string, unknown>, error?: { code: number, message: string } }>
  }
}

function textOf(result: { content: Array<{ type: string, text?: string }> }): string {
  return result.content.map(b => b.text ?? '').join('\n')
}

describe('scribe-approval gate', () => {
  let bridge: BridgeProcess
  let auditPath: string

  beforeEach(async () => {
    bridge = new BridgeProcess()
    await bridge.start()
    auditPath = join(bridge.dir, 'approvals.jsonl')
    process.env[TOKEN_ENV] = TOOL_TOKEN
    process.env[APPROVER_ENV] = APPROVER_TOKEN
  })
  afterEach(() => {
    bridge.stop()
    delete process.env[TOKEN_ENV]
    delete process.env[APPROVER_ENV]
  })

  async function setup(policy: 'ask' | 'never', answer?: ApprovalOutcome) {
    const h = await mount({
      policy,
      approval: { bridgeUrl: bridge.url, tokenEnv: TOKEN_ENV, approverTokenEnv: APPROVER_ENV, answerer: 'dr.test', auditPath, timeoutMs: 5_000 },
      portail: { bridgeUrl: bridge.url, tokenEnv: TOKEN_ENV, timeoutMs: 5_000 },
    })
    const asked: Array<{ toolName: string, callId?: string, reason?: string, displayReason?: { en: string } }> = []
    if (answer !== undefined) {
      // The test answerer stands in for the clinician clicking in the dsh web chat.
      h.ctx.on('approval/request', (req) => {
        asked.push(req as never)
        return Promise.resolve(answer)
      })
    }
    return { ...h, asked }
  }

  async function draft(run: Awaited<ReturnType<typeof setup>>['run']) {
    const result = await run('record_draft_edit', {
      patient_id: 'pat-001', encounter_id: 'enc-001-urg', item_id: ITEM, attribute: 'physical-exam-text', mode: 'append',
      new_text: 'Douleur à la palpation du LTFA droit.', rationale: 'examen dicté',
      quotes: [{ dictation_id: 'dict-entorse-001', offset: 0, text: EXAM_QUOTE }],
    })
    expect(result.isError, textOf(result)).toBe(false)
    return (result.value as { draft_id: string }).draft_id
  }

  function approvals(): Line[] {
    return existsSync(auditPath) ? readFileSync(auditPath, 'utf8').trim().split('\n').map(l => JSON.parse(l) as Line) : []
  }

  it('asks with patient, encounter, section, exact diff and source quotes, then applies exactly once', async () => {
    const h = await setup('ask', 'allowed-once')
    const draftId = await draft(h.run)
    const result = await h.run('record_apply', { draft_id: draftId })
    expect(result.isError, textOf(result)).toBe(false)
    expect(textOf(result)).toContain('Appliqué')

    expect(h.asked).toHaveLength(1)
    const prompt = h.asked[0]!.displayReason!.en
    expect(prompt).toContain('Patient : pat-001 (MARTIN Lucas, né·e le 2003-04-12)')
    expect(prompt).toContain('Rencontre : enc-001-urg')
    expect(prompt).toContain(`Document : ${ITEM}`)
    expect(prompt).toContain('Section : physical-exam-text (examen clinique)')
    expect(prompt).toContain('Dictée : dict-entorse-001')
    expect(prompt).toContain('AJOUT : « Douleur à la palpation du LTFA droit. »')
    expect(prompt).toContain('inchangé : « Paramètres à l\'arrivée : TA 124/78 mmHg')
    expect(prompt).toContain(`« ${EXAM_QUOTE} » (dictée dict-entorse-001, car. `)
    expect(prompt).toContain('retrouvée dans la dictée')
    expect(h.asked[0]!.reason).not.toContain('LTFA') // the audited reason carries ids, no prose

    expect(bridge.writes()).toHaveLength(1)
    const lines = approvals()
    expect(lines.map(l => [l.event, l.decision ?? l.ok])).toEqual([['decision', 'allowed'], ['result', true]])
    expect(lines[0]).toMatchObject({ tool: 'record_apply', draft_id: draftId, patient_id: 'pat-001', answerer: 'dr.test' })
    expect(String(lines[0]!.approval_id)).toMatch(/^apr-/)
    expect(JSON.stringify(lines)).not.toContain('LTFA')
    // The session log carries dsh's own asked/decided pair too.
    expect(h.approvalEvents().map(e => e.type)).toEqual(['approval/asked', 'approval/decided'])
  })

  it.each(['rejected', 'cancelled', 'unavailable'] as const)('on %s the tool does not run and the model reads the refusal', async (outcome) => {
    const h = await setup('ask', outcome)
    const draftId = await draft(h.run)
    const result = await h.run('record_apply', { draft_id: draftId })
    expect(result.isError).toBe(true)
    expect(textOf(result)).toContain(ScribeApproval.REFUSAL)
    expect(textOf(result)).toContain('Rien n\'a été écrit')
    expect(bridge.writes()).toHaveLength(0)
    expect((await bridge.rpc('draft_get', { draft_id: draftId })).result!.status).toBe('drafted')
    expect(approvals().map(l => l.decision)).toEqual([outcome])
  })

  it('with no answerer composed, fails closed (unavailable)', async () => {
    const h = await setup('ask')
    const result = await h.run('record_apply', { draft_id: await draft(h.run) })
    expect(textOf(result)).toContain(ScribeApproval.REFUSAL)
    expect(bridge.writes()).toHaveLength(0)
    expect(approvals().map(l => l.decision)).toEqual(['unavailable'])
  })

  it('with policy never, no answerer is consulted and nothing is written', async () => {
    const h = await setup('never', 'allowed-once')
    const result = await h.run('record_apply', { draft_id: await draft(h.run) })
    expect(textOf(result)).toContain(ScribeApproval.REFUSAL)
    expect(h.asked).toHaveLength(0)
    expect(bridge.writes()).toHaveLength(0)
    expect(approvals()).toMatchObject([{ decision: 'rejected', reason: 'politique never : aucun clinicien consulté' }])
  })

  it('the guard denies a gated call that some other policy allowed without a relayed grant', async () => {
    const h = await setup('ask', 'allowed-once')
    const draftId = await draft(h.run)
    // A hostile or buggy listener placed before ours short-circuits the waterfall with allow.
    h.ctx.on('tools/pre-execute', () => Promise.resolve({ kind: 'allow' as const }), { prepend: true })
    const result = await h.run('record_apply', { draft_id: draftId })
    expect(result.isError).toBe(true)
    expect(textOf(result)).toContain(ScribeApproval.REFUSAL)
    expect(h.asked).toHaveLength(0)
    expect(bridge.writes()).toHaveLength(0)
  })

  it('a failed relay to the bridge turns the human allow into unavailable (no write)', async () => {
    const h = await setup('ask', 'allowed-once')
    const draftId = await draft(h.run)
    process.env[APPROVER_ENV] = 'wrong-approver-token'
    const result = await h.run('record_apply', { draft_id: draftId })
    expect(textOf(result)).toContain(ScribeApproval.REFUSAL)
    expect(bridge.writes()).toHaveLength(0)
    expect(approvals()).toMatchObject([{ decision: 'relay-failed', answerer: 'dr.test' }])
  })

  it('an unknown or already applied draft is refused before asking', async () => {
    const h = await setup('ask', 'allowed-once')
    const unknown = await h.run('record_apply', { draft_id: 'drf-inconnu' })
    expect(textOf(unknown)).toContain(ScribeApproval.REFUSAL)
    const draftId = await draft(h.run)
    await h.run('record_apply', { draft_id: draftId })
    const again = await h.run('record_apply', { draft_id: draftId })
    expect(textOf(again)).toContain('déjà appliqué')
    expect(h.asked).toHaveLength(1)
    expect(bridge.writes()).toHaveLength(1)
  })

  it('record_restore is asked for, relayed and audited the same way', async () => {
    const h = await setup('ask', 'allowed-once')
    const applied = await h.run('record_apply', { draft_id: await draft(h.run) })
    const backupId = (applied.value as { backup_id: string }).backup_id
    const restored = await h.run('record_restore', { backup_id: backupId })
    expect(restored.isError, textOf(restored)).toBe(false)
    expect(textOf(restored)).toContain('Restauré')
    expect(h.asked.map(a => a.toolName)).toEqual(['record_apply', 'record_restore'])
    expect(h.asked[1]!.displayReason!.en).toContain(`Annuler une modification (restauration de la sauvegarde ${backupId})`)
    expect(h.asked[1]!.displayReason!.en).toContain('RETRAIT : « Douleur à la palpation du LTFA droit. »')
    expect(bridge.lines('portal-writes.jsonl').filter(l => l.result === 'ok').map(l => l.event)).toEqual(['apply', 'restore'])
    expect(approvals().filter(l => l.event === 'decision').map(l => [l.tool, l.decision]))
      .toEqual([['record_apply', 'allowed'], ['record_restore', 'allowed']])
  })

  it('a rejected restore leaves the applied text in place', async () => {
    const h = await setup('ask', 'allowed-once')
    const applied = await h.run('record_apply', { draft_id: await draft(h.run) })
    const backupId = (applied.value as { backup_id: string }).backup_id
    h.ctx.on('approval/request', () => Promise.resolve<ApprovalOutcome>('rejected'), { prepend: true })
    const restored = await h.run('record_restore', { backup_id: backupId })
    expect(textOf(restored)).toContain(ScribeApproval.REFUSAL)
    expect(bridge.writes().map(l => l.event)).toEqual(['apply'])
  })

  it('renders a line diff', () => {
    expect(ScribeApproval.lineDiff('a\nb', 'a\nc\nb')).toEqual(['  a', '+ c', '  b'])
    expect(ScribeApproval.lineDiff('', 'x')).toEqual(['+ x'])
    expect(ScribeApproval.lineDiff('x\ny', 'x')).toEqual(['  x', '- y'])
  })
})
