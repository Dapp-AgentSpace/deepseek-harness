/**
 * Degenerate-output detection for the agent loop.
 *
 * Models under long-context stress occasionally stop making progress and emit
 * the same few short fragments over and over — e.g. thousands of lines of
 * `OK.` / `Go.` / `Now.` reasoning, or (as observed in the wild) a visible
 * text block of the same fragments followed by a pseudo-progress tool call.
 * A third observed shape pads each loop iteration into a *long* line by
 * concatenating the same fragment several times (e.g. 60-char lines built
 * from `Now add DATA-UT-18:` × 3) or alternates two near-identical phrasings
 * (`Let me read the epic ITEM-14/17:` ↔ `Let me read the epic ITEM-14 and
 * ITEM-17:`), which defeats a short-line-only classifier.
 * A fourth observed shape is a *truncated tool call*: the provider stream
 * ends mid-invocation (e.g. reasoning leaves an unclosed `<invoke name="read">`
 * and pi-ai still reports `stopReason: toolUse`), so the assembled tool-call
 * block carries an empty `id` and `name`. Executing it would write a
 * `tool/call` with `callId: ""` and a `tool/result` whose empty `toolCallId`
 * violates session format v4 admission (`requires toolCallId matching its
 * tool source`), crashing the run at persistence time.
 * Without a guard, the loop faithfully streams and persists that garbage as an
 * `assistant/message` and treats the turn as completed: silent, durable, and
 * fed straight back into the next request.
 *
 * {@link degenerateOutputReason} classifies such output so the loop can fail
 * the request (code `DEGENERATE_OUTPUT`) before anything is persisted and
 * route it through the retry pipeline. The thresholds below are calibrated
 * against real degraded sessions and the ordinary-reasoning baseline; they are
 * deliberately strict so legitimate reasoning is never flagged.
 * @module dsh-agent-loop/degenerate
 */

import type { ContentBlock } from '@deepseek-ai/dsh-llm'

/**
 * Minimum non-empty reasoning lines before a response is even eligible. Healthy
 * model steps (including substantive reasoning) rarely produce more than a few
 * dozen lines, while degraded output runs into the thousands.
 */
const MIN_LINES = 50

/**
 * A line is a "short fragment" when it carries at most this many characters.
 * The observed degenerate loop is built almost entirely from 3–13 char lines.
 */
const SHORT_LINE_MAX_CHARS = 24

/** Share of lines that must be short fragments (observed: 97%; baseline ≤ 23%). */
const SHORT_LINE_RATIO = 0.6

/** Share of lines covered by the single most frequent line (observed: 46%; baseline ≤ 14%). */
const TOP_LINE_RATIO = 0.25

/**
 * Upper bound on `distinct / total` lines. Degenerate output reuses a tiny
 * vocabulary (~79 distinct lines across 37k lines); healthy output has ~1
 * distinct line per line.
 */
const MAX_DISTINCT_RATIO = 0.3

/**
 * Third-wave guard: instead of the whole-line repetition checks above, compare
 * adjacent lines on their *fragments* (tokens split on `:` / whitespace /
 * CJK punctuation). Degenerate output that pads each iteration into a long
 * line (`Now add DATA-UT-18:` × 3) or alternates near-identical phrasings
 * still repeats the same fragments on consecutive lines; healthy prose does
 * not. Measured on two real sessions: every degraded block scored 73–100%
 * adjacent-line similarity while the most similar healthy block scored 22%.
 */
const ADJACENT_SIMILARITY_RATIO = 0.5

/** A fragment is only a meaningful token when it is at least this long. */
const MIN_FRAGMENT_CHARS = 4

/**
 * Return a diagnostic reason string when the assembled assistant content is
 * degenerate output, or `undefined` when it represents usable progress.
 *
 * Degenerate detection is deliberately conservative:
 * - both `reasoning` and visible `text` blocks are analyzed — degraded models
 *   have been observed emitting the loop as *visible text* (e.g. a 2 KB text
 *   block of `OK.` / `Go.` / `Let me issue.` fragments followed by a tool
 *   call), so a non-empty text block is *not* an automatic pass;
 * - a tool call is *not* an automatic pass either — the observed failure
 *   mode attaches a "pseudo-progress" tool call (e.g. `job_output` waits)
 *   to the same degenerate text;
 * - small outputs are never flagged (they cannot show a repetition loop),
 *   except that a tool call with an empty `id` or `name` is rejected even in a
 *   tiny response — it is structurally undispatchable and would corrupt the
 *   session log at tool/result admission;
 * - the line-level repetition must clear all three thresholds (short-line
 *   share, single-line dominance, distinct-vocabulary bound) before firing,
 *   **or** the adjacent-line fragment similarity must clear the third-wave
 *   threshold (degenerate long lines and near-identical alternations).
 *   Ordinary answers — prose, lists, code — cannot simultaneously clear a
 *   ≥60% short-line share, a ≥25% single-line share and a ≤30% distinct
 *   vocabulary, nor do they repeat fragments across consecutive lines, so
 *   legitimate output is not flagged.
 */
export function degenerateOutputReason(blocks: readonly ContentBlock[]): string | undefined {
  // A truncated/incomplete tool call is unusable progress regardless of how
  // healthy the surrounding reasoning looks: dispatching it would persist a
  // `tool/call` with an empty callId and a `tool/result` that session format
  // v4 admission rejects (empty toolCallId fails `requires toolCallId matching
  // its tool source`), crashing the run at persistence time. Reject it up front
  // through the same DEGENERATE_OUTPUT retry pipeline.
  for (const block of blocks) {
    if (block.type === 'tool-call' && (block.id === '' || block.name === '')) {
      return `degenerate output: tool call "${block.name}" with empty ${block.id === '' ? 'id' : 'name'} is not dispatchable`
    }
  }

  const lines: string[] = []
  for (const block of blocks) {
    if (block.type === 'reasoning' || block.type === 'text') pushTrimmedLines(lines, block.text)
  }

  const total = lines.length
  if (total < MIN_LINES) return undefined

  const shortLines = lines.filter(line => line.length <= SHORT_LINE_MAX_CHARS).length
  const counts = new Map<string, number>()
  for (const line of lines) counts.set(line, (counts.get(line) ?? 0) + 1)
  let topCount = 0
  let topLine = ''
  for (const [line, count] of counts) {
    if (count > topCount) {
      topCount = count
      topLine = line
    }
  }

  // First wave / second wave: whole-line repetition of short fragments.
  if (shortLines / total >= SHORT_LINE_RATIO) {
    if (topCount / total >= TOP_LINE_RATIO && counts.size / total <= MAX_DISTINCT_RATIO) {
      return `degenerate output: ${total} lines, ${counts.size} distinct fragments, `
        + `${Math.round(topCount / total * 100)}% from "${topLine.slice(0, 40)}" `
        + `(${Math.round(shortLines / total * 100)}% short lines)`
    }
  }

  // Third wave: long concatenated lines / near-identical alternations defeat
  // the short-line check, but adjacent lines still share fragments.
  let adjacentSimilar = 0
  let previous: string | undefined
  for (const line of lines) {
    if (previous !== undefined && fragmentSimilarity(previous, line) >= ADJACENT_SIMILARITY_RATIO) adjacentSimilar++
    previous = line
  }
  const adjacentRatio = adjacentSimilar / (total - 1)
  if (adjacentRatio >= ADJACENT_SIMILARITY_RATIO) {
    return `degenerate output: ${total} lines, ${counts.size} distinct fragments, `
      + `top line "${topLine.slice(0, 40)}" repeated ${topCount}x `
      + `(${Math.round(adjacentRatio * 100)}% adjacent lines share fragments)`
  }

  return undefined
}

/** Split text on newlines, appending each non-empty trimmed line. */
function pushTrimmedLines(target: string[], text: string): void {
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.length > 0) target.push(line)
  }
}

/**
 * Split a line into meaningful fragments (tokens of ≥ {@link MIN_FRAGMENT_CHARS}
 * characters, split on `:` / whitespace / CJK punctuation). A degenerate long
 * line like `Now add DATA-UT-18:Now add DATA-UT-18:Now add DATA-UT-18:` yields
 * three identical fragments, exposing the loop the whole-line check misses.
 */
function lineFragments(line: string): string[] {
  return line.split(/(?::|\s|，|。|；|、)/).map(part => part.trim()).filter(part => part.length >= MIN_FRAGMENT_CHARS)
}

/**
 * Fragment overlap of two lines: `|A ∩ B| / max(|A|, |B|)`. Two identical
 * lines score 1; healthy consecutive lines score well below the threshold.
 */
function fragmentSimilarity(left: string, right: string): number {
  const leftFragments = lineFragments(left)
  const rightFragments = lineFragments(right)
  if (leftFragments.length === 0 || rightFragments.length === 0) return 0
  const rightSet = new Set(rightFragments)
  let overlap = 0
  for (const fragment of leftFragments) {
    if (rightSet.has(fragment)) overlap++
  }
  return overlap / Math.max(leftFragments.length, rightFragments.length)
}
