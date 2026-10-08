/**
 * The globally named `wait_settlement` tool: a thin model-facing adapter over
 * `ctx.subagents.waitSettlement()`. With `wait: true` it blocks up to the
 * budget for one direct continuable child to settle and reports its final
 * projection; by default (or with `wait: false`) it only probes the live
 * `agents` registry and reports the current projection without blocking. It
 * stays separately loadable from the root `send_message` plugin so a deployment
 * can register continuation delivery without exposing discovery.
 * @module @deepseek-ai/dsh-tool-subagent-control/wait-settlement
 */

import type { Context } from '@deepseek-ai/cordis'
import { defineTool } from '@deepseek-ai/dsh-tools'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type { SubagentWaitProjection } from '@deepseek-ai/dsh-subagent'

export const name = 'tool-subagent-wait-settlement'
export const inject = ['tools', 'subagents', 'agents']

/** Default budget when `wait: true` without an explicit `timeout_ms`. */
const WAIT_DEFAULT_MS = 30_000
/** Hard cap applied to any `timeout_ms`, keeping the model from arming a huge timer. */
const WAIT_CAP_MS = 600_000

interface WaitSettlementRequest {
  readonly agent_id: string
  readonly wait?: boolean
  readonly timeout_ms?: number
}

interface WaitSettlementSpec {
  readonly agentId: SessionId
  readonly wait: boolean
  readonly timeoutMs: number
}

/** Resolve the optional model request into an internal required-budget spec. */
function resolveWaitSettlementRequest(request: WaitSettlementRequest): WaitSettlementSpec {
  return {
    agentId: request.agent_id as SessionId,
    wait: request.wait ?? false,
    timeoutMs: request.timeout_ms === undefined
      ? WAIT_DEFAULT_MS
      : Math.min(request.timeout_ms, WAIT_CAP_MS),
  }
}

/** Observe the live `agents` projection for one child without a service call. */
function probe(ctx: Context, childId: SessionId): SubagentWaitProjection {
  const agent: Agent | undefined = ctx.agents.get(childId)
  return {
    id: childId,
    status: agent?.status === 'running' ? 'running' : 'inactive',
    lastActivityAt: agent?.lastActivityAt ?? 0,
  }
}

/**
 * Register the `wait_settlement` tool.
 * @param ctx - context carrying the tool registry, subagent service, and live Agent registry.
 */
export function apply(ctx: Context): void {
  ctx.tools.register(defineTool({
    name: 'wait_settlement',
    description:
      'Observe one subagent you started, waiting for it to settle when asked. '
      + 'With wait=true it blocks up to timeout_ms for the subagent to finish and reports '
      + 'its final projection; otherwise it only reports the live status and last activity '
      + 'timestamp without blocking. Timeout returns the live projection instead of erroring.',
    parameters: {
      agent_id: {
        type: 'string',
        required: true,
        description: 'The session id of the direct child subagent to observe.',
      },
      wait: {
        type: 'boolean',
        description: 'Whether to block for settlement. Defaults to false (probe only).',
      },
      timeout_ms: {
        type: 'number',
        description: 'Maximum wait budget in milliseconds when wait=true. Defaults to 30000, capped at 600000.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          settled: {
            type: 'boolean',
            required: true,
            description: 'true when the child settled (or is no longer resident) within the budget.',
          },
          agent: {
            type: 'object',
            required: true,
            additionalProperties: false,
            properties: {
              id: { type: 'string', required: true },
              status: { type: 'string', required: true, enum: ['running', 'inactive'] },
              lastActivityAt: { type: 'number', required: true },
            },
          },
        },
      },
      render: (_args, outcome) => [{
        type: 'text',
        text: outcome.settled
          ? `${outcome.agent.id} [settled]`
          : `${outcome.agent.id} [${outcome.agent.status}] lastActivityAt=${outcome.agent.lastActivityAt}`,
      }],
    },
    async execute(args, exec) {
      const parent = exec.agent
      if (!parent) {
        // Non-agent callers have no child whose settlement could be observed.
        throw new Error('wait_settlement requires a calling agent (exec.agent was undefined)')
      }
      const spec = resolveWaitSettlementRequest(args)
      if (!spec.wait) {
        const observed = probe(ctx, spec.agentId)
        return { settled: observed.status === 'inactive', agent: observed }
      }
      return ctx.subagents.waitSettlement(spec.agentId, spec.timeoutMs, exec.signal)
    },
  }))
}
