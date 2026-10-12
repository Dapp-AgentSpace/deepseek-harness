import { mountWorkingDirectoryFixture } from './working-directory-fixture.ts'
// The fork-specific `waitSettlement` capability: observe one direct child with
// a bounded budget and receive its final projection on settlement. Upstream
// lacks this API (dedup: 0/0 waitSettlement/wait_settlement), so these tests
// pin the ported behavior on SubagentManager.

import { describe, expect, it, onTestFinished } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import SubagentRuntime, {
  type SubagentActivation,
  type SubagentCapabilities,
  type SubagentProvider,
  type SubagentResult,
  type SubagentRun,
  type SubagentStartRequest,
} from '@deepseek-ai/dsh-subagent'
import { SessionId } from '@deepseek-ai/dsh-session'
import { managerState } from './manager-internals.ts'

function fakeParent(id = 'parent-1'): Agent {
  return { id: SessionId(id) } as unknown as Agent
}

const ALL_CAPS: SubagentCapabilities = { agentOptions: true, outputSchema: true, depthLimit: true, toolFilter: true, persona: true }

function baseRequest(overrides: Partial<SubagentStartRequest> = {}): SubagentStartRequest {
  return {
    prompt: [{ type: 'text', text: 'do a thing' }],
    parent: fakeParent(),
    signal: new AbortController().signal,
    ...overrides,
  }
}

/** A provider whose run result settles on demand, letting tests hold a child in `running`. */
class GateProvider implements SubagentProvider {
  readonly inheritsParentContext = false
  readonly capabilities: SubagentCapabilities = ALL_CAPS
  readonly run = Promise.withResolvers<SubagentResult>()
  readonly runId: ReturnType<typeof SessionId>

  constructor(readonly name: string, childSuffix: string) {
    this.runId = SessionId(`child:${name}:${childSuffix}`)
  }

  async start(_request: SubagentStartRequest): Promise<SubagentRun> {
    return {
      id: this.runId,
      result: this.run.promise,
      async dispose() {},
    }
  }

  settle(outcome: SubagentResult = { output: [{ type: 'text', text: 'ok' }], stopReason: 'completed' }): void {
    this.run.resolve(outcome)
  }
}

const contexts = new WeakMap<SubagentRuntime, Context>()

async function service(): Promise<{ ctx: Context; subagents: SubagentRuntime }> {
  const ctx = new Context()
  await mountAgentLoopTestDependencies(ctx)
  await ctx.plugin(AgentLoop, { agents: [] })
  await mountWorkingDirectoryFixture(ctx)
  await ctx.plugin(SubagentRuntime)
  const subagents = ctx.subagents
  contexts.set(subagents, ctx)
  onTestFinished(() => ctx.fiber.dispose())
  return { ctx, subagents }
}

/** Start through the managed API with a real parent owned by the fixture. */
async function start(subagents: SubagentRuntime, provider: string, request: SubagentStartRequest): Promise<SubagentActivation> {
  const ctx = contexts.get(subagents)!
  const parent = ctx.agents.get(request.parent.id)
    ?? (await ctx.agents.create({ sessionId: request.parent.id })).agent
  const { label, signal, ...options } = request
  return subagents.startActivation({
    provider, label: label ?? provider, request: { ...options, parent }, signal, delivery: 'caller',
  })
}

describe('waitSettlement', () => {
  it('settles immediately for a child that was never resident', async () => {
    const { subagents } = await service()
    const outcome = await subagents.waitSettlement(SessionId('ghost-child'), 1_000)
    expect(outcome.settled).toBe(true)
    expect(outcome.agent).toEqual({
      id: SessionId('ghost-child'),
      status: 'inactive',
      lastActivityAt: 0,
    })
  })

  it('returns the live running projection when the budget elapses first', async () => {
    const { ctx, subagents } = await service()
    const provider = new GateProvider('gated', 'running')
    subagents.registerProvider(provider)
    const activation = await start(subagents, 'gated', baseRequest())
    expect(managerState(ctx).resident.has(activation.childId)).toBe(true)

    const outcome = await subagents.waitSettlement(activation.childId, 50)
    expect(outcome.settled).toBe(false)
    expect(outcome.agent.status).toBe('running')
    expect(outcome.agent.lastActivityAt).toBe(0)

    provider.settle()
    await activation.result
  })

  it('releases the waiter with the final inactive projection once the child settles', async () => {
    const { subagents } = await service()
    const provider = new GateProvider('gated', 'settle')
    subagents.registerProvider(provider)
    const activation = await start(subagents, 'gated', baseRequest())
    const waiting = subagents.waitSettlement(activation.childId, 5_000)

    provider.settle()
    const outcome = await waiting
    expect(outcome.settled).toBe(true)
    expect(outcome.agent.id).toBe(activation.childId)
    expect(outcome.agent.status).toBe('inactive')
  })

  it('honors a pre-aborted signal with the live projection and no wait', async () => {
    const { subagents } = await service()
    const provider = new GateProvider('gated', 'aborted')
    subagents.registerProvider(provider)
    const activation = await start(subagents, 'gated', baseRequest())
    const controller = new AbortController()
    controller.abort()

    const outcome = await subagents.waitSettlement(activation.childId, 5_000, controller.signal)
    expect(outcome.settled).toBe(false)
    expect(outcome.agent.status).toBe('running')

    provider.settle()
    await activation.result
  })

  it('treats a later-settled child as already settled on a fresh call', async () => {
    const { subagents } = await service()
    const provider = new GateProvider('gated', 'late')
    subagents.registerProvider(provider)
    const activation = await start(subagents, 'gated', baseRequest())
    provider.settle()
    await activation.result

    const outcome = await subagents.waitSettlement(activation.childId, 1_000)
    expect(outcome.settled).toBe(true)
    expect(outcome.agent.status).toBe('inactive')
  })

  it.each([
    ['zero', 0],
    ['negative', -5],
    ['NaN', Number.NaN],
  ] as const)('rejects an invalid %s timeout budget', async (_label, timeoutMs) => {
    const { subagents } = await service()
    await expect(subagents.waitSettlement(SessionId('ghost-child'), timeoutMs)).rejects.toThrow(/positive number of milliseconds/)
  })
})
