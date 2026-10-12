/**
 * Durable journal of background jobs reconstructed from the session log.
 *
 * Background jobs live in the process-local job registry and die with their
 * owning agent (host reload, agent recreation, or a session resume dispose the
 * old agent and its jobs). The *session log*, however, is durable: it records
 * every `job_output` / `job_kill` / `job_list` call with its structured
 * `job_id` argument and the tool-rendered status line, plus every background
 * producer call (pwsh/bash promotion, `run_in_background` subagent/workflow,
 * terminal_send) whose result names the created job.
 *
 * This journal replays those events on construction (so a resumed agent sees
 * the jobs its predecessor started) and then follows `session/event`, exactly
 * like {@link ActionRegistry}. It never guesses at model text: every fact is
 * read from a structured argument (`job_id`) or a controlled tool-rendered
 * format (`[status: …]`, `unknown job <id>`, `moved to background job <id>`).
 * @module @deepseek-ai/dsh-agent-loop/job-journal
 */

import type { Context } from '@deepseek-ai/cordis'
import type { ToolCallId } from '@deepseek-ai/dsh-llm'
import type { Session, SessionEvent, SessionSeq } from '@deepseek-ai/dsh-session'

/**
 * One background job observed in the session, keyed by its job id. Fields are
 * the durable facts the log actually carries; there is no live status here —
 * that lives only in the process-local registry.
 */
export interface JobJournalRecord {
  readonly jobId: string
  /**
   * Producer tool name when the job was created here (pwsh, bash, subagent,
   * workflow, terminal_send, …), or `'job'` when only ever addressed through
   * `job_output` / `job_kill`.
   */
  readonly kind: string
  /** Short human label: command excerpt for shell jobs, description for subagents/workflows. */
  readonly label?: string
  /** Seq of the first event that mentioned this job. */
  readonly firstSeenSeq: SessionSeq
  /** Seq of the most recent event that mentioned this job. */
  readonly lastSeenSeq: SessionSeq
  /**
   * Last status token observed in a tool-rendered `[status: …]` line
   * (running / completed / killed / failed / stopping), or `'unknown'` when
   * the last sighting was an `unknown job <id>` error.
   */
  readonly lastStatus?: string
}

/** Tool names whose background results name a job; everything else is not a job producer. */
const PRODUCER_TOOLS = new Set([
  'pwsh', 'bash', 'subagent', 'workflow', 'terminal_send',
])

/**
 * Rendered `[status: <token>[, detail]]` status line (tool-jobs render.ts and
 * the subagent/workflow/terminal tools share the shape).
 */
const STATUS_LINE = /\[status:\s*([^,\]\n]+)/u

/** An `unknown job <id>` error: the job no longer exists in the registry. */
const UNKNOWN_JOB = /unknown job\s+([A-Za-z0-9][A-Za-z0-9_-]*)/u

/** A kill receipt for an already-settled job: `job <id> had already finished …`. */
const ALREADY_FINISHED = /job\s+([A-Za-z0-9][A-Za-z0-9_-]*)\s+had already finished/u

/** pwsh/bash promotion: `[still running after 120000ms; moved to background job pwsh-4]`. */
const MOVED_TO_BACKGROUND = /moved to background job\s+([A-Za-z0-9][A-Za-z0-9_-]*)/u

/** workflow: `workflow "…" started in the background as job workflow-1`. */
const STARTED_IN_BACKGROUND = /started in the background as job\s+([A-Za-z0-9][A-Za-z0-9_-]*)/u

/** subagent: `started background subagent job subagent-1`. */
const STARTED_BACKGROUND_JOB = /started background (?:sub)?agent job\s+([A-Za-z0-9][A-Za-z0-9_-]*)/u

/** Structured producer result rendered as JSON: `{"kind":"background","jobId":"pty-send-1",…}`. */
const JSON_JOB_ID = /"jobId"\s*:\s*"([^"]+)"/u
/**
 * Compaction-summary fallback: a job id spelled out in the summary text. Only
 * known producer prefixes count — `pwsh-4`, `subagent-1`, `workflow-9`,
 * `terminal-send-2`, `pty-send-3` — so a bare numeric fragment or prose that
 * merely mentions a number is never taken as evidence. This is the journal's
 * one deliberately loose read: the summary is model-written text, but the
 * prefix-anchored shape is a controlled artifact of the tools that created
 * those jobs, not free-form guesswork.
 */
const SUMMARY_JOB_ID = /\b(?:pwsh|bash|subagent|workflow|terminal[-_]send|pty(?:[-_]send)?)-[0-9][A-Za-z0-9_-]*\b/gu

/** Extract a job id from a producer result's rendered text, or undefined. */
export function jobIdFromProducerText(text: string): string | undefined {
  const structured = JSON_JOB_ID.exec(text)
  if (structured?.[1] !== undefined) return structured[1]
  const promoted = MOVED_TO_BACKGROUND.exec(text)
  if (promoted?.[1] !== undefined) return promoted[1]
  const background = STARTED_IN_BACKGROUND.exec(text)
  if (background?.[1] !== undefined) return background[1]
  const subagent = STARTED_BACKGROUND_JOB.exec(text)
  if (subagent?.[1] !== undefined) return subagent[1]
  return undefined
}

/** Extract a status token from a job tool result's rendered text, or undefined. */
export function statusFromJobResultText(text: string): string | undefined {
  const status = STATUS_LINE.exec(text)
  if (status?.[1] !== undefined) return status[1].trim()
  if (UNKNOWN_JOB.test(text)) return 'unknown'
  // A kill receipt for an already-settled job carries no `[status:]` line.
  if (ALREADY_FINISHED.test(text)) return 'finished'
  return undefined
}

/** A tool call awaiting its result, mapped from the model's call id. */
interface PendingJobCall {
  kind: string
  jobId?: string
  label?: string
}

/** Parse raw model arguments JSON, mapping invalid JSON to an empty object. */
function parseArgs(raw: string): Record<string, unknown> {
  try {
    const parsed: unknown = raw ? JSON.parse(raw) : {}
    return typeof parsed === 'object' && parsed !== null ? parsed as Record<string, unknown> : {}
  } catch {
    return {}
  }
}

/** Short label for a producer call: command for shells, description/prompt for agents, text for terminals. */
function producerLabel(toolName: string, args: Record<string, unknown>): string | undefined {
  if (toolName === 'pwsh' || toolName === 'bash') {
    const command = args.command
    return typeof command === 'string' && command.length > 0 ? command.slice(0, 80) : undefined
  }
  if (toolName === 'subagent' || toolName === 'workflow') {
    const description = args.description
    if (typeof description === 'string' && description.length > 0) return description.slice(0, 80)
    const prompt = args.prompt
    if (typeof prompt === 'string' && prompt.length > 0) return prompt.slice(0, 80)
    return undefined
  }
  if (toolName === 'terminal_send') {
    const text = args.text
    return typeof text === 'string' && text.length > 0 ? text.slice(0, 80) : undefined
  }
  return undefined
}

/** Render the text content of a `tool/result` event as one string. */
function resultText(event: SessionEvent): string {
  if (event.type !== 'tool/result') return ''
  return event.data.message.content
    .filter((block): block is { type: 'text'; text: string } => block.type === 'text')
    .map(block => block.text)
    .join(' ')
}

/**
 * Session-scoped journal of background jobs. Built by replaying `tool/call` +
 * `tool/result` events on construction (so a resumed session restores the
 * inventory of its predecessor agent), then kept current by following
 * `session/event`.
 */
export class JobJournal {
  private readonly records = new Map<string, JobJournalRecord>()
  private readonly pendingByCallId = new Map<ToolCallId, PendingJobCall>()

  constructor(ctx: Context, session: Session) {
    this.seed(session)
    ctx.on('session/event', (subject, event) => {
      if (subject !== session) return
      this.observe(event)
    })
  }

  /** Replay existing history so a resumed loop sees its predecessor's jobs. */
  private seed(session: Session): void {
    // oxlint-disable-next-line typescript/no-deprecated -- Existing Session history read; migration deferred.
    for (const event of session.snapshotEvents()) this.observe(event)
  }

  private observe(event: SessionEvent): void {
    if (event.type === 'tool/call') {
      this.onToolCall(event)
    } else if (event.type === 'tool/result') {
      this.onToolResult(event)
    }
  }

  private onToolCall(event: Extract<SessionEvent, { type: 'tool/call' }>): void {
    const { callId, name, arguments: raw } = event.data
    const args = parseArgs(raw)
    if (name === 'job_output' || name === 'job_kill' || name === 'job_list') {
      const jobId = args.job_id
      if (typeof jobId === 'string' && jobId.length > 0) {
        this.touch(jobId, 'job', undefined, event.seq)
        this.pendingByCallId.set(callId, { kind: 'job', jobId })
      }
    } else if (PRODUCER_TOOLS.has(name)) {
      const label = producerLabel(name, args)
      this.pendingByCallId.set(callId, label === undefined ? { kind: name } : { kind: name, label })
    }
  }

  private onToolResult(event: Extract<SessionEvent, { type: 'tool/result' }>): void {
    const pending = this.pendingByCallId.get(event.data.message.toolCallId)
    if (pending === undefined) return
    this.pendingByCallId.delete(event.data.message.toolCallId)
    if (pending.kind === 'job') {
      if (pending.jobId === undefined) return
      const status = statusFromJobResultText(resultText(event))
      if (status !== undefined) {
        const record = this.records.get(pending.jobId)
        if (record !== undefined) {
          this.records.set(pending.jobId, {
            ...record,
            lastStatus: status,
            lastSeenSeq: event.seq,
          })
        }
      }
      return
    }
    // A producer call: its result names the job id when the call went background.
    const jobId = jobIdFromProducerText(resultText(event))
    if (jobId !== undefined) this.touch(jobId, pending.kind, pending.label, event.seq)
  }

  /** Create a record if absent (preserving an earlier producer kind/label) and advance the seen seq. */
  private touch(jobId: string, kind: string, label: string | undefined, seq: SessionSeq): void {
    const existing = this.records.get(jobId)
    if (existing === undefined) {
      this.records.set(jobId, { jobId, kind, ...label !== undefined ? { label } : {}, firstSeenSeq: seq, lastSeenSeq: seq })
      return
    }
    if (existing.lastSeenSeq < seq) {
      this.records.set(jobId, { ...existing, lastSeenSeq: seq })
    }
  }

  /**
   * Re-ingest job ids named in a compaction summary's text (the one loose,
   * prefix-anchored read — see {@link SUMMARY_JOB_ID}). Never downgrades an
   * existing record: a richer kind/label/status observed live wins; a
   * re-sighted id only advances `lastSeenSeq`.
   */
  ingestSummaryText(text: string, seq: SessionSeq): void {
    for (const match of text.matchAll(SUMMARY_JOB_ID)) {
      const jobId = match.at(0)
      if (jobId === undefined) continue
      const existing = this.records.get(jobId)
      if (existing === undefined) {
        this.records.set(jobId, { jobId, kind: 'job', firstSeenSeq: seq, lastSeenSeq: seq })
      } else if (existing.lastSeenSeq < seq) {
        this.records.set(jobId, { ...existing, lastSeenSeq: seq })
      }
    }
  }

  /** All observed jobs in first-seen order. */
  list(): JobJournalRecord[] {
    return [...this.records.values()].sort((a, b) => a.firstSeenSeq - b.firstSeenSeq)
  }

  /** The record for one job id, or undefined. */
  get(jobId: string): JobJournalRecord | undefined {
    return this.records.get(jobId)
  }

  /** How many distinct jobs the session has seen. */
  count(): number {
    return this.records.size
  }
}

/**
 * Render the journal inventory as one compact line for a recovery notice:
 * `pwsh-4 (pwsh, running)`, `pwsh-12 (job, unknown)` — at most `limit` jobs.
 */
export function renderJobInventory(journal: JobJournal, limit = 8): string {
  const jobs = journal.list()
  if (jobs.length === 0) return ''
  const shown = jobs.slice(0, limit)
  const rendered = shown.map((record) => {
    const kind = record.kind === 'job' ? 'addressed via job tools' : record.kind
    const status = record.lastStatus === undefined ? 'status unknown' : record.lastStatus
    const label = record.label === undefined ? '' : ` — ${record.label}`
    return `${record.jobId} (${kind}, ${status}${label})`
  }).join('; ')
  return jobs.length > limit ? `${rendered}; and ${jobs.length - limit} more` : rendered
}
