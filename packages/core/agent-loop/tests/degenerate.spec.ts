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
 * never repeat a whole sentence. Every line carries a unique per-line suffix
 * (`note N`) so the block is genuinely non-repetitive — the hash-similarity
 * fifth wave must not flag it.
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
  const text = Array.from({ length: lines }, (_unused, index) => `${notes[index % notes.length]} (note ${index})`).join('\n')
  return { type: 'reasoning', text }
}

/**
 * Substantive long-line output (prose / analysis): every line states a
 * distinct point, so adjacent-line similarity stays far below the threshold
 * even though lines exceed the short-line cap. Every line carries a unique
 * per-line suffix so the block is genuinely non-repetitive — the
 * hash-similarity fifth wave must not flag it.
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
  const text = Array.from({ length: lines }, (_unused, index) => `${notes[index % notes.length]} (item ${index})`).join('\n')
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

/**
 * A healthy long work-plan orbiting one topic: 50 short lines that share
 * fragments ("grep", "diff", "分支") with half their neighbours — the shape
 * session-007b2e99 emitted at turn 9 step 9 (51 lines, 44 distinct, top line
 * ×3, ~50% adjacent similarity) when it was planning `grep diff in
 * judge-review.sh` steps. Every line is unique (top-line share ≈ 0), so the
 * first/second waves never fire and only the third-wave adjacent-fragment
 * check is exercised. The strict 0.5 threshold flags it (the false positive
 * that drained retries and killed the turn), while the streaming watchdog's
 * conservative 0.7 threshold lets it finish and be judged post-stream.
 */
function workPlanAroundTopic(lines: number): ContentBlock {
  const text = Array.from({ length: lines }, (_unused, index) => {
    // 5-line cycle → 4 adjacent pairs, 2 of them sharing 3/4 fragments (0.75):
    //   A→B 0.75 (hit) · B→C 0 (miss) · C→A′ 0 (miss) · A′→B′ 0.75 (hit)
    // so exactly 50% of adjacent pairs clear the strict 0.5 threshold.
    switch (index % 5) {
      case 0: return `grep diff 分支 目标${Math.floor(index / 5)}。`
      case 1: return `grep diff 分支 用法${Math.floor(index / 5)}。`
      case 2: return `quality audit 检查 报告${Math.floor(index / 5)}。`
      case 3: return `grep diff 分支 目标${Math.floor(index / 5) + 1}。`
      default: return `grep diff 分支 用法${Math.floor(index / 5) + 1}。`
    }
  }).join('\n')
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

  it('streaming mode does not flag a high-diversity work-plan the strict mode flags (third wave)', () => {
    // Regression for session-007b2e99 turn 9 step 9: the model recovered from
    // a repetition loop into a *healthy* 51-line work-plan (44 distinct lines,
    // top line ×3, ~50% adjacent) — real progress — but the strict 0.5
    // third-wave threshold still flagged it, draining the last retry and
    // killing the turn with DEGENERATE_OUTPUT. The streaming watchdog samples
    // mid-flight (before the model has finished), so it uses the conservative
    // 0.7 threshold: the same plan must pass streaming mode while the strict
    // post-stream detector still flags it (it did, and would retry once more).
    const plan = workPlanAroundTopic(50)
    // Strict (post-stream / abort-salvage) calibration still flags this shape.
    expect(degenerateOutputReason([plan])).toMatch(/degenerate output/)
    expect(degenerateOutputReason([plan])).toContain('adjacent lines share fragments')
    // Conservative streaming calibration lets the healthy plan through.
    expect(degenerateOutputReason([plan], { streaming: true })).toBeUndefined()
  })

  it('streaming mode still flags extreme third-wave repetition', () => {
    // The conservative streaming threshold only relaxes the *edge*: genuine
    // degenerate long-line loops (identical fragments on every line → 100%
    // adjacent similarity) must still interrupt the stream instead of letting
    // it run forever.
    expect(degenerateOutputReason([degenerateLongLineText(200)], { streaming: true })).toMatch(/degenerate output/)
    expect(degenerateOutputReason([degenerateAlternatingText(200)], { streaming: true })).toMatch(/degenerate output/)
  })

  it('flags a single giant line that re-states the same fragment (fifth wave, hash similarity)', () => {
    // Real dsh-work selftest shape: the model emits one 1.3 KB *line* that
    // concatenates `Collecting the selftest job output now:` / `Collecting the
    // selftest output:` / `Checking the selftest job:` over and over. total = 1
    // defeats every line-level wave (no short-line share, no dominant line, no
    // adjacent pairs), yet word-level vocabulary is tiny (3.6% distinct) and
    // the 6-gram windows are ~97% self-similar. The hash-similarity fifth wave
    // catches it in both streaming and strict calibration.
    const fragments = ['Collecting the selftest job output now:', 'Collecting the selftest output:', 'Checking the selftest job:']
    const text = `selftest:${Array.from({ length: 42 }, (_unused, index) => fragments[index % fragments.length]).join('')}`
    expect(text.length).toBeGreaterThan(400)
    expect(text.split('\n').filter(line => line.trim().length > 0)).toHaveLength(1)
    expect(degenerateOutputReason([{ type: 'text', text }])).toMatch(/degenerate output/)
    expect(degenerateOutputReason([{ type: 'text', text }])).toContain('window self-similarity')
    expect(degenerateOutputReason([{ type: 'text', text }], { streaming: true })).toMatch(/degenerate output/)
  })

  it('flags a sub-50-line CJK short-phrase loop (fifth wave, short-output vocabulary)', () => {
    // Real dsh-work shape: 9 lines cycling `检查 ocr。` / `确认 ocr 可用。` /
    // `查 ocr CLI。` … — too few lines for the first/second waves and too few
    // characters for window statistics, but the word vocabulary is 33% distinct
    // with one word (`ocr`) dominating 38% of tokens. Layer 2 flags it in both
    // calibrations (a 9-line loop is degenerate before it ever gets to 50).
    const pool = [
      '检查 ocr。',
      '确认 ocr 可用。',
      '查 ocr CLI。',
      '检查 ocr 是否安装。',
      '确认 ocr。',
      '查 ocr。',
      '检查 ocr CLI 是否可用。',
      '确认 ocr 是否安装。',
      '查 ocr。',
    ]
    const text = pool.join('\n')
    const reason = degenerateOutputReason([{ type: 'text', text }])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('sub-50-line loop')
    expect(degenerateOutputReason([{ type: 'text', text }], { streaming: true })).toMatch(/degenerate output/)
  })

  it('flags a sub-50-line English short-phrase loop (fifth wave, short-output vocabulary)', () => {
    // Same shape in English: `check ocr.` / `verify ocr.` / `run ocr cli.` …
    // The word splitter must treat the ASCII period as a token boundary, or
    // `ocr.`/`cli.` would inflate the distinct-word count and hide the loop.
    const lines = [
      'check ocr.',
      'verify ocr.',
      'run ocr cli.',
      'check ocr install.',
      'confirm ocr.',
      'check ocr.',
      'run ocr cli.',
      'verify ocr install.',
      'check ocr.',
    ]
    const text = lines.join('\n')
    const reason = degenerateOutputReason([{ type: 'text', text }])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('sub-50-line loop')
    expect(degenerateOutputReason([{ type: 'text', text }], { streaming: true })).toMatch(/degenerate output/)
  })

  it('flags a padded CJK loop once it exceeds 50 lines (fifth wave, hash similarity)', () => {
    // The same ocr loop padded to 60 lines: wordDistinct sits at ~5% (right on
    // the streaming edge) with ~100% window self-similarity. Strict calibration
    // catches it; the conservative streaming bar lets it slide mid-flight
    // (5.0% > 5.0% would not fire) and the strict post-stream check catches it.
    const pool = [
      '检查 ocr。',
      '确认 ocr 可用。',
      '查 ocr CLI。',
      '检查 ocr 是否安装。',
      '确认 ocr。',
      '查 ocr。',
      '检查 ocr CLI 是否可用。',
      '确认 ocr 是否安装。',
      '查 ocr。',
    ]
    const text = Array.from({ length: 60 }, (_unused, index) => pool[index % pool.length]).join('\n')
    expect(degenerateOutputReason([{ type: 'text', text }])).toMatch(/degenerate output/)
    // Streaming: wordDistinct 5.0% is at the 5% edge → conservative bar passes.
    expect(degenerateOutputReason([{ type: 'text', text }], { streaming: true })).toBeUndefined()
  })

  it('flags a long-line loop re-stating the same observations (fifth wave, hash similarity)', () => {
    // The shape the first three waves are blind to: 200 lines, but only 10
    // distinct observations cycled — every line is long (>24 chars, wave 1
    // misses) and consecutive lines differ (wave 3 misses), yet the model is
    // just re-stating the same notes. Word vocabulary is ~4% distinct and
    // 6-gram windows are 100% self-similar → Layer 1 fires in both
    // calibrations. The healthy fixture is identical except every line carries
    // a unique `(note N)` suffix and must stay unflagged (see above).
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
    const text = Array.from({ length: 200 }, (_unused, index) => notes[index % notes.length]).join('\n')
    expect(degenerateOutputReason([{ type: 'reasoning', text }])).toMatch(/degenerate output/)
    expect(degenerateOutputReason([{ type: 'reasoning', text }])).toContain('window self-similarity')
    expect(degenerateOutputReason([{ type: 'reasoning', text }], { streaming: true })).toMatch(/degenerate output/)
  })

  it('does not flag 200 genuinely unique reasoning lines (fifth wave, hash similarity)', () => {
    // The control for the note-loop test above: same 10 observations, but each
    // line is unique (`Observation N: … (context N)`). Word vocabulary jumps to
    // ~16% distinct and window self-similarity collapses to ~37% — neither
    // Layer 1 nor any earlier wave fires.
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
    const text = Array.from({ length: 200 }, (_unused, index) => `Observation ${index}: ${notes[index % notes.length]} (context ${index})`).join('\n')
    expect(degenerateOutputReason([{ type: 'reasoning', text }])).toBeUndefined()
    expect(degenerateOutputReason([{ type: 'reasoning', text }], { streaming: true })).toBeUndefined()
  })

  it('flags a varied-phrasing CJK loop that never reaches Tier A similarity (fifth wave, Layer 1 Tier B)', () => {
    // Real session-007b2e99 shape (turn 11 step 6): 3427 lines cycling ~16
    // near-identical phrasings (`读 arch 报告。` / `读 arch-review 报告。` /
    // `读 arch-review.md。` / `读 arch review 报告。` …) behind a normal
    // opening. Word vocabulary collapses to ~1.4% distinct, but because the
    // phrasings *vary*, window self-similarity only reaches ~71% — far below
    // Tier A's 0.9 bar. Tier B (≤3% distinct AND ≥0.65 similarity) must catch
    // it in both calibrations.
    const pool = [
      '读 arch 报告。',
      '读 arch-review 报告。',
      '读 arch-review.md。',
      '读 arch review 报告。',
      '读 arch-review 范式。',
      '读 arch review。',
      '读 arch-review.md。',
      '读 arch 评审报告。',
      '读 arch-review。',
      '读 arch review。',
      '读 arch-review.md。',
      '读 arch 报告。',
      '读 arch-review 报告。',
      '读 arch-review.md 范式。',
      '读 arch review 报告。',
    ]
    const opening = '明白。ITEM-3 时 ocr 因 maiforce 代理 502 不可用，diff review 以确定性证据 + arch 评审替代（owner 指示跳过 ocr）。现在 ITEM-4 的 review 节点需要同样处理。\n\n先看 arch-review 范式，然后跑 ITEM-4 的 arch 评审（judge-review.sh arch，走 claude LLM 通道——需要 LLM 可用）。arch 是判断类必须读 arch.md 全文，走 prompt 型 runner（claude）。LLM 通道：User 级 ANTHROPIC_AUTH_TOKEN + BASE_URL=model.maiforce.com，harness-llm.sh claude 分支自动注入。\n\n先确认 LLM 通道可用性（小请求测试），再决定 review 策略：\n1. 先跑 `judge-review.sh arch`（走 claude，arch 评审）——如果 LLM 通，arch 可跑\n2. diff review：ocr 可能仍不可用（maiforce 502 历史），若 ocr 卡死则按 ITEM-3 模式用确定性证据 + arch 评审替代\n\n先看 forge-arch-review.md 范式 + 测试 LLM 通道。\n'
    const loop = Array.from({ length: 1700 }, (_unused, index) => pool[index % pool.length]).join('\n')
    const text = opening + loop + '\n'
    const reason = degenerateOutputReason([{ type: 'text', text }])
    expect(reason).toMatch(/degenerate output/)
    expect(reason).toContain('window self-similarity')
    // Streaming: 1.4% distinct ≤ 2% streaming Tier B bound → fires too.
    expect(degenerateOutputReason([{ type: 'text', text }], { streaming: true })).toMatch(/degenerate output/)
  })

  it('does not flag long-line prose with a unique suffix (fifth wave, Layer 1 Tier B control)', () => {
    // The Tier B control: healthyLongLineText(200) measures 7.0% distinct /
    // 66.5% similarity — the similarity alone is above Tier B's 0.65 bar, but
    // the distinct ratio (7.0%) clears the 3% Tier B gate, so it must stay
    // unflagged. This is the razor-thin margin that motivated gating Tier B on
    // vocabulary size rather than just lowering Tier A's similarity threshold.
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
    const text = Array.from({ length: 200 }, (_unused, index) => `${notes[index % notes.length]} (item ${index})`).join('\n')
    expect(degenerateOutputReason([{ type: 'text', text }])).toBeUndefined()
    expect(degenerateOutputReason([{ type: 'text', text }], { streaming: true })).toBeUndefined()
  })
})
