import { describe, expect, it } from 'vitest'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import { degenerateOutputReason } from '../src/degenerate.ts'

/**
 * A reasoning-only block whose text loops a small vocabulary of short lines —
 * the shape observed in real degraded sessions: `OK.` between every other
 * fragment, thousands of lines, ~97% short lines, `OK.` covering ~50%.
 */
function degenerateReasoning(lines: number): ContentBlock {
  const fragments = ['Go.', 'Now.', 'Issue.', 'Let me read.', 'Reading.']
  const text = Array.from({ length: lines }, (_unused, index) => (
    index % 2 === 0 ? 'OK.' : fragments[Math.floor(index / 2) % fragments.length]
  )).join('\n')
  return { type: 'reasoning', text }
}

/** Ordinary substantive reasoning: many distinct lines, few repeats. */
function healthyReasoning(lines: number): ContentBlock {
  const text = Array.from(
    { length: lines },
    (_unused, index) => `Step ${index}: inspect the parsed fields and verify the template mapping.`,
  ).join('\n')
  return { type: 'reasoning', text }
}

describe('degenerateOutputReason', () => {
  it('flags reasoning that loops short repeated fragments', () => {
    const reason = degenerateOutputReason([degenerateReasoning(200)])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('OK.')
  })

  it('flags a large-scale loop matching the real degraded session profile', () => {
    // 37,898 non-empty lines from ~6 distinct short fragments — the observed
    // harness-suite signature. Built small enough to stay fast in the suite.
    const reason = degenerateOutputReason([degenerateReasoning(400)])
    expect(reason).toMatch(/distinct fragments/)
  })

  it('does not flag substantive healthy reasoning', () => {
    expect(degenerateOutputReason([healthyReasoning(200)])).toBeUndefined()
  })

  it('does not flag small outputs (no repetition loop possible)', () => {
    expect(degenerateOutputReason([degenerateReasoning(10)])).toBeUndefined()
  })

  it('does not flag a response that ends with a tool call', () => {
    const blocks: ContentBlock[] = [
      degenerateReasoning(200),
      { type: 'tool-call', id: 'call_1', name: 'read', arguments: '{}' },
    ]
    expect(degenerateOutputReason(blocks)).toBeUndefined()
  })

  it('does not flag reasoning churn that still delivers a real answer', () => {
    const blocks: ContentBlock[] = [
      degenerateReasoning(200),
      { type: 'text', text: 'The template stores fields in both frontmatter and the inner block.' },
    ]
    expect(degenerateOutputReason(blocks)).toBeUndefined()
  })

  it('does not flag repeated lines that are too long to be fragments', () => {
    const blocks: ContentBlock[] = [{
      type: 'reasoning',
      text: Array.from({ length: 200 }, () => 'This is a substantially longer repeated line that cannot be a fragment.').join('\n'),
    }]
    expect(degenerateOutputReason(blocks)).toBeUndefined()
  })

  it('does not flag many distinct short lines (vocabulary not degenerate)', () => {
    const blocks: ContentBlock[] = [{
      type: 'reasoning',
      text: Array.from({ length: 200 }, (_unused, index) => `f${index}`).join('\n'),
    }]
    expect(degenerateOutputReason(blocks)).toBeUndefined()
  })

  it('flags across multiple reasoning blocks combined', () => {
    const blocks: ContentBlock[] = [
      degenerateReasoning(120),
      degenerateReasoning(120),
    ]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
  })
})
