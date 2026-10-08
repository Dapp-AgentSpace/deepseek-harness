/**
 * Structured action registry: records every tool call by a normalized argument
 * fingerprint and its outcome, so a model that re-issues an identical call after
 * it failed can be intercepted *before* execution. This is the behavioral
 * counterpart to the text-level degenerate detectors: instead of matching
 * repeated *text*, it compares the *structured arguments* of actual tool calls
 * and knows the outcome (failed vs succeeded), which text matching cannot see.
 *
 * The registry is rebuilt from the session log on construction and then follows
 * `session/event`, so it survives compaction and resume without extra
 * persistence.
 * @module @deepseek-ai/dsh-agent-loop/action-registry
 */

import type { Context } from '@deepseek-ai/cordis'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { Session, SessionEvent, SessionSeq } from '@deepseek-ai/dsh-session'

/**
 * Argument keys that never carry tool meaning — model/transport metadata that
 * would otherwise make two semantically identical calls look different. Kept
 * minimal and conservative: stripping a meaningful key would cause false
 * positives, so only clearly volatile transport ids are ignored.
 */
const VOLATILE_KEYS = new Set(['callId', 'requestId', 'nonce', 'traceId'])

/**
 * Tool names whose successful completion records an `fs/observed` observation
 * for the targeted file, refreshing the edit/write guard basis. The
 * fs-observation-policy plugin keys on these; any successful call here after a
 * failed mutation is evidence the model re-observed the target.
 */
const OBSERVING_TOOL_NAMES = new Set(['read', 'read_image', 'write', 'edit'])

/** One completed tool call, keyed by tool name + normalized argument fingerprint. */
export interface ActionRecord {
  readonly toolName: string
  /** Recursive key-sorted compact JSON of the parsed arguments. */
  readonly fingerprint: string
  /** Normalized `file_path` argument when the call targeted a file; undefined otherwise. */
  readonly filePath?: string
  readonly seq: SessionSeq
  readonly turn: number
  readonly step: number
  /** Whether the call failed (`tool/result` carried `isError: true`). */
  readonly isError: boolean
  /** Short user-facing outcome: the error reason, or a content summary. */
  readonly outcome: string
}

/**
 * How many consecutive byte-identical outcomes of the same normalized call
 * count as "no net progress" (a STALL-shaped loop). Two identical reads can be
 * a legitimate double-check; three identical outcomes in a row with the same
 * normalized arguments is a loop. Used by {@link ActionRegistry.findStalledRepeat}
 * and referenced by the agent's action guard for its stall notice text.
 */
export const STALL_MIN_STREAK = 3

/** Normalize parsed tool arguments to a stable fingerprint string. */
export function fingerprintArguments(value: unknown): string {
  return JSON.stringify(normalize(value))
}

/** Recursively sort keys, strip volatile metadata, normalize strings, and emit compact JSON. */
function normalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalize)
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value).sort()) {
      if (VOLATILE_KEYS.has(key)) continue
      out[key] = normalize((value as Record<string, unknown>)[key])
    }
    return out
  }
  // Strings are normalized for volatile tokens: timestamps and machine
  // addresses are almost never load-bearing in an argument fingerprint, so two
  // calls that differ only by them compare equal and the registry can see the
  // repeat. Plain prose is left untouched.
  return typeof value === 'string' ? normalizeString(value) : value
}

/**
 * Normalize a single string for fingerprinting: strip volatile machine tokens
 * so semantically identical calls compare equal. An ISO-8601 timestamp prefix
 * (`2026-09-30T10:00:00Z`) or a bare epoch of 10+ digits becomes `<ts>`;
 * path-shaped values (`./a/b`, `a\b`) are unified to forward slashes with a
 * leading `./` and trailing `/` removed and duplicate separators collapsed.
 * Everything else — including numbers and prose — passes through unchanged, so
 * the normalization can never conflate load-bearing content.
 */
export function normalizeString(value: string): string {
  if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/u.test(value) || /^\d{10,}$/u.test(value)) return '<ts>'
  if (value.includes('/') || value.includes('\\')) {
    return value
      .replaceAll('\\', '/')
      .replace(/^\.\//u, '')
      .replace(/\/+$/u, '')
      .replace(/\/{2,}/gu, '/')
  }
  return value
}

/** A call awaiting its `tool/result`, keyed by the model's call id. */
interface PendingCall {
  toolName: string
  fingerprint: string
  filePath?: string
  seq: SessionSeq
  turn: number
  step: number
}

/**
 * Session-scoped record of every completed tool call. Built by replaying
 * `tool/call` + `tool/result` events on construction, then kept current by
 * following `session/event`.
 */
export class ActionRegistry {
  private readonly records: ActionRecord[] = []
  private readonly byCallId = new Map<ToolCallId, PendingCall>()

  constructor(ctx: Context, session: Session) {
    this.seed(session)
    ctx.on('session/event', (subject, event) => {
      if (subject !== session) return
      this.observe(event)
    })
  }

  /** Replay existing history so a resumed loop still guards repeated failures. */
  private seed(session: Session): void {
    for (const event of session.snapshotEvents()) this.observe(event)
  }

  private observe(event: SessionEvent): void {
    if (event.type === 'tool/call') {
      const args = parseArgs(event.data.arguments)
      const filePath = filePathOf(args)
      this.byCallId.set(event.data.callId, {
        toolName: event.data.name,
        fingerprint: fingerprintArguments(args),
        ...filePath !== undefined ? { filePath } : {},
        seq: event.seq,
        turn: event.data.turn,
        step: event.data.step,
      })
    } else if (event.type === 'tool/result') {
      const pending = this.byCallId.get(event.data.message.toolCallId)
      if (pending === undefined) return
      this.byCallId.delete(event.data.message.toolCallId)
      this.records.push({
        toolName: pending.toolName,
        fingerprint: pending.fingerprint,
        ...pending.filePath !== undefined ? { filePath: pending.filePath } : {},
        seq: pending.seq,
        turn: pending.turn,
        step: pending.step,
        isError: event.data.message.isError === true,
        outcome: summarizeOutcome(event),
      })
    }
  }

  /**
   * The most recent completed call of the same tool with the same normalized
   * arguments that *failed*, or undefined when there is none. Only a failed
   * prior call is evidence of a repeat: intercepting successful or first calls
   * would block legitimate work.
   */
  findFailedRepeat(toolName: string, args: unknown): ActionRecord | undefined {
    const fingerprint = fingerprintArguments(args)
    for (let index = this.records.length - 1; index >= 0; index -= 1) {
      const record = this.records[index]
      if (record?.toolName !== toolName || record.fingerprint !== fingerprint) continue
      // The first (and any successful) occurrence is not a repeat to intercept.
      return record.isError ? record : undefined
    }
    return undefined
  }

  /**
   * Zero-progress repeat detection: the same tool with the same normalized
   * arguments whose trailing runs are byte-identical, whether successful or
   * failed. A successful call that keeps returning the identical result makes
   * no net progress; an identical failure streak is a consistent fallback
   * behind {@link findFailedRepeat}. The streak must be *trailing* and
   * outcome-*identical*: any call that differs in tool, normalized arguments,
   * or outcome breaks it, so a verification loop that reads changing files is
   * never intercepted.
   */
  findStalledRepeat(toolName: string, args: unknown): ActionRecord | undefined {
    const fingerprint = fingerprintArguments(args)
    const last = this.records.at(-1)
    if (last === undefined || last.toolName !== toolName || last.fingerprint !== fingerprint) {
      return undefined
    }
    const outcome = last.outcome
    let streak = 0
    for (let index = this.records.length - 1; index >= 0; index -= 1) {
      const record = this.records[index]
      if (record?.toolName !== toolName || record.fingerprint !== fingerprint || record.outcome !== outcome) break
      streak += 1
      if (streak >= STALL_MIN_STREAK) return record
    }
    return undefined
  }

  /** The most recently completed tool call, or undefined when none has run yet. */
  lastAction(): ActionRecord | undefined {
    return this.records.at(-1)
  }

  /**
   * Whether a successful observing action on the same file happened after
   * `prior` in the record sequence. A re-observation is the documented remedy
   * for a stale-version failure: it means the retry's guard basis is fresh
   * rather than a blind re-run of the failed call. Only calls that record an
   * `fs/observed` observation count; a successful non-observing call (e.g.
   * `stat`) does not refresh the edit basis.
   */
  hasObservingActionAfter(prior: ActionRecord): boolean {
    if (prior.filePath === undefined) return false
    for (let index = this.records.length - 1; index >= 0; index -= 1) {
      const record = this.records[index]
      if (record === undefined || record.seq <= prior.seq || record.isError) continue
      if (record.filePath !== prior.filePath) continue
      if (OBSERVING_TOOL_NAMES.has(record.toolName)) return true
    }
    return false
  }
}

/** Parse raw model arguments JSON, mapping invalid JSON to an empty object. */
function parseArgs(raw: string): unknown {
  try {
    return raw ? JSON.parse(raw) : {}
  } catch {
    return {}
  }
}

/** Extract a normalized `file_path` from parsed arguments, when present. */
function filePathOf(args: unknown): string | undefined {
  if (args === null || typeof args !== 'object') return undefined
  const filePath = (args as Record<string, unknown>).file_path
  return typeof filePath === 'string' ? normalizeString(filePath) : undefined
}

/** Build a short user-facing outcome from a `tool/result` event. */
function summarizeOutcome(event: SessionEvent): string {
  if (event.type !== 'tool/result') return ''
  const { message, error } = event.data
  const reason = error?.reason ?? error?.code
  if (reason !== undefined && reason !== '') return reason.slice(0, 200)
  const text = message.content
    .filter((block): block is { type: 'text'; text: string } => block.type === 'text')
    .map(block => block.text)
    .join(' ')
    .trim()
  return text.length === 0 ? '(empty result)' : text.slice(0, 200)
}
