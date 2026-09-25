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
  const openSession = () => {
    const s = ctx.sessions.create(SessionId(`scribe-approval-${++seq}`))
    s.append('turn/start', { turn: 1 })
    return s
  }
  const session = openSession()
  /** One tool call in `target` with an explicit call id (dsh call ids repeat across sessions). */
  const runAs = (target: typeof session, callId: string, name: string, args: Record<string, unknown>): Promise<ToolExecutionResult> =>
    ctx.tools.execute({ signal: new AbortController().signal, callId: ToolCallId(callId), name, arguments: args as never, agent: { session: target } as never })
  const run = (name: string, args: Record<string, unknown>): Promise<ToolExecutionResult> => runAs(session, `call-${++seq}`, name, args)
  const approvalEvents = () => session.snapshotEvents().filter(e => e.type.startsWith('approval/'))
  return { ctx, run, runAs, openSession, session, approvalEvents }
}
