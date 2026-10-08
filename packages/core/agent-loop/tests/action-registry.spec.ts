/**
 * Pillar A: the structured action registry intercepts a tool call that repeats
 * an identical, previously *failed* call — the behavioral counterpart to the
 * text-level degenerate detectors. It compares normalized argument fingerprints
 * (so it survives key-order and transport-metadata drift) and knows the outcome
 * (so it never blocks a first call or a successful repeat).
 */

import { describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import LlmRuntime, { createUserMessage, createToolResultMessage, ToolCallId } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId, type Session } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime, { defineContentToolFixture } from '@deepseek-ai/dsh-tools'
import AgentRegistry, { type Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import { ActionRegistry, fingerprintArguments } from '../src/action-registry.ts'
import { MockAdapter, degenerateReasoningResponse, textResponse, toolCallResponse } from './mock-adapter.ts'

declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap {
    'action-test': { kind: 'action-test' } & import('@deepseek-ai/dsh-llm').ContextFormed
  }
}

async function harness(adapter: MockAdapter) {
  const ctx = new Context()
  await ctx.plugin(LlmRuntime)
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SystemPrompt, { personaPrefix: '' })
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(AgentRegistry)
  await ctx.plugin(AgentLoop, { agents: [] })
  ctx.llm.registerAdapter(['mock'], adapter)
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

/** A tool whose every invocation fails. */
function failingTool(name: string) {
  let calls = 0
  const tool = defineContentToolFixture({
    name,
    description: `failing ${name}`,
    parameters: { cmd: { type: 'string' } },
    async execute() {
      calls += 1
      throw new Error(`${name} failed: node exited 1`)
    },
  })
  return { tool, calls: () => calls }
}

describe('fingerprintArguments', () => {
  it('is independent of key order, at any nesting depth', () => {
    expect(fingerprintArguments({ a: 1, b: { d: 2, c: 3 } }))
      .toBe(fingerprintArguments({ b: { c: 3, d: 2 }, a: 1 }))
  })

  it('ignores transport-metadata keys', () => {
    expect(fingerprintArguments({ cmd: 'x', callId: 'abc' }))
      .toBe(fingerprintArguments({ cmd: 'x', requestId: 'def' }))
    expect(fingerprintArguments({ cmd: 'x', nonce: 1 }))
      .toBe(fingerprintArguments({ cmd: 'x', traceId: 't' }))
  })

  it('keeps semantically meaningful keys and array order', () => {
    expect(fingerprintArguments({ cmd: 'x', id: 'a' }))
      .not.toBe(fingerprintArguments({ cmd: 'x', id: 'b' }))
    expect(fingerprintArguments({ list: [1, 2] }))
      .not.toBe(fingerprintArguments({ list: [2, 1] }))
    expect(fingerprintArguments({ cmd: 'x' }))
      .not.toBe(fingerprintArguments({ cmd: 'y' }))
  })

  it('collapses timestamp values (ISO-8601 prefix and bare epochs)', () => {
    expect(fingerprintArguments({ at: '2026-09-30T10:00:00Z' }))
      .toBe(fingerprintArguments({ at: '2026-09-30T11:00:00Z' }))
    expect(fingerprintArguments({ at: '2026-09-30T10:00:00.000Z' }))
      .toBe(fingerprintArguments({ at: '2026-09-30T11:00:00Z' }))
    expect(fingerprintArguments({ epoch: '1750000000000' }))
      .toBe(fingerprintArguments({ epoch: '1759999999999' }))
  })

  it('unifies path-shaped values to normalized forward slashes', () => {
    expect(fingerprintArguments({ file: './a/b' }))
      .toBe(fingerprintArguments({ file: 'a/b' }))
    expect(fingerprintArguments({ file: 'a/b' }))
      .toBe(fingerprintArguments({ file: 'a\\b' }))
    expect(fingerprintArguments({ file: 'a//b/' }))
      .toBe(fingerprintArguments({ file: 'a/b' }))
  })

  it('keeps prose and embedded identifiers untouched', () => {
    expect(fingerprintArguments({ job: 'job-12345' }))
      .not.toBe(fingerprintArguments({ job: 'job-67890' }))
    // A timestamp *inside* prose is not a timestamp value: do not conflate it.
    expect(fingerprintArguments({ note: 'ran at 2026-09-30T10:00:00Z' }))
      .not.toBe(fingerprintArguments({ note: 'ran at 2026-09-30T11:00:00Z' }))
  })
})

describe('ActionRegistry', () => {
  async function session() {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('action-registry'), {
      provider: 'mock',
      model: 'mock',
    })
    return { ctx, agent }
  }

  it('rebuilds from the session log and finds a failed identical repeat', async () => {
    const { ctx, agent } = await session()
    const callId = ToolCallId('c1')
    agent.session.append('tool/call', { turn: 1, step: 1, callId, name: 'launch', arguments: '{"cmd":"node x.js"}' })
    agent.session.append('tool/result', {
      turn: 1,
      step: 1,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: 'Error: launch failed' }],
        isError: true,
      }),
      error: { name: 'Error', code: 'EXECUTION_FAILED', reason: 'launch failed: node exited 1' },
    }, { surfaceOp: 'append' })

    const registry = new ActionRegistry(ctx, agent.session)
    const prior = registry.findFailedRepeat('launch', { cmd: 'node x.js' })
    expect(prior).toBeDefined()
    expect(prior?.isError).toBe(true)
    expect(prior?.outcome).toContain('launch failed')
  })

  it('does not report a successful call as a repeat to intercept', async () => {
    const { ctx, agent } = await session()
    const callId = ToolCallId('ok')
    agent.session.append('tool/call', { turn: 1, step: 1, callId, name: 'launch', arguments: '{"cmd":"node x.js"}' })
    agent.session.append('tool/result', {
      turn: 1,
      step: 1,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: 'started' }],
        isError: false,
      }),
    }, { surfaceOp: 'append' })

    const registry = new ActionRegistry(ctx, agent.session)
    expect(registry.findFailedRepeat('launch', { cmd: 'node x.js' })).toBeUndefined()
  })

  it('does not conflate different arguments', async () => {
    const { ctx, agent } = await session()
    const callId = ToolCallId('c1')
    agent.session.append('tool/call', { turn: 1, step: 1, callId, name: 'launch', arguments: '{"cmd":"node x.js"}' })
    agent.session.append('tool/result', {
      turn: 1,
      step: 1,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: 'Error' }],
        isError: true,
      }),
      error: { name: 'Error', code: 'EXECUTION_FAILED' },
    }, { surfaceOp: 'append' })

    const registry = new ActionRegistry(ctx, agent.session)
    expect(registry.findFailedRepeat('launch', { cmd: 'node y.js' })).toBeUndefined()
    expect(registry.findFailedRepeat('other', { cmd: 'node x.js' })).toBeUndefined()
  })

  it('follows live tool/result events appended after construction', async () => {
    const { ctx, agent } = await session()
    const registry = new ActionRegistry(ctx, agent.session)
    expect(registry.findFailedRepeat('launch', { cmd: 'node x.js' })).toBeUndefined()

    const callId = ToolCallId('c1')
    agent.session.append('tool/call', { turn: 1, step: 1, callId, name: 'launch', arguments: '{"cmd":"node x.js"}' })
    agent.session.append('tool/result', {
      turn: 1,
      step: 1,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: 'Error' }],
        isError: true,
      }),
      error: { name: 'Error', code: 'EXECUTION_FAILED' },
    }, { surfaceOp: 'append' })

    const prior = registry.findFailedRepeat('launch', { cmd: 'node x.js' })
    expect(prior).toBeDefined()
    expect(prior?.isError).toBe(true)
  })

  it('exposes the most recent completed action for stateful recovery notices', async () => {
    const { ctx, agent } = await session()
    const registry = new ActionRegistry(ctx, agent.session)
    // No actions have run yet: nothing to cite.
    expect(registry.lastAction()).toBeUndefined()

    const callId = ToolCallId('c1')
    agent.session.append('tool/call', { turn: 1, step: 1, callId, name: 'launch', arguments: '{"cmd":"node x.js"}' })
    agent.session.append('tool/result', {
      turn: 1,
      step: 1,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: 'started' }],
        isError: false,
      }),
    }, { surfaceOp: 'append' })

    const last = registry.lastAction()
    expect(last?.toolName).toBe('launch')
    expect(last?.isError).toBe(false)
    expect(last?.outcome).toBe('started')
  })
})

describe('ActionRegistry.findStalledRepeat', () => {
  async function session() {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('action-stalled'), {
      provider: 'mock',
      model: 'mock',
    })
    return { ctx, agent }
  }

  /** Append one completed successful tool call with the given outcome text. */
  function appendSuccess(session: Session, step: number, name: string, rawArgs: string, outcome: string) {
    const callId = ToolCallId(`s${step}`)
    session.append('tool/call', { turn: 1, step, callId, name, arguments: rawArgs })
    session.append('tool/result', {
      turn: 1,
      step,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: outcome }],
        isError: false,
      }),
    }, { surfaceOp: 'append' })
  }

  it('three byte-identical successful outcomes of the same call are a stall', async () => {
    const { ctx, agent } = await session()
    for (let step = 1; step <= 3; step += 1) {
      appendSuccess(agent.session, step, 'read', '{"path":"a.txt"}', 'same output')
    }
    const registry = new ActionRegistry(ctx, agent.session)
    const stalled = registry.findStalledRepeat('read', { path: 'a.txt' })
    expect(stalled).toBeDefined()
    expect(stalled?.isError).toBe(false)
    expect(stalled?.outcome).toBe('same output')
  })

  it('two identical successes are not yet a stall', async () => {
    const { ctx, agent } = await session()
    appendSuccess(agent.session, 1, 'read', '{"path":"a.txt"}', 'same output')
    appendSuccess(agent.session, 2, 'read', '{"path":"a.txt"}', 'same output')
    const registry = new ActionRegistry(ctx, agent.session)
    expect(registry.findStalledRepeat('read', { path: 'a.txt' })).toBeUndefined()
  })

  it('a differing call in the trail breaks the streak', async () => {
    const { ctx, agent } = await session()
    appendSuccess(agent.session, 1, 'read', '{"path":"a.txt"}', 'same output')
    appendSuccess(agent.session, 2, 'read', '{"path":"a.txt"}', 'same output')
    appendSuccess(agent.session, 3, 'write', '{"path":"a.txt","content":"x"}', 'written')
    appendSuccess(agent.session, 4, 'read', '{"path":"a.txt"}', 'same output')
    appendSuccess(agent.session, 5, 'read', '{"path":"a.txt"}', 'same output')
    const registry = new ActionRegistry(ctx, agent.session)
    // The trailing streak is only two reads long: the write breaks it.
    expect(registry.findStalledRepeat('read', { path: 'a.txt' })).toBeUndefined()
  })

  it('a different-argument call breaks the streak', async () => {
    const { ctx, agent } = await session()
    appendSuccess(agent.session, 1, 'read', '{"path":"a.txt"}', 'same output')
    appendSuccess(agent.session, 2, 'read', '{"path":"a.txt"}', 'same output')
    appendSuccess(agent.session, 3, 'read', '{"path":"b.txt"}', 'same output')
    const registry = new ActionRegistry(ctx, agent.session)
    // The query must match the *trailing* run: a.txt never runs three deep.
    expect(registry.findStalledRepeat('read', { path: 'a.txt' })).toBeUndefined()
    expect(registry.findStalledRepeat('read', { path: 'b.txt' })).toBeUndefined()
  })

  it('changing outcome breaks the streak (a verification loop is not a stall)', async () => {
    const { ctx, agent } = await session()
    appendSuccess(agent.session, 1, 'read', '{"path":"a.txt"}', 'v1')
    appendSuccess(agent.session, 2, 'read', '{"path":"a.txt"}', 'v1')
    appendSuccess(agent.session, 3, 'read', '{"path":"a.txt"}', 'v2')
    const registry = new ActionRegistry(ctx, agent.session)
    expect(registry.findStalledRepeat('read', { path: 'a.txt' })).toBeUndefined()
  })
})

describe('agent loop: identical failed action interception', () => {
  it('intercepts a re-run of an identical failed call, executes it only once', async () => {
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'launch', { cmd: 'node x.js' }, 'launching'),
      toolCallResponse('c2', 'launch', { cmd: 'node x.js' }),
      textResponse('done'),
    ])
    const ctx = await harness(adapter)
    const failing = failingTool('launch')
    ctx.tools.register(failing.tool)
    const agent = await ctx.agentLoop.create(SessionId('action-repeat'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'launch the node script')
    await waitForIdle(ctx, agent)

    // The first call ran and failed; the identical second call was intercepted
    // BEFORE execution, so the tool body ran exactly once.
    expect(failing.calls()).toBe(1)

    // The model received the targeted intervention notice.
    expect(userTexts(agent).some(text => text.includes('You already ran `launch` with identical arguments'))).toBe(true)
    expect(userTexts(agent).some(text => text.includes('launch failed: node exited 1'))).toBe(true)

    // Only one tool/result was ever recorded (the failed first call); the
    // intercepted call never reached the session log.
    const results = agent.session.snapshotEvents().filter(event => event.type === 'tool/result')
    expect(results).toHaveLength(1)

    // The turn completed normally with the final scripted reply.
    const done = agent.session.snapshotEvents().findLast(event =>
      event.type === 'assistant/message'
      && event.data.message.content.some(block => block.type === 'text' && block.text === 'done'))
    expect(done).toBeDefined()
  })

  it('does not intercept a repeat with different arguments', async () => {
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'launch', { cmd: 'node x.js' }),
      toolCallResponse('c2', 'launch', { cmd: 'node y.js' }),
      textResponse('done'),
    ])
    const ctx = await harness(adapter)
    const failing = failingTool('launch')
    ctx.tools.register(failing.tool)
    const agent = await ctx.agentLoop.create(SessionId('action-diff-args'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'launch both scripts')
    await waitForIdle(ctx, agent)

    // Different arguments are not a repeat: both calls executed.
    expect(failing.calls()).toBe(2)
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(false)
  })

  it('does not intercept a successful repeat', async () => {
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'ping', { host: 'h' }),
      toolCallResponse('c2', 'ping', { host: 'h' }),
      textResponse('done'),
    ])
    const ctx = await harness(adapter)
    let calls = 0
    ctx.tools.register(defineContentToolFixture({
      name: 'ping',
      description: 'succeeds',
      parameters: { host: { type: 'string' } },
      async execute() {
        calls += 1
        return [{ type: 'text', text: `pong ${calls}` }]
      },
    }))
    const agent = await ctx.agentLoop.create(SessionId('action-success-repeat'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'ping twice')
    await waitForIdle(ctx, agent)

    expect(calls).toBe(2)
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(false)
  })

  it('intercepts the fourth byte-identical successful call (zero-progress loop)', async () => {
    // Pillar C: a *successful* call can still be a loop when every outcome is
    // byte-identical — reading the same file three times returns the same
    // content and makes no net progress. The fourth identical call is
    // intercepted BEFORE execution with a targeted notice.
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'read', { path: 'a.txt' }),
      toolCallResponse('c2', 'read', { path: 'a.txt' }),
      toolCallResponse('c3', 'read', { path: 'a.txt' }),
      toolCallResponse('c4', 'read', { path: 'a.txt' }),
      textResponse('done'),
    ])
    const ctx = await harness(adapter)
    let calls = 0
    ctx.tools.register(defineContentToolFixture({
      name: 'read',
      description: 'reads a file',
      parameters: { path: { type: 'string' } },
      async execute() {
        calls += 1
        return [{ type: 'text', text: 'same output' }]
      },
    }))
    const agent = await ctx.agentLoop.create(SessionId('action-stalled-repeat'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'read the file repeatedly')
    await waitForIdle(ctx, agent)

    // Three identical successful calls ran; the fourth was intercepted BEFORE
    // execution, so the tool body executed exactly three times.
    expect(calls).toBe(3)
    expect(userTexts(agent).some(text => text.includes('makes no net progress'))).toBe(true)
    expect(userTexts(agent).some(text => text.includes('You already ran `read` with identical arguments'))).toBe(true)

    // Only the three executed calls recorded a tool/result; the intercepted
    // fourth never reached the session log.
    const results = agent.session.snapshotEvents().filter(event => event.type === 'tool/result')
    expect(results).toHaveLength(3)

    // The turn completed normally with the final scripted reply.
    const done = agent.session.snapshotEvents().findLast(event =>
      event.type === 'assistant/message'
      && event.data.message.content.some(block => block.type === 'text' && block.text === 'done'))
    expect(done).toBeDefined()
  })

  it('degenerate notice cites the concrete reason and the last action outcome (stateful recovery)', async () => {
    // Pillar B: a degenerate/repetition intervention is no longer generic
    // "no filler" boilerplate — it must cite *what* was repeated (the
    // detector's own reason), the *last action's result* (which the text-level
    // detectors cannot see), and an explicit next step.
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'launch', { cmd: 'node x.js' }, 'launching'),
      degenerateReasoningResponse(200),
      textResponse('recovered'),
    ])
    const ctx = await harness(adapter)
    const failing = failingTool('launch')
    ctx.tools.register(failing.tool)
    ctx.on('agent/request-error', async ({ failure }) => {
      if (failure.code === 'DEGENERATE_OUTPUT') return { kind: 'retry' as const }
      return undefined
    })
    const agent = await ctx.agentLoop.create(SessionId('degenerate-notice'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'launch the node script then keep working')
    await waitForIdle(ctx, agent)

    // Exactly one stateful degenerate notice was surfaced.
    const notices = userTexts(agent).filter(text => text.includes('classified as degenerate'))
    expect(notices).toHaveLength(1)
    const notice = notices[0]!
    // The concrete detector reason is cited (what the model repeated).
    expect(notice).toMatch(/degenerate output/)
    // The last action's failure is cited — the loop's visible consequence.
    expect(notice).toContain('The last action `launch`')
    expect(notice).toContain('failed:')
    expect(notice).toContain('launch failed: node exited 1')
    // An explicit next step is present.
    expect(notice).toContain('fix the failing action and retry it')
    // The retried request recovered to the scripted answer.
    const recovered = agent.session.snapshotEvents().findLast(event =>
      event.type === 'assistant/message'
      && event.data.message.content.some(block => block.type === 'text' && block.text === 'recovered'))
    expect(recovered).toBeDefined()
  })
})

describe('ActionRegistry file targeting (Pillar C input)', () => {
  async function session() {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('action-file-target'), {
      provider: 'mock',
      model: 'mock',
    })
    return { ctx, agent }
  }

  function appendFailed(
    session: Session,
    step: number,
    name: string,
    rawArgs: string,
    error: { name: string; code: string; reason?: string },
  ) {
    const callId = ToolCallId(`f${step}`)
    session.append('tool/call', { turn: 1, step, callId, name, arguments: rawArgs })
    session.append('tool/result', {
      turn: 1,
      step,
      message: createToolResultMessage({
        callId,
        content: [{ type: 'text', text: `Error: ${error.code}` }],
        isError: true,
      }),
      error,
    }, { surfaceOp: 'append' })
  }

  it('captures a normalized file_path from edit arguments', async () => {
    const { ctx, agent } = await session()
    // Raw JSON carries a Windows-style backslash path.
    appendFailed(agent.session, 1, 'edit', '{"file_path":"a\\\\b.txt","old_string":"x","new_string":"y"}', { name: 'FsError', code: 'FS_STALE_VERSION' })
    const registry = new ActionRegistry(ctx, agent.session)
    const prior = registry.findFailedRepeat('edit', { file_path: 'a\\b.txt', old_string: 'x', new_string: 'y' })
    expect(prior).toBeDefined()
    expect(prior?.filePath).toBe('a/b.txt')
  })

  it('leaves filePath undefined when the arguments carry no file_path', async () => {
    const { ctx, agent } = await session()
    appendFailed(agent.session, 1, 'edit', '{"old_string":"x","new_string":"y"}', { name: 'FsError', code: 'FS_STALE_VERSION' })
    const registry = new ActionRegistry(ctx, agent.session)
    const prior = registry.findFailedRepeat('edit', { old_string: 'x', new_string: 'y' })
    expect(prior).toBeDefined()
    expect(prior?.filePath).toBeUndefined()
  })

  it('leaves filePath undefined for a non-string file_path', async () => {
    const { ctx, agent } = await session()
    appendFailed(agent.session, 1, 'edit', '{"file_path":123,"old_string":"x","new_string":"y"}', { name: 'FsError', code: 'FS_STALE_VERSION' })
    const registry = new ActionRegistry(ctx, agent.session)
    const prior = registry.findFailedRepeat('edit', { file_path: 123, old_string: 'x', new_string: 'y' })
    expect(prior).toBeDefined()
    expect(prior?.filePath).toBeUndefined()
  })
})

describe('ActionRegistry.hasObservingActionAfter (Pillar C re-observation)', () => {
  async function session() {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('action-observing-after'), {
      provider: 'mock',
      model: 'mock',
    })
    return { ctx, agent }
  }

  function appendSuccess(session: Session, step: number, name: string, rawArgs: string, outcome: string) {
    const callId = ToolCallId(`s${step}`)
    session.append('tool/call', { turn: 1, step, callId, name, arguments: rawArgs })
    session.append('tool/result', {
      turn: 1,
      step,
      message: createToolResultMessage({ callId, content: [{ type: 'text', text: outcome }], isError: false }),
    }, { surfaceOp: 'append' })
  }

  function appendFailed(
    session: Session,
    step: number,
    name: string,
    rawArgs: string,
    error: { name: string; code: string },
  ) {
    const callId = ToolCallId(`f${step}`)
    session.append('tool/call', { turn: 1, step, callId, name, arguments: rawArgs })
    session.append('tool/result', {
      turn: 1,
      step,
      message: createToolResultMessage({ callId, content: [{ type: 'text', text: `Error: ${error.code}` }], isError: true }),
      error,
    }, { surfaceOp: 'append' })
  }

  const editArgs = JSON.stringify({ file_path: 'a.txt', old_string: 'x', new_string: 'y' })

  async function failedEditPrior(ctx: Context, agent: Agent) {
    appendFailed(agent.session, 1, 'edit', editArgs, { name: 'FsError', code: 'FS_STALE_VERSION' })
    const registry = new ActionRegistry(ctx, agent.session)
    const prior = registry.findFailedRepeat('edit', { file_path: 'a.txt', old_string: 'x', new_string: 'y' })
    expect(prior).toBeDefined()
    return { registry, prior: prior! }
  }

  it('is true when a successful read of the same path follows the failure', async () => {
    const { ctx, agent } = await session()
    const { registry, prior } = await failedEditPrior(ctx, agent)
    expect(registry.hasObservingActionAfter(prior)).toBe(false)
    appendSuccess(agent.session, 2, 'read', JSON.stringify({ file_path: 'a.txt' }), 'content')
    expect(registry.hasObservingActionAfter(prior)).toBe(true)
  })

  it('is true when a successful edit of the same path follows the failure (edit observes too)', async () => {
    const { ctx, agent } = await session()
    const { registry, prior } = await failedEditPrior(ctx, agent)
    appendSuccess(agent.session, 2, 'edit', JSON.stringify({ file_path: 'a.txt', old_string: 'x', new_string: 'z' }), 'edited')
    expect(registry.hasObservingActionAfter(prior)).toBe(true)
  })

  it('is false when the following observing call targets a different path', async () => {
    const { ctx, agent } = await session()
    const { registry, prior } = await failedEditPrior(ctx, agent)
    appendSuccess(agent.session, 2, 'read', JSON.stringify({ file_path: 'b.txt' }), 'content')
    expect(registry.hasObservingActionAfter(prior)).toBe(false)
  })

  it('is false when the following same-path call is not an observing tool', async () => {
    const { ctx, agent } = await session()
    const { registry, prior } = await failedEditPrior(ctx, agent)
    appendSuccess(agent.session, 2, 'launch', JSON.stringify({ file_path: 'a.txt' }), 'started')
    expect(registry.hasObservingActionAfter(prior)).toBe(false)
  })

  it('is false when the following observing call failed (errors never refresh the basis)', async () => {
    const { ctx, agent } = await session()
    const { registry, prior } = await failedEditPrior(ctx, agent)
    appendFailed(agent.session, 2, 'read', JSON.stringify({ file_path: 'a.txt' }), { name: 'Error', code: 'READ_FAILED' })
    expect(registry.hasObservingActionAfter(prior)).toBe(false)
  })

  it('is false for a prior without a file path even with observing calls after', async () => {
    const { ctx, agent } = await session()
    appendFailed(agent.session, 1, 'launch', JSON.stringify({ cmd: 'node x.js' }), { name: 'Error', code: 'EXECUTION_FAILED' })
    const registry = new ActionRegistry(ctx, agent.session)
    const prior = registry.findFailedRepeat('launch', { cmd: 'node x.js' })
    expect(prior).toBeDefined()
    expect(prior?.filePath).toBeUndefined()
    appendSuccess(agent.session, 2, 'read', JSON.stringify({ file_path: 'a.txt' }), 'content')
    expect(registry.hasObservingActionAfter(prior!)).toBe(false)
  })
})
