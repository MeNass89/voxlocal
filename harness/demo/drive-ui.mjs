// Drive the dsh web chat through the 90-second « Parcours agent » and save the five evidence PNGs.
// Chrome DevTools Protocol over Node's built-in WebSocket: no npm dependency.
//
//   node harness/demo/drive-ui.mjs --url <dsh web URL with ?token=> --message <file> --out <dir>
//        --browser <chrome-headless-shell> [--profile-dir <dir>] [--prefix <name>]
//
// Steps: send the delivered dictation -> (a) dictation in the chat -> wait for the first approval
// -> (b) drafts with sections and quotes -> (c) approval prompt -> « Allow once » for every write
// -> (d) applied diff card -> ask to cancel -> « Allow once » -> (e) restore card.
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseArgs } from 'node:util'

const { values: opt } = parseArgs({
  options: {
    url: { type: 'string' }, message: { type: 'string' }, out: { type: 'string' },
    browser: { type: 'string' }, 'profile-dir': { type: 'string' },
    prefix: { type: 'string', default: '2026-09-25-harness-demo' },
    cancel: { type: 'string', default: 'Annulez l’ajout dans l’orientation : je le reprendrai moi-même.' },
  },
})
for (const k of ['url', 'message', 'out', 'browser']) if (!opt[k]) throw new Error(`--${k} requis`)
mkdirSync(opt.out, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const W = 1280, H = 1000
const pendingApprovals = `document.querySelectorAll('[data-approval-key]').length`

// ------------------------------------------------------------------ browser + CDP
const dir = opt['profile-dir'] ?? mkdtempSync(join(tmpdir(), 'dsh-drive-'))
mkdirSync(dir, { recursive: true })
const chrome = spawn(opt.browser, ['--headless', '--disable-gpu', '--hide-scrollbars',
  '--force-prefers-reduced-motion', '--remote-debugging-port=0', `--user-data-dir=${dir}`,
  '--lang=fr-FR', `--window-size=${W},${H}`, 'about:blank'], { stdio: 'ignore' })
const kill = () => { try { chrome.kill('SIGKILL') } catch {} }
process.on('exit', kill)

let send, evaluate
try {
  const portFile = join(dir, 'DevToolsActivePort')
  for (let i = 0; i < 150 && !existsSync(portFile); i++) await sleep(100)
  const port = readFileSync(portFile, 'utf8').split('\n')[0]
  const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page')
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j })
  let id = 0
  const pending = new Map()
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data)
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
  }
  send = (method, params = {}) => new Promise((resolve, reject) => {
    const i = ++id
    pending.set(i, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)))
    ws.send(JSON.stringify({ id: i, method, params }))
  })
  evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true })
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text)
    return r.result.value
  }
  await main()
  kill()
  process.exit(0)
} catch (err) {
  console.error('ERREUR', err.message)
  try { await shot('failure') } catch {}
  kill()
  process.exit(1)
}

// ------------------------------------------------------------------ helpers
async function waitFor(expression, what, timeoutMs = 15000) {
  const end = Date.now() + timeoutMs
  while (Date.now() < end) {
    const v = await evaluate(expression)
    if (v) return v
    await sleep(200)
  }
  throw new Error(`délai dépassé : ${what}`)
}

async function shot(name, clip) {
  const params = { format: 'png', captureBeyondViewport: false }
  if (clip) params.clip = { ...clip, scale: 1 }
  const r = await send('Page.captureScreenshot', params)
  const path = join(opt.out, `${opt.prefix}-${name}.png`)
  writeFileSync(path, Buffer.from(r.data, 'base64'))
  console.log(`capture ${path}`)
  return path
}

/** Click the first visible button whose text is exactly `label`, inside `scope` (a CSS selector) or the page. */
async function click(label, scope = 'body', last = false) {
  const ok = await evaluate(`(() => {
    const all = [...document.querySelectorAll(${JSON.stringify(scope)})].flatMap((s) => [...s.querySelectorAll('button')])
      .filter((b) => b.innerText.trim() === ${JSON.stringify(label)} && b.offsetParent !== null && !b.disabled)
    const b = ${last ? 'all[all.length - 1]' : 'all[0]'}
    if (!b) return false
    b.scrollIntoView({ block: 'center' }); b.click(); return true
  })()`)
  if (!ok) throw new Error(`bouton introuvable : ${label}`)
}

async function type(text) {
  await waitFor(`!!document.querySelector('[contenteditable="true"]')`, 'zone de saisie')
  await evaluate(`(() => { const e = document.querySelector('[contenteditable="true"]'); e.focus(); return true })()`)
  await send('Input.insertText', { text })
  await sleep(300)
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' })
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 })
}

/** Scroll the element matched by the JS expression `find` into view. */
async function scrollTo(find, block = 'start') {
  const ok = await evaluate(`(() => { const e = (${find}); if (!e) return false; e.scrollIntoView({ block: ${JSON.stringify(block)} }); return true })()`)
  if (!ok) throw new Error(`élément introuvable pour la capture : ${find.slice(0, 80)}`)
  await evaluate(`document.activeElement && document.activeElement.blur && document.activeElement.blur()`)
  await sleep(700)
}

/** Open collapsed turns and step groups, then the rows of the given tools (the web client
 *  renders portail-tools calls as generic rows: « Tool call · record_… », IN / OUT when open). */
async function expand(tools) {
  await evaluate(`[...document.querySelectorAll('button[data-turn-process][aria-expanded="false"]')].forEach((b) => b.click())`)
  await sleep(600)
  await evaluate(`[...document.querySelectorAll('[data-step-process="true"] button[aria-expanded="false"]')].forEach((b) => b.click())`)
  await sleep(600)
  const n = await evaluate(`[...document.querySelectorAll(${JSON.stringify(tools.map((t) => `[data-tool="${t}"] [data-disclosure-row][aria-expanded="false"]`).join(','))})].map((r) => r.click()).length`)
  await sleep(800)
  return n
}

function lastUserMessage(re) {
  return `[...document.querySelectorAll('[data-chat-flow-kind="user"]')].filter((e) => ${re}.test(e.innerText ?? '')).pop()`
}

// ------------------------------------------------------------------ the script
async function main() {
  await send('Page.enable')
  await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 2, mobile: false })
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] })
  await send('Page.navigate', { url: opt.url })
  await waitFor(`document.readyState === 'complete' && !!document.querySelector('[contenteditable="true"]')`, 'interface dsh')
  await sleep(1500)
  if (await evaluate(`[...document.querySelectorAll('button')].some((b) => b.innerText.trim() === 'Continue')`)) {
    await click('Continue')
    await sleep(600)
  }

  // (a) the dictation delivered by the feeder arrives in the chat; the agent starts working
  await type(readFileSync(opt.message, 'utf8').trim())
  await waitFor(pendingApprovals, 'première demande de feu vert', 30000)
  await sleep(1500)
  await scrollTo(lastUserMessage('/Nouvelle dictée/'))
  await shot('dictation')

  // (b) the drafts: one per section, with the proposed text and the verified dictation quotes
  const drafts = await expand(['record_draft_edit'])
  if (drafts !== 2) throw new Error(`2 brouillons attendus, ${drafts} trouvés`)
  // The pending approval card is pinned over the bottom of the chat and the step group scrolls
  // inside a 400 px box: for this one capture, a taller window and the group's height cap lifted
  // (injected style, capture only) show both drafts at once. Each IN pane is scrolled to its
  // quotes, as the clinician would scroll it.
  await send('Emulation.setDeviceMetricsOverride', { width: W, height: 1800, deviceScaleFactor: 2, mobile: false })
  await evaluate(`(() => { const s = document.createElement('style'); s.id = 'demo-capture'
    s.textContent = '[data-step-process-body] { max-height: none !important; overflow: visible !important }'
    document.head.append(s); return true })()`)
  await sleep(600)
  await evaluate(`[...document.querySelectorAll('[data-tool="record_draft_edit"] [class*="ioSection"]')]
    .filter((io) => /"quotes"/.test(io.textContent)).forEach((io) => {
      const t = io.textContent; io.scrollTop = Math.round(io.scrollHeight * t.indexOf('"rationale"') / t.length) - 8 })`)
  await scrollTo(`document.querySelector('[data-tool="record_draft_edit"]')`)
  await shot('draft')
  await evaluate(`document.getElementById('demo-capture').remove()`)
  await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 2, mobile: false })
  await sleep(500)

  // (c) the approval prompt: patient, encounter, section, exact change, quotes; nothing written yet
  await scrollTo(`document.querySelector('[data-approval-key]')`, 'end')
  await shot('approval')

  // « Allow once » for each write the model asks for (one per draft)
  let allowed = 0
  for (;;) {
    let n = await evaluate(pendingApprovals)
    if (!n) n = await evaluate(`new Promise((r) => setTimeout(() => r(${pendingApprovals}), 2500))`)
    if (!n) break
    await click('Allow once', '[data-approval-key]')
    allowed++
    await sleep(1500)
    if (allowed > 4) throw new Error('trop de demandes de feu vert')
  }
  console.log(`feu vert donné ${allowed} fois`)
  await waitFor(`/Brouillons .* traités/.test(document.body.innerText)`, 'résumé final du modèle', 20000)
  await sleep(1000)

  // (d) the applied writes: version before → after and the backup id, returned by the bridge
  const applied = await expand(['record_apply'])
  if (applied !== 2) throw new Error(`2 écritures attendues, ${applied} trouvées`)
  await scrollTo(`document.querySelector('[data-tool="record_apply"]')`)
  await shot('applied')

  // (e) cancel one write: record_restore, gated by the same « Allow once »
  await type(opt.cancel)
  await waitFor(pendingApprovals, 'feu vert de la restauration', 20000)
  await sleep(800)
  console.log(`restauration demandée : ${(await evaluate(`document.querySelector('[data-approval-key]').innerText`)).slice(0, 160).replace(/\s+/g, ' ')}`)
  await click('Allow once', '[data-approval-key]')
  await waitFor(`/revenue à son texte d'avant/.test(document.body.innerText)`, 'confirmation de restauration', 20000)
  await sleep(1000)
  if (await expand(['record_restore']) !== 1) throw new Error('restauration introuvable')
  await scrollTo(lastUserMessage('/^Annulez/'))
  await shot('restore')
}
