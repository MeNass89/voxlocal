/**
 * Test runtime for `harness/tests/test_portail_tools.spec.ts`: a minimal dsh tool runtime with
 * this plugin mounted. Kept inside the package so its dsh imports resolve from here.
 */
import { Context } from '@deepseek-ai/cordis'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import type { ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import * as PortailTools from '../src/index.ts'

export { PortailTools }

let seq = 0

export async function mount(config: PortailTools.Config) {
  const ctx = new Context()
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(PortailTools, config)
  const run = (name: string, args: Record<string, unknown>): Promise<ToolExecutionResult> =>
    ctx.tools.execute({ signal: new AbortController().signal, callId: `call-${++seq}` as never, name, arguments: args as never })
  return { ctx, run, tool: (name: string) => ctx.tools.get(name)! }
}
