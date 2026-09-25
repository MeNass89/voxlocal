/**
 * TEST ONLY. A terminal `approval/request` answerer standing in for the clinician's click in the
 * dsh web chat, for headless loop tests (`harness/tests/test_loop.py`). Never mount it in a
 * clinical profile: it answers every question with the configured outcome.
 *
 * Each request is appended to `$SCRIBE_TEST_ANSWERS` (JSONL) so the test can check what the
 * clinician would have been shown.
 */
import { appendFileSync } from 'node:fs'
import type { Context } from '@deepseek-ai/cordis'

export const name = 'scribe-test-answerer'
export const inject = ['approval']

export function apply(ctx: Context, config: { outcome?: 'allowed-once' | 'rejected' } = {}) {
  const outcome = config.outcome ?? 'rejected'
  ctx.on('approval/request', async (req) => {
    const path = process.env.SCRIBE_TEST_ANSWERS
    if (path) {
      appendFileSync(path, `${JSON.stringify({
        ts: new Date().toISOString(), toolName: req.toolName, callId: req.callId, reason: req.reason,
        displayReason: req.displayReason?.en, outcome,
      })}\n`)
    }
    return outcome
  })
}
