/**
 * portail-tools plugin: tool surface, bridge calls, card presenters.
 *
 * Part 1 runs against an in-process stub bridge (records every JSON-RPC call).
 * Part 2 runs the real Python bridge (mock backend) to prove the TS/Python contract.
 *
 * Run: cd harness/plugins/portail-tools && pnpm test
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { mount, PortailTools } from '../plugins/portail-tools/tests/runtime.ts'

const TOKEN_ENV = 'PORTAIL_TOOLS_TEST_TOKEN'
const TOOL_TOKEN = 'tool-token-for-tests-0123456789'
const APPROVER_TOKEN = 'approver-token-for-tests-9876543210'
const ITEM = '1f19a001-aaaa-4000-8000-000000000101'
const QUOTE = { dictation_id: 'dict-entorse-001', offset: 0, text: 'Critères d\'Ottawa négatifs' }

type Rpc = { method: string, params: Record<string, unknown>, auth: string | undefined }

/** In-process stub of the bridge: canned results per method, every call recorded. */
class StubBridge {
  calls: Rpc[] = []
  handlers: Record<string, (params: Record<string, unknown>) => { result?: unknown, error?: { code: number, message: string } }> = {}
  private server!: Server
  url = ''

  async start() {
    this.server = createServer((req, res) => {
      let body = ''
      req.on('data', c => { body += c })
      req.on('end', () => {
        const msg = JSON.parse(body) as { id: number, method: string, params: Record<string, unknown> }
        this.calls.push({ method: msg.method, params: msg.params, auth: req.headers.authorization })
        const handler = this.handlers[msg.method]
        const out = handler ? handler(msg.params) : { error: { code: -32601, message: 'Method not found' } }
        res.setHeader('Content-Type', 'application/json')
        res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, ...out }))
      })
    })
    await new Promise<void>(r => this.server.listen(0, '127.0.0.1', r))
    this.url = `http://127.0.0.1:${(this.server.address() as AddressInfo).port}/`
  }

  async stop() {
    await new Promise<void>(r => this.server.close(() => r()))
  }

  methods() {
    return this.calls.map(c => c.method)
  }
}

const draftResult = {
  draft_id: 'drf-0001', status: 'drafted', patient_id: 'pat-001', encounter_id: 'enc-001-urg',
  item_id: ITEM, attribute: 'physical-exam-text', mode: 'append', quotes_verified: true,
  base_digest: 'aaaa', final_text_digest: 'bbbb', base_text: 'Avant.', final_text: 'Avant.\nOttawa négatif.',
}
const applyResult = {
  draft_id: 'drf-0001', kind: 'edit', replayed: false, item_id: ITEM, attribute: 'physical-exam-text',
  version_before: 3, version_after: 4, readback_digest: 'bbbb', backup_id: 'bak-1', verified: true,
  base_text: 'Avant.', final_text: 'Avant.\nOttawa négatif.',
}

function textOf(result: { content: Array<{ type: string, text?: string }> }): string {
  return result.content.map(b => b.text ?? '').join('\n')
}

describe('portail-tools against a stub bridge', () => {
  const stub = new StubBridge()
  let tools: Awaited<ReturnType<typeof mount>>

  beforeAll(async () => {
    await stub.start()
    process.env[TOKEN_ENV] = TOOL_TOKEN
  })
  afterAll(async () => {
    await stub.stop()
    delete process.env[TOKEN_ENV]
  })
  beforeEach(async () => {
    stub.calls = []
    stub.handlers = {
      resolve_patient: () => ({ result: [{ patient_id: 'pat-001', tpms: 'TPMS-900001', display_name: 'MARTIN Lucas', birth_date: '2003-04-12', sex: 'M', ehr_id: 'e' }] }),
      draft_create: () => ({ result: draftResult }),
      apply: () => ({ result: applyResult }),
      draft_restore: () => ({ result: { ...draftResult, draft_id: 'drf-0002', kind: 'restore' } }),
      restore: () => ({ result: { draft_id: 'drf-0002', kind: 'restore', replayed: false, restored: true, item_id: ITEM, attribute: 'physical-exam-text', version_before: 4, version_after: 5, readback_digest: 'aaaa', base_text: 'Avant.\nOttawa négatif.', final_text: 'Avant.' } }),
    }
    tools = await mount({ bridgeUrl: stub.url, tokenEnv: TOKEN_ENV, timeoutMs: 5_000 })
  })

  it('registers the seven tools with French descriptions', () => {
    const names = Object.values(PortailTools.TOOL_NAMES)
    expect(names).toEqual(['patient_resolve', 'patient_read', 'record_find_sections', 'record_read_section', 'record_draft_edit', 'record_apply', 'record_restore'])
    for (const n of names) {
      const tool = tools.tool(n)
      expect(tool, n).toBeDefined()
      expect(tool.description).toMatch(/[éèàç]|\b(le|la|les|un|une|du|des)\b/)
    }
  })

  it('exposes the draft schema the plan requires', () => {
    const params = tools.tool('record_draft_edit').parameters as { properties: Record<string, { enum?: string[] }>, required: string[] }
    expect(Object.keys(params.properties)).toEqual(expect.arrayContaining(['item_id', 'attribute', 'mode', 'new_text', 'rationale', 'quotes', 'patient_id', 'encounter_id']))
    expect(params.required).toEqual(expect.arrayContaining(['patient_id', 'encounter_id', 'item_id', 'attribute', 'mode', 'new_text', 'rationale', 'quotes']))
    expect(params.properties.mode!.enum).toEqual(['append', 'replace'])
    expect(params.properties.attribute!.enum).toHaveLength(8)
  })

  it('sends the tool-side bearer token and JSON-RPC params', async () => {
    const r = await tools.run('patient_resolve', { query: 'martin' })
    expect(r.isError).toBe(false)
    expect(textOf(r)).toContain('patient_id=pat-001')
    expect(stub.calls).toEqual([{ method: 'resolve_patient', params: { query: 'martin' }, auth: `Bearer ${TOOL_TOKEN}` }])
  })

  it('record_draft_edit stores the draft in the bridge, not locally, and returns its id', async () => {
    const args = { patient_id: 'pat-001', encounter_id: 'enc-001-urg', item_id: ITEM, attribute: 'physical-exam-text', mode: 'append', new_text: 'Ottawa négatif.', rationale: 'examen dicté', quotes: [QUOTE] }
    const r = await tools.run('record_draft_edit', args)
    expect(r.isError).toBe(false)
    expect(r.value).toMatchObject({ draft_id: 'drf-0001', status: 'drafted' })
    expect(stub.methods()).toEqual(['draft_create'])
    expect(stub.calls[0]!.params).toEqual(args)
    expect(textOf(r)).toContain('rien n\'est écrit dans le portail')
    expect(r.meta).toEqual({ path: `portail://${ITEM}#physical-exam-text`, oldText: 'Avant.', newText: 'Avant.\nOttawa négatif.' })
  })

  it('record_draft_edit refuses malformed drafts before reaching the bridge', async () => {
    const base = { patient_id: 'pat-001', encounter_id: 'enc-001-urg', item_id: ITEM, attribute: 'physical-exam-text', new_text: 'x', rationale: 'r', quotes: [QUOTE] }
    const replaceWithoutOld = await tools.run('record_draft_edit', { ...base, mode: 'replace' })
    const noQuotes = await tools.run('record_draft_edit', { ...base, mode: 'append', quotes: [] })
    const badAttribute = await tools.run('record_draft_edit', { ...base, mode: 'append', attribute: 'title' })
    const badMode = await tools.run('record_draft_edit', { ...base, mode: 'overwrite' })
    for (const r of [replaceWithoutOld, noQuotes, badAttribute, badMode]) expect(r.isError).toBe(true)
    expect(textOf(replaceWithoutOld)).toContain('old')
    expect(stub.calls).toEqual([])
  })

  it('record_apply calls bridge apply with the draft id only', async () => {
    const r = await tools.run('record_apply', { draft_id: 'drf-0001' })
    expect(r.isError).toBe(false)
    expect(stub.calls.map(c => [c.method, c.params])).toEqual([['apply', { draft_id: 'drf-0001' }]])
    expect(textOf(r)).toContain('version 3 → 4')
  })

  it('a bridge 403 (no approval) comes back as a French tool error', async () => {
    stub.handlers.apply = () => ({ error: { code: 403, message: 'aucun feu vert pour ce brouillon : application refusée' } })
    const r = await tools.run('record_apply', { draft_id: 'drf-0001' })
    expect(r.isError).toBe(true)
    expect(textOf(r)).toContain('Pont portail (403)')
    expect(textOf(r)).toContain('Aucun feu vert')
  })

  it('a bridge 409 (live text changed) tells the model to re-read', async () => {
    stub.handlers.apply = () => ({ error: { code: 409, message: 'la section a changé depuis le brouillon' } })
    const r = await tools.run('record_apply', { draft_id: 'drf-0001' })
    expect(r.isError).toBe(true)
    expect(textOf(r)).toContain('Relire la section')
  })

  it('record_restore drafts the restore then asks the bridge to restore', async () => {
    const r = await tools.run('record_restore', { backup_id: 'bak-1' })
    expect(r.isError).toBe(false)
    expect(stub.methods()).toEqual(['draft_restore', 'restore'])
    expect(textOf(r)).toContain('Restauré')
  })

  it('record_apply result renders as a diff card (old/new text)', async () => {
    const tool = tools.tool('record_apply')
    const r = await tools.run('record_apply', { draft_id: 'drf-0001' })
    expect(tool.presentResult!({ draft_id: 'drf-0001' }, r as never)).toEqual({
      card: 'diff',
      title: 'Modification appliquée au portail',
      diffs: [{ path: `portail://${ITEM}#physical-exam-text`, oldText: 'Avant.', newText: 'Avant.\nOttawa négatif.' }],
    })
    expect(tool.presentResult!({ draft_id: 'x' }, { isError: true, content: [] } as never)).toBeUndefined()
    expect(tool.presentResult!({ draft_id: 'x' }, { isError: false, content: [], meta: { junk: 1 } } as never)).toBeUndefined()
  })

  it('record_draft_edit presents its pending call as a diff card', () => {
    const view = tools.tool('record_draft_edit').presentCall!({ patient_id: 'p', encounter_id: 'e', item_id: ITEM, attribute: 'disposition', mode: 'replace', old: 'EVA 6/10', new_text: 'EVA 5/10', rationale: 'r', quotes: [QUOTE] })
    expect(view).toEqual({ card: 'diff', title: 'Brouillon de remplacement : disposition', diffs: [{ path: `portail://${ITEM}#disposition`, oldText: 'EVA 6/10', newText: 'EVA 5/10' }] })
  })

  it('fails closed without a token and refuses a non-loopback bridge', async () => {
    delete process.env[TOKEN_ENV]
    try {
      const r = await tools.run('patient_resolve', { query: 'martin' })
      expect(r.isError).toBe(true)
      expect(textOf(r)).toContain(TOKEN_ENV)
      expect(stub.calls).toEqual([])
    } finally {
      process.env[TOKEN_ENV] = TOOL_TOKEN
    }
    expect(() => new PortailTools.BridgeClient({ url: 'http://10.0.0.5:47368/', tokenEnv: TOKEN_ENV, timeoutMs: 1000 })).toThrow(/boucle locale/)
  })
})

describe('portail-tools against the real Python bridge (mock backend)', () => {
  const repo = resolve(import.meta.dirname, '../..')
  let dir: string
  let proc: ChildProcess
  let url: string
  let tools: Awaited<ReturnType<typeof mount>>

  beforeAll(async () => {
    dir = mkdtempSync(join(tmpdir(), 'portail-tools-e2e-'))
    proc = spawn('python3', ['-m', 'harness.bridge.portail_bridge', '--port', '0', '--backend', 'mock'], {
      cwd: repo,
      env: {
        ...process.env,
        PORTAIL_BRIDGE_TOKEN: TOOL_TOKEN,
        PORTAIL_BRIDGE_APPROVER_TOKEN: APPROVER_TOKEN,
        PORTAIL_BRIDGE_DRAFTS: join(dir, 'drafts.jsonl'),
        PORTAIL_BRIDGE_AUDIT: join(dir, 'audit.jsonl'),
        PORTAIL_BRIDGE_STATE_DIR: join(dir, 'state'),
      },
      stdio: ['ignore', 'ignore', 'pipe'],
    })
    url = await new Promise<string>((ok, fail) => {
      let err = ''
      proc.stderr!.on('data', (c: Buffer) => {
        err += c.toString()
        const m = /http:\/\/127\.0\.0\.1:(\d+)/.exec(err)
        if (m) ok(`http://127.0.0.1:${m[1]}/`)
      })
      proc.on('exit', code => fail(new Error(`bridge exited ${code}: ${err}`)))
    })
    process.env[TOKEN_ENV] = TOOL_TOKEN
    tools = await mount({ bridgeUrl: url, tokenEnv: TOKEN_ENV, timeoutMs: 5_000 })
  })
  afterAll(() => {
    proc?.kill()
    delete process.env[TOKEN_ENV]
    rmSync(dir, { recursive: true, force: true })
  })
  afterEach(() => { process.env[TOKEN_ENV] = TOOL_TOKEN })

  async function approve(draftId: string, token = APPROVER_TOKEN) {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'approve_draft', params: { draft_id: draftId, answerer: 'dr.test' } }),
    })
    return res.json() as Promise<{ result?: unknown, error?: { code: number } }>
  }

  it('drafts, is refused without approval, applies once approved, and restores', async () => {
    const found = await tools.run('record_find_sections', { patient_id: 'pat-001', query: 'EVA' })
    expect(found.isError).toBe(false)
    const loc = (found.value as Array<{ item_id: string, encounter_id: string, attribute: string, digest: string }>)[0]!
    expect(loc).toMatchObject({ item_id: ITEM, encounter_id: 'enc-001-urg', attribute: 'physical-exam-text' })

    const draft = await tools.run('record_draft_edit', {
      patient_id: 'pat-001', encounter_id: loc.encounter_id, item_id: loc.item_id, attribute: loc.attribute,
      mode: 'append', new_text: 'Critères d\'Ottawa négatifs.', rationale: 'examen dicté', quotes: [QUOTE], base_digest: loc.digest,
    })
    expect(draft.isError, textOf(draft)).toBe(false)
    const draftId = (draft.value as { draft_id: string }).draft_id

    const refused = await tools.run('record_apply', { draft_id: draftId })
    expect(refused.isError).toBe(true)
    expect(textOf(refused)).toContain('(403)')

    expect((await approve(draftId, TOOL_TOKEN)).error?.code).toBe(403) // the tool token cannot approve
    expect((await approve(draftId)).result).toMatchObject({ status: 'approved' })

    const applied = await tools.run('record_apply', { draft_id: draftId })
    expect(applied.isError, textOf(applied)).toBe(false)
    expect(applied.value).toMatchObject({ replayed: false, version_before: 3, version_after: 4 })
    const card = tools.tool('record_apply').presentResult!({ draft_id: draftId }, applied as never) as { card: string, diffs: Array<{ oldText: string, newText: string }> }
    expect(card.card).toBe('diff')
    expect(card.diffs[0]!.newText).toBe(`${card.diffs[0]!.oldText}\nCritères d'Ottawa négatifs.`)

    const replay = await tools.run('record_apply', { draft_id: draftId })
    expect(replay.value).toMatchObject({ replayed: true, version_after: 4 })

    const backupId = (applied.value as { backup_id: string }).backup_id
    const restoreRefused = await tools.run('record_restore', { backup_id: backupId })
    expect(restoreRefused.isError).toBe(true)
    expect(textOf(restoreRefused)).toContain('(403)')
    const restoreDraft = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${TOOL_TOKEN}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'draft_restore', params: { backup_id: backupId } }),
    }).then(r => r.json()) as { result: { draft_id: string } }
    expect((await approve(restoreDraft.result.draft_id)).result).toMatchObject({ status: 'approved' })
    const restored = await tools.run('record_restore', { backup_id: backupId })
    expect(restored.isError, textOf(restored)).toBe(false)
    expect(restored.value).toMatchObject({ restored: true, version_after: 5 })

    const after = await tools.run('record_read_section', { item_id: ITEM, attribute: 'physical-exam-text' })
    expect((after.value as { digest: string }).digest).toBe(loc.digest)

    const audit = readFileSync(join(dir, 'audit.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l) as { event: string, result: string })
    expect(audit.map(a => `${a.event}:${a.result}`)).toEqual(['apply:refused', 'apply:ok', 'restore:refused', 'restore:ok'])
  })
})
