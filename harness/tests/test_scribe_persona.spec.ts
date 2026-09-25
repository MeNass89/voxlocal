/**
 * scribe-persona: the French clinical sections reach the assembled system prompt, in order, and
 * the coding persona can be blanked by the profile row.
 *
 * Run: cd harness/plugins/scribe-persona && pnpm test
 */
import { describe, expect, it } from 'vitest'
import { mount, ScribePersona } from '../plugins/scribe-persona/tests/runtime.ts'

describe('scribe-persona', () => {
  it('renders role, loop, hard rules, SOAP mapping, approval reminder and toolbox gaps in order', async () => {
    const { render } = await mount({}, { personaPrefix: '', personaSuffix: '' })
    const prompt = await render()
    const markers = [
      'Vous êtes le scribe clinique VoxLocal du service des urgences',
      '# La boucle de travail',
      '# Règles absolues',
      '# Correspondance SOAP → sections du dossier',
      '# Feu vert',
      '# Boîte à outils : pas encore disponible',
    ]
    const positions = markers.map(m => prompt.indexOf(m))
    expect(positions.every(p => p >= 0)).toBe(true)
    expect([...positions].sort((a, b) => a - b)).toEqual(positions)
    expect(prompt).toContain('propulsé par le modèle qwen3.8-27b')
    expect(prompt).not.toContain('coding agent')
  })

  it('states the loop: read the dictation, read the record, draft with quotes, wait, apply, re-read', async () => {
    const { render } = await mount()
    const prompt = await render()
    for (const step of ['Lire la dictée', 'Lire le dossier', 'record_draft_edit', 'citations exactes',
      'attendre son feu vert explicite', 'record_apply', 'Relire la section']) {
      expect(prompt).toContain(step)
    }
  })

  it('treats a repeated dictation id as a re-delivery, not a new dictation', async () => {
    const prompt = await (await mount()).render()
    expect(prompt).toContain('« Renvoi possible après interruption »')
    expect(prompt).toContain('est un renvoi, pas une nouvelle dictée')
  })

  it('maps SOAP onto the four narrative sections', async () => {
    const { render } = await mount()
    const prompt = await render()
    expect(ScribePersona.SOAP_MAPPING).toEqual({
      subjectif: 'current-affliction', objectif: 'physical-exam-text', 'évaluation': 'text-conclusion', plan: 'disposition',
    })
    expect(prompt).toContain('Subjectif (plainte, anamnèse, antécédents dits par le patient) → `current-affliction`')
    expect(prompt).toContain('Objectif (examen clinique, paramètres, signes, scores) → `physical-exam-text`')
    expect(prompt).toContain('Évaluation (diagnostic retenu ou probable, raisonnement) → `text-conclusion`')
    expect(prompt).toContain('→ `disposition`')
  })

  it('keeps the hard rules: no invention, negations/doses/units preserved, ask when ambiguous', async () => {
    const prompt = await (await mount()).render()
    expect(prompt).toContain('N\'inventez aucun fait')
    expect(prompt).toContain('négations')
    expect(prompt).toContain('doses, les unités')
    expect(prompt).toContain('posez une question')
    expect(prompt).toContain('aucune décision clinique')
  })

  it('reminds that record_apply needs approval and quotes the refusal message', async () => {
    const prompt = await (await mount()).render()
    expect(prompt).toContain('`record_apply` et `record_restore` exigent l\'approbation explicite du médecin')
    expect(prompt).toContain('« Application refusée : aucun feu vert. »')
  })

  it('lists protocoles, INAMI and prescriptions as not yet available', async () => {
    const prompt = await (await mount()).render()
    const toolbox = prompt.slice(prompt.indexOf('# Boîte à outils'))
    expect(toolbox).toContain('protocoles de soins')
    expect(toolbox).toContain('INAMI')
    expect(toolbox).toContain('prescriptions')
    expect(toolbox).toContain('xCare')
  })

  it('takes the service name from config and removes its sections on unload', async () => {
    const { render, fiber } = await mount({ service: 'soins intensifs' })
    expect(await render()).toContain('du service des soins intensifs')
    await fiber.dispose()
    expect(await render()).not.toContain('scribe clinique')
  })
})
