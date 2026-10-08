import { afterEach, describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import AgentLoop from '@deepseek-ai/dsh-agent-loop'
import LlmRuntime from '@deepseek-ai/dsh-llm'
import SessionStore from '@deepseek-ai/dsh-session'
import SessionProjectionRegistry from '@deepseek-ai/dsh-session-projection'
import SystemPrompt, { renderPrompt } from '@deepseek-ai/dsh-system-prompt'
import ToolRuntime from '@deepseek-ai/dsh-tools'

const contexts: Context[] = []
afterEach(async () => {
  for (const ctx of contexts.splice(0)) await ctx.fiber.dispose()
})

async function harness(): Promise<Context> {
  const ctx = new Context()
  contexts.push(ctx)
  await ctx.plugin(LlmRuntime)
  await ctx.plugin(SessionStore)
  await ctx.plugin(SessionProjectionRegistry)
  await ctx.plugin(SystemPrompt, { personaPrefix: 'Persona.', personaSuffix: 'Suffix.' })
  await ctx.plugin(ToolRuntime)
  await ctx.plugin(AgentRegistry)
  await ctx.plugin(AgentLoop, { agents: [] })
  return ctx
}

describe('AgentLoop system-prompt sections', () => {
  it('registers the progress-policy and tool-format sections in the expected positions', async () => {
    const ctx = await harness()
    const assembly = await ctx.systemPrompt.assemble()
    const names = assembly.sections.map(section => section.name)
    // Built-ins plus the two agent-loop behavioral contracts, ordered by
    // section order: identity(-1000) → progress(-500) → persona-prefix(0) →
    // tool-format(4990) → persona-suffix(10200).
    expect(names).toEqual([
      'harness:identity',
      'agent-loop:progress-policy',
      'deployment:persona-prefix',
      'agent-loop:tool-format',
      'deployment:persona-suffix',
    ])
    // Assembled sections expose only name/text; their placement is proven by
    // the order above (progress before persona-prefix, tool-format between the
    // persona prefix and suffix) and by the rendered order in the next test.
  })

  it('renders both behavioral contracts into the assembled prompt', async () => {
    const ctx = await harness()
    const rendered = renderPrompt(await ctx.systemPrompt.assemble())
    expect(rendered).toContain('Every step must advance the task')
    expect(rendered).toContain('Call tools only through the native structured tool-call mechanism')
    // The progress rule precedes the persona prefix; the tool-format rule
    // follows it but still precedes the persona suffix.
    expect(rendered.indexOf('Every step must advance the task'))
      .toBeLessThan(rendered.indexOf('Persona.'))
    expect(rendered.indexOf('Call tools only through the native structured tool-call mechanism'))
      .toBeGreaterThan(rendered.indexOf('Persona.'))
    expect(rendered.indexOf('Call tools only through the native structured tool-call mechanism'))
      .toBeLessThan(rendered.indexOf('Suffix.'))
  })

  it('keeps the sections resolvable as text (no interpolation placeholders)', async () => {
    const ctx = await harness()
    const assembly = await ctx.systemPrompt.assemble()
    const texts = assembly.sections
      .filter(section => section.name.startsWith('agent-loop:'))
      .map(section => section.text)
    expect(texts).toEqual([
      'Every step must advance the task: either call a tool to perform a concrete action, or give the final answer. Do not restate plans or actions you have already stated or performed; if the next step is identical to a previous one, stop and call a tool or answer directly instead.',
      'Call tools only through the native structured tool-call mechanism. Never emit a tool call as plain text, XML, JSON, or any other pseudo-format (e.g. `<invoke name="...">` or hand-written JSON arguments): those formats are not parsed or executed, they stall the run, and the session can only be recovered by deleting the invalid message.',
    ])
  })
})
