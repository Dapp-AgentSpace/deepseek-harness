/**
 * The hard progress gate (STALL): the last line of defense when a turn makes no
 * durable progress — a stream that never finishes, a guard exhausted by
 * repeated degenerate completions, or a turn whose wall-clock budget expires.
 * Every intervention surfaces a durable notice and fails the turn with the
 * STALLED_OUTPUT code (not in the default retryable set), so the driver never
 * burns retry budget on an already-exhausted loop. Guard counters persist in
 * the session history (they survive compaction and agent recreation), and a
 * clean settle *decays* them by one instead of resetting them, so a good step
 * lengthens the runway without erasing a long bad history.
 */

import { afterEach, describe, expect, it } from 'vitest'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import LlmRuntime, { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId, type Session } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineContentToolFixture } from '@deepseek-ai/dsh-tools'
import AgentRegistry, { type Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import JsonlSessionPersistence from '@deepseek-ai/dsh-session-persistence-jsonl'
import { MockAdapter, textResponse, toolCallResponse, degenerateReasoningResponse } from './mock-adapter.ts'

declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap {
    'stall-test': { kind: 'stall-test'; form: 'notice' }
  }
}

const dirs: string[] = []
afterEach(async () => { for (const dir of dirs.splice(0)) await rm(dir, { recursive: true, force: true }) })

async function coreContext() {
  const ctx = new Context()
  await ctx.plugin(LlmRuntime)
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SystemPrompt, { personaPrefix: '' })
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(AgentRegistry)
  return ctx
}

async function harness(adapter: MockAdapter) {
  const ctx = await coreContext()
  ctx.llm.registerAdapter(['mock'], adapter)
  await ctx.plugin(AgentLoop, { agents: [] })
  return ctx
}

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

/** All user-message texts in the log (asserting what the model was told). */
function userTexts(agent: Agent): string[] {
  return agent.session.snapshotEvents()
    .filter(event => event.type === 'user/message')
    .flatMap(event => event.type === 'user/message' ? event.data.content : [])
    .flatMap(block => block.type === 'text' ? [block.text] : [])
}

/** Hard-error codes the driver surfaced (each STALL carries `STALLED_OUTPUT`). */
function errorCodes(ctx: Context, _agent: Agent): string[] {
  const codes: string[] = []
  ctx.on('agent/error', ({ error }) => {
    if (error instanceof Error) {
      const failure = (error as { failure?: { code?: string } }).failure
      if (failure?.code !== undefined) codes.push(failure.code)
    }
  })
  return codes
}

/** Append a todo/write event so the todo guard sees pending todos. */
function appendTodo(session: Session) {
  session.append('todo/write', {
    todos: [{ content: 'finish the review', status: 'pending' }],
  })
}

/** A todo-guard intervention notice exactly as the loop surfaces it. */
function todoNotice() {
  return createUserMessage({
    content: [{
      type: 'text',
      text: '(System) The session log still contains unfinished todo items. If you were answering the user directly and the reply is complete, explicitly mark those items completed with the todo tool before ending; otherwise keep executing the unfinished todos instead of ending the turn early.',
    }],
    source: { kind: 'stall-test', form: 'notice' },
  })
}

describe('streaming wall-clock hard limit', () => {
  it('fails a stream that never finishes with STALLED_OUTPUT and a durable notice', async () => {
    const ctx = await harness(new MockAdapter(['stall']))
    const codes = errorCodes(ctx, ctx.agents.get(SessionId('stall-stream')) as Agent)
    const agent = await ctx.agentLoop.create(SessionId('stall-stream'), {
      provider: 'mock',
      model: 'mock',
      streamingHardLimitMs: 150,
    })
    const idle = waitForIdle(ctx, agent)
    send(agent, 'keep going')
    await idle

    // The stream was cut by the hard limit, not by a finish chunk.
    expect(userTexts(agent).some(text => text.includes('without a finish chunk'))).toBe(true)
    expect(codes).toContain('STALLED_OUTPUT')
    await ctx.fiber.dispose()
  })
})

describe('guard budget exhausted → hard error', () => {
  it('todo guard: the third consecutive premature completion STALLs instead of passing through', async () => {
    const ctx = await harness(new MockAdapter([
      textResponse('done'),
      textResponse('done'),
      textResponse('done'),
    ]))
    const agent = await ctx.agentLoop.create(SessionId('stall-todo-guard'), {
      provider: 'mock',
      model: 'mock',
    })
    const codes = errorCodes(ctx, agent)
    appendTodo(agent.session)

    const idle = waitForIdle(ctx, agent)
    send(agent, 'finish it')
    await idle

    expect(userTexts(agent).filter(text => text.includes('still contains unfinished todo items'))).toHaveLength(2)
    expect(userTexts(agent).some(text => text.includes('todo guard exhausted'))).toBe(true)
    expect(codes).toEqual(['STALLED_OUTPUT'])
    await ctx.fiber.dispose()
  })

  it('persists guard counts across a reload: a resumed agent STALLs on its first premature completion', async () => {
    const root = await mkdtemp(join(tmpdir(), 'dsh-stall-persist-'))
    dirs.push(root)
    // Core context WITHOUT a pre-registered AgentLoop so the same ctx can
    // mount (and unmount) the loop twice against one persisted root.
    const ctx = await coreContext()
    await ctx.plugin(JsonlSessionPersistence, { root })
    ctx.llm.registerAdapter(['mock'], new MockAdapter([textResponse('done')]))
    const config = { agents: [{ id: 'main', sessionId: SessionId('stall-persisted'), provider: 'mock', model: 'mock' }] }

    // First loop: a session that already accumulated two todo-guard notices
    // (the loop abandoned two premature completions) and a pending todo.
    const firstLoop = await ctx.plugin(AgentLoop, config)
    await expect.poll(() => ctx.agents.get(SessionId('stall-persisted'))).toBeDefined()
    const first = ctx.agents.get(SessionId('stall-persisted'))!
    appendTodo(first.session)
    first.session.append('user/message', todoNotice(), { surfaceOp: 'append' })
    first.session.append('user/message', todoNotice(), { surfaceOp: 'append' })
    await ctx.sessions.flush(first.session)
    await firstLoop.dispose()

    // Reload: the fresh agent's constructor seeds the guard counters from
    // history — the notices survived, so the very first premature completion
    // hard-errors instead of getting a free pass.
    const secondLoop = await ctx.plugin(AgentLoop, config)
    await expect.poll(() => ctx.agents.get(SessionId('stall-persisted'))).toBeDefined()
    const second = ctx.agents.get(SessionId('stall-persisted'))!
    const codes = errorCodes(ctx, second)
    const idle = waitForIdle(ctx, second)
    send(second, 'wrap up')
    await idle

    expect(userTexts(second).some(text => text.includes('todo guard exhausted'))).toBe(true)
    expect(codes).toEqual(['STALLED_OUTPUT'])
    await secondLoop.dispose()
    await ctx.fiber.dispose()
  })

  it('decays guard counts on a clean settle: one good step lengthens the runway without resetting history', async () => {
    const ctx = await harness(new MockAdapter([
      textResponse('done'),
      textResponse('done'),
      toolCallResponse('p1', 'ping', { host: 'h' }),
      textResponse('done'),
      textResponse('done'),
    ]))
    let pings = 0
    ctx.tools.register(defineContentToolFixture({
      name: 'ping',
      description: 'pings a host',
      parameters: { host: { type: 'string' } },
      async execute() {
        pings += 1
        return [{ type: 'text', text: 'pong' }]
      },
    }))
    const agent = await ctx.agentLoop.create(SessionId('stall-decay'), {
      provider: 'mock',
      model: 'mock',
    })
    const codes = errorCodes(ctx, agent)
    appendTodo(agent.session)

    const idle = waitForIdle(ctx, agent)
    send(agent, 'work through it')
    await idle

    // bad, bad, good, bad, bad: the two early premature completions (count 2)
    // decay to 1 at the ping settle; the two later ones reach 2 again and the
    // final completion hard-errors — two abandon notices on each run, with the
    // stall itself carrying no notice (the hard error is the signal). With the
    // old reset behavior the ping would zero the counter and this would never
    // stall.
    expect(pings).toBe(1)
    expect(userTexts(agent).filter(text => text.includes('still contains unfinished todo items'))).toHaveLength(3)
    expect(userTexts(agent).some(text => text.includes('todo guard exhausted'))).toBe(true)
    expect(codes).toEqual(['STALLED_OUTPUT'])
    await ctx.fiber.dispose()
  })
})

describe('turn-level stall gate', () => {
  it('hard-stalls a turn that keeps retrying degenerate output with no durable progress', async () => {
    const ctx = await harness(new MockAdapter([
      degenerateReasoningResponse(200),
      textResponse('done'),
    ]))
    // Degenerate output is retryable by default; keep retrying so the loop only
    // exits when the wall-clock stall gate fires.
    ctx.on('agent/request-error', async ({ failure }) => {
      if (failure.code === 'DEGENERATE_OUTPUT') return { kind: 'retry' as const }
      return undefined
    })
    const agent = await ctx.agentLoop.create(SessionId('stall-turn-gate'), {
      provider: 'mock',
      model: 'mock',
      stallHardLimitMs: 1,
    })
    const codes = errorCodes(ctx, agent)
    const idle = waitForIdle(ctx, agent)
    send(agent, 'try again')
    await idle

    expect(userTexts(agent).some(text => text.includes('no durable progress'))).toBe(true)
    expect(codes).toContain('STALLED_OUTPUT')
    await ctx.fiber.dispose()
  })
})
