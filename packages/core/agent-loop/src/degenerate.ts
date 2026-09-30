/**
 * Degenerate-output detection for the agent loop.
 *
 * Models under long-context stress occasionally stop making progress and emit
 * the same few short fragments over and over — e.g. thousands of lines of
 * `OK.` / `Go.` / `Now.` reasoning with no tool call and no answer. Without a
 * guard, the loop faithfully streams and persists that garbage as an
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
 * Return a diagnostic reason string when the assembled assistant content is
 * degenerate output, or `undefined` when it represents usable progress.
 *
 * Degenerate detection is deliberately conservative:
 * - any tool call means the model is making progress → never flagged;
 * - any visible text means the user received an answer → never flagged
 *   (the observed problem is reasoning-only churn that silently "completes");
 * - small outputs are never flagged (they cannot show a repetition loop);
 * - the line-level repetition must clear all three thresholds (short-line
 *   share, single-line dominance, distinct-vocabulary bound) before firing.
 */
export function degenerateOutputReason(blocks: readonly ContentBlock[]): string | undefined {
  // Tool calls are usable progress regardless of any reasoning churn.
  if (blocks.some(block => block.type === 'tool-call')) return undefined
  // Visible text is a deliverable; reasoning churn beside it is not the
  // silent-completion failure this guard exists to catch.
  if (blocks.some(block => block.type === 'text' && block.text.trim().length > 0)) return undefined

  const lines: string[] = []
  for (const block of blocks) {
    if (block.type === 'reasoning') pushTrimmedLines(lines, block.text)
  }

  const total = lines.length
  if (total < MIN_LINES) return undefined

  const shortLines = lines.filter(line => line.length <= SHORT_LINE_MAX_CHARS).length
  if (shortLines / total < SHORT_LINE_RATIO) return undefined

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
  if (topCount / total < TOP_LINE_RATIO) return undefined
  if (counts.size / total > MAX_DISTINCT_RATIO) return undefined

  return `degenerate output: ${total} lines, ${counts.size} distinct fragments, `
    + `${Math.round(topCount / total * 100)}% from "${topLine.slice(0, 40)}" `
    + `(${Math.round(shortLines / total * 100)}% short lines, no tool call, no answer)`
}

/** Split text on newlines, appending each non-empty trimmed line. */
function pushTrimmedLines(target: string[], text: string): void {
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.length > 0) target.push(line)
  }
}
