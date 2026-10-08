/**
 * Pillar D: the job journal makes background-job state *durable* across agent
 * reload. Jobs live in the process-local registry and die with their owner, but
 * the session log records every `job_output`/`job_kill` call (structured
 * `job_id` argument) and every background producer result (`moved to background
 * job <id>`, workflow/subagent/JSON job ids). The journal replays that history
 * on construction, so a resumed/recreated agent knows which jobs its
 * predecessor started — and injects a one-shot recovery notice instead of
 * flailing against an empty registry (the observed c079 failure). Every fact is
 * read from a structured argument or a controlled tool-rendered format; no
 * model text is ever classified.
 */

import { describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import LlmRuntime, { createToolResultMessage, createUserMessage, ToolCallId } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId, SessionSeq } from '@deepseek-ai/dsh-session'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'
import AgentRegistry, { type Agent } from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import {
  JobJournal,
  jobIdFromProducerText,
  renderJobInventory,
  statusFromJobResultText,
} from '../src/job-journal.ts'
import { MockAdapter, textResponse } from './mock-adapter.ts'

declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap {
    'job-journal-test': { kind: 'job-journal-test' } & import('@deepseek-ai/dsh-llm').ContextFormed
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

/** A `tool/result` message body for direct session appends. */
function toolResult(callId: string, text: string, isError = false) {
  return createToolResultMessage({
    callId: ToolCallId(callId),
    content: [{ type: 'text', text }],
    isError,
  })
}

/** Append a surface-eligible `tool/result` event with the required marker. */
function appendToolResult(agent: Agent, data: unknown) {
  return (agent.session.append as (type: string, data: unknown, surface?: unknown) => unknown)(
    'tool/result',
    data,
    { surfaceOp: 'append' },
  )
}

describe('statusFromJobResultText', () => {
  it('reads the controlled `[status: …]` line', () => {
    expect(statusFromJobResultText('(no new output)\n[status: running]')).toBe('running')
    expect(statusFromJobResultText('[status: completed, review done]')).toBe('completed')
  })

  it('marks a job that no longer exists as unknown', () => {
    expect(statusFromJobResultText('Error: unknown job pwsh-12')).toBe('unknown')
  })

  it('marks a kill receipt for an already-settled job as finished', () => {
    expect(statusFromJobResultText('job pwsh-4 had already finished')).toBe('finished')
  })

  it('returns undefined for unrelated text', () => {
    expect(statusFromJobResultText('some random model text')).toBeUndefined()
  })
})

describe('jobIdFromProducerText', () => {
  it('extracts a pwsh/bash promotion job id', () => {
    expect(jobIdFromProducerText('[still running after 120000ms; moved to background job pwsh-4]\nThe command keeps running in the background.'))
      .toBe('pwsh-4')
  })

  it('extracts a workflow background job id', () => {
    expect(jobIdFromProducerText('workflow "audit" started in the background as job workflow-1. Its return value arrives with the completion notice.'))
      .toBe('workflow-1')
  })

  it('extracts a subagent background job id', () => {
    expect(jobIdFromProducerText('started background subagent job subagent-7')).toBe('subagent-7')
  })

  it('extracts a structured JSON job id', () => {
    expect(jobIdFromProducerText('{"kind":"background","jobId":"pty-send-1","runId":"run-1"}')).toBe('pty-send-1')
  })

  it('returns undefined when the result names no job', () => {
    expect(jobIdFromProducerText('completed in 3ms')).toBeUndefined()
  })
})

describe('JobJournal', () => {
  async function session() {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('job-journal'), {
      provider: 'mock',
      model: 'mock',
    })
    return { ctx, agent }
  }

  it('rebuilds promotion + status tracking from the session log', async () => {
    const { ctx, agent } = await session()
    // A pwsh call that promoted to a background job, then a wait that saw it running.
    agent.session.append('tool/call', { turn: 1, step: 1, callId: ToolCallId('p1'), name: 'pwsh', arguments: '{"command":"node review.js --full"}' })
    const promotedSeq = (appendToolResult(agent, { turn: 1, step: 1, message: toolResult('p1', '[still running after 120000ms; moved to background job pwsh-4]') }) as { seq: SessionSeq }).seq
    agent.session.append('tool/call', { turn: 1, step: 2, callId: ToolCallId('w1'), name: 'job_output', arguments: '{"job_id":"pwsh-4","wait":true}' })
    const statusSeq = (appendToolResult(agent, { turn: 1, step: 2, message: toolResult('w1', '(no new output)\n[status: running]') }) as { seq: SessionSeq }).seq

    const journal = new JobJournal(ctx, agent.session)
    expect(journal.count()).toBe(1)
    const record = journal.get('pwsh-4')
    expect(record?.kind).toBe('pwsh')
    expect(record?.label).toContain('node review.js')
    expect(record?.lastStatus).toBe('running')
    expect(record?.firstSeenSeq).toBe(promotedSeq)
    expect(record?.lastSeenSeq).toBe(statusSeq)
  })

  it('records a job addressed only through job tools as kind job', async () => {
    const { ctx, agent } = await session()
    agent.session.append('tool/call', { turn: 1, step: 1, callId: ToolCallId('k1'), name: 'job_kill', arguments: '{"job_id":"pwsh-12"}' })
    appendToolResult(agent, { turn: 1, step: 1, message: toolResult('k1', 'Error: unknown job pwsh-12', true) })

    const journal = new JobJournal(ctx, agent.session)
    expect(journal.get('pwsh-12')).toMatchObject({ kind: 'job', lastStatus: 'unknown' })
  })

  it('follows live events appended after construction', async () => {
    const { ctx, agent } = await session()
    const journal = new JobJournal(ctx, agent.session)
    expect(journal.count()).toBe(0)

    agent.session.append('tool/call', { turn: 1, step: 1, callId: ToolCallId('s1'), name: 'subagent', arguments: '{"description":"audit the repo"}' })
    appendToolResult(agent, { turn: 1, step: 1, message: toolResult('s1', 'started background subagent job subagent-7') })

    expect(journal.get('subagent-7')?.kind).toBe('subagent')
    expect(journal.get('subagent-7')?.label).toBe('audit the repo')
  })

  it('a producer result naming no job creates no record', async () => {
    const { ctx, agent } = await session()
    agent.session.append('tool/call', { turn: 1, step: 1, callId: ToolCallId('f1'), name: 'pwsh', arguments: '{"command":"echo hi"}' })
    appendToolResult(agent, { turn: 1, step: 1, message: toolResult('f1', 'hi') })

    const journal = new JobJournal(ctx, agent.session)
    expect(journal.count()).toBe(0)
  })
})

describe('ingestSummaryText', () => {
  async function session() {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('journal-summary'), {
      provider: 'mock',
      model: 'mock',
    })
    return { ctx, agent }
  }

  it('ingests job ids spelled out in a compaction summary text', async () => {
    const { ctx, agent } = await session()
    const journal = new JobJournal(ctx, agent.session)
    journal.ingestSummaryText(
      'launched pwsh-4 and subagent-1; workflow-9 still running; also terminal_send-2 and pty-send-3',
      SessionSeq(10),
    )

    expect(journal.count()).toBe(5)
    for (const jobId of ['pwsh-4', 'subagent-1', 'workflow-9', 'terminal_send-2', 'pty-send-3']) {
      expect(journal.get(jobId)).toMatchObject({
        jobId,
        kind: 'job',
        firstSeenSeq: SessionSeq(10),
        lastSeenSeq: SessionSeq(10),
      })
    }
  })

  it('ignores bare numbers and prose that merely mentions numbers', async () => {
    const { ctx, agent } = await session()
    const journal = new JobJournal(ctx, agent.session)
    journal.ingestSummaryText(
      'finished 4 tasks and saw 1750000000000 ms elapsed; the workflow-9 job id is fine',
      SessionSeq(10),
    )

    expect(journal.get('4')).toBeUndefined()
    expect(journal.get('1750000000000')).toBeUndefined()
    expect(journal.get('workflow-9')).toMatchObject({ jobId: 'workflow-9', kind: 'job' })
  })

  it('never downgrades a richer live record, only advances lastSeenSeq', async () => {
    const { ctx, agent } = await session()
    // A live promotion produced a richer kind ('pwsh' + label) than 'job'.
    agent.session.append('tool/call', { turn: 1, step: 1, callId: ToolCallId('p1'), name: 'pwsh', arguments: '{"command":"node review.js"}' })
    appendToolResult(agent, { turn: 1, step: 1, message: toolResult('p1', '[still running after 120000ms; moved to background job pwsh-4]') })

    const journal = new JobJournal(ctx, agent.session)
    expect(journal.get('pwsh-4')?.kind).toBe('pwsh')

    // The summary re-sights the job: the id survives, the richer kind survives,
    // and only the last-seen seq advances.
    journal.ingestSummaryText('job pwsh-4 is still running', SessionSeq(50))
    expect(journal.get('pwsh-4')).toMatchObject({
      kind: 'pwsh',
      label: 'node review.js',
      lastSeenSeq: SessionSeq(50),
    })
    expect(journal.get('pwsh-4')?.firstSeenSeq).not.toBe(SessionSeq(50))
  })
})

describe('renderJobInventory', () => {
  it('renders a compact inventory with kind, status and label', () => {
    const journal = {
      list: () => [
        { jobId: 'pwsh-4', kind: 'pwsh', label: 'node review.js --full', firstSeenSeq: SessionSeq(0), lastSeenSeq: SessionSeq(3), lastStatus: 'running' },
        { jobId: 'pwsh-12', kind: 'job', firstSeenSeq: SessionSeq(4), lastSeenSeq: SessionSeq(5), lastStatus: 'unknown' },
      ],
      count: () => 2,
    } as unknown as JobJournal
    const rendered = renderJobInventory(journal)
    expect(rendered).toContain('pwsh-4 (pwsh, running — node review.js --full)')
    expect(rendered).toContain('pwsh-12 (addressed via job tools, unknown)')
  })

  it('returns an empty string for an empty journal', () => {
    const journal = { list: () => [], count: () => 0 } as unknown as JobJournal
    expect(renderJobInventory(journal)).toBe('')
  })
})

describe('agent loop: reload recovery', () => {
  it('injects a one-shot reload notice when a new agent attaches to a session with background jobs', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done'), textResponse('ok')]))
    const handle = await ctx.agentLoop.createAgent(ctx, {
      sessionId: SessionId('reload-jobs'),
      // History left behind by a previous (now dead) agent instance.
      seed: [
        { type: 'tool/call', seq: SessionSeq(0), time: 1, data: { turn: 1, step: 1, callId: ToolCallId('p1'), name: 'pwsh', arguments: '{"command":"node review.js"}' } },
        { type: 'tool/result', seq: SessionSeq(1), time: 1, surfaceOp: 'append', data: { turn: 1, step: 1, message: toolResult('p1', '[still running after 120000ms; moved to background job pwsh-4]') } },
        { type: 'tool/call', seq: SessionSeq(2), time: 1, data: { turn: 1, step: 2, callId: ToolCallId('w1'), name: 'job_output', arguments: '{"job_id":"pwsh-4","wait":true}' } },
        { type: 'tool/result', seq: SessionSeq(3), time: 1, surfaceOp: 'append', data: { turn: 1, step: 2, message: toolResult('w1', '(no new output)\n[status: running]') } },
      ],
      agentOptions: { provider: 'mock', model: 'mock' },
    })
    const agent = handle.agent

    send(agent, 'continue the work')
    await waitForIdle(ctx, agent)

    const notices = userTexts(agent).filter(text => text.includes("This session's history records background jobs"))
    expect(notices).toHaveLength(1)
    expect(notices[0]).toContain('pwsh-4')
    expect(notices[0]).toContain('previous agent instance')
    expect(notices[0]).toContain('re-launch unfinished work deliberately')
    expect(notices[0]).toContain('job_list')

    // A second turn must not repeat the notice (one-shot).
    send(agent, 'and then?')
    await waitForIdle(ctx, agent)
    expect(userTexts(agent).filter(text => text.includes("This session's history records background jobs"))).toHaveLength(1)

    await handle.dispose()
    await ctx.fiber.dispose()
  })

  it('fires no reload notice on a fresh session', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('fresh-jobs'), {
      provider: 'mock',
      model: 'mock',
    })
    send(agent, 'hello')
    await waitForIdle(ctx, agent)
    expect(userTexts(agent).some(text => text.includes("This session's history records background jobs"))).toBe(false)
    await ctx.fiber.dispose()
  })

  it('appends the journal inventory to the compaction recovery notice', async () => {
    const ctx = await harness(new MockAdapter([textResponse('done')]))
    const agent = await ctx.agentLoop.create(SessionId('compact-jobs'), {
      provider: 'mock',
      model: 'mock',
    })
    // Live job history, then an automatic compaction, before the first turn runs.
    agent.session.append('tool/call', { turn: 1, step: 1, callId: ToolCallId('p1'), name: 'pwsh', arguments: '{"command":"node review.js"}' })
    appendToolResult(agent, { turn: 1, step: 1, message: toolResult('p1', '[still running after 120000ms; moved to background job pwsh-4]') })
    ;(agent.session.append as unknown as (type: string, data: unknown) => unknown)('compaction/end', { compactionId: 'test-compaction', turn: null })

    send(agent, 'continue')
    await waitForIdle(ctx, agent)

    const compacted = userTexts(agent).find(text => text.includes('automatically compacted'))
    expect(compacted).toBeDefined()
    expect(compacted).toContain('Background jobs recorded in this session: pwsh-4')
    expect(compacted).toContain('job_list')
    await ctx.fiber.dispose()
  })
})
