/**
 * Test runtime for `harness/tests/test_scribe_approval.spec.ts`: the dsh tool pipeline with the
 * real approval service, the real portail-tools plugin and this plugin, plus an agent whose
 * session sits inside an open turn (the approval seam's precondition).
 */
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import type { ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import type { ApprovalPolicy } from '@deepseek-ai/dsh-user-approval'
import * as PortailTools from '../../portail-tools/src/index.ts'
import * as ScribeApproval from '../src/index.ts'

export { ScribeApproval }

let seq = 0

export async function mount(options: {
  policy: ApprovalPolicy
  approval: ScribeApproval.Config
  portail: PortailTools.Config
}) {
  const ctx = new Context()
  await ctx.plugin(SessionStore)
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(ApprovalService, { policy: options.policy })
  await ctx.plugin(PortailTools, options.portail)
  await ctx.plugin(ScribeApproval, options.approval)
  const session = ctx.sessions.create(SessionId(`scribe-approval-${++seq}`))
  session.append('turn/start', { turn: 1 })
  const agent = { session } as never
  const run = (name: string, args: Record<string, unknown>): Promise<ToolExecutionResult> =>
    ctx.tools.execute({ signal: new AbortController().signal, callId: ToolCallId(`call-${++seq}`), name, arguments: args as never, agent })
  const approvalEvents = () => session.snapshotEvents().filter(e => e.type.startsWith('approval/'))
  return { ctx, run, session, approvalEvents }
}
