/**
 * `voxlocal-tools`: the agent reads the clinician's dictations.
 *
 * Tools: `dictation_list`, `dictation_get`, `dictation_retranscribe`. They talk
 * to the VoxLocal dictation API (Mac loopback API, or the Python agent API in
 * `--mock` mode). Nothing here writes to a patient record.
 *
 * Secrets: the Bearer token is read from the environment variable named by
 * `tokenEnv` (default `VOXLOCAL_API_TOKEN`) at call time; it never lives in
 * `cordis.yml`. The URL may be interpolated there with `!!js process.env.VOXLOCAL_API_URL`.
 * @module @voxlocal/dsh-voxlocal-tools
 */

import type { Context } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { ToolDefinition } from '@deepseek-ai/dsh-tools'
import { VoxLocalClient, type Dictation } from './client.ts'

export { VoxLocalClient, VoxLocalAPIError, validateApiUrl, type Dictation } from './client.ts'

export const name = 'voxlocal-tools'
export const inject = ['tools']

export interface Config {
  /** VoxLocal dictation API base URL (loopback HTTP, or HTTPS). */
  apiUrl: string
  /** Name of the environment variable that holds the Bearer token. */
  tokenEnv: string
  /** Per-request timeout. */
  timeoutMs: number
  /** Upper bound for `dictation_list.limit`. */
  maxList: number
}

export const Config: Schema<Config> = Schema.object({
  apiUrl: Schema.string().default(process.env.VOXLOCAL_API_URL ?? 'http://127.0.0.1:47367'),
  tokenEnv: Schema.string().default('VOXLOCAL_API_TOKEN'),
  timeoutMs: Schema.number().default(10_000),
  maxList: Schema.number().default(50),
})

const DICTATION_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    id: { type: 'string', required: true },
    timestamp: { type: 'string', required: true },
    deviceName: { type: 'string', required: true },
    modeId: { type: 'string', required: true },
    rawTranscription: { type: 'string', required: true },
    finalTranscription: { type: 'string', required: true },
    processingStatus: { type: 'string', required: true },
    duration: { type: 'number', required: true },
    patientContext: { oneOf: [{ type: 'string' }, { type: 'null' }], required: true },
  },
} as const

const STATUS_FR: Record<string, string> = {
  recording: 'en cours d’enregistrement',
  processing: 'en cours de traitement',
  completed: 'terminée',
  completed_with_warning: 'terminée avec avertissement',
  error: 'en erreur',
  interrupted: 'interrompue',
}

/** "1 min 05 s" / "12 s". */
export function formatDuration(seconds: number): string {
  const total = Math.max(0, Math.round(seconds))
  const minutes = Math.floor(total / 60)
  const rest = total % 60
  return minutes > 0 ? `${minutes} min ${String(rest).padStart(2, '0')} s` : `${rest} s`
}

function headline(d: Dictation): string {
  const patient = d.patientContext ? ` · patient : ${d.patientContext}` : ' · aucun patient déclaré'
  return `Dictée ${d.id} (${formatDuration(d.duration)}, ${d.deviceName}, ${STATUS_FR[d.processingStatus] ?? d.processingStatus})${patient}`
}

/** Pure: pick the page a list call returns. */
export function page(all: Dictation[], since: string | undefined, limit: number): { dictations: Dictation[], hasMore: boolean } {
  // After a cursor, the oldest unread come first so the agent can page forward;
  // without one, the most recent `limit` (still oldest first).
  const dictations = since ? all.slice(0, limit) : all.slice(Math.max(0, all.length - limit))
  return { dictations, hasMore: all.length > dictations.length }
}

export function createTools(client: VoxLocalClient, config: Pick<Config, 'maxList'>): ToolDefinition[] {
  const list = defineTool({
    name: 'dictation_list',
    description: 'Liste les dictées du clinicien (texte final nettoyé, durée, patient déclaré). Sans « since » : les plus récentes. Avec « since » : celles postérieures à cet identifiant, de la plus ancienne à la plus récente. Lecture seule.',
    parameters: {
      since: { type: 'string', description: 'Identifiant de la dernière dictée déjà lue.' },
      limit: { type: 'integer', description: `Nombre maximum de dictées (1 à ${config.maxList}, défaut 10).` },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          dictations: { type: 'array', items: DICTATION_SCHEMA, required: true },
          hasMore: { type: 'boolean', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.dictations.length === 0
          ? 'Aucune dictée à lire.'
          : [
              `${value.dictations.length} dictée(s)${value.hasMore ? ' (d’autres restent à lire)' : ''} :`,
              ...value.dictations.map(d => `- ${headline(d)}\n  ${d.finalTranscription || '(texte vide)'}`),
            ].join('\n'),
      }],
    },
    isConcurrencySafe: () => true,
    presentCall: args => ({ card: 'generic', kind: 'read', title: args.since ? `Dictées après ${args.since}` : 'Dernières dictées' }),
    async execute(args, exec) {
      const limit = args.limit ?? 10
      if (!Number.isInteger(limit) || limit < 1 || limit > config.maxList) throw new Error(`limit doit être compris entre 1 et ${config.maxList}.`)
      const all = await client.list(args.since || undefined, exec.signal)
      return page(all, args.since || undefined, limit)
    },
  })

  const get = defineTool({
    name: 'dictation_get',
    description: 'Lit une dictée par son identifiant : transcription brute, texte final nettoyé, durée, appareil, patient déclaré. Lecture seule.',
    parameters: {
      id: { type: 'string', required: true, description: 'Identifiant de la dictée.' },
    },
    output: {
      schema: DICTATION_SCHEMA,
      render: (_args, d) => [{
        type: 'text',
        text: `${headline(d)}\nTexte final :\n${d.finalTranscription || '(vide)'}\n\nTranscription brute :\n${d.rawTranscription || '(vide)'}`,
      }],
    },
    isConcurrencySafe: () => true,
    presentCall: args => ({ card: 'generic', kind: 'read', title: `Dictée ${args.id}` }),
    async execute(args, exec) {
      if (!args.id.trim()) throw new Error('id ne peut pas être vide.')
      return client.get(args.id, exec.signal)
    },
  })

  const retranscribe = defineTool({
    name: 'dictation_retranscribe',
    description: 'Relance la transcription et le nettoyage d’une dictée à partir de son audio conservé sur le Mac (utile si le texte est vide ou en erreur). Ne touche à aucun dossier patient ; relire ensuite avec dictation_get.',
    parameters: {
      id: { type: 'string', required: true, description: 'Identifiant de la dictée.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: { id: { type: 'string', required: true }, status: { type: 'string', required: true } },
      },
      render: (_args, value) => [{ type: 'text', text: `Retranscription de la dictée ${value.id} lancée (${STATUS_FR[value.status] ?? value.status}). Relisez-la avec dictation_get dans quelques secondes.` }],
    },
    presentCall: args => ({ card: 'generic', kind: 'read', title: `Retranscrire la dictée ${args.id}` }),
    async execute(args, exec) {
      if (!args.id.trim()) throw new Error('id ne peut pas être vide.')
      return client.retranscribe(args.id, exec.signal)
    },
  })

  return [list, get, retranscribe]
}

export function apply(ctx: Context, config: Config) {
  const client = new VoxLocalClient({ apiUrl: config.apiUrl, token: () => process.env[config.tokenEnv], timeoutMs: config.timeoutMs })
  for (const tool of createTools(client, config)) ctx.tools.register(tool)
}
