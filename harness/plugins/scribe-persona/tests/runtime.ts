/**
 * Test runtime: the real dsh prompt registry with this plugin mounted, and a helper that renders
 * the assembled prompt exactly as the agent loop does.
 */
import { Context } from '@deepseek-ai/cordis'
import SystemPrompt, { renderPrompt } from '@deepseek-ai/dsh-system-prompt'
import * as ScribePersona from '../src/index.ts'

export { ScribePersona }

export async function mount(config: ScribePersona.Config = {}, prompt: Record<string, unknown> = {}) {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt, prompt)
  const fiber = await ctx.plugin(ScribePersona, config)
  const render = async () => {
    const assembly = await ctx.systemPrompt.assemble({})
    return renderPrompt({ ...assembly, variables: { ...assembly.variables, model: 'qwen3.8-27b', cwd: '/tmp' } })
  }
  return { ctx, fiber, render }
}
