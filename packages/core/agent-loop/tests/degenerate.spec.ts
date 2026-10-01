import { describe, expect, it } from 'vitest'
import { ToolCallId } from '@deepseek-ai/dsh-llm'
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

/**
 * A *visible text* block in the same degenerate shape. This mirrors the real
 * second wave of failures: the model streamed the loop as an `text` block
 * (`OK.` / `Go.` / `Let me issue.` … ~2 KB) instead of `reasoning`, usually
 * followed by a pseudo-progress tool call.
 */
function degenerateText(lines: number): ContentBlock {
  const fragments = ['Go.', 'Issuing.', 'Let me issue.', 'I will launch the review.']
  const text = Array.from({ length: lines }, (_unused, index) => (
    index % 2 === 0 ? 'OK.' : fragments[Math.floor(index / 2) % fragments.length]
  )).join('\n')
  return { type: 'text', text }
}

/**
 * Third-wave degenerate *visible text*: each line concatenates the same
 * fragment several times, producing long (>24 char) lines that defeat the
 * short-line check. Real shape from a dsh-work session: 60-char lines built
 * from `Now add DATA-UT-18:` × 3, 1090 lines, 33 distinct fragments.
 */
function degenerateLongLineText(lines: number): ContentBlock {
  const fragments = [
    'Now add DATA-UT-18:Now add DATA-UT-18:Now add DATA-UT-18:',
    'Let me add DATA-UT-18:Now add DATA-UT-18:Now add DATA-UT-18:',
  ]
  const text = Array.from({ length: lines }, (_unused, index) => fragments[index % fragments.length]!).join('\n')
  return { type: 'text', text }
}

/**
 * Third-wave degenerate *visible text*: alternates two near-identical phrasings
 * (`ITEM-14/17` vs `ITEM-14 and ITEM-17`) that share almost all fragments but
 * differ at the whole-line level. Real shape from a dsh-work session: 44 KB of
 * `Let me read the epic ITEM-14/17:Let me read the epic ITEM-14 and ITEM-17:`
 * alternating lines.
 */
function degenerateAlternatingText(lines: number): ContentBlock {
  const a = 'Let me read the epic ITEM-14/17:Let me read the epic ITEM-14 and ITEM-17:'
  const b = 'Let me read the epic ITEM-14 and ITEM-17:Let me read the epic ITEM-14/17:'
  const text = Array.from({ length: lines }, (_unused, index) => (index % 2 === 0 ? a : b)).join('\n')
  return { type: 'text', text }
}

/**
 * Ordinary substantive reasoning shaped like the real healthy baseline (a
 * 3663-char block from a live session scored 0% adjacent-line similarity):
 * each line states a distinct observation, adjacent lines share words but
 * never repeat a whole sentence.
 */
function healthyReasoning(lines: number): ContentBlock {
  const notes = [
    'The drawer renders the info card only after the ready gate flips.',
    'The state gate at L919 guards content while the async load settles.',
    'A stale bundle keeps serving the old client assets until refresh.',
    'The metrics date shows 2026/9/30 but the report files are dated 9/17.',
    'Judge-review writes a fresh diff under a target-specific name.',
    'The overlay path differs from the drawer path in its mount timing.',
    'Renaming happens inside the runner, so the original file is gone.',
    'Cross-checking the runcard fields against the actual git history.',
    'The handoff confirms the previous round closed with no blockers.',
    'Appending the v31 section after the reconfirmed v30 tail at L1144.',
  ]
  const text = Array.from({ length: lines }, (_unused, index) => notes[index % notes.length]!).join('\n')
  return { type: 'reasoning', text }
}

/**
 * Substantive long-line output (prose / analysis): every line states a
 * distinct point, so adjacent-line similarity stays far below the threshold
 * even though lines exceed the short-line cap.
 */
function healthyLongLineText(lines: number): ContentBlock {
  const notes = [
    'Analysis point: the drawer render path differs from the overlay path and the state gate at L919 is the root cause of the timing failure.',
    'The v8 drawer-open check queries the card class immediately after open, while the content is still in its loading phase under the ready flag.',
    'A page refresh would pick up the rebuilt bundle only if the GUI reads the client assets from disk at each load rather than caching them.',
    'The review outputs are named with a round suffix, which suggests the runner renames each diff instead of overwriting a shared file.',
    'Cross-referencing the runcard dates against the metrics shows the report timestamps predate the current run by almost two weeks.',
    'The handoff block confirms the predecessor round closed cleanly with zero leftover items and no unresolved blocking issues.',
    'Appending the new section after the reconfirmed tail keeps the body monotonic and preserves the content hash invariants.',
    'The acceptance criteria items live in a separate section, so the body edit must update both the checklist and the accounting.',
  ]
  const text = Array.from({ length: lines }, (_unused, index) => notes[index % notes.length]!).join('\n')
  return { type: 'text', text }
}

/** A normal answer: prose paragraphs, most lines well over the fragment cap. */
function healthyText(): ContentBlock {
  const text = [
    'The template stores fields in both frontmatter and the inner block.',
    'When a document is loaded, the loader merges frontmatter into the block map.',
    'Duplicate keys prefer the inner block value so per-file overrides win.',
    'Serialization reverses the merge and flattens keys back to frontmatter.',
  ].join('\n')
  return { type: 'text', text }
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

  it('flags a degenerate loop emitted as visible text', () => {
    const reason = degenerateOutputReason([degenerateText(200)])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('OK.')
  })

  it('flags a degenerate visible text loop even when a tool call follows', () => {
    // Real second-wave shape: ~2 KB text loop of OK./Go./Let me issue. followed
    // by a pseudo-progress tool call (e.g. job_output wait). The text alone is
    // degenerate, so the tool call must not mask it.
    const blocks: ContentBlock[] = [
      degenerateText(184),
      { type: 'tool-call', id: ToolCallId('call_1'), name: 'job_output', arguments: '{"job_id":"pwsh-50"}' },
    ]
    const reason = degenerateOutputReason(blocks)
    expect(reason).toMatch(/degenerate output/)
  })

  it('flags a degenerate reasoning loop even when a tool call follows', () => {
    // The first-wave shape had no tool call at all; some later runs attached a
    // tool call to the same degenerate reasoning. Degenerate text is the
    // signal, so a tool call alone must not pass it.
    const blocks: ContentBlock[] = [
      degenerateReasoning(200),
      { type: 'tool-call', id: ToolCallId('call_1'), name: 'read', arguments: '{}' },
    ]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
  })

  it('flags reasoning churn that only appends a one-line answer', () => {
    // 200 degenerate lines + one normal line: the loop dominates, so the
    // response is still degenerate (the "answer" is a rounding error).
    const blocks: ContentBlock[] = [
      degenerateReasoning(200),
      { type: 'text', text: 'The template stores fields in both frontmatter and the inner block.' },
    ]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
  })

  it('does not flag substantive healthy reasoning', () => {
    expect(degenerateOutputReason([healthyReasoning(200)])).toBeUndefined()
  })

  it('does not flag long-line prose where every line differs (third wave)', () => {
    // Long lines alone are not the signal: adjacent-line similarity is. Lines
    // that all differ (like a real analysis) must not be flagged.
    expect(degenerateOutputReason([healthyLongLineText(200)])).toBeUndefined()
  })

  it('does not flag a normal prose answer', () => {
    expect(degenerateOutputReason([healthyText()])).toBeUndefined()
  })

  it('does not flag a normal prose answer beside healthy reasoning', () => {
    const blocks: ContentBlock[] = [healthyReasoning(60), healthyText()]
    expect(degenerateOutputReason(blocks)).toBeUndefined()
  })

  it('does not flag small outputs (no repetition loop possible)', () => {
    expect(degenerateOutputReason([degenerateReasoning(10)])).toBeUndefined()
  })

  it('flags a tool call with an empty id even when the reasoning is healthy', () => {
    // Real dsh-work shape: the provider stream ended mid-invocation (reasoning
    // leaves an unclosed `<invoke name="read">`) and pi-ai reported
    // stopReason=toolUse, so the assembled tool-call block has id:""/name:"".
    // Executing it would write tool/result with an empty toolCallId that
    // session format v4 admission rejects at persistence time.
    const blocks: ContentBlock[] = [
      healthyReasoning(10),
      { type: 'tool-call', id: ToolCallId(''), name: 'read', arguments: '{}' },
    ]
    const reason = degenerateOutputReason(blocks)
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('empty id')
  })

  it('flags a tool call with an empty name even when the reasoning is healthy', () => {
    const blocks: ContentBlock[] = [
      healthyReasoning(10),
      { type: 'tool-call', id: ToolCallId('call_1'), name: '', arguments: '{}' },
    ]
    const reason = degenerateOutputReason(blocks)
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('empty name')
  })

  it('flags a tool call with both empty id and name (the observed truncated shape)', () => {
    // The exact shape from seq 47031: `{"type":"tool-call","id":"","name":"",
    // "arguments":"{}"}` — reasoning healthy, tool-call completely empty.
    const blocks: ContentBlock[] = [
      { type: 'reasoning', text: 'Let me look at the forge.js PR normalization around L256.' },
      { type: 'tool-call', id: ToolCallId(''), name: '', arguments: '{}' },
    ]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
  })

  it('does not flag a valid tool call with healthy reasoning', () => {
    const blocks: ContentBlock[] = [
      healthyReasoning(10),
      { type: 'tool-call', id: ToolCallId('call_1'), name: 'read', arguments: '{"path":"forge.js"}' },
    ]
    expect(degenerateOutputReason(blocks)).toBeUndefined()
  })

  it('skips blank and whitespace-only lines when collecting lines', () => {
    // Blank / whitespace-only lines trim to empty and must not count toward
    // the line total (or be treated as fragments). The 200 non-blank degenerate
    // lines below must still be flagged.
    const base = (degenerateReasoning(200) as Extract<ContentBlock, { type: 'reasoning' }>).text
    const blocks: ContentBlock[] = [{
      type: 'reasoning',
      text: base.replaceAll('\n', '\n\n\n   \n'),
    }]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
  })

  it('flags repeated long lines via adjacent-line fragment similarity (third wave)', () => {
    // v2's short-line check passes on lines >24 chars; the third-wave guard
    // compares adjacent lines on fragments, so 200 identical long lines are
    // now correctly flagged as degenerate.
    const blocks: ContentBlock[] = [{
      type: 'reasoning',
      text: Array.from({ length: 200 }, () => 'This is a substantially longer repeated line that cannot be a fragment.').join('\n'),
    }]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
  })

  it('flags visible text that concatenates the same fragment into long lines (third wave)', () => {
    // Real dsh-work shape: `Now add DATA-UT-18:` × 3 per line, 60-char lines —
    // no short lines at all, yet clearly a repetition loop.
    const reason = degenerateOutputReason([degenerateLongLineText(200)])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('adjacent lines share fragments')
  })

  it('flags visible text alternating two near-identical phrasings (third wave)', () => {
    // Real dsh-work shape: `Let me read the epic ITEM-14/17:` ↔ `Let me read
    // the epic ITEM-14 and ITEM-17:` — whole lines differ but fragments repeat.
    const reason = degenerateOutputReason([degenerateAlternatingText(200)])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('adjacent lines share fragments')
  })

  it('flags a third-wave degenerate long-line loop even when a tool call follows', () => {
    const blocks: ContentBlock[] = [
      degenerateLongLineText(184),
      { type: 'tool-call', id: ToolCallId('call_1'), name: 'job_output', arguments: '{"job_id":"pwsh-50"}' },
    ]
    expect(degenerateOutputReason(blocks)).toMatch(/degenerate output/)
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
