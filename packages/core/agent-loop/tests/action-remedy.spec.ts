/**
 * Pillar C (loop level): the action guard consults the fs observation registry
 * before intercepting a repeated failed call, so a *remedy-driven re-run* — the
 * identical call re-issued after its target was re-observed (the documented fix
 * for FS_NOT_OBSERVED / FS_STALE_VERSION) — is allowed through, while any
 * unverifiable retry still degrades to interception.
 *
 * The three fs scenarios run against the real local backend + observation
 * policy + tool stack; the degrade scenarios run with no fs service at all
 * (the guard's remedy check must fail closed, not crash the loop).
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { writeFileSync } from 'node:fs'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
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
import { LocalFileSystem } from '@deepseek-ai/dsh-fs-local'
import * as FsPolicy from '@deepseek-ai/dsh-fs-observation-policy'
import * as ToolFs from '@deepseek-ai/dsh-tool-fs'
import { FsError, type FsErrorCode } from '@deepseek-ai/dsh-fs'
import { MockAdapter, textResponse, toolCallResponse } from './mock-adapter.ts'

/** Core loop stack without any fs service (degrade scenarios). */
async function plainHarness(adapter: MockAdapter) {
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

/** Core loop stack + local fs backend + observation policy + fs tools. */
async function fsHarness(adapter: MockAdapter, dir: string) {
  const ctx = await plainHarness(adapter)
  await ctx.plugin(LocalFileSystem, { cwd: dir })
  // tool-fs resolves call paths through the working-directory service (upstream
  // 0.2.1 dependency); provide the fixed-directory test collaborator so the fs
  // tools register and resolve against the per-session cwd.
  ctx.provide('workingDirectory', {
    defaultDirectory: dir,
    get: (session: Session) => session.header.cwd ?? dir,
    ensure: (agent: Agent): Promise<string> => Promise.resolve(agent.session.header.cwd ?? dir),
  })
  await ctx.plugin(FsPolicy)
  await ctx.plugin(ToolFs)
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

/** A tool whose every invocation throws an FsError with the given code. */
function failingFsTool(name: string, code: FsErrorCode) {
  let calls = 0
  const tool = defineContentToolFixture({
    name,
    description: `failing fs tool ${name}`,
    parameters: { file_path: { type: 'string' }, cmd: { type: 'string' } },
    async execute() {
      calls += 1
      throw new FsError(`${name} failed`, code)
    },
  })
  return { tool, calls: () => calls }
}

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'dsh-action-remedy-'))
})

afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('action guard fs-remedy exemption (Pillar C)', () => {
  it('FS_NOT_OBSERVED: a read after the failure exempts the identical edit re-run', async () => {
    const file = join(dir, 'a.txt')
    await writeFile(file, 'alpha\n')
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'edit', { file_path: 'a.txt', old_string: 'alpha', new_string: 'beta' }),
      toolCallResponse('c2', 'read', { file_path: 'a.txt' }),
      toolCallResponse('c3', 'edit', { file_path: 'a.txt', old_string: 'alpha', new_string: 'beta' }),
      textResponse('done'),
    ])
    const ctx = await fsHarness(adapter, dir)
    const agent = await ctx.agentLoop.create(SessionId('action-remedy-a'), {
      provider: 'mock',
      model: 'mock',
    }, { cwd: dir })

    send(agent, 'edit the file')
    await waitForIdle(ctx, agent)

    // The identical edit was NOT intercepted: it executed against the fresh read.
    expect(await readFile(file, 'utf8')).toBe('beta\n')
    const results = agent.session.snapshotEvents().filter(event => event.type === 'tool/result')
    expect(results).toHaveLength(3)
    expect(results[0]?.data.error).toMatchObject({ code: 'FS_NOT_OBSERVED' })
    // No interception notice was surfaced to the model.
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(false)
  })

  it('FS_STALE_VERSION: without a re-read after the failure the identical re-run is still intercepted', async () => {
    const file = join(dir, 'a.txt')
    await writeFile(file, 'alpha\n')
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'read', { file_path: 'a.txt' }),
      // The file changes behind the model's back between the read and the edit.
      () => {
        writeFileSync(file, 'alpha beta\n')
        return toolCallResponse('c2', 'edit', { file_path: 'a.txt', old_string: 'alpha', new_string: 'gamma' })
      },
      toolCallResponse('c3', 'edit', { file_path: 'a.txt', old_string: 'alpha', new_string: 'gamma' }),
      textResponse('done'),
    ])
    const ctx = await fsHarness(adapter, dir)
    const agent = await ctx.agentLoop.create(SessionId('action-remedy-b'), {
      provider: 'mock',
      model: 'mock',
    }, { cwd: dir })

    send(agent, 'update the file')
    await waitForIdle(ctx, agent)

    // The edit never ran: the file still holds the external modification.
    expect(await readFile(file, 'utf8')).toBe('alpha beta\n')
    const results = agent.session.snapshotEvents().filter(event => event.type === 'tool/result')
    expect(results).toHaveLength(2)
    expect(results[1]?.data.error).toMatchObject({ code: 'FS_STALE_VERSION' })
    // The interception notice was surfaced.
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(true)
  })

  it('FS_STALE_VERSION: a re-read after the failure exempts the identical edit re-run', async () => {
    const file = join(dir, 'a.txt')
    await writeFile(file, 'alpha\n')
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'read', { file_path: 'a.txt' }),
      // The file changes behind the model's back between the read and the edit.
      () => {
        writeFileSync(file, 'alpha beta\n')
        return toolCallResponse('c2', 'edit', { file_path: 'a.txt', old_string: 'alpha', new_string: 'gamma' })
      },
      toolCallResponse('c3', 'read', { file_path: 'a.txt' }),
      toolCallResponse('c4', 'edit', { file_path: 'a.txt', old_string: 'alpha', new_string: 'gamma' }),
      textResponse('done'),
    ])
    const ctx = await fsHarness(adapter, dir)
    const agent = await ctx.agentLoop.create(SessionId('action-remedy-c'), {
      provider: 'mock',
      model: 'mock',
    }, { cwd: dir })

    send(agent, 'update the file')
    await waitForIdle(ctx, agent)

    // The identical edit was exempted (the target was re-read after the failure).
    expect(await readFile(file, 'utf8')).toBe('gamma beta\n')
    const results = agent.session.snapshotEvents().filter(event => event.type === 'tool/result')
    expect(results).toHaveLength(4)
    expect(results[2]?.data.error).toBeUndefined()
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(false)
  })

  it('degrades to interception when the fs service is unavailable (resolve fails closed)', async () => {
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'launch', { file_path: 'a.txt', cmd: 'node x.js' }),
      toolCallResponse('c2', 'launch', { file_path: 'a.txt', cmd: 'node x.js' }),
      textResponse('done'),
    ])
    const ctx = await plainHarness(adapter)
    const failing = failingFsTool('launch', 'FS_NOT_OBSERVED')
    ctx.tools.register(failing.tool)
    const agent = await ctx.agentLoop.create(SessionId('action-remedy-d'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'launch the node script')
    await waitForIdle(ctx, agent)

    // Without a fs service the remedy cannot be verified: the re-run is intercepted.
    expect(failing.calls()).toBe(1)
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(true)
  })

  it('degrades to interception when the failed call carries no file_path', async () => {
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'launch', { cmd: 'node x.js' }),
      toolCallResponse('c2', 'launch', { cmd: 'node x.js' }),
      textResponse('done'),
    ])
    const ctx = await plainHarness(adapter)
    const failing = failingFsTool('launch', 'FS_NOT_OBSERVED')
    ctx.tools.register(failing.tool)
    const agent = await ctx.agentLoop.create(SessionId('action-remedy-e'), {
      provider: 'mock',
      model: 'mock',
    })

    send(agent, 'launch the node script')
    await waitForIdle(ctx, agent)

    // No file path means no observable target: the re-run is intercepted.
    expect(failing.calls()).toBe(1)
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(true)
  })

  it('intercepts when the registry confirms absence (absent is not a remedy)', async () => {
    const adapter = new MockAdapter([
      toolCallResponse('c1', 'launch', { file_path: 'a.txt', cmd: 'node x.js' }),
      toolCallResponse('c2', 'launch', { file_path: 'a.txt', cmd: 'node x.js' }),
      textResponse('done'),
    ])
    const ctx = await fsHarness(adapter, dir)
    const failing = failingFsTool('launch', 'FS_NOT_OBSERVED')
    ctx.tools.register(failing.tool)
    const agent = await ctx.agentLoop.create(SessionId('action-remedy-f'), {
      provider: 'mock',
      model: 'mock',
    }, { cwd: dir })

    // Seed a confirmed-absent observation for this session and target: the guard
    // resolves the same path, so it must see absence and keep intercepting.
    const target = await ctx.fs.resolve('a.txt', { cwd: dir })
    ctx.emit('fs/observed', target, { kind: 'absent' }, { agent: { session: agent.session } })

    send(agent, 'launch the node script')
    await waitForIdle(ctx, agent)

    expect(failing.calls()).toBe(1)
    expect(userTexts(agent).some(text => text.includes('You already ran'))).toBe(true)
  })
})
