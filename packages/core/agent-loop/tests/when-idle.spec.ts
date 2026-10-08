import { afterEach, describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import LlmRuntime, { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import AgentRegistry, { type Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import { MockAdapter, textResponse } from './mock-adapter.ts'

const contexts = new Set<Context>()

async function harness(adapter: MockAdapter) {
  const ctx = new Context()
  contexts.add(ctx)
  await ctx.plugin(LlmRuntime)
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SystemPrompt)
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(AgentRegistry)
  await ctx.plugin(AgentLoop, { agents: [] })
  ctx.llm.registerAdapter(['mock'], adapter)
  return ctx
}

afterEach(async () => {
  for (const ctx of contexts) await ctx.fiber.dispose()
  contexts.clear()
})

/** Wait for the agent's next transition to idle after a waking send. */
function waitForIdle(ctx: Context, agent: Agent): Promise<void> {
  return new Promise((resolve) => {
    const dispose = ctx.on('agent/status', ({ agent: subject, status }) => {
      if (subject === agent && status === 'idle') {
        dispose()
        resolve()
      }
    })
  })
}

function send(agent: Agent, text: string) {
  agent.followup(createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } }))
}

describe('agent whenIdle with an idle-wait budget', () => {
  it('returns "timeout" when the agent stays busy past the budget', async () => {
    const ctx = await harness(new MockAdapter(['hang']))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-stall'), { provider: 'mock', model: 'mock' })
    send(agent, 'work forever')
    // wait until the stream is hanging, mirroring the loop.spec cancel test
    await new Promise(r => setTimeout(r, 30))
    expect(agent.status).toBe('running')
    // A compliant whenIdle resolves "timeout" after ~50ms; a non-compliant one
    // (ignoring the budget) must not hang the suite, so race it against a bound.
    const result = await Promise.race([
      agent.whenIdle({ timeoutMs: 50 }),
      new Promise<'hung'>(resolve => setTimeout(() => resolve('hung'), 2000)),
    ])
    agent.cancel({ kind: 'user' })
    await waitForIdle(ctx, agent)
    expect(result).toBe('timeout')
  })

  it('returns "idle" when quiescence arrives within the budget', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-idle'), { provider: 'mock', model: 'mock' })
    const idle = waitForIdle(ctx, agent)
    send(agent, 'finish quickly')
    await idle
    await expect(agent.whenIdle({ timeoutMs: 1000 })).resolves.toBe('idle')
  })

  it('keeps the no-arg contract byte-equivalent (unbounded wait resolves once idle)', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-noarg'), { provider: 'mock', model: 'mock' })
    const idle = waitForIdle(ctx, agent)
    send(agent, 'finish quickly')
    await idle
    await expect(agent.whenIdle()).resolves.toBe('idle')
  })

  it('rejects a non-positive timeout like jobs.wait does', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-bad-timeout'), { provider: 'mock', model: 'mock' })
    await expect(agent.whenIdle({ timeoutMs: 0 })).rejects.toThrow()
  })

  it('tracks lastActivityAt as an advancing epoch-ms timestamp', async () => {
    const ctx = await harness(new MockAdapter([textResponse('first'), textResponse('second')]))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-activity'), { provider: 'mock', model: 'mock' })
    const created = agent.lastActivityAt
    expect(Number.isFinite(created)).toBe(true)
    const idle = waitForIdle(ctx, agent)
    send(agent, 'turn one')
    await idle
    expect(agent.lastActivityAt).toBeGreaterThanOrEqual(created)
  })

  it('rejects a non-finite timeout such as NaN like jobs.wait does', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-nan'), { provider: 'mock', model: 'mock' })
    await expect(agent.whenIdle({ timeoutMs: Number.NaN })).rejects.toThrow()
  })

  it('keeps waiting across a second activity generation within one budget', async () => {
    const ctx = await harness(new MockAdapter([textResponse('first'), textResponse('second')]))
    const agent = await ctx.agentLoop.create(SessionId('when-idle-iter'), { provider: 'mock', model: 'mock' })
    const firstIdle = waitForIdle(ctx, agent)
    send(agent, 'turn one')
    await firstIdle
    const pending = agent.whenIdle({ timeoutMs: 2000 })
    // followup wakes synchronously (wakeDriver replaces activityDone before
    // whenIdle's microtask re-check), forcing the wait loop to iterate again.
    send(agent, 'turn two')
    const secondIdle = waitForIdle(ctx, agent)
    await secondIdle
    await expect(pending).resolves.toBe('idle')
  })
})
