import { afterEach, describe, expect, it, vi } from 'vitest'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { GenerateOptions, StreamChunk } from '@deepseek-ai/dsh-llm'
import { LlmAdapter } from '@deepseek-ai/dsh-llm'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import { mountAgentLoopTestDependencies } from '@deepseek-ai/dsh-agent-loop-testkit'
import { mountWorkingDirectoryFixture } from '../../../subagent/subagent/tests/working-directory-fixture.ts'
import { SessionId } from '@deepseek-ai/dsh-session'
import JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import SubagentRuntime from '@deepseek-ai/dsh-subagent'
import * as SubagentSpawn from '@deepseek-ai/dsh-subagent-spawn-in-process'
import { MockAdapter, textResponse } from '../../../core/agent-loop/tests/mock-adapter.ts'
import * as tool from '../src/wait-settlement.ts'
import { parkParent } from './park-parent.ts'
import { TestSessionQuery } from './test-session-query.ts'

/** One scripted response that may wait on a caller-released gate before streaming. */
interface GatedEntry {
  chunks: StreamChunk[]
  gate?: Promise<undefined>
}

/**
 * Adapter whose entries can hold a model call open until the test releases it.
 * Unlike the plain gate in list-agents.spec.ts, the gate also unblocks on
 * abort so a failed (red-phase) test never leaves the child's stream hanging
 * past context disposal.
 */
class GatedAdapter extends LlmAdapter {
  readonly requests: GenerateOptions[] = []

  constructor(private script: GatedEntry[]) {
    super()
  }

  async * stream(options: GenerateOptions): AsyncIterable<StreamChunk> {
    this.requests.push(options)
    const entry = this.script.shift()
    if (!entry) throw new Error('GatedAdapter: script exhausted')
    if (entry.gate) {
      await new Promise<void>((resolve) => {
        if (options.signal?.aborted) { resolve(); return }
        const release = (): void => { resolve() }
        options.signal?.addEventListener('abort', release, { once: true })
        entry.gate!.then(release, release)
      })
    }
    for (const chunk of entry.chunks) {
      if (options.signal?.aborted) throw new Error('aborted')
      yield chunk
    }
  }
}

const testToolSignal = new AbortController().signal

const roots: string[] = []
const contexts = new Set<Context>()
afterEach(async () => {
  vi.restoreAllMocks()
  for (const ctx of contexts) await ctx.fiber.dispose()
  contexts.clear()
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

async function setupWith(adapter: MockAdapter | GatedAdapter) {
  const ctx = new Context()
  contexts.add(ctx)
  await mountAgentLoopTestDependencies(ctx)
  await mountWorkingDirectoryFixture(ctx)
  const root = mkdtempSync(join(tmpdir(), 'dsh-tool-wait-settlement-'))
  roots.push(root)
  await ctx.plugin(JsonlSessionPersistence, { root })
  await ctx.plugin(TestSessionQuery)
  await ctx.plugin(AgentLoop, { agents: [] })
  await ctx.plugin(SubagentRuntime)
  await ctx.plugin(SubagentSpawn, { providerName: 'spawn' })
  await ctx.plugin(tool)
  ctx.llm.registerAdapter(['mock'], adapter)
  const parent = await ctx.agentLoop.create(SessionId('parent'), { provider: 'mock', model: 'mock' })
  parkParent(ctx, parent)
  return { ctx, parent, adapter }
}

async function setup(script: ConstructorParameters<typeof MockAdapter>[0]) {
  return setupWith(new MockAdapter(script))
}

function text(result: { content: readonly { type: string; text?: string }[] }): string {
  return result.content.filter(block => block.type === 'text').map(block => block.text).join('')
}

let calls = 0
function callTool(
  ctx: Context,
  name: string,
  args: unknown,
  agent?: unknown,
  signal: AbortSignal = testToolSignal,
) {
  return ctx.tools.execute({
    signal,
    callId: ToolCallId(`call-${++calls}`),
    name,
    arguments: args,
    ...agent !== undefined ? { agent: agent as never } : {},
  })
}

/** Wait until a continuable child released its current Activation. */
async function waitNoActivation(ctx: Context, childId: SessionId): Promise<void> {
  await vi.waitFor(() => {
    expect(ctx.agents.get(childId)).toBeUndefined()
  }, { timeout: 5_000 })
}

describe('dsh-tool-subagent-control/wait-settlement', () => {
  it('registers wait_settlement once, globally, with agent_id required and optional wait/timeout_ms', async () => {
    const { ctx } = await setup([])
    const schemas = ctx.tools.schemas().filter(schema => schema.name === 'wait_settlement')
    expect(schemas).toHaveLength(1)
    const parameters = schemas[0]!.parameters as {
      properties?: Record<string, unknown>
      required?: string[]
    }
    expect(Object.keys(parameters.properties ?? {})).toEqual(['agent_id', 'wait', 'timeout_ms'])
    expect(parameters.required ?? []).toEqual(['agent_id'])
  })

  it('has the namespace-plugin export shape', () => {
    expect('default' in tool).toBe(false)
    expect(tool.name).toBe('tool-subagent-wait-settlement')
    expect(tool.inject).toEqual(['tools', 'subagents', 'agents'])
    expect(typeof tool.apply).toBe('function')
  })

  it('returns a current-projection outcome (not an error) when a running child outlives the wait budget', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('long child work'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'long child',
      request: { prompt: [{ type: 'text', text: 'do the long task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const result = await callTool(ctx, 'wait_settlement', {
      agent_id: started.childId,
      wait: true,
      timeout_ms: 50,
    }, parent)
    expect(result.isError).toBe(false)
    expect(text(result)).toContain('[running]')
    gate.resolve(undefined)
    await waitNoActivation(ctx, started.childId)
  })

  it('reports settled once the child settles and releases every concurrent waiter', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('short child work'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'short child',
      request: { prompt: [{ type: 'text', text: 'do the short task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const waiterA = ctx.subagents.waitSettlement(started.childId, 5_000)
    const waiterB = ctx.subagents.waitSettlement(started.childId, 5_000)
    gate.resolve(undefined)
    const [a, b] = await Promise.all([waiterA, waiterB])
    expect(a.settled).toBe(true)
    expect(b.settled).toBe(true)
    expect(a.agent.status).toBe('inactive')
    await waitNoActivation(ctx, started.childId)
  })

  it('does not throw on a timed-out wait (mirrors jobs.wait semantics)', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('still working'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'held child',
      request: { prompt: [{ type: 'text', text: 'do the long task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const outcome = await ctx.subagents.waitSettlement(started.childId, 30)
    expect(outcome.settled).toBe(false)
    expect(outcome.agent.status).toBe('running')
    expect(Number.isFinite(outcome.agent.lastActivityAt)).toBe(true)
    gate.resolve(undefined)
    await waitNoActivation(ctx, started.childId)
  })

  it('rejects a non-positive timeout like jobs.wait does', async () => {
    const { ctx, parent } = await setup([])
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'settled child',
      request: { prompt: [{ type: 'text', text: 'quick task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await waitNoActivation(ctx, started.childId)
    await expect(ctx.subagents.waitSettlement(started.childId, 0)).rejects.toThrow()
  })

  it('rejects an agent-less caller through the standard error result (not a raw rejection)', async () => {
    const { ctx } = await setup([])
    const result = await callTool(ctx, 'wait_settlement', { agent_id: SessionId('ghost') })
    expect(result.isError).toBe(true)
    expect(text(result)).toContain('requires a calling agent')
  })

  it('probes without blocking when wait is omitted, reporting the live running projection', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('long child work'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'probe running child',
      request: { prompt: [{ type: 'text', text: 'do the long task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const result = await callTool(ctx, 'wait_settlement', { agent_id: started.childId }, parent)
    expect(result.isError).toBe(false)
    expect(text(result)).toContain('[running]')
    gate.resolve(undefined)
    await waitNoActivation(ctx, started.childId)
  })

  it('reports a settled child through the probe path when wait is false', async () => {
    const { ctx, parent } = await setup([])
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'settled probe child',
      request: { prompt: [{ type: 'text', text: 'quick task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await waitNoActivation(ctx, started.childId)
    const result = await callTool(ctx, 'wait_settlement', { agent_id: started.childId, wait: false }, parent)
    expect(result.isError).toBe(false)
    expect(text(result)).toContain('[settled]')
  })

  it('reports a child that already left as settled immediately (non-resident early return)', async () => {
    const { ctx, parent } = await setup([])
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'departed child',
      request: { prompt: [{ type: 'text', text: 'quick task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await waitNoActivation(ctx, started.childId)
    const outcome = await ctx.subagents.waitSettlement(started.childId, 5_000)
    expect(outcome.settled).toBe(true)
    expect(outcome.agent.status).toBe('inactive')
  })

  it('returns the live projection immediately when the caller signal is already aborted', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('held child work'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'abort-held child',
      request: { prompt: [{ type: 'text', text: 'do the long task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const controller = new AbortController()
    controller.abort()
    const outcome = await ctx.subagents.waitSettlement(started.childId, 5_000, controller.signal)
    expect(outcome.settled).toBe(false)
    expect(outcome.agent.status).toBe('running')
    gate.resolve(undefined)
    await waitNoActivation(ctx, started.childId)
  })

  it('uses the default 30s budget when timeout_ms is omitted and settles on release', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('default-budget child'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'default budget child',
      request: { prompt: [{ type: 'text', text: 'do the short task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const pending = callTool(ctx, 'wait_settlement', { agent_id: started.childId, wait: true }, parent)
    gate.resolve(undefined)
    const result = await pending
    expect(result.isError).toBe(false)
    expect(text(result)).toContain('[settled]')
    await waitNoActivation(ctx, started.childId)
  })

  it('projects a resident idle child (waiting on its own grandchild) as inactive after the budget elapses', async () => {
    const releaseGrandchild = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('child done') },
      { chunks: textResponse('grandchild'), gate: releaseGrandchild.promise },
      { chunks: textResponse('woken') },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'child task',
      request: { prompt: [{ type: 'text', text: 'child task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    const child = await vi.waitFor(() => {
      const found = ctx.agents.get(started.childId)
      expect(found).toBeDefined()
      return found!
    })
    // The child starts its own continuable grandchild, then goes quiescent.
    const grandchild = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'grandchild task',
      request: { prompt: [{ type: 'text', text: 'grandchild task' }], parent: child },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(child.status).toBe('idle')
    }, { timeout: 5_000 })
    // Resident and idle: the wait observes an inactive projection instead of a running one.
    const outcome = await ctx.subagents.waitSettlement(started.childId, 50)
    expect(outcome.settled).toBe(false)
    expect(outcome.agent.id).toBe(started.childId)
    expect(outcome.agent.status).toBe('inactive')
    releaseGrandchild.resolve(undefined)
    await waitNoActivation(ctx, grandchild.childId)
    await waitNoActivation(ctx, started.childId)
  })

  it('treats caller cancellation (not a budget timeout) as a projection outcome without a timeout log', async () => {
    const gate = Promise.withResolvers<undefined>()
    const { ctx, parent } = await setupWith(new GatedAdapter([
      { chunks: textResponse('long child work'), gate: gate.promise },
    ]))
    const started = await ctx.subagents.startActivation({
      provider: 'spawn',
      label: 'abort child',
      request: { prompt: [{ type: 'text', text: 'do the long task' }], parent },
      signal: testToolSignal,
      delivery: 'parent',
    })
    await vi.waitFor(() => {
      expect(ctx.agents.get(started.childId)?.status).toBe('running')
    })
    const infoSpy = vi.spyOn(ctx.logger, 'info')
    const controller = new AbortController()
    const pending = ctx.subagents.waitSettlement(started.childId, 5_000, controller.signal)
    controller.abort()
    const outcome = await pending
    expect(outcome.settled).toBe(false)
    expect(outcome.agent.status).toBe('running')
    expect(infoSpy.mock.calls.some(([message]) => String(message).includes('subagent wait timed out'))).toBe(false)
    gate.resolve(undefined)
    await waitNoActivation(ctx, started.childId)
  })
})
