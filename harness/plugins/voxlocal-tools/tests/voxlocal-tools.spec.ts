import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import type { ToolDefinition, ToolRunContext } from '@deepseek-ai/dsh-tools'
import { apply, createTools, formatDuration, page, validateApiUrl, VoxLocalAPIError, VoxLocalClient, type Dictation } from '../src/index.ts'

const TOKEN = 'stub-token-0123456789abcdef'

function dictation(n: number, extra: Partial<Dictation> = {}): Dictation {
  return {
    id: `d-${n}`, timestamp: `2026-09-25T08:0${n}:00Z`, deviceName: 'iPhone du poste 3', modeId: 'medical',
    rawTranscription: `brut ${n}`, finalTranscription: `Texte ${n}.`, processingStatus: 'completed', duration: 65,
    patientContext: null, ...extra,
  }
}

/** Stub of the VoxLocal API: same envelope and routes as LocalAPI.swift. */
let records: Dictation[] = []
const calls: string[] = []
let server: Server
let base: string

function send(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(body))
}

function handle(req: IncomingMessage, res: ServerResponse) {
  calls.push(`${req.method} ${req.url}`)
  if (req.headers.authorization !== `Bearer ${TOKEN}`) return send(res, 401, { ok: false, error: { code: 'unauthorized', message: 'Bearer token requis.' } })
  const url = new URL(req.url ?? '/', 'http://stub')
  const parts = url.pathname.split('/').filter(Boolean)
  if (req.method === 'GET' && url.pathname === '/v1/dictations') {
    const since = url.searchParams.get('since')
    if (since && !records.some(r => r.id === since)) return send(res, 404, { ok: false, error: { code: 'since_not_found', message: 'Dictée « since » introuvable.' } })
    const after = since ? records.slice(records.findIndex(r => r.id === since) + 1) : records
    return send(res, 200, { ok: true, data: { dictations: after } })
  }
  if (req.method === 'GET' && parts.length === 3) {
    const found = records.find(r => r.id === decodeURIComponent(parts[2]!))
    return found ? send(res, 200, { ok: true, data: found }) : send(res, 404, { ok: false, error: { code: 'not_found', message: 'Dictée introuvable.' } })
  }
  if (req.method === 'POST' && parts[3] === 'retranscribe') return send(res, 202, { ok: true, data: { id: parts[2], status: 'processing' } })
  send(res, 404, { ok: false, error: { code: 'not_found', message: 'Endpoint inconnu.' } })
}

beforeAll(async () => {
  server = createServer(handle)
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})
afterAll(() => new Promise<void>(resolve => server.close(() => resolve())))
beforeEach(() => { records = [dictation(1), dictation(2, { patientContext: 'Patient fictif, chambre 12' }), dictation(3)]; calls.length = 0 })

const exec = { signal: new AbortController().signal } as unknown as ToolRunContext

function tools(token: string | null = TOKEN): Record<string, ToolDefinition> {
  const client = new VoxLocalClient({ apiUrl: base, token: () => token ?? undefined, timeoutMs: 2000 })
  return Object.fromEntries(createTools(client, { maxList: 50 }).map(t => [t.name, t]))
}

function text(tool: ToolDefinition, args: unknown, value: unknown): string {
  return tool.output.render(args, value as never).map(block => (block as { text: string }).text).join('')
}

describe('voxlocal-tools', () => {
  it('registers the three dictation tools through ctx.tools', () => {
    const registered: string[] = []
    apply({ tools: { register: (t: ToolDefinition) => registered.push(t.name) } } as never,
      { apiUrl: 'http://127.0.0.1:47367', tokenEnv: 'VOXLOCAL_API_TOKEN', timeoutMs: 1000, maxList: 50 })
    expect(registered).toEqual(['dictation_list', 'dictation_get', 'dictation_retranscribe'])
  })

  it('dictation_list sends since and renders a French summary', async () => {
    const { dictation_list: list } = tools()
    const value = await list!.execute({ since: 'd-1' }, exec) as { dictations: Dictation[], hasMore: boolean }
    expect(calls).toEqual(['GET /v1/dictations?since=d-1'])
    expect(value.dictations.map(d => d.id)).toEqual(['d-2', 'd-3'])
    expect(value.hasMore).toBe(false)
    const rendered = text(list!, { since: 'd-1' }, value)
    expect(rendered).toContain('2 dictée(s)')
    expect(rendered).toContain('Dictée d-2 (1 min 05 s, iPhone du poste 3, terminée) · patient : Patient fictif, chambre 12')
    expect(rendered).toContain('aucun patient déclaré')
  })

  it('dictation_list without since keeps the most recent, oldest first, and bounds limit', async () => {
    const { dictation_list: list } = tools()
    const value = await list!.execute({ limit: 2 }, exec) as { dictations: Dictation[], hasMore: boolean }
    expect(value.dictations.map(d => d.id)).toEqual(['d-2', 'd-3'])
    expect(value.hasMore).toBe(true)
    await expect(list!.execute({ limit: 0 }, exec)).rejects.toThrow('limit doit être compris entre 1 et 50')
    expect(text(list!, {}, { dictations: [], hasMore: false })).toBe('Aucune dictée à lire.')
  })

  it('dictation_get returns the canonical record, without any audio field', async () => {
    const { dictation_get: get } = tools()
    const value = await get!.execute({ id: 'd-2' }, exec) as Dictation
    expect(Object.keys(value).sort()).toEqual(['deviceName', 'duration', 'finalTranscription', 'id', 'modeId', 'patientContext', 'processingStatus', 'rawTranscription', 'timestamp'])
    expect(text(get!, { id: 'd-2' }, value)).toContain('Texte final :\nTexte 2.')
    await expect(get!.execute({ id: 'absent' }, exec)).rejects.toMatchObject({ code: 'not_found' })
    await expect(get!.execute({}, exec)).rejects.toThrow()
  })

  it('dictation_retranscribe posts to the retranscribe route', async () => {
    const { dictation_retranscribe: retranscribe } = tools()
    const value = await retranscribe!.execute({ id: 'd-3' }, exec)
    expect(calls).toEqual(['POST /v1/dictations/d-3/retranscribe'])
    expect(text(retranscribe!, { id: 'd-3' }, value)).toContain('Retranscription de la dictée d-3 lancée')
  })

  it('surfaces auth failures with the API code and a French hint when the token is missing', async () => {
    await expect(tools('wrong-token-wrong-token')['dictation_list']!.execute({}, exec)).rejects.toMatchObject({ code: 'unauthorized', status: 401 })
    await expect(tools(null)['dictation_list']!.execute({}, exec)).rejects.toBeInstanceOf(VoxLocalAPIError)
    await expect(tools(null)['dictation_list']!.execute({}, exec)).rejects.toThrow('VOXLOCAL_API_TOKEN')
  })

  it('presents read cards', () => {
    const all = tools()
    expect(all['dictation_list']!.presentCall!({ since: 'd-1' })).toEqual({ card: 'generic', kind: 'read', title: 'Dictées après d-1' })
    expect(all['dictation_get']!.presentCall!({ id: 'd-2' })).toMatchObject({ card: 'generic', kind: 'read' })
    expect(all['dictation_retranscribe']!.presentCall!({ id: 'd-2' })).toMatchObject({ card: 'generic', kind: 'read' })
  })

  it('refuses plain HTTP to a non-loopback host', () => {
    expect(validateApiUrl('http://127.0.0.1:47367/')).toBe('http://127.0.0.1:47367')
    expect(() => validateApiUrl('http://10.0.0.8:47367')).toThrow('HTTP est réservé')
    expect(validateApiUrl('https://scribe.example')).toBe('https://scribe.example')
  })

  it('formats durations and pages', () => {
    expect(formatDuration(12.4)).toBe('12 s')
    expect(formatDuration(125)).toBe('2 min 05 s')
    expect(page(records, 'd-1', 1)).toEqual({ dictations: [records[0]], hasMore: true })
  })
})
