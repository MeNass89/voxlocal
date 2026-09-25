/**
 * Model-facing `patient_*` and `record_*` tools of the VoxLocal scribe. Every call goes to the
 * portal bridge (loopback JSON-RPC, tool-side token). The bridge stores drafts and is the only
 * place a write can happen; it refuses `apply` and `restore` until a human approval reached it
 * over the separate approver credential (plan Amendment 1). These tools therefore prepare,
 * they never decide: `record_draft_edit` stores a draft, `record_apply` asks the bridge to
 * write an approved one.
 * @module @voxlocal/portail-tools
 */

import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { DiffCallView, DiffResultView, GenericCallView, ToolResult } from '@deepseek-ai/dsh-tools'
import { BridgeClient, BridgeError } from './bridge.ts'

export { BridgeClient, BridgeError } from './bridge.ts'
export type { BridgeOptions } from './bridge.ts'

export const name = 'portail-tools'
export const inject = ['tools']

/** Plugin configuration. */
export interface Config {
  /** Bridge endpoint; must be loopback. */
  bridgeUrl?: string
  /** Environment variable holding the tool-side bearer token. */
  tokenEnv?: string
  /** Per-call deadline in milliseconds. */
  timeoutMs?: number
}

export const Config: z<Config> = z.object({
  bridgeUrl: z.string().default('http://127.0.0.1:47368/'),
  tokenEnv: z.string().default('PORTAIL_BRIDGE_TOKEN'),
  timeoutMs: z.natural().default(15_000),
})

/** The 8 narrative sections that render in the clinician's view (portail.records). */
export const NARRATIVE_SECTIONS = [
  'current-affliction',
  'main-problem-history',
  'physical-exam-text',
  'systematic-review-text',
  'text-evolution',
  'text-conclusion',
  'disposition',
  'other-risk-text',
] as const

/** Tool names, for policy plugins (H4 gates `record_apply` and `record_restore`). */
export const TOOL_NAMES = {
  patientResolve: 'patient_resolve',
  patientRead: 'patient_read',
  findSections: 'record_find_sections',
  readSection: 'record_read_section',
  draftEdit: 'record_draft_edit',
  apply: 'record_apply',
  restore: 'record_restore',
} as const

// ------------------------------------------------------------------------ schemas
const text = (description: string) => ({ type: 'string', description }) as const
const openObject = { type: 'object', additionalProperties: true } as const

const patientSchema = {
  type: 'object',
  additionalProperties: true,
  properties: {
    patient_id: { type: 'string', required: true },
    tpms: { type: 'string', required: true },
    display_name: { type: 'string', required: true },
    birth_date: { type: 'string', required: true },
    sex: { type: 'string', required: true },
  },
} as const

const locationSchema = {
  type: 'object',
  additionalProperties: true,
  properties: {
    item_id: { type: 'string', required: true },
    encounter_id: { type: 'string', required: true },
    attribute: { type: 'string', required: true },
    label: { type: 'string', required: true },
    current_text: { type: 'string', required: true },
    version: { type: 'integer', required: true },
    digest: { type: 'string', required: true },
  },
} as const

const sectionSchema = {
  type: 'object',
  additionalProperties: true,
  properties: {
    patient_id: { type: 'string', required: true },
    item_id: { type: 'string', required: true },
    encounter_id: { oneOf: [{ type: 'string' }, { type: 'null' }], required: true },
    filed: { type: 'boolean', required: true },
    attribute: { type: 'string', required: true },
    text: { type: 'string', required: true },
    version: { type: 'integer', required: true },
    digest: { type: 'string', required: true },
  },
} as const

const quoteSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    dictation_id: text('Identifiant de la dictée citée.'),
    offset: { type: 'integer', description: 'Position (caractères) de la citation dans la dictée.' },
    text: text('Extrait exact de la dictée, mot pour mot.'),
  },
} as const

const draftSchema = {
  type: 'object',
  additionalProperties: true,
  properties: {
    draft_id: { type: 'string', required: true },
    status: { type: 'string', required: true },
    patient_id: { type: 'string', required: true },
    encounter_id: { type: 'string', required: true },
    item_id: { type: 'string', required: true },
    attribute: { type: 'string', required: true },
    mode: { type: 'string', required: true },
    quotes_verified: { type: 'boolean', required: true },
    base_digest: { type: 'string', required: true },
    final_text_digest: { type: 'string', required: true },
    base_text: { type: 'string', required: true },
    final_text: { type: 'string', required: true },
  },
} as const

const writeSchema = {
  type: 'object',
  additionalProperties: true,
  properties: {
    draft_id: { type: 'string', required: true },
    replayed: { type: 'boolean', required: true },
    item_id: { type: 'string', required: true },
    attribute: { type: 'string', required: true },
    version_before: { type: 'integer', required: true },
    version_after: { type: 'integer', required: true },
    readback_digest: { type: 'string', required: true },
    backup_id: { type: 'string' },
    base_text: { type: 'string', required: true },
    final_text: { type: 'string', required: true },
  },
} as const

// ------------------------------------------------------------------------ helpers
function nonEmpty(value: string, field: string): void {
  if (value.trim() === '') throw new Error(`${field} : texte non vide attendu`)
}

/** Bridge refusals reach the model as plain French with the status it can act on. */
function explain(error: unknown): never {
  if (error instanceof BridgeError) {
    const hint = error.code === 403
      ? ' Aucun feu vert du clinicien pour cette écriture.'
      : error.code === 409
        ? ' Relire la section puis refaire le brouillon.'
        : ''
    throw new Error(`Pont portail (${error.code}) : ${error.message}.${hint}`)
  }
  throw error
}

function sectionPath(itemId: string, attribute: string): string {
  return `portail://${itemId}#${attribute}`
}

/** Replayable diff metadata, derived from the canonical value only. */
function diffMeta(value: { item_id: string, attribute: string, base_text: string, final_text: string }) {
  return { path: sectionPath(value.item_id, value.attribute), oldText: value.base_text, newText: value.final_text }
}

/** Completed diff card from persisted metadata; malformed replay metadata falls back to generic. */
function diffResult(title: string, result: ToolResult): DiffResultView | undefined {
  if (result.isError) return undefined
  const meta = result.meta as { path?: unknown, oldText?: unknown, newText?: unknown } | undefined
  if (typeof meta?.path !== 'string' || typeof meta.oldText !== 'string' || typeof meta.newText !== 'string') return undefined
  return { card: 'diff', title, diffs: [{ path: meta.path, oldText: meta.oldText, newText: meta.newText }] }
}

// ------------------------------------------------------------------------ plugin
export function apply(ctx: Context, config: Config = {}) {
  const bridge = new BridgeClient({
    url: config.bridgeUrl ?? 'http://127.0.0.1:47368/',
    tokenEnv: config.tokenEnv ?? 'PORTAIL_BRIDGE_TOKEN',
    timeoutMs: config.timeoutMs ?? 15_000,
  })
  const call = <T>(method: string, params: Record<string, unknown>, signal: AbortSignal) =>
    bridge.call<T>(method, params, signal).catch(explain)

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.patientResolve,
    description: 'Rechercher un patient dans le portail par nom, identifiant TPMS ou date de naissance. '
      + 'Renvoie les patients correspondants avec leur patient_id. Lecture seule.',
    parameters: {
      query: { type: 'string', required: true, description: 'Nom, TPMS ou date de naissance (AAAA-MM-JJ).' },
    },
    output: {
      schema: { type: 'array', items: patientSchema },
      render: (args, value) => [{
        type: 'text',
        text: value.length === 0
          ? `Aucun patient trouvé pour « ${args.query} ».`
          : value.map(p => `- ${p.display_name} (${p.sex}, né·e le ${p.birth_date}) : patient_id=${p.patient_id}, TPMS=${p.tpms}`).join('\n'),
      }],
    },
    async execute(args, exec) {
      nonEmpty(args.query, 'query')
      return call('resolve_patient', { query: args.query }, exec.signal)
    },
    presentCall: (args): GenericCallView => ({ card: 'generic', title: `Recherche patient : ${args.query}`, kind: 'search' }),
  }))

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.patientRead,
    description: 'Lire les données structurées d\'un patient (allergies, antécédents, traitements en cours) '
      + 'depuis le sous-ensemble FHIR du portail. Lecture seule.',
    parameters: {
      patient_id: { type: 'string', required: true, description: 'patient_id renvoyé par patient_resolve.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          patient: { ...openObject, required: true },
          allergies: { type: 'array', items: { type: 'json' }, required: true },
          conditions: { type: 'array', items: { type: 'json' }, required: true },
          medications: { type: 'array', items: { type: 'json' }, required: true },
        },
      },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value, null, 2) }],
    },
    async execute(args, exec) {
      nonEmpty(args.patient_id, 'patient_id')
      return call('read_patient', { patient_id: args.patient_id }, exec.signal)
    },
    presentCall: (args): GenericCallView => ({ card: 'generic', title: `Dossier patient ${args.patient_id}`, kind: 'read' }),
  }))

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.findSections,
    description: 'Lister les sections narratives éditables du patient (anamnèse, examen clinique, conclusion, '
      + 'orientation…) dans ses documents classés sous une rencontre, avec le texte actuel, la version et l\'empreinte. '
      + 'Seules ces sections sont visibles par le clinicien. Filtre optionnel par texte. Lecture seule.',
    parameters: {
      patient_id: { type: 'string', required: true, description: 'patient_id renvoyé par patient_resolve.' },
      query: { type: 'string', description: 'Ne garder que les sections contenant ce texte (sans accents ni casse).' },
    },
    output: {
      schema: { type: 'array', items: locationSchema },
      render: (_args, value) => [{
        type: 'text',
        text: value.length === 0
          ? 'Aucune section trouvée.'
          : value.map(l => `- ${l.attribute} (${l.label}) : item_id=${l.item_id}, encounter_id=${l.encounter_id}, `
            + `version=${l.version}, empreinte=${l.digest}\n  « ${l.current_text} »`).join('\n'),
      }],
    },
    async execute(args, exec) {
      nonEmpty(args.patient_id, 'patient_id')
      return call('find_sections', { patient_id: args.patient_id, query: args.query }, exec.signal)
    },
    presentCall: (args): GenericCallView => ({ card: 'generic', title: `Sections du dossier ${args.patient_id}`, kind: 'search' }),
  }))

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.readSection,
    description: 'Relire le texte actuel d\'une section narrative (item_id + attribut), avec sa version et son empreinte. '
      + 'À faire juste avant un brouillon et juste après une application. Lecture seule.',
    parameters: {
      item_id: { type: 'string', required: true, description: 'item_id renvoyé par record_find_sections.' },
      attribute: { type: 'string', enum: NARRATIVE_SECTIONS, required: true, description: 'Section narrative.' },
    },
    output: {
      schema: sectionSchema,
      render: (_args, v) => [{
        type: 'text',
        text: `${v.attribute} (item ${v.item_id}, version ${v.version}, empreinte ${v.digest}`
          + `${v.filed ? '' : ', NON CLASSÉ : invisible pour le clinicien'}) :\n${v.text}`,
      }],
    },
    async execute(args, exec) {
      nonEmpty(args.item_id, 'item_id')
      return call('read_section', { item_id: args.item_id, attribute: args.attribute }, exec.signal)
    },
    presentCall: (args): GenericCallView => ({ card: 'generic', title: `Lecture ${args.attribute}`, kind: 'read' }),
  }))

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.draftEdit,
    description: 'Préparer un BROUILLON de modification d\'une section narrative, sans rien écrire dans le portail. '
      + 'Mode « append » (ajout en fin de section) ou « replace » (remplacement d\'un extrait exact, présent une seule fois, '
      + 'fourni dans old). Chaque brouillon cite mot pour mot la dictée qui le justifie (quotes). Le pont enregistre le '
      + 'brouillon et renvoie un draft_id ; l\'application exige ensuite le feu vert explicite du clinicien.',
    parameters: {
      patient_id: { type: 'string', required: true, description: 'Patient de la dictée.' },
      encounter_id: { type: 'string', required: true, description: 'Rencontre sous laquelle le document est classé.' },
      item_id: { type: 'string', required: true, description: 'Document à modifier (record_find_sections).' },
      attribute: { type: 'string', enum: NARRATIVE_SECTIONS, required: true, description: 'Section narrative visée.' },
      mode: { type: 'string', enum: ['append', 'replace'], required: true, description: 'append ou replace.' },
      new_text: { type: 'string', required: true, description: 'Texte proposé (ajouté, ou remplaçant old).' },
      old: { type: 'string', description: 'Pour replace uniquement : extrait exact à remplacer.' },
      rationale: { type: 'string', required: true, description: 'Pourquoi cette modification, en une phrase.' },
      quotes: {
        type: 'array',
        items: quoteSchema,
        required: true,
        description: 'Citations exactes de la dictée qui fondent le texte proposé : [{dictation_id, offset, text}].',
      },
      base_digest: { type: 'string', description: 'Empreinte de la section lue (record_read_section), pour détecter une modification concurrente.' },
    },
    output: {
      schema: draftSchema,
      render: (_args, d) => [{
        type: 'text',
        text: `Brouillon ${d.draft_id} enregistré (statut ${d.status}), rien n'est écrit dans le portail.\n`
          + `Section ${d.attribute} de l'item ${d.item_id}, mode ${d.mode}. `
          + `Citations vérifiées dans la dictée : ${d.quotes_verified ? 'oui' : 'non (source de dictée indisponible)'}.\n`
          + `Texte final proposé :\n${d.final_text}\n`
          + `Pour appliquer : record_apply({"draft_id": "${d.draft_id}"}), après feu vert explicite du clinicien.`,
      }],
      presentationMeta: (_args, d) => diffMeta(d),
    },
    async execute(args, exec) {
      for (const field of ['patient_id', 'encounter_id', 'item_id', 'new_text', 'rationale'] as const) nonEmpty(args[field], field)
      if (args.mode === 'replace' && (args.old === undefined || args.old === '')) {
        throw new Error('old : un remplacement exige l\'extrait exact à remplacer')
      }
      if (args.mode === 'append' && args.old !== undefined) throw new Error('old : réservé au mode replace')
      if (args.quotes.length === 0) throw new Error('quotes : au moins une citation de la dictée est exigée')
      for (const q of args.quotes) {
        if (typeof q.dictation_id !== 'string' || typeof q.text !== 'string' || typeof q.offset !== 'number') {
          throw new Error('quotes : chaque citation exige dictation_id, offset et text')
        }
        nonEmpty(q.text, 'quotes[].text')
      }
      return call('draft_create', {
        patient_id: args.patient_id,
        encounter_id: args.encounter_id,
        item_id: args.item_id,
        attribute: args.attribute,
        mode: args.mode,
        new_text: args.new_text,
        old: args.old,
        rationale: args.rationale,
        quotes: args.quotes,
        base_digest: args.base_digest,
      }, exec.signal)
    },
    // Pure, args-only diff of the proposed change (the section's full text is not in the args).
    presentCall: (args): DiffCallView => ({
      card: 'diff',
      title: `Brouillon ${args.mode === 'append' ? 'd\'ajout' : 'de remplacement'} : ${args.attribute}`,
      diffs: [{ path: sectionPath(args.item_id, args.attribute), oldText: args.mode === 'replace' ? args.old ?? null : null, newText: args.new_text }],
    }),
    presentResult: (args, result) => diffResult(`Brouillon : ${args.attribute}`, result),
  }))

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.apply,
    description: 'Appliquer dans le portail un brouillon APPROUVÉ par le clinicien. Le pont refuse sans feu vert (403) '
      + 'et si la section a changé depuis le brouillon (409). Rejouer un brouillon déjà appliqué ne réécrit rien. '
      + 'Relire la section ensuite avec record_read_section.',
    parameters: {
      draft_id: { type: 'string', required: true, description: 'draft_id renvoyé par record_draft_edit.' },
    },
    output: {
      schema: writeSchema,
      render: (_args, v) => [{
        type: 'text',
        text: `${v.replayed ? 'Déjà appliqué (rejeu, aucune nouvelle écriture)' : 'Appliqué'} : brouillon ${v.draft_id}, `
          + `${v.attribute} de l'item ${v.item_id}, version ${v.version_before} → ${v.version_after}, `
          + `sauvegarde ${v.backup_id ?? '?'}.`,
      }],
      presentationMeta: (_args, v) => diffMeta(v),
    },
    async execute(args, exec) {
      nonEmpty(args.draft_id, 'draft_id')
      return call('apply', { draft_id: args.draft_id }, exec.signal)
    },
    // The args hold only the draft id; the diff card is the completed view (from result meta).
    presentCall: (args): GenericCallView => ({ card: 'generic', title: `Appliquer le brouillon ${args.draft_id}`, kind: 'edit' }),
    presentResult: (_args, result) => diffResult('Modification appliquée au portail', result),
  }))

  ctx.tools.register(defineTool({
    name: TOOL_NAMES.restore,
    description: 'Annuler une modification appliquée en restaurant la sauvegarde (backup_id renvoyé par record_apply). '
      + 'Exige aussi le feu vert explicite du clinicien ; refusé si la section a été modifiée depuis.',
    parameters: {
      backup_id: { type: 'string', required: true, description: 'backup_id renvoyé par record_apply.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          draft_id: { type: 'string', required: true },
          replayed: { type: 'boolean', required: true },
          restored: { type: 'boolean', required: true },
          item_id: { type: 'string', required: true },
          attribute: { type: 'string', required: true },
          version_after: { type: 'integer', required: true },
          base_text: { type: 'string', required: true },
          final_text: { type: 'string', required: true },
        },
      },
      render: (args, v) => [{
        type: 'text',
        text: `${v.replayed ? 'Déjà restauré (rejeu)' : v.restored ? 'Restauré' : 'Restauration non vérifiée'} : `
          + `sauvegarde ${args.backup_id}, ${v.attribute} de l'item ${v.item_id}, version ${v.version_after}.`,
      }],
      presentationMeta: (_args, v) => diffMeta(v),
    },
    async execute(args, exec) {
      nonEmpty(args.backup_id, 'backup_id')
      // The restore draft is idempotent per backup; the approval plugin approves that draft.
      await call('draft_restore', { backup_id: args.backup_id }, exec.signal)
      return call('restore', { backup_id: args.backup_id }, exec.signal)
    },
    presentCall: (args): GenericCallView => ({ card: 'generic', title: `Restaurer la sauvegarde ${args.backup_id}`, kind: 'edit' }),
    presentResult: (_args, result) => diffResult('Modification annulée', result),
  }))
}
