/**
 * Default Agent driver over queued turns and step-boundary input. Every request
 * is derived from the session log.
 * @module dsh-agent-loop/agent
 */

import type {
  Agent,
  AgentCancelCause,
  AgentEventDispatch,
  AgentOptions,
  AgentStatus,
  CancelOptions,
  InboxTarget,
  PreStepDecision,
  RequestErrorAction,
} from '@deepseek-ai/dsh-agent'
import { agentEvents, assembleContextFor } from '@deepseek-ai/dsh-agent'
import type { ContentBlock, GenerateOptions, LlmCallConfig, Message, PreparedLlmCall } from '@deepseek-ai/dsh-llm'
import {
  DEGENERATE_OUTPUT_CODE,
  LlmError,
  createAssistantMessage,
  createDeveloperMessage,
  createUserMessage,
  errorChain,
  markAgentLoopRequest,
} from '@deepseek-ai/dsh-llm'
declare module '@deepseek-ai/dsh-llm' {
  interface MessageSourceMap {
    'agent-loop-progress': { kind: 'agent-loop-progress'; form: 'notice' | 'progress' }
  }
}
declare module '@deepseek-ai/dsh-agent' {
  interface AgentOptions {
    /**
     * Wall-clock budget (ms) for one assistant streaming attempt. The mid-stream
     * watchdog catches *repetition*; a model that streams novel-looking text
     * forever trips neither it nor the post-stream detectors, so this absolute
     * budget ends the attempt as a STALL hard error. Defaults to 10 minutes.
     */
    streamingHardLimitMs?: number
    /**
     * Wall-clock budget (ms) for durable progress within a turn: a settled
     * assistant message or a successful tool result. An unbounded retry storm
     * or a loop whose steps never complete anything trips this as a STALL hard
     * error, independent of the shape-specific detectors. Kept above
     * `streamingHardLimitMs` so one legitimately long generation cannot trip
     * it. Defaults to 15 minutes.
     */
    stallHardLimitMs?: number
  }
}
import { assertNever, deepFreeze } from '@deepseek-ai/dsh-util-values'
import type { Scope } from '@deepseek-ai/dsh-scope'
import { createScope } from '@deepseek-ai/dsh-scope'
import type { EpochHeader, RequestContext, Session, SessionEvent, SessionId, SessionSeq, TurnEndReason, UserMessage } from '@deepseek-ai/dsh-session'
import { canonicalHeader, headerEquals, ToolCallRecovery } from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-fs'
import { joinContextSections, renderContextSections, renderPrompt } from '@deepseek-ai/dsh-system-prompt'
import type { PromptAssembly } from '@deepseek-ai/dsh-system-prompt'
import type {} from '@deepseek-ai/dsh-session-projection'
import { deadline, timeoutOf } from '@deepseek-ai/dsh-timeout'
import type { Context } from '@deepseek-ai/cordis'
import { ReactLoopInbox } from './inbox.ts'
import { RuntimeContextProjection } from './runtime-context.ts'
import { AssistantStreamAttempt } from './assistant-stream.ts'
import { degenerateOutputReason } from './degenerate.ts'
import { ActionRegistry, STALL_MIN_STREAK, type ActionRecord } from './action-registry.ts'
import { JobJournal, renderJobInventory } from './job-journal.ts'
import { SystemPromptProjection } from './runtime-context.ts'
import { executeToolCalls } from './tool-calls.ts'

/**
 * Self-monitoring knobs for main-session turns. The loop resists premature
 * plain-text completion while todos remain unfinished, reviews automatic
 * compaction recovery points, and reports progress for long turns.
 */

/** How many consecutive premature completions the todo guard may interrupt; one more hard-errors the turn as stalled (STALL). */
const TODO_GUARD_LIMIT = 2
/** First progress heartbeat delay (ms) after a turn starts. */
const PROGRESS_FIRST_MS = 30_000
/** Progress heartbeat interval (ms) after the first has fired. */
const PROGRESS_INTERVAL_MS = 60_000
/** Model-visible source shared by guard, compaction-review and progress notices. */
const AGENT_LOOP_NOTICE_SOURCE = { kind: 'agent-loop-progress', form: 'notice' } as const
/**
 * How many consecutive plain-text completions that repeat the same fragment
 * the repetition guard may interrupt. Mirrors TODO_GUARD_LIMIT: two
 * interruptions give the model a chance to recover under guidance; a third
 * identical non-progress text hard-errors the turn as stalled (STALL) instead
 * of being let through, so a bad/good/bad oscillation cannot keep re-arming
 * free passes.
 */
const REPETITION_GUARD_LIMIT = 2
/**
 * How many consecutive repeated tool calls (identical failed calls, or
 * identical calls with byte-identical outcomes) the action guard may interrupt.
 * Mirrors REPETITION_GUARD_LIMIT: two interventions give the model a chance to
 * recover under targeted guidance; a third identical call hard-errors the turn
 * as stalled (STALL) instead of being let through.
 */
const ACTION_REPEAT_GUARD_LIMIT = 2
/**
 * A text-only reply whose single most repeated paragraph accounts for at least
 * this many occurrences is treated as a degenerate loop. The observed failure
 * (c079 / cs-epic runcard advance) repeated one sentence ~475 times; ordinary
 * prose never reaches even a handful of identical paragraphs.
 */
const REPETITION_MIN_COUNT = 8
/**
 * Only a paragraph at least this long is evidence of a meaningful loop. Tiny
 * repeated interjections ("OK.", "Go.") are handled by the line-level
 * DEGENERATE_OUTPUT classifier instead.
 */
const REPETITION_MIN_PARAGRAPH_CHARS = 30
/**
 * Windows shell preference surfaced into every main-session request: `bash`
 * must resolve to Git Bash, not WSL. The cs-epic loop that prompted this fix
 * repeatedly called `bash ci/bin/harness-runcard.sh` and got a WSL
 * "localhost cannot connect" error (the script never ran), then degenerated
 * into repeating "let me read the usage". The hint keeps the model on Git Bash
 * so the shell tool actually executes.
 */
const SHELL_PREFERENCE_HINT = 'On Windows, when you need a bash shell, prefer Git Bash (e.g. "C:\\Program Files\\Git\\bin\\bash.exe") over WSL: WSL often fails with "localhost cannot connect" and the command never runs.'
/**
 * How many stream chunks elapse before the mid-stream degenerate watchdog
 * samples the accumulated blocks again. A model stuck in a repetition loop
 * never emits a finish chunk, so the post-stream degenerate/repetition guards
 * never run and the stream would run forever (c079 seq 1090: 94 copies of
 * "Critical context found. Re-running gates under git-bash:"). Sampling every
 * chunk would re-split the whole accumulated text on character-wise streams,
 * so the watchdog checks on this cadence instead; the detectors early-return
 * below their line/paragraph thresholds, keeping healthy streams cheap.
 */
const STREAMING_GUARD_CHECK_INTERVAL = 32
/**
 * Wall-clock budget (ms) for one assistant streaming attempt. The mid-stream
 * watchdog catches *repetition*; a model that streams novel-looking text
 * forever trips neither it nor the post-stream detectors, so this absolute
 * budget ends the attempt as a STALL hard error. Generous by default: a
 * legitimate generation (even a long report) finishes well inside it.
 */
const STREAMING_HARD_LIMIT_MS = 10 * 60_000
/**
 * Wall-clock budget (ms) for durable progress within a turn: a settled
 * assistant message or a successful tool result. An unbounded retry storm or a
 * loop whose steps never complete anything trips this as a STALL hard error,
 * independent of the shape-specific detectors. Kept above
 * {@link STREAMING_HARD_LIMIT_MS} so one legitimately long generation can
 * never trip it.
 */
const STALL_HARD_LIMIT_MS = 15 * 60_000
/**
 * Terminal stall classification. Deliberately absent from the default
 * retryable set (where DEGENERATE_OUTPUT lives): a stall has already exhausted
 * generous budgets and guard limits, so re-running it only burns more budget.
 * The turn hard-errors at the driver boundary instead.
 */
const STALLED_OUTPUT_CODE = 'STALLED_OUTPUT'
/** Timeout-reason code for a bounded `whenIdle` wait that elapsed first. */
const WHEN_IDLE_TIMEOUT = 'WHEN_IDLE_TIMEOUT'

/** One entry of a plugin `todo/write` payload. */
interface TodoItem {
  content: string
  status: 'pending' | 'in_progress' | 'completed'
}

/** Todos that are not yet done; the loop treats these as unfinished work. */
function unfinishedTodos(todos: unknown): TodoItem[] {
  if (!Array.isArray(todos)) return []
  return todos.filter((item): item is TodoItem =>
    typeof item === 'object' && item !== null
      && typeof (item as TodoItem).content === 'string'
      && ((item as TodoItem).status === 'pending' || (item as TodoItem).status === 'in_progress'))
}

/** Human-readable elapsed time for progress notices. */
function formatElapsed(ms: number): string {
  const total = Math.round(ms / 1_000)
  if (total < 60) return `${total}s`
  const minutes = Math.floor(total / 60)
  if (minutes < 60) return `${minutes}m ${total % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m ${total % 60}s`
}

/**
 * Detect a text-only degenerate loop at the *paragraph* level: the same
 * sentence/passage repeated many times with no tool call. This is the failure
 * mode the line-level {@link degenerateOutputReason} can miss — a long line
 * (e.g. "The usage is `advance <runcard-id> ...`. Let me read the script usage
 * section:") stays above the short-line threshold, so the whole-line classifier
 * never fires even though the message is ~475 repetitions of one sentence.
 * Returns the dominant repeated paragraph (trimmed) and its count, or undefined
 * when the text is not dominated by repetition.
 */
function textRepetitionReason(blocks: readonly ContentBlock[]): { fragment: string; count: number } | undefined {
  const paragraphs: string[] = []
  for (const block of blocks) {
    if (block.type !== 'text') continue
    for (const raw of block.text.split(/\n\n+/)) {
      const paragraph = raw.replace(/\s+/g, ' ').trim()
      if (paragraph.length >= REPETITION_MIN_PARAGRAPH_CHARS) paragraphs.push(paragraph)
    }
  }
  if (paragraphs.length < REPETITION_MIN_COUNT) return undefined
  const counts = new Map<string, number>()
  for (const paragraph of paragraphs) counts.set(paragraph, (counts.get(paragraph) ?? 0) + 1)
  let top = ''
  let topCount = 0
  for (const [paragraph, count] of counts) {
    if (count > topCount) {
      top = paragraph
      topCount = count
    }
  }
  if (topCount >= REPETITION_MIN_COUNT) {
    return { fragment: top.slice(0, 90), count: topCount }
  }
  return undefined
}

type Phase =
  | { kind: 'idle'; lastTurn: number }
  | {
    kind: 'maintenance'
    abort: AbortController
    lastTurn: number
    wakeRequested: boolean
  }
  | { kind: 'running'; abort: AbortController; turn: number; step: number; wakeRequested: boolean }

type StepEndReason = Extract<TurnEndReason, { kind: 'completed' | 'max-tokens' }>

type PreparedStep =
  | { kind: 'reject' }
  | {
    kind: 'enter'
    messages: UserMessage[]
    startsRequestSeries?: true
    assembly: PromptAssembly
  }

/** Remove adapter-derived values before plugins propose the next request config. */
function requestProposal(header: EpochHeader): LlmCallConfig {
  if (header.adapterDefaults === undefined) return header.config
  const proposal = { ...header.config }
  if (header.adapterDefaults.reasoningEffort === true) delete proposal.reasoningEffort
  if (header.adapterDefaults.maxTokens === true) delete proposal.maxTokens
  return proposal
}

/**
 * Read the cause `cancel()` passed when aborting a loop-owned signal, copying
 * only the fields `turn/end` records. The live reason stays the caller's
 * object, and Node's fetch assigns a `stack` onto it that `Session.append`
 * would either log or reject as data JSON cannot hold.
 * @param signal - a turn or maintenance signal this loop owns.
 * @returns the copied cause, or undefined while the signal is still live.
 */
function abortedCancelCause(signal: AbortSignal): AgentCancelCause | undefined {
  if (!signal.aborted) return undefined
  // `cancel()` is the only aborter of the signals this loop owns.
  const cause = signal.reason as AgentCancelCause
  switch (cause.kind) {
    case 'user':
    case 'parent':
    case 'disposed':
      return { kind: cause.kind }
    case 'hook':
      return { kind: 'hook', reason: cause.reason }
    /* v8 ignore next -- cancel accepts the closed AgentCancelCause union */
    default:
      return assertNever(cause)
  }
}

/** Drives one session through turn and step boundaries. */
export class ReactLoopAgent implements Agent {
  readonly inbox: ReactLoopInbox
  private phase: Phase
  private activityDone: Promise<void> = Promise.resolve()

  /** The agent-scoped registration boundary; the lifecycle owner unwinds it after the driver exits. */
  readonly scope: Scope
  readonly ctx: Context

  /** Fused dispatcher, built once in the constructor so hot-path dispatches never allocate. */
  private readonly dispatch: AgentEventDispatch

  /** Whether this loop instance has appended its initial/resume request anchor. */
  private requestHeaderLogged = false
  /** Surface generation at attachment or the preceding built request. */
  private requestSurfaceGeneration: number
  private readonly runtimeContext: RuntimeContextProjection
  /** Structured record of completed tool calls, intercepting identical failed repeats. */
  private readonly actionRegistry: ActionRegistry
  /**
   * Durable journal of background jobs reconstructed from the session log, so a
   * resumed/recreated agent knows which jobs its predecessor started.
   */
  private readonly jobJournal: JobJournal
  /**
   * One-shot: a new loop attached to a session whose history already records
   * background jobs. The owning process-local registry was torn down with the
   * previous agent, so the first step must tell the model what it knows before
   * it assumes jobs are still running.
   */
  private jobRecoveryPending = false
  /** Process-local revision of assistant frames for this attached Session. */
  private assistantStreamRevision = 0
  private assistantAttemptCounter = 0
  private readonly systemPrompt: SystemPromptProjection
  /** Identities fully frozen by this loop; weak references do not retain replaced history. */
  private readonly frozenMessages = new WeakSet<Message>()
  /** Latest `todo/write` snapshot; `null` until the first one is seen. */
  private lastTodoWrite: { seq: SessionSeq; todos: TodoItem[] } | null = null
  /** Set when the session recorded an automatic compaction summary/end. */
  private compactionPending = false
  /** Consecutive plain-text completions the todo guard has interrupted. */
  private todoGuardCount = 0
  /** Consecutive plain-text completions the repetition guard has interrupted. */
  private repetitionGuardCount = 0
  /** Consecutive identical-failed tool-call repeats the action guard has interrupted. */
  private actionRepeatGuardCount = 0
  /**
   * Wall-clock of the last durable progress (a settled assistant message or a
   * successful tool result). The stall gate compares against this; refreshed at
   * turn start, on settle and on successful tool results. Failed results do not
   * count — a loop that only re-tries failing actions must still trip the gate.
   */
  private lastMeaningfulAt = Date.now()

  /**
   * Wall-clock (epoch ms) of the last phase/step activity transition, refreshed
   * on every `setPhase` commit and every step start. Public because bounded
   * idle waits and settlement watches use it to tell live progress from staleness.
   */
  lastActivityAt = Date.now()

  constructor(
    private loopCtx: Context,
    public readonly id: SessionId,
    public readonly options: AgentOptions,
    public readonly session: Session,
  ) {
    this.requestSurfaceGeneration = session.surface.contentGeneration
    this.dispatch = agentEvents(loopCtx, this)
    this.scope = createScope(loopCtx, this)
    this.ctx = this.scope.ctx
    this.inbox = new ReactLoopInbox(this.ctx.sessionProjections, session, this.dispatch)
    /* v8 ignore next -- the loop registers its own turnBoundary unit, so the key is always present */
    const lastTurn = this.loopCtx.sessionProjections.stateOf(session, 'turnBoundary')?.lastTurn ?? 0
    this.phase = { kind: 'idle', lastTurn }
    this.runtimeContext = new RuntimeContextProjection(this.ctx, session)
    this.actionRegistry = new ActionRegistry(this.ctx, session)
    this.jobJournal = new JobJournal(this.ctx, session)
    // A session that already records background jobs reached this loop by a
    // resume/recreation whose old agent (and its process-local jobs) is gone.
    this.jobRecoveryPending = this.jobJournal.count() > 0
    this.systemPrompt = new SystemPromptProjection(session)
    this.observeLoopState(session)
    this.seedGuardCounters(session)
  }

  /**
   * Follow plugin-merged `todo/write` and `compaction/*` events so the loop can
   * resist premature completion and review compaction recovery points. Both
   * event kinds are SessionEventMap extensions that may not be visible at this
   * compile site, so they are read through a structural view rather than the
   * closed SessionEvent union.
   */
  private observeLoopState(session: Session): void {
    const view = (event: SessionEvent): {
      type: string
      seq: SessionSeq
      data: { todos?: unknown; summary?: unknown; message?: { isError?: boolean } }
    } =>
      event as unknown as {
        type: string
        seq: SessionSeq
        data: { todos?: unknown; summary?: unknown; message?: { isError?: boolean } }
      }
    this.ctx.on('session/event', (subject, event) => {
      if (subject !== session) return
      const observed = view(event)
      if (observed.type === 'todo/write') {
        this.lastTodoWrite = { seq: observed.seq, todos: unfinishedTodos(observed.data.todos) }
      } else if (observed.type === 'compaction/summary' || observed.type === 'compaction/end') {
        this.compactionPending = true
        if (observed.type === 'compaction/summary') {
          // Fallback for jobs lost to compaction: the model-written summary is
          // the only text the journal reads, and only under the narrow
          // known-prefix pattern — never bare guesses at model prose.
          this.ingestCompactionSummary(observed.data.summary, observed.seq)
        }
      } else if (observed.type === 'tool/result' && observed.data.message?.isError !== true) {
        // A successful tool result is durable progress: it resets the stall
        // clock so a turn that keeps completing actions is never misread as
        // stalled. Failed results are deliberately not progress — a loop that
        // only re-runs failing actions must still trip the stall gate.
        this.lastMeaningfulAt = Date.now()
      }
    })
    // Seed from history so a resumed loop still guards. The most recent
    // todo/write wins (scanning backwards keeps overwriting); every compaction
    // summary contributes the job ids its text names to the journal. Compaction
    // summaries in history do NOT set `compactionPending`, which stays a
    // live-flow-only one-shot notice.
    // oxlint-disable-next-line typescript/no-deprecated -- Existing Session history read; migration deferred.
    const events = session.snapshotEvents()
    for (let index = events.length - 1; index >= 0; index -= 1) {
      const event = events[index]
      if (event === undefined) continue
      const observed = view(event)
      if (observed.type === 'todo/write') {
        this.lastTodoWrite = { seq: observed.seq, todos: unfinishedTodos(observed.data.todos) }
      } else if (observed.type === 'compaction/summary') {
        this.ingestCompactionSummary(observed.data.summary, observed.seq)
      }
    }
  }

  /** Extract the text blocks of a compaction summary and re-ingest any job ids they name. */
  private ingestCompactionSummary(summary: unknown, seq: SessionSeq): void {
    if (!Array.isArray(summary)) return
    const text = summary
      .filter((block): block is { type: 'text'; text: string } =>
        typeof block === 'object' && block !== null
          && (block as { type?: unknown }).type === 'text'
          && typeof (block as { text?: unknown }).text === 'string')
      .map(block => block.text)
      .join(' ')
    if (text.length === 0) return
    this.jobJournal.ingestSummaryText(text, seq)
  }

  /**
   * Rebuild the three guard counters from the durable log so an interruption
   * history survives compaction and resume (in-memory counters alone would
   * reset on every agent recreation, re-arming the free passes). In-session the
   * counters count consecutive guard interruptions since the last *clean*
   * settle, so seeding walks the log: reset on each non-interrupted
   * `assistant/message` (interrupted/abort-salvaged messages are not the
   * clean-settle reset point), then count each guard kind's distinctive notice
   * text. Counts are capped at their guard limit so a stale log can never
   * inflate the next decision.
   */
  private seedGuardCounters(session: Session): void {
    // oxlint-disable-next-line typescript/no-deprecated -- Existing Session history read; migration deferred.
    const events = session.snapshotEvents()
    let todo = 0
    let repetition = 0
    let action = 0
    for (const event of events) {
      if (event.type === 'assistant/message') {
        if ((event.data as { interrupted?: boolean }).interrupted !== true) {
          todo = 0
          repetition = 0
          action = 0
        }
        continue
      }
      if (event.type !== 'user/message') continue
      const data = event.data as { source?: { form?: string }; content?: readonly ContentBlock[] }
      if (data.source?.form !== 'notice') continue
      const text = data.content
        ?.filter((block): block is { type: 'text'; text: string } => block.type === 'text')
        .map(block => block.text)
        .join(' ') ?? ''
      if (text.includes('still contains unfinished todo items')) todo += 1
      else if (text.includes('times with no tool call')) repetition += 1
      else if (text.includes('with identical arguments')) action += 1
    }
    this.todoGuardCount = Math.min(todo, TODO_GUARD_LIMIT)
    this.repetitionGuardCount = Math.min(repetition, REPETITION_GUARD_LIMIT)
    this.actionRepeatGuardCount = Math.min(action, ACTION_REPEAT_GUARD_LIMIT)
  }

  /**
   * Whether a failed tool call the action guard would otherwise intercept has
   * been remedied by re-observation. Consults the fs observation registry — the
   * same one the tool layer writes on every read/write/edit — directly, so a
   * model that followed the documented remedy (read the target, then re-issue
   * the edit) is not treated as a blind repeat.
   *
   * Only remedy-type failures qualify: an unobserved target
   * (`FS_NOT_OBSERVED`) needs merely a present observation now (any later
   * observation postdates the failure by construction), while a stale-version
   * failure (`FS_STALE_VERSION`) additionally requires a successful observing
   * action after it, so a pre-existing stale observation cannot falsely exempt
   * an infinite blind retry. Anything else, or any lookup failure, stays a
   * repeat — the guard degrades to its previous behavior.
   */
  private async isObservationRemedied(prior: ActionRecord, args: unknown): Promise<boolean> {
    const code = prior.outcome
    const isUnobservedFailure = code.includes('FS_NOT_OBSERVED')
    const isStaleFailure = code.includes('FS_STALE_VERSION')
    if (!isUnobservedFailure && !isStaleFailure) return false
    const filePath = args !== null && typeof args === 'object'
      ? (args as Record<string, unknown>).file_path
      : undefined
    if (typeof filePath !== 'string') return false
    let target
    try {
      // Resolve through the loop's owning context. Property access (`ctx.fs`)
      // walks the live fiber chain, which does not include the fiber where the
      // fs service is mounted, so it throws "without inject"; the explicit
      // service lookup (`ctx.get`) reads the shared reflect store instead and
      // resolves regardless of fiber ancestry.
      const fs = this.loopCtx.get('fs')
      if (!fs) return false
      const { cwd } = this.session.header
      target = await fs.resolve(filePath, cwd !== undefined ? { cwd } : {})
    } catch {
      // Resolution failure: cannot map to the observation registry; keep the
      // interception so the guard never silently passes an unverifiable retry.
      return false
    }
    let observation
    try {
      observation = await this.ctx.waterfall(
        'fs/observed-query',
        target,
        { agent: { session: this.session } },
        () => undefined,
      )
    } catch {
      return false
    }
    if (observation?.kind !== 'present') {
      return false
    }
    return isStaleFailure ? this.actionRegistry.hasObservingActionAfter(prior) : true
  }

  /** The wall-clock budget for one assistant streaming attempt (agent option or default). */
  private get streamingHardLimitMs(): number {
    return this.options.streamingHardLimitMs ?? STREAMING_HARD_LIMIT_MS
  }

  /** The wall-clock budget for durable progress within a turn (agent option or default). */
  private get stallHardLimitMs(): number {
    return this.options.stallHardLimitMs ?? STALL_HARD_LIMIT_MS
  }

  /**
   * Surface a terminal STALL intervention and fail the current step/turn as a
   * hard error. The notice is durable (the user sees why the loop ended); the
   * thrown `LlmError` carries the STALLED_OUTPUT code, which is not in the
   * default retryable set, so the driver boundary reports it without burning
   * retry budget on an already-exhausted loop.
   */
  private stall(reason: string): never {
    this.session.append('user/message', createUserMessage({
      content: [{ type: 'text', text: `(System) ${reason}` }],
      source: AGENT_LOOP_NOTICE_SOURCE,
    }), { surfaceOp: 'append' })
    throw new LlmError(reason, STALLED_OUTPUT_CODE)
  }

  get status(): AgentStatus {
    return this.phase.kind === 'idle' || this.phase.kind === 'maintenance' ? 'idle' : 'running'
  }

  /** Commit a phase and publish its externally visible status transition. */
  private setPhase(next: Phase): void {
    const previousStatus = this.status
    this.phase = next
    this.lastActivityAt = Date.now()
    const status = this.status
    if (status !== previousStatus) {
      this.dispatch.emit('agent/status', { status })
    }
  }

  send(message: UserMessage, target: InboxTarget, wakeup: boolean): void {
    // Waking input cannot join an aborted activity, so it starts the next turn.
    // Captured before the insertion so a reentrant cancel from a splice observer cannot reclassify it.
    const wakingAfterAbort = wakeup && this.phase.kind !== 'idle' && this.phase.abort.signal.aborted
    const resolvedTarget = wakingAfterAbort ? 'next-turn' : target
    this.inbox.splice(resolvedTarget, Infinity, 0, [message])
    if (wakeup) this.wakeDriver(wakingAfterAbort)
  }

  followup(input: UserMessage): void {
    this.send(input, 'next-turn', true)
  }

  steer(input: UserMessage): void {
    this.send(input, 'next-step', true)
  }

  inject(input: UserMessage): void {
    this.send(input, 'next-step', false)
  }

  cancel(cause: AgentCancelCause, options: CancelOptions = {}): void {
    if (!options.keepInbox) {
      this.inbox.clear()
      if (this.phase.kind !== 'idle') this.phase.wakeRequested = false
    }
    if (this.phase.kind !== 'idle') this.phase.abort.abort(cause)
  }

  runMaintenance<T>(job: (signal: AbortSignal) => Promise<T>): Promise<T> {
    if (this.phase.kind !== 'idle') throw new Error(`agent "${this.id}" already has active work`)
    const done = Promise.withResolvers<void>()
    const maintenance: Phase = {
      kind: 'maintenance',
      abort: new AbortController(),
      lastTurn: this.phase.lastTurn,
      wakeRequested: false,
    }
    this.setPhase(maintenance)
    this.activityDone = done.promise
    return (async () => {
      try {
        return await job(maintenance.abort.signal)
      } finally {
        this.setPhase({ kind: 'idle', lastTurn: maintenance.lastTurn })
        const cause = abortedCancelCause(maintenance.abort.signal)
        if (cause?.kind !== 'disposed' && maintenance.wakeRequested && this.inbox.hasPending) this.wakeDriver()
        done.resolve()
      }
    })()
  }

  /**
   * Start one driver, or latch its wake behind maintenance or an aborted
   * activity. A wake sent while idle always opens its turn boundary, even
   * when its message was cleared; only a latched replay is suppressed when
   * the queue no longer holds the wake.
   * @param wakeAfterAbort - the {@link send} classification, captured before
   *   the inbox insertion so a reentrant cancel cannot reclassify it.
   */
  private wakeDriver(wakeAfterAbort = false): void {
    if (this.phase.kind !== 'idle') {
      // Maintenance and aborted drivers cannot deliver the wake: latch it for
      // replay at convergence. Live drivers claim queued work themselves;
      // disposal never latches, so teardown waits on no model turn.
      const reason = abortedCancelCause(this.phase.abort.signal)
      if (reason?.kind !== 'disposed' && (this.phase.kind === 'maintenance' || wakeAfterAbort)) {
        this.phase.wakeRequested = true
      }
      return
    }
    const driver = Promise.withResolvers<void>()
    this.activityDone = driver.promise
    this.setPhase({
      kind: 'running',
      abort: new AbortController(),
      turn: this.phase.lastTurn,
      step: 0,
      wakeRequested: false,
    })
    this.loopCtx.agents.withInitiator(this, () => this.kick()).then(driver.resolve, driver.reject)
  }

  async whenIdle(options: { timeoutMs?: number } = {}): Promise<'idle' | 'timeout'> {
    const { timeoutMs } = options
    if (timeoutMs !== undefined && (!Number.isFinite(timeoutMs) || timeoutMs <= 0)) {
      throw new Error('invalid idle wait timeout: expected a positive number of milliseconds, got ' + JSON.stringify(timeoutMs))
    }
    if (timeoutMs === undefined) {
      let activity: Promise<void>
      do {
        await (activity = this.activityDone)
      } while (activity !== this.activityDone)
      return 'idle'
    }
    const startedAt = Date.now()
    // A scoped deadline distinguishes a budget that elapsed from caller state,
    // and its timer is cleared on every exit path.
    using d = deadline(undefined, timeoutMs, WHEN_IDLE_TIMEOUT)
    let activity: Promise<void>
    do {
      activity = this.activityDone
      await new Promise<void>((resolve, reject) => {
        const release = (): void => {
          d.signal.removeEventListener('abort', onAbort)
          resolve()
        }
        const onAbort = (): void => {
          release()
        }
        activity.then(release, reject)
        d.signal.addEventListener('abort', onAbort, { once: true })
      })
      if (timeoutOf(d.signal, WHEN_IDLE_TIMEOUT) !== undefined) {
        this.ctx.logger.warn('agent idle wait timed out', this.id, Date.now() - startedAt)
        return 'timeout'
      }
    } while (activity !== this.activityDone)
    return 'idle'
  }

  /** Report one failure at its live boundary, then preserve it for driver containment. */
  private throwError(error: unknown): never {
    const turn = this.phase.kind === 'running' ? this.phase.turn : this.phase.lastTurn
    const step = this.phase.kind === 'running' ? this.phase.step : 0
    this.dispatch.emit('agent/error', { turn, step, error })
    throw error
  }

  /**
   * Build a stateful, directed recovery notice for a degenerate/repetition
   * intervention. The generic "no filler" boilerplate tells a degraded model
   * nothing about *what* it repeated or *what* to do instead, so it can loop
   * against the same notice. This variant cites the concrete repeated material
   * (the detector's own reason string), the most recent action's outcome (the
   * loop's visible consequence — the text-level detectors cannot see action
   * outcomes, so this bridges that gap), any unfinished todos, and an explicit
   * next step, so the retried request arrives with a directed recovery target.
   */
  private directedRecoveryNotice(reason: string): string {
    const state: string[] = []
    const last = this.actionRegistry.lastAction()
    if (last !== undefined) {
      state.push(last.isError
        ? `The last action \`${last.toolName}\` (step ${last.step}) failed: ${last.outcome}.`
        : `The last action \`${last.toolName}\` (step ${last.step}) returned: ${last.outcome}.`)
    }
    if (this.lastTodoWrite !== null && this.lastTodoWrite.todos.length > 0) {
      const open = this.lastTodoWrite.todos.length
      state.push(`You still have ${open} unfinished todo${open === 1 ? '' : 's'}.`)
    }
    const context = state.length > 0 ? ` ${state.join(' ')}` : ''
    return `(System) Your previous output was classified as degenerate: ${reason}.${context} Stop repeating yourself and diagnose why progress stalled: fix the failing action and retry it with corrected arguments, call a different tool to make concrete progress, or finish your turn with a concise final answer.`
  }

  private async kick(): Promise<void> {
    try {
      while (await this.turn()) {}
    } catch (_error) {
      // Reported failures and cancellation are contained at the driver boundary.
    } finally {
      /* v8 ignore next -- kick owns a running phase until this driver boundary */
      if (this.phase.kind === 'running') {
        const { turn, wakeRequested } = this.phase
        this.setPhase({ kind: 'idle', lastTurn: turn })
        if (wakeRequested && this.inbox.hasPending) this.wakeDriver()
      }
    }
  }

  private async preStep(target: InboxTarget, position: { turn: number; step: number }): Promise<PreparedStep> {
    /* v8 ignore next -- private callers establish the running phase before proposing a step */
    if (this.phase.kind !== 'running') throw new Error(`agent "${this.id}": pre-step outside running phase`)
    const signal = this.phase.abort.signal
    const claimed = this.inbox.claim(target, position.turn)
    const assembly = await this.loopCtx.systemPrompt.assemble(assembleContextFor(this, signal))
    signal.throwIfAborted()
    const decision = await this.dispatch.waterfall(
      'agent/pre-step', { messages: claimed, ...position, signal },
      (): Promise<PreStepDecision> => {
        const sections = renderContextSections(assembly)
        // Surface the Windows Git Bash preference as part of the runtime context so
        // every main-session request carries it (the projection deduplicates the
        // identical snapshot after the first projection). Only when a shell is
        // actually relevant: win32 hosts.
        let contextText = joinContextSections(sections)
        if (process.platform === 'win32') {
          contextText = contextText.length === 0
            ? SHELL_PREFERENCE_HINT
            : `${SHELL_PREFERENCE_HINT}\n\n${contextText}`
        }
        const context = this.runtimeContext.project(contextText, sections)
        return Promise.resolve<PreStepDecision>({
          kind: 'enter',
          messages: context === undefined ? claimed : [...claimed, context],
        })
      },
    )
    signal.throwIfAborted()
    if (decision.kind === 'reject') return decision
    return { ...decision, assembly }
  }

  /** Whether the assembled tool schemas differ from the logged request header's. */
  private toolsChanged(tools: PromptAssembly['tools']): boolean {
    const baseline = this.session.requestHeader()
    if (baseline === undefined) return false
    return !headerEquals(baseline, canonicalHeader({ ...baseline, tools: [...tools] }))
  }

  /** Open one turn before claiming its first proposed step. */
  private async turn(): Promise<boolean> {
    if (this.phase.kind !== 'running') {
      this.throwError(new Error(`agent "${this.id}": turn without driver reservation`))
    }
    const phase = this.phase
    const { signal } = phase.abort
    signal.throwIfAborted()
    const turn = phase.turn + 1
    try {
      this.session.append('turn/start', { turn })
    } catch (error: unknown) {
      this.throwError(error)
    }
    phase.turn = turn
    const turnStartedAt = Date.now()
    // The stall clock opens at turn start: a step may legitimately take a while
    // (bounded by the streaming hard limit), but the turn must show durable
    // progress within the stall limit or end as a STALL error.
    this.lastMeaningfulAt = turnStartedAt
    let lastProgressAt = turnStartedAt
    let turnEnds: TurnEndReason | null = null
    let target: InboxTarget = 'next-turn'
    try {
      while (true) {
        signal.throwIfAborted()
        const step = phase.step + 1
        const decision = await this.preStep(target, { turn, step })
        if (decision.kind === 'reject') {
          turnEnds = { kind: 'blocked' }
          return false
        }
        if (turnEnds && decision.messages.length === 0) break
        // A removed waking message or an enter decision rewritten to empty
        // still owns the initial turn boundary, but it spends no model call.
        if (phase.step === 0 && decision.messages.length === 0) {
          turnEnds = { kind: 'completed' }
          return false
        }
        signal.throwIfAborted()
        this.session.append('step/start', { turn, step })
        phase.step = step
        this.lastActivityAt = Date.now()
        const toolRecovery = new ToolCallRecovery()
        const stopRecovery = this.ctx.on('session/event', (session, event) => {
          if (session === this.session) toolRecovery.observe(event)
        })
        try {
          // max-tokens is sticky: once any step hits the ceiling, later steps
          // that complete normally must not downgrade the turn outcome.
          const stepEnd = await this.step(decision)
          // max-tokens stays sticky: a later completed step must not
          // downgrade the turn outcome.
          if (turnEnds === null || turnEnds.kind !== 'max-tokens') turnEnds = stepEnd
        } catch (error: unknown) {
          try {
            for (const event of toolRecovery.results()) {
              this.session.append('tool/result', event.data, {
                surfaceOp: 'append',
                ...event.sourceEventSeqs === undefined ? {} : { sourceEventSeqs: event.sourceEventSeqs },
              })
            }
          } catch (recoveryError: unknown) {
            throw new AggregateError([error, recoveryError], 'Step failed and its pending tool results could not be recorded', { cause: error })
          }
          throw error
        } finally {
          stopRecovery()
          this.session.append('step/end', { turn, step })
        }
        // Between-step stall backstop: a step that returned without settling
        // anything (successful tool results refresh the stall clock via
        // `tool/result`; a settle refreshes it at the settle site) leaves the
        // turn open with no durable progress — end it as a STALL hard error
        // instead of letting the turn pin.
        if (turnEnds === null
          && Date.now() - this.lastMeaningfulAt > this.stallHardLimitMs) {
          this.stall(`agent "${this.id}": turn ${turn} made no durable progress (no successful tool result or settled assistant message) for over ${Math.round(this.stallHardLimitMs / 1_000)}s — stalled turn`)
        }
        const elapsed = Date.now() - turnStartedAt
        if (turnEnds === null
          && elapsed >= PROGRESS_FIRST_MS
          && Date.now() - lastProgressAt >= PROGRESS_INTERVAL_MS) {
          lastProgressAt = Date.now()
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: `(System progress) turn ${turn} has executed ${step} step(s), ${formatElapsed(Date.now() - turnStartedAt)} elapsed. The task is still in progress; continue working and do not reply to this message.`,
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
        }
        signal.throwIfAborted()
        if (turnEnds && this.inbox.nextStep.length === 0) {
          await this.dispatch.serial('agent/turn-stopping', { turn, signal })
          signal.throwIfAborted()
        }
        if (turnEnds && this.inbox.nextStep.length === 0) break
        target = 'next-step'
      }
    } catch (error: unknown) {
      // A cause is present exactly while the signal is aborted.
      const cause = abortedCancelCause(signal)
      if (cause !== undefined) {
        turnEnds = { kind: 'aborted', reason: cause }
        throw error
      }
      // Every failure is structured: an `LlmError` keeps its facts, anything
      // else flattens to `errorChain` text under the `UNKNOWN` code.
      turnEnds = {
        kind: 'error',
        error: error instanceof LlmError
          ? error.failure
          : { message: errorChain(error), code: 'UNKNOWN' },
      }
      this.throwError(error)
    } finally {
      try {
        // oxlint-disable-next-line typescript/no-non-null-assertion -- every exit assigns a turn ending
        this.session.append('turn/end', { turn, reason: turnEnds! })
      } catch (error: unknown) {
        this.throwError(error)
      }
    }
    if (!this.inbox.hasPending) return false
    phase.abort = new AbortController()
    // A fresh controller makes a latch set on the old one stale: the live driver claims the queue itself.
    phase.wakeRequested = false
    phase.step = 0
    return true
  }

  private async step(decision: Extract<PreparedStep, { kind: 'enter' }>): Promise<StepEndReason | null> {
    /* v8 ignore next -- private callers establish the running phase before executing a step */
    if (this.phase.kind !== 'running') throw new Error(`agent "${this.id}": step outside running phase`)
    const { turn, step, abort: { signal } } = this.phase
    signal.throwIfAborted()

    const { assembly } = decision
    const renderedPrompt = renderPrompt(assembly)
    let firstAttempt = true
    while (true) {
      // Hard stall gate at the retry-loop top: an unbounded retry storm (or any
      // step that makes no durable progress within the hard limit) must end
      // visibly instead of spinning forever. The clock refreshes at turn start,
      // on settle and on successful tool results, so a legitimately working
      // step never trips it.
      if (Date.now() - this.lastMeaningfulAt > this.stallHardLimitMs) {
        this.stall(`agent "${this.id}": no durable progress (no successful tool result or settled assistant message) for over ${Math.round(this.stallHardLimitMs / 1_000)}s — stalled turn ${turn} step ${step}`)
      }
      // An automatic compaction during the preceding pre-step (or a recovered
      // context overflow inside this step's request-error waterfall) leaves a
      // recovery point: inject a review notice before the next model call so
      // the model re-grounds on the summary instead of ending prematurely.
      if (this.compactionPending) {
        this.compactionPending = false
        const inventory = renderJobInventory(this.jobJournal)
        const text = '(System) The context was just automatically compacted. Cross-check the compaction summary for unfinished work and todo items and continue executing; explicitly mark completed items and do not end the turn early based on the summary alone.'
          + (inventory === '' ? '' : ` Background jobs recorded in this session: ${inventory}. Confirm each with job_list/job_output before assuming its state.`)
        this.session.append('user/message', createUserMessage({
          content: [{
            type: 'text',
            text,
          }],
          source: AGENT_LOOP_NOTICE_SOURCE,
        }), { surfaceOp: 'append' })
      }
      // A loop that attached to a session already recording background jobs
      // succeeded a torn-down agent: its jobs are not live in this process.
      // Tell the model exactly which jobs the log names, once, before it can
      // assume work is still in flight (the observed c079 failure was a
      // resumed agent flailing against an empty job registry).
      if (this.jobRecoveryPending) {
        this.jobRecoveryPending = false
        const inventory = renderJobInventory(this.jobJournal)
        if (inventory !== '') {
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: `(System) This session's history records background jobs started by a previous agent instance: ${inventory}. Those jobs were owned by that agent and are not running in this process (registry jobs do not survive a host restart or agent recreation). Verify what actually survived — check output files with read/glob — and re-launch unfinished work deliberately. Do not assume a job is still running unless job_list reports it live.`,
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
        }
      }
      const { config, preparedCall } = await this.prepareRequest(turn, step, signal)
      const currentContext = this.loopCtx.systemPrompt.refreshContext(assembly, assembleContextFor(this, signal))
      const sections = renderContextSections(currentContext)
      const context = this.runtimeContext.project(joinContextSections(sections), sections)
      signal.throwIfAborted()
      const startsRequestSeries = firstAttempt && decision.startsRequestSeries === true
      const commits = this.systemPrompt.project(renderedPrompt, {
        inHistory: preparedCall?.systemPromptUpdate === 'in-history',
        startsSeries: startsRequestSeries
          || this.requestSurfaceGeneration !== this.session.surface.contentGeneration
          || (preparedCall?.toolUpdate === undefined && this.toolsChanged(assembly.tools)),
      })
      for (const { message, intent } of commits) {
        this.session.append('system/message', { turn, step, message }, intent)
      }
      let contextAdmitted = false
      if (firstAttempt) {
        for (const message of decision.messages) {
          if (message.source.kind === 'runtime-context') {
            if (context !== undefined && !contextAdmitted) {
              this.session.append('user/message', context, { surfaceOp: 'append' })
              contextAdmitted = true
            }
          } else {
            this.session.append('user/message', message, { surfaceOp: 'append' })
          }
        }
      }
      if (context !== undefined && !contextAdmitted) {
        this.session.append('user/message', context, { surfaceOp: 'append' })
      }
      firstAttempt = false
      const request = this.buildRequest(config, preparedCall, assembly.tools, { turn, step }, startsRequestSeries, signal)
      const live = new AssistantStreamAttempt(
        this.session.id,
        ++this.assistantAttemptCounter,
        () => ++this.assistantStreamRevision,
        turn,
        step,
        (frame) => { this.dispatch.emit('agent/assistant-stream', { frame }) },
      )
      let started = false
      // Mid-stream degenerate watchdog state: set to a diagnostic reason when
      // the streaming guard fires, so the attempt is rejected through the same
      // DEGENERATE_OUTPUT pipeline as a degenerate finish instead of running
      // forever. `streamingChunksSinceGuard` throttles the sampling cadence.
      let streamingDegenerate: string | undefined
      let streamingChunksSinceGuard = 0
      // Set alongside `streamingDegenerate` when the wall-clock budget (not a
      // detector) ended the stream; the rejection then hard-errors instead of
      // routing through the retryable DEGENERATE_OUTPUT pipeline.
      let streamingStalled = false
      try {
        const stream = preparedCall?.stream(request) ?? this.loopCtx.llm.stream(request)
        signal.throwIfAborted()
        live.start()
        started = true
        // Wall-clock budget for this attempt: the watchdog catches repetition,
        // but a model emitting novel-looking text forever trips neither it nor
        // the post-stream detectors, so an absolute budget ends the attempt as
        // a STALL hard error. The check runs per-chunk, so it only fires while
        // chunks keep arriving; a fully silent hung stream is left to the
        // transport/abort machinery.
        const streamStartedAt = Date.now()
        for await (const chunk of stream) {
          signal.throwIfAborted()
          live.push(chunk)
          if (Date.now() - streamStartedAt > this.streamingHardLimitMs) {
            streamingStalled = true
            streamingDegenerate = `assistant stream exceeded ${Math.round(this.streamingHardLimitMs / 1_000)}s without a finish chunk`
            break
          }
          // Streaming watchdog: a model stuck in a repetition loop never emits
          // a finish chunk, so the post-stream degenerate/repetition guards
          // never run and the stream would run forever (c079 seq 1090: 94
          // copies of "Critical context found. Re-running gates under
          // git-bash:"). Sample the accumulated blocks on a cadence and break
          // out of the stream when the same detectors fire mid-stream; the
          // rejection is handled after the stream block, mirroring a
          // degenerate finish.
          if (++streamingChunksSinceGuard >= STREAMING_GUARD_CHECK_INTERVAL) {
            streamingChunksSinceGuard = 0
            const current = live.blocks()
            // Mid-stream tool-call blocks legitimately carry an empty id/name
            // while their deltas are still arriving, so the fourth-wave
            // tool-call check must not run here; strip tool calls and keep the
            // line/paragraph waves.
            const textOnly = current.filter(block => block.type !== 'tool-call')
            // The streaming watchdog samples a still-incomplete attempt: the
            // conservative thresholds reject only extreme repetition, so a
            // healthy long work-plan orbiting one topic is not abandoned and
            // retried until retries are exhausted. The post-stream detector
            // still applies the strict thresholds to the finished output.
            const degenerateReason = degenerateOutputReason(textOnly, { streaming: true })
            const repetition = textRepetitionReason(textOnly)
            if (degenerateReason !== undefined) {
              streamingDegenerate = degenerateReason
              break
            }
            if (repetition !== undefined) {
              streamingDegenerate = `repeated "${repetition.fragment}" ${repetition.count} times with no tool call`
              break
            }
          }
        }
        signal.throwIfAborted()
      } catch (error: unknown) {
        if (!started) throw error
        try {
          if (signal.aborted) {
            const content = live.interruptedBlocks()
            if (content.length > 0) {
              // Abort salvage persists whatever the model produced before the
              // user stopped the stream, and this path bypasses the
              // degenerate/repetition guards that only run after a clean
              // finish. A model stuck in a repetition loop therefore dumped
              // hundreds of repeated paragraphs into the log on abort (c079
              // seq 1090: "Critical context found. Re-running gates under
              // git-bash:" x94). Run the same detectors on the salvage and
              // replace degenerate content with a short notice so the loop
              // cannot pollute the session log through the abort path either.
              const degenerateReason = degenerateOutputReason(content)
              const repetition = textRepetitionReason(content)
              let suppressed: string | undefined
              if (degenerateReason !== undefined) {
                suppressed = degenerateReason
              } else if (repetition !== undefined) {
                suppressed = `repeated "${repetition.fragment}" ${repetition.count} times with no tool call`
              }
              live.settle('assistant/message', () => this.session.append('assistant/message', {
                turn,
                step,
                message: createAssistantMessage({
                  content: suppressed === undefined
                    ? content
                    : [{
                      type: 'text',
                      text: `(interrupted output suppressed — ${suppressed})`,
                    }],
                  source: {
                    provider: request.provider,
                    model: request.model,
                    ...live.replayState === undefined ? {} : { replayState: live.replayState },
                  },
                }),
                interrupted: true,
                ...live.usage === undefined ? {} : { usage: live.usage },
                stream: live.stream,
              }, { surfaceOp: 'append' }).seq)
            } else {
              live.settle(
                'assistant/attempt',
                () => this.session.append('assistant/attempt', { turn, step, stream: live.stream }).seq,
              )
            }
          } else {
            live.settle(
              'assistant/attempt',
              () => this.session.append('assistant/attempt', { turn, step, stream: live.stream }).seq,
            )
          }
        } catch (settlementError: unknown) {
          throw new AggregateError(
            [error, settlementError],
            'Assistant stream failed and its durable settlement was rejected',
            { cause: error },
          )
        }
        throw error
      }
      // The streaming watchdog broke out of the stream mid-flight: the model
      // was emitting degenerate repetition with no finish chunk in sight. Reject
      // the attempt exactly like a degenerate finish (abandon + notice + the
      // DEGENERATE_OUTPUT request-error pipeline) so it retries instead of
      // streaming forever.
      if (streamingDegenerate !== undefined) {
        live.abandon()
        this.session.append('user/message', createUserMessage({
          content: [{
            type: 'text',
            text: this.directedRecoveryNotice(streamingDegenerate),
          }],
          source: AGENT_LOOP_NOTICE_SOURCE,
        }), { surfaceOp: 'append' })
        if (streamingStalled) {
          // A wall-clock hard-limit stall is terminal: the attempt streamed far
          // past a generous budget with no finish chunk, so re-running yields
          // the same unbounded stream. Fail as a hard error instead of routing
          // through the retryable DEGENERATE_OUTPUT pipeline.
          throw new LlmError(streamingDegenerate, STALLED_OUTPUT_CODE)
        }
        const action = await this.dispatch.waterfall(
          'agent/request-error', {
            turn,
            step,
            provider: request.provider,
            failure: { message: streamingDegenerate, code: DEGENERATE_OUTPUT_CODE },
            retryPolicy: preparedCall?.retryPolicy,
            signal,
          },
          () => Promise.resolve<RequestErrorAction>(undefined),
        )
        signal.throwIfAborted()
        if (action?.kind !== 'retry') {
          throw new LlmError(streamingDegenerate, DEGENERATE_OUTPUT_CODE)
        }
        continue
      }
      try {
        const finish = live.finish
        if (finish.kind === 'error' || finish.kind === 'aborted') {
          live.settle(
            'assistant/attempt',
            () => this.session.append('assistant/attempt', { turn, step, stream: live.stream }).seq,
          )
          const action = await this.dispatch.waterfall(
            'agent/request-error', {
              turn,
              step,
              provider: request.provider,
              failure: finish.failure,
              retryPolicy: preparedCall?.retryPolicy,
              signal,
            },
            () => Promise.resolve<RequestErrorAction>(undefined),
          )
          signal.throwIfAborted()
          if (action?.kind !== 'retry') {
            throw new LlmError(finish.failure.message, finish.failure.code, finish.failure)
          }
          continue
        }

        const message = createAssistantMessage({
          content: live.blocks(),
          source: {
            provider: request.provider,
            model: request.model,
            ...live.replayState !== undefined ? { replayState: live.replayState } : {},
          },
        })
        // A response that looped on repeated fragments is unusable progress: it
        // must never be persisted (it would pollute the session log and feed
        // back into the next request) nor counted as a completed turn. Classify
        // it before settling and route it through the request-error pipeline so
        // retry policy can decide (DEGENERATE_OUTPUT is retryable by default).
        const degenerateReason = degenerateOutputReason(message.content)
        if (degenerateReason !== undefined) {
          live.abandon()
          // Surface an intervention notice before the retry so the regenerated
          // request carries explicit guidance instead of looping the same
          // degenerate text. The request-error pipeline still decides whether
          // to retry (DEGENERATE_OUTPUT is retryable by default).
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: this.directedRecoveryNotice(degenerateReason),
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
          const action = await this.dispatch.waterfall(
            'agent/request-error', {
              turn,
              step,
              provider: request.provider,
              failure: { message: degenerateReason, code: DEGENERATE_OUTPUT_CODE },
              retryPolicy: preparedCall?.retryPolicy,
              signal,
            },
            () => Promise.resolve<RequestErrorAction>(undefined),
          )
          signal.throwIfAborted()
          if (action?.kind !== 'retry') {
            throw new LlmError(degenerateReason, DEGENERATE_OUTPUT_CODE)
          }
          continue
        }
        const toolCalls = message.content.filter(block => block.type === 'tool-call')
        // A text-only completion that leaves unfinished todos is a premature
        // wrap-up (common right after compaction): abandon the text so it never
        // pollutes the log, surface a notice as user input, and let the model
        // continue or explicitly mark the todos completed.
        if (toolCalls.length === 0
          && finish.kind !== 'max-tokens'
          && this.lastTodoWrite !== null
          && this.lastTodoWrite.todos.length > 0) {
          if (this.todoGuardCount >= TODO_GUARD_LIMIT) {
            // Guard budget exhausted: the model keeps completing text-only
            // while todos remain. Letting it through (the old behavior) merely
            // ends a turn that pins the loop; hard-error as stalled instead.
            this.stall(`agent "${this.id}": ${this.todoGuardCount + 1} consecutive premature plain-text completions while todos remain unfinished — stalled turn (todo guard exhausted)`)
          }
          this.todoGuardCount += 1
          live.abandon()
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: '(System) The session log still contains unfinished todo items. If you were answering the user directly and the reply is complete, explicitly mark those items completed with the todo tool before ending; otherwise keep executing the unfinished todos instead of ending the turn early.',
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
          continue
        }
        // A text-only reply that repeats the same paragraph many times is a
        // degenerate loop (observed in the wild: ~475 repetitions of one
        // sentence with no tool call while the model claims it will "read the
        // usage"). The line-level DEGENERATE_OUTPUT classifier misses this
        // shape because each repetition is a long line, so catch it here:
        // abandon the text, surface an intervention notice telling the model it
        // is looping, and let it regenerate under guidance.
        const repetition = textRepetitionReason(message.content)
        if (toolCalls.length === 0
          && finish.kind !== 'max-tokens'
          && repetition !== undefined) {
          if (this.repetitionGuardCount >= REPETITION_GUARD_LIMIT) {
            this.stall(`agent "${this.id}": ${this.repetitionGuardCount + 1} consecutive plain-text completions repeating "${repetition.fragment}" with no tool call — stalled turn (repetition guard exhausted)`)
          }
          this.repetitionGuardCount += 1
          live.abandon()
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: this.directedRecoveryNotice(`repeated "${repetition.fragment}" ${repetition.count} times with no tool call`),
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
          continue
        }
        // A step that re-issues an identical tool call that already failed is
        // the structured shape of a retry loop: the model re-runs the same
        // action instead of diagnosing why it failed. The text-level guards
        // cannot see this — each call is fresh prose — so compare the actual
        // arguments against the session's completed calls and intervene before
        // execution, citing the concrete failure so the model has a real
        // anchor to break the loop.
        const repeat = await (async () => {
          if (toolCalls.length === 0 || finish.kind === 'max-tokens') return undefined
          for (const block of toolCalls) {
            let args: unknown
            try {
              args = JSON.parse(block.arguments)
            } catch {
              continue
            }
            const prior = this.actionRegistry.findFailedRepeat(block.name, args)
            if (prior !== undefined) {
              // A remedy-driven re-run is not a repeat: a failure whose target
              // was subsequently re-observed (the documented fix for
              // FS_NOT_OBSERVED / FS_STALE_VERSION) legitimately re-issues the
              // identical call against a fresh guard basis. Consult the fs
              // observation registry before intercepting.
              const remedied = await this.isObservationRemedied(prior, args)
              if (!remedied) return { name: block.name, prior, kind: 'failed' as const }
              // Remedied — fall through to the stalled check so a genuinely
              // stuck identical-outcome streak is still caught.
            }
            // Zero-progress detection: the same call has already succeeded
            // byte-identically several times (same normalized args, identical
            // outcome) — re-running it makes no net progress. The outcome
            // comparison keeps this safe: only identical results count as a
            // streak, so a verification loop that reads changing files is not
            // intercepted.
            const stalled = this.actionRegistry.findStalledRepeat(block.name, args)
            if (stalled !== undefined) return { name: block.name, prior: stalled, kind: 'stalled' as const }
          }
          return undefined
        })()
        if (repeat !== undefined) {
          if (this.actionRepeatGuardCount >= ACTION_REPEAT_GUARD_LIMIT) {
            this.stall(`agent "${this.id}": ${this.actionRepeatGuardCount + 1} consecutive repeated tool calls (\`${repeat.name}\`) with no progress — stalled turn (action-repeat guard exhausted)`)
          }
          this.actionRepeatGuardCount += 1
          live.abandon()
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: repeat.kind === 'failed'
                ? `(System) You already ran \`${repeat.name}\` with identical arguments (step ${repeat.prior.step}); it failed: ${repeat.prior.outcome}. Re-running the identical call repeats a failed action. Diagnose why it failed (${repeat.prior.outcome}) and either fix the underlying issue or take a different action — do not re-run it unchanged.`
                : `(System) You already ran \`${repeat.name}\` with identical arguments at least ${STALL_MIN_STREAK} times (step ${repeat.prior.step}) and every call returned the identical result: ${repeat.prior.outcome}. Re-running it unchanged makes no net progress. Stop re-running this call; take a different action or answer the user directly.`,
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
          continue
        }
        // A clean settle decays (not resets) the guard counters: one good step
        // must not erase a long bad history, or an oscillation (bad, good, bad,
        // bad, …) would keep re-arming free passes forever. Decay by one so a
        // single recovery extends the runway without resetting it. Settling is
        // also durable progress for the stall clock.
        this.todoGuardCount = Math.max(0, this.todoGuardCount - 1)
        this.repetitionGuardCount = Math.max(0, this.repetitionGuardCount - 1)
        this.actionRepeatGuardCount = Math.max(0, this.actionRepeatGuardCount - 1)
        this.lastMeaningfulAt = Date.now()
        live.settle(
          'assistant/message',
          () => this.session.append('assistant/message', {
            turn,
            step,
            message,
            ...live.usage === undefined ? {} : { usage: live.usage },
            stream: live.stream,
          }, { surfaceOp: 'append' }).seq,
        )
        if (finish.kind === 'max-tokens') return { kind: 'max-tokens' }
        if (toolCalls.length === 0) return { kind: 'completed' }
        const { concluded } = await executeToolCalls(
          this.loopCtx, turn, step, toolCalls, signal,
          context => this.inbox.splice('next-step', this.inbox.nextStep.length, 0, [context]),
        )
        return concluded ? { kind: 'completed' } : null
      } catch (error: unknown) {
        if (!live.ended) live.abandon()
        throw error
      }
    }
  }

  /** Resolve request config and bind its adapter before admitting model-visible input. */
  private async prepareRequest(
    turn: number,
    step: number,
    signal: AbortSignal,
  ): Promise<{ config: LlmCallConfig; preparedCall?: PreparedLlmCall }> {
    const { session } = this

    // A loop instance starts from its declared route, restoring only an explicit
    // effort owned by that exact model. Later steps re-resolve marked defaults.
    const persistedHeader = session.requestHeader()
    const persistedConfig = persistedHeader?.config
    const route = { provider: this.options.provider ?? '', model: this.options.model ?? '' }
    const persistedReasoningEffort = persistedConfig?.provider === route.provider
      && persistedConfig.model === route.model
      && persistedHeader?.adapterDefaults?.reasoningEffort !== true
      ? persistedConfig.reasoningEffort
      : undefined
    const reasoningEffort = this.options.reasoningEffort ?? persistedReasoningEffort
    const maxTokens = this.options.maxTokens
    const seedConfig = deepFreeze(structuredClone(
      this.requestHeaderLogged
        // oxlint-disable-next-line typescript/no-non-null-assertion -- the instance logged the header it now folds
        ? requestProposal(persistedHeader!)
        : {
          ...route,
          ...reasoningEffort === undefined ? {} : { reasoningEffort },
          ...maxTokens === undefined ? {} : { maxTokens },
        },
    ))
    const proposedConfig = await this.dispatch.waterfall(
      'agent/request', { turn, step, signal },
      () => Promise.resolve(seedConfig),
    )
    signal.throwIfAborted()
    if (!proposedConfig.provider || !proposedConfig.model) {
      throw new Error(`agent "${this.id}" has no provider/model: set AgentOptions.provider and AgentOptions.model or supply both via the agent/request waterfall`)
    }
    let config: LlmCallConfig
    let preparedCall: PreparedLlmCall | undefined
    try {
      preparedCall = await this.loopCtx.llm.prepareCall(proposedConfig, signal)
      config = preparedCall.config
    } catch (error: unknown) {
      // Middleware may serve an unregistered route; terminal dispatch still requires an adapter.
      if (!(error instanceof LlmError) || error.code !== 'NO_ADAPTER') throw error
      config = proposedConfig
    }
    signal.throwIfAborted()
    return { config, ...preparedCall === undefined ? {} : { preparedCall } }
  }

  /** Log the resolved envelope and derive a frozen request from the admitted surface. */
  private buildRequest(
    config: LlmCallConfig,
    preparedCall: PreparedLlmCall | undefined,
    tools: GenerateOptions['tools'] & object,
    position: { turn: number; step: number },
    startsRequestSeries: boolean,
    signal: AbortSignal,
  ): GenerateOptions {
    const { session } = this
    const surfaceGeneration = session.surface.contentGeneration
    const header = canonicalHeader({
      config,
      ...preparedCall === undefined ? {} : { adapterDefaults: preparedCall.adapterDefaults },
      ...tools.length > 0 ? { tools } : {},
    })
    const baseline = this.session.requestHeader()
    const startsSeries = startsRequestSeries
      || this.requestSurfaceGeneration !== surfaceGeneration
    let headerSeq: SessionSeq | undefined
    if (!this.requestHeaderLogged) {
      // Compaction during the first resumed pre-step must still mark a new series.
      headerSeq = this.session.append('request/header', {
        header,
        reason: baseline === undefined ? 'initial' : 'resume',
        ...startsSeries ? { startsSeries: true } : {},
      }).seq
      this.requestHeaderLogged = true
    } else if (baseline === undefined || !headerEquals(baseline, header)) {
      headerSeq = this.session.append('request/header', {
        header,
        reason: 'change',
        ...startsSeries ? { startsSeries: true } : {},
      }).seq
    } else if (startsSeries) {
      this.session.append('request/header', { header, reason: 'series' })
    }
    if (baseline !== undefined && headerSeq !== undefined) {
      const previousNames = new Set(baseline.tools?.map(tool => tool.name))
      const currentNames = new Set(tools.map(tool => tool.name))
      const additions = tools.filter(tool => !previousNames.has(tool.name))
        .map(tool => ({ type: 'tool-addition' as const, toolName: tool.name }))
      const removals = (baseline.tools ?? []).filter(tool => !currentNames.has(tool.name))
        .map(tool => ({ type: 'tool-removal' as const, toolName: tool.name }))
      if (additions.length > 0 || removals.length > 0) {
        session.append('developer/message', {
          ...position,
          message: createDeveloperMessage({ source: { kind: 'tool-registry' }, content: [...additions, ...removals] }),
          ...additions.length > 0 ? { headerSeq } : {},
        }, { surfaceOp: 'append' })
      }
    }
    this.requestSurfaceGeneration = surfaceGeneration

    const contextWindow = preparedCall?.context?.contextWindow
    const systemPromptUpdate = preparedCall?.systemPromptUpdate
    const requestContext: RequestContext = {
      provider: config.provider,
      model: config.model,
      ...contextWindow === undefined ? {} : { contextWindow },
      ...systemPromptUpdate === undefined ? {} : { systemPromptUpdate },
    }
    const previousContext = session.requestContext()
    if (previousContext?.provider !== requestContext.provider
      || previousContext.model !== requestContext.model
      || previousContext.contextWindow !== requestContext.contextWindow
      || previousContext.systemPromptUpdate !== requestContext.systemPromptUpdate) {
      session.append('request/context', requestContext)
    }
    signal.throwIfAborted()

    // canonicalHeader is shallow; append logs a detached snapshot, not these local values.
    deepFreeze(header)
    const boundaryMessages = session.deriveMessages()
    for (const message of boundaryMessages) {
      if (this.frozenMessages.has(message)) continue
      deepFreeze(message)
      this.frozenMessages.add(message)
    }
    Object.freeze(boundaryMessages)
    const request = markAgentLoopRequest(Object.freeze({
      ...header.config,
      messages: boundaryMessages,
      toolHistory: session.toolHistory(),
      ...header.tools !== undefined ? { tools: header.tools } : {},
      sessionId: this.session.id,
      signal,
    }))
    return request
  }
}
