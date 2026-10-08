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

/**
 * Streaming-watchdog variant of the third-wave threshold. The mid-stream
 * watchdog samples the *accumulated* blocks before the model has finished, so
 * a healthy long work-plan — dozens of short lines all orbiting one topic
 * (e.g. 51 lines of "grep diff in judge-review.sh." variants, 86% distinct
 * lines) — can clear the 0.5 adjacent-fragment threshold mid-flight and be
 * abandoned + retried even though it is real, forward-moving progress. Each
 * retry regenerates the same plan and trips the same detector until retries
 * are exhausted and the turn dies with DEGENERATE_OUTPUT (session-007b2e99,
 * turn 9 step 9: 6 consecutive abandons, retry 5 drained, then the *recovered*
 * 51-line/44-distinct output was still rejected at 50% adjacent).
 *
 * The streaming path therefore only interrupts on *extreme* adjacent
 * repetition (≥0.7, above every healthy-work-plan reading we have seen, where
 * the true degenerate blocks measured 61–98%). The line-level first/second
 * waves and the paragraph-level text-repetition guard still run unchanged, and
 * the post-stream detector still applies the strict 0.5 threshold to the
 * finished output — so a block that clears the relaxed streaming bar but is
 * genuinely degenerate on close reading is still caught and retried once the
 * stream ends.
 */
const STREAMING_ADJACENT_SIMILARITY_RATIO = 0.7

/** A fragment is only a meaningful token when it is at least this long. */
const MIN_FRAGMENT_CHARS = 4

/**
 * Fifth wave (hash self-similarity), Layer 1 — long text. The line-level waves
 * above are structurally blind to two real degenerate shapes:
 * - a single-line mega block: the model concatenates the same fragment into one
 *   long line (e.g. the 1.7 KB `selftest:Collecting the selftest…` block), so
 *   `total` is 1 and the `MIN_LINES` gate short-circuits before any wave;
 * - a sub-50-line loop of *varied* short phrasing (CJK `检查 ocr。` /
 *   `确认 ocr 可用。` / `查 ocr CLI。` …): `total < MIN_LINES` short-circuits,
 *   and the first/second waves need a dominant *line* (none — every line
 *   differs) while the third wave needs adjacent *fragment* overlap (Chinese
 *   2-char tokens are filtered by {@link MIN_FRAGMENT_CHARS}, and the phrasings
 *   share little).
 *
 * Layer 1 measures how self-similar a block is *as a whole*, shape-agnostically:
 * split the full text into character shingles, slice it into consecutive
 * windows, and average the Jaccard similarity of adjacent windows (an O(n)
 * approximation of a minhash self-similarity). Degenerate blocks orbit a tiny
 * word vocabulary and are near-identical across windows (measured: 1–8%
 * distinct words, 0.94–1.00 window similarity); healthy reasoning, prose and
 * code sit at 11%+ distinct words or below 0.9 similarity — including the
 * healthy work-plan (19% / 0.26) that fix-B must keep streaming.
 */
const HASH_MIN_CHARS = 400
const HASH_MAX_WORD_DISTINCT = 0.08
const HASH_MIN_WINDOW_SIMILARITY = 0.9
/** Conservative streaming variant: only *extreme* self-similarity interrupts mid-flight. */
const HASH_STREAMING_MAX_WORD_DISTINCT = 0.05
const HASH_STREAMING_MIN_WINDOW_SIMILARITY = 0.95
/**
 * Layer 1, Tier B — *varied-phrasing* loops. Exact-repeat loops reach 0.94–1.00
 * window similarity and are caught by the Tier A AND above, but a second real
 * shape cycles a small set of near-identical phrasings (the 3427-line
 * `读 arch-review…` block from session-007b2e99: 16 phrasings rotating, 1.4%
 * distinct words, only 71% window similarity — far below Tier A's 0.9). The
 * word vocabulary is so tiny (<3% distinct) that no healthy text comes close
 * (measured healthy floor: 7% for long-line prose), so a *moderate* window
 * similarity (≥0.65, still double the healthy work-plan's 0.26) is damning.
 * Streaming uses the tighter 2% bound: mid-stream samples are smaller, and the
 * strict post-stream check catches anything that slides through anyway.
 */
const HASH_VARIED_MAX_WORD_DISTINCT = 0.03
const HASH_STREAMING_VARIED_MAX_WORD_DISTINCT = 0.02
const HASH_VARIED_MIN_WINDOW_SIMILARITY = 0.65

/**
 * Layer 1, Tier C — longest periodic-run coverage. Catches *long-sentence
 * loops*: the model emits the same 60–300-char paragraph verbatim (10× in the
 * reported session), concatenated with no line breaks (`call):Both nodes…`).
 * Tier A/B cannot see this shape — a full English sentence carries dozens of
 * distinct words, so even a 10× exact repeat of one sentence stays above the
 * 8% word-distinct bar (measured: 9.5% distinct at 1.00 window similarity),
 * and a healthy prefix dilutes both metrics further (15.7% distinct / 0.34
 * similarity for the 8831-char block).
 *
 * The metric itself is the longest *contiguous* run of fragments that agree
 * under some period {@link PERIOD_MAX} (fragments[i] === fragments[i + p] for
 * every i in the run). A degenerate long-sentence loop is a periodic sequence
 * of fragments (`[S1,S2,S3] × 10` → period 3, ~100% of the tail), while
 * healthy reasoning that reuses a sentence across lines always interleaves
 * unique material (a per-line suffix), which breaks periodicity at the very
 * first comparison — measured 0–2% on healthy 11–79 KB blocks and on the
 * rotating-sentence control texts. Coverage = longest run / total fragments.
 */
const PERIOD_MAX = 16
const PERIOD_MIN_RUN_FRAGMENTS = 8
const PERIOD_MIN_FRAGMENT_CHARS = 20
const PERIOD_COVERAGE_RATIO = 0.25
/** Conservative streaming variant: mid-flight samples are smaller, so require a higher bar. */
const PERIOD_STREAMING_COVERAGE_RATIO = 0.35

/**
 * Fifth wave, Layer 2 — short-output loop. When the block is too small for
 * window statistics (below {@link HASH_MIN_CHARS}) but still shows the loop
 * signal (≥4 lines, high short-line share, a tiny word vocabulary dominated by
 * one word), flag it. This is the sub-50-line short-phrase loop the first two
 * waves cannot see (no dominant *line*) and the third wave cannot see (Chinese
 * tokens filtered / low overlap).
 */
const SHORT_LOOP_MIN_LINES = 4
const SHORT_LOOP_MAX_WORD_DISTINCT = 0.55
const SHORT_LOOP_MIN_TOP_WORD = 0.3

/**
 * Options controlling {@link degenerateOutputReason} behavior.
 */
export interface DegenerateOutputOptions {
  /**
   * Use the conservative mid-stream thresholds. The streaming watchdog passes
   * this because it samples a still-incomplete attempt: rejecting too eagerly
   * abandons healthy work-plans and burns retries. The post-stream and
   * abort-salvage paths omit it, keeping the strict line-level calibration.
   */
  streaming?: boolean
}

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
export function degenerateOutputReason(blocks: readonly ContentBlock[], opts: DegenerateOutputOptions = {}): string | undefined {
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

  // Fifth wave, Layer 2 — short-output loop. Runs before the MIN_LINES gate:
  // a sub-50-line short-phrase loop (CJK or EN) has too few lines for the
  // first/second waves (no dominant line) and too few characters for window
  // statistics, yet it is a real degenerate shape (e.g. the 9-line
  // `检查 ocr。` / `确认 ocr 可用。` … loop). The word-level vocabulary is tiny
  // and dominated by one word, while healthy short output has a rich
  // vocabulary (distinct ratio 100% in the healthy reasoning baseline).
  if (total >= SHORT_LOOP_MIN_LINES && total < MIN_LINES) {
    const shortLines = lines.filter(line => line.length <= SHORT_LINE_MAX_CHARS).length
    if (shortLines / total >= SHORT_LINE_RATIO) {
      const wordCounts = countWords(blocks)
      const top = topWord(wordCounts)
      if (wordCounts.size / top.total <= SHORT_LOOP_MAX_WORD_DISTINCT && top.count / top.total >= SHORT_LOOP_MIN_TOP_WORD) {
        return `degenerate output: ${total} lines, ${wordCounts.size} distinct words, `
          + `"${top.word}" ${top.count}x (${Math.round(shortLines / total * 100)}% short lines, sub-50-line loop)`
      }
    }
  }

  // Fifth wave, Layer 1 — long-text hash self-similarity. Runs before the
  // MIN_LINES gate too: a single-line mega block (total = 1) or a sub-50-line
  // varied loop would otherwise short-circuit here and escape every wave. The
  // line-level waves below still take priority — when they fire they carry a
  // more precise diagnostic — so Layer 1 only returns when nothing earlier
  // matched.
  if (total < MIN_LINES) {
    const hashReason = hashSelfSimilarityReason(blocks, opts)
    if (hashReason) return hashReason
    return undefined
  }

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
  // the short-line check, but adjacent lines still share fragments. The
  // streaming watchdog uses the conservative threshold (sampled mid-flight,
  // before the model has finished), while the post-stream and abort-salvage
  // paths keep the strict calibration on the completed output.
  const adjacentThreshold = opts.streaming ? STREAMING_ADJACENT_SIMILARITY_RATIO : ADJACENT_SIMILARITY_RATIO
  let adjacentSimilar = 0
  let previous: string | undefined
  for (const line of lines) {
    if (previous !== undefined && fragmentSimilarity(previous, line) >= adjacentThreshold) adjacentSimilar++
    previous = line
  }
  const adjacentRatio = adjacentSimilar / (total - 1)
  if (adjacentRatio >= adjacentThreshold) {
    return `degenerate output: ${total} lines, ${counts.size} distinct fragments, `
      + `top line "${topLine.slice(0, 40)}" repeated ${topCount}x `
      + `(${Math.round(adjacentRatio * 100)}% adjacent lines share fragments)`
  }

  // Fifth wave, Layer 1 (fallback for ≥ MIN_LINES blocks the line waves missed,
  // e.g. a 60-line varied CJK loop with no dominant line and no adjacent
  // fragment overlap).
  return hashSelfSimilarityReason(blocks, opts) ?? undefined
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

/**
 * Tokenize text into words: split on `:` / whitespace / CJK punctuation /
 * ASCII `,` `.` `;`, keeping every non-empty token. Unlike
 * {@link lineFragments}, short CJK tokens (2 chars: `检查`) and short Latin
 * tokens (3 chars: `ocr`) are kept — they are the *signal* for short-phrase
 * loops, and a degenerate block's tiny vocabulary only becomes visible when
 * these are counted. The ASCII punctuation matters for English short loops
 * (`check ocr.` must yield `ocr`, not `ocr.`, or the trailing period inflates
 * the distinct-word count and hides the loop).
 */
function wordTokens(blocks: readonly ContentBlock[]): string[] {
  const tokens: string[] = []
  for (const block of blocks) {
    if (block.type === 'reasoning' || block.type === 'text') {
      for (const part of block.text.split(/(?::|\s|，|。|；|、|,|\.|;)/)) {
        const token = part.trim()
        if (token.length > 0) tokens.push(token)
      }
    }
  }
  return tokens
}

/** Count word tokens across all text/reasoning blocks. */
function countWords(blocks: readonly ContentBlock[]): Map<string, number> {
  const counts = new Map<string, number>()
  for (const token of wordTokens(blocks)) counts.set(token, (counts.get(token) ?? 0) + 1)
  return counts
}

/** Return the most frequent word, its count, and the total token count. */
function topWord(counts: Map<string, number>): { word: string; count: number; total: number } {
  let word = ''
  let count = 0
  let total = 0
  for (const [token, c] of counts) {
    total += c
    if (c > count) {
      count = c
      word = token
    }
  }
  return { word, count, total }
}

/**
 * Average Jaccard similarity of consecutive windows over the text's character
 * shingles (6-grams). This is a shape-agnostic "self-similarity" measure: a
 * block that repeats the same material reads near-1.0 (every window shares the
 * same shingles), healthy prose/code reads well below (windows differ). O(n)
 * and cheap enough for the streaming watchdog's 32-chunk sampling.
 */
function windowSelfSimilarity(text: string): number {
  const shingleSize = 6
  const shingles: string[] = []
  for (let i = 0; i + shingleSize <= text.length; i++) shingles.push(text.slice(i, i + shingleSize))
  if (shingles.length < 8) return 0
  const windowCount = 4
  const windowSize = Math.floor(shingles.length / windowCount)
  const windows: Set<string>[] = []
  for (let w = 0; w < windowCount; w++) {
    windows.push(new Set(shingles.slice(w * windowSize, (w + 1) * windowSize)))
  }
  let sum = 0
  for (let i = 1; i < windowCount; i++) {
    const left = windows[i - 1]
    const right = windows[i]
    if (left === undefined || right === undefined) continue
    let overlap = 0
    for (const shingle of left) if (right.has(shingle)) overlap++
    const union = left.size + right.size - overlap
    sum += union > 0 ? overlap / union : 0
  }
  return sum / (windowCount - 1)
}

/**
 * Split text into sentence-ish fragments for exact-repeat detection. A
 * fragment is a trimmed run bounded by a newline, a `.`/`:`/`;` followed by
 * whitespace, a CJK `。`/`；`/`、`, or a `:`/`：` followed by an uppercase
 * letter or CJK char (handles `bash:PowerShell` and `call):Both` without
 * whitespace). Long-sentence loops repeat whole fragments verbatim; healthy
 * prose does not.
 */
function repeatFragments(text: string): string[] {
  return text
    .split(/\n+|(?<=[.:;])\s+|(?<=[:：])(?=[A-Z\u4e00-\u9fff])|(?<=[。；、])(?=\S)/)
    .map(part => part.trim())
    .filter(part => part.length > 0)
}

/**
 * Tier C metric: the longest *contiguous* run of fragments that agree under a
 * single period p ≤ {@link PERIOD_MAX} (fragments[i] === fragments[i + p] for
 * consecutive i), expressed as a share of all fragments. A degenerate
 * long-sentence loop repeats its paragraph verbatim, so the fragment sequence
 * is periodic (`[S1,S2,S3] × 10` → period 3, run ≈ n − 3) and coverage is
 * high; healthy text that merely *reuses* a sentence across lines interleaves
 * unique material between occurrences, which breaks every candidate period at
 * the first comparison (run ≈ 1–2). Returns the best period, its run length,
 * and a sample fragment for the diagnostic message. O(n·PERIOD_MAX).
 */
function periodicRunCoverage(text: string): { coverage: number; run: number; period: number; sample: string } {
  const fragments = repeatFragments(text)
  const n = fragments.length
  if (n < PERIOD_MIN_RUN_FRAGMENTS) return { coverage: 0, run: 0, period: 0, sample: '' }
  let bestRun = 0
  let bestPeriod = 0
  let bestStart = 0
  for (let p = 1; p <= PERIOD_MAX; p++) {
    let run = 0
    let start = 0
    for (let i = 0; i + p < n; i++) {
      if (fragments[i] === fragments[i + p]) {
        if (run === 0) start = i
        run++
        if (run > bestRun) {
          bestRun = run
          bestPeriod = p
          bestStart = start
        }
      } else {
        run = 0
      }
    }
  }
  if (bestRun < PERIOD_MIN_RUN_FRAGMENTS) return { coverage: 0, run: bestRun, period: bestPeriod, sample: '' }
  // Gate on the average length of the fragments inside the periodic run:
  // long-sentence loops repeat 46+ char fragments, while short-phrase loops
  // (~7 chars) are already caught by Tiers A/B and must not trigger Tier C
  // (especially mid-stream, where the watchdog is deliberately conservative).
  const runEnd = Math.min(bestStart + bestRun + bestPeriod, n)
  let runChars = 0
  for (let i = bestStart; i < runEnd; i++) {
    const fragment = fragments[i]
    if (fragment !== undefined) runChars += fragment.length
  }
  const avgLength = runEnd > bestStart ? runChars / (runEnd - bestStart) : 0
  if (avgLength < PERIOD_MIN_FRAGMENT_CHARS) return { coverage: 0, run: bestRun, period: bestPeriod, sample: '' }
  // A fragment inside the best periodic run, for the diagnostic message.
  let sample = ''
  for (let i = 0; i < n && sample === ''; i++) {
    const candidate = fragments[i]
    if (candidate !== undefined && i + bestPeriod < n && candidate === fragments[i + bestPeriod]) sample = candidate
  }
  return { coverage: bestRun / n, run: bestRun, period: bestPeriod, sample }
}

/**
 * Fifth wave, Layer 1 — long-text hash self-similarity. Assembles all
 * text/reasoning blocks into one string and flags blocks whose word vocabulary
 * is tiny (distinct ratio ≤ 8% strict / ≤ 5% streaming) AND whose windows are
 * near-identical (similarity ≥ 0.9 strict / ≥ 0.95 streaming). Catches:
 * - single-line mega blocks (selftest: 1.7 KB, 3% distinct words, 0.94);
 * - sub-50-line varied CJK loops (ocr 60 lines: 5% distinct, 1.00);
 * - long-line note loops the adjacent-fragment wave cannot see.
 * A second tier (Tier B) catches *varied-phrasing* loops whose window
 * similarity only reaches ~0.71 (16 phrasings rotating, e.g. the 3427-line
 * `读 arch-review…` block at 1.4% distinct words): when the vocabulary is that
 * tiny (<3% strict / <2% streaming distinct) a moderate ≥0.65 similarity is
 * still damning (healthy floor: 7% distinct, so no healthy text reaches it).
 */
function hashSelfSimilarityReason(blocks: readonly ContentBlock[], opts: DegenerateOutputOptions): string | undefined {
  let text = ''
  for (const block of blocks) {
    if (block.type === 'reasoning' || block.type === 'text') text += block.text + '\n'
  }
  if (text.length < HASH_MIN_CHARS) return undefined

  const counts = countWords(blocks)
  const top = topWord(counts)
  const wordDistinct = counts.size / top.total
  const similarity = windowSelfSimilarity(text)

  // Tier A: tiny vocabulary AND near-identical windows (exact-repeat loops).
  const maxDistinctA = opts.streaming ? HASH_STREAMING_MAX_WORD_DISTINCT : HASH_MAX_WORD_DISTINCT
  const minSimA = opts.streaming ? HASH_STREAMING_MIN_WINDOW_SIMILARITY : HASH_MIN_WINDOW_SIMILARITY
  const tierA = wordDistinct <= maxDistinctA && similarity >= minSimA

  // Tier B: extremely tiny vocabulary AND moderately high self-similarity
  // (varied-phrasing loops that never reach Tier A's similarity bar).
  const maxDistinctB = opts.streaming ? HASH_STREAMING_VARIED_MAX_WORD_DISTINCT : HASH_VARIED_MAX_WORD_DISTINCT
  const tierB = wordDistinct <= maxDistinctB && similarity >= HASH_VARIED_MIN_WINDOW_SIMILARITY

  // Tier C: longest periodic-run coverage (long-sentence loops). Tier A/B miss
  // this shape — a full sentence has too many distinct words, and a healthy
  // prefix dilutes both metrics — but a repeated paragraph makes the fragment
  // sequence periodic, and the longest contiguous periodic run dominates.
  const periodic = periodicRunCoverage(text)
  const coverageBar = opts.streaming ? PERIOD_STREAMING_COVERAGE_RATIO : PERIOD_COVERAGE_RATIO
  const tierC = periodic.coverage >= coverageBar

  if (!tierA && !tierB && !tierC) return undefined

  if (!tierA && !tierB) {
    return `degenerate output: "${periodic.sample.slice(0, 40)}" repeated with period ${periodic.period}, `
      + `${Math.round(periodic.coverage * 100)}% periodic-run coverage over ${text.length} chars`
  }

  return `degenerate output: ${Math.round(wordDistinct * 100)}% distinct words, `
    + `"${top.word}" ${top.count}x, ${Math.round(similarity * 100)}% window self-similarity over ${text.length} chars`
}
