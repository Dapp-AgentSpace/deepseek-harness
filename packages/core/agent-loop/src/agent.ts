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
import { assertNever, deepFreeze } from '@deepseek-ai/dsh-util-values'
import type { Scope } from '@deepseek-ai/dsh-scope'
import { createScope } from '@deepseek-ai/dsh-scope'
import type { EpochHeader, RequestContext, Session, SessionEvent, SessionId, SessionSeq, TurnEndReason, UserMessage } from '@deepseek-ai/dsh-session'
import { canonicalHeader, headerEquals, ToolCallRecovery } from '@deepseek-ai/dsh-session'
import { joinContextSections, renderContextSections, renderPrompt } from '@deepseek-ai/dsh-system-prompt'
import type { PromptAssembly } from '@deepseek-ai/dsh-system-prompt'
import type {} from '@deepseek-ai/dsh-session-projection'
import type { Context } from '@deepseek-ai/cordis'
import { ReactLoopInbox } from './inbox.ts'
import { RuntimeContextProjection } from './runtime-context.ts'
import { AssistantStreamAttempt } from './assistant-stream.ts'
import { degenerateOutputReason } from './degenerate.ts'
import { SystemPromptProjection } from './runtime-context.ts'
import { executeToolCalls } from './tool-calls.ts'

/**
 * Self-monitoring knobs for main-session turns. The loop resists premature
 * plain-text completion while todos remain unfinished, reviews automatic
 * compaction recovery points, and reports progress for long turns.
 */

/** How many consecutive premature completions the todo guard may interrupt before deferring. */
const TODO_GUARD_LIMIT = 2
/** First progress heartbeat delay (ms) after a turn starts. */
const PROGRESS_FIRST_MS = 30_000
/** Progress heartbeat interval (ms) after the first has fired. */
const PROGRESS_INTERVAL_MS = 60_000
/** Model-visible source shared by guard, compaction-review and progress notices. */
const AGENT_LOOP_NOTICE_SOURCE = { kind: 'agent-loop-progress', form: 'notice' } as const
/**
 * How many consecutive plain-text completions that repeat the same fragment
 * the repetition guard may interrupt before deferring. Mirrors TODO_GUARD_LIMIT:
 * two interruptions give the model a chance to recover under guidance; a third
 * identical non-progress text is then let through so the loop cannot pin forever.
 */
const REPETITION_GUARD_LIMIT = 2
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
    this.systemPrompt = new SystemPromptProjection(session)
    this.observeLoopState(session)
  }

  /**
   * Follow plugin-merged `todo/write` and `compaction/*` events so the loop can
   * resist premature completion and review compaction recovery points. Both
   * event kinds are SessionEventMap extensions that may not be visible at this
   * compile site, so they are read through a structural view rather than the
   * closed SessionEvent union.
   */
  private observeLoopState(session: Session): void {
    const view = (event: SessionEvent): { type: string; seq: SessionSeq; data: { todos?: unknown } } =>
      event as unknown as { type: string; seq: SessionSeq; data: { todos?: unknown } }
    this.ctx.on('session/event', (subject, event) => {
      if (subject !== session) return
      const observed = view(event)
      if (observed.type === 'todo/write') {
        this.lastTodoWrite = { seq: observed.seq, todos: unfinishedTodos(observed.data.todos) }
      } else if (observed.type === 'compaction/summary' || observed.type === 'compaction/end') {
        this.compactionPending = true
      }
    })
    // Seed from the most recent todo/write so a resumed loop still guards.
    // oxlint-disable-next-line typescript/no-deprecated -- Existing Session history read; migration deferred.
    const events = session.snapshotEvents()
    for (let index = events.length - 1; index >= 0; index -= 1) {
      const event = events[index]
      if (event === undefined) continue
      const observed = view(event)
      if (observed.type === 'todo/write') {
        this.lastTodoWrite = { seq: observed.seq, todos: unfinishedTodos(observed.data.todos) }
        break
      }
    }
  }

  get status(): AgentStatus {
    return this.phase.kind === 'idle' || this.phase.kind === 'maintenance' ? 'idle' : 'running'
  }

  /** Commit a phase and publish its externally visible status transition. */
  private setPhase(next: Phase): void {
    const previousStatus = this.status
    this.phase = next
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

  async whenIdle(): Promise<void> {
    let activity: Promise<void>
    do {
      await (activity = this.activityDone)
    } while (activity !== this.activityDone)
  }

  /** Report one failure at its live boundary, then preserve it for driver containment. */
  private throwError(error: unknown): never {
    const turn = this.phase.kind === 'running' ? this.phase.turn : this.phase.lastTurn
    const step = this.phase.kind === 'running' ? this.phase.step : 0
    this.dispatch.emit('agent/error', { turn, step, error })
    throw error
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
    const decision = await this.dispatch.waterfall(
      'agent/pre-step', { messages: claimed, ...position, signal },
      (): Promise<PreStepDecision> => Promise.resolve<PreStepDecision>({
        kind: 'enter',
        messages: context === undefined ? claimed : [...claimed, context],
      }),
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
      // An automatic compaction during the preceding pre-step (or a recovered
      // context overflow inside this step's request-error waterfall) leaves a
      // recovery point: inject a review notice before the next model call so
      // the model re-grounds on the summary instead of ending prematurely.
      if (this.compactionPending) {
        this.compactionPending = false
        this.session.append('user/message', createUserMessage({
          content: [{
            type: 'text',
            text: '(System) The context was just automatically compacted. Cross-check the compaction summary for unfinished work and todo items and continue executing; explicitly mark completed items and do not end the turn early based on the summary alone.',
          }],
          source: AGENT_LOOP_NOTICE_SOURCE,
        }), { surfaceOp: 'append' })
      }
      const { config, preparedCall } = await this.prepareRequest(turn, step, signal)
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
      if (firstAttempt) {
        for (const message of decision.messages) {
          this.session.append('user/message', message, { surfaceOp: 'append' })
        }
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
      try {
        const stream = preparedCall?.stream(request) ?? this.loopCtx.llm.stream(request)
        signal.throwIfAborted()
        live.start()
        started = true
        for await (const chunk of stream) {
          signal.throwIfAborted()
          live.push(chunk)
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
              text: '(System) Your previous output was classified as degenerate (repeated fragments with no progress). Regenerate it as concise, forward-moving text: no repetition, no filler — either call a tool or give the final answer directly.',
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
          && this.lastTodoWrite.todos.length > 0
          && this.todoGuardCount < TODO_GUARD_LIMIT) {
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
          && repetition !== undefined
          && this.repetitionGuardCount < REPETITION_GUARD_LIMIT) {
          this.repetitionGuardCount += 1
          live.abandon()
          this.session.append('user/message', createUserMessage({
            content: [{
              type: 'text',
              text: `(System) Your last message repeated "${repetition.fragment}" ${repetition.count} times with no tool call — a degenerate loop. Stop repeating the same sentence: either call a tool to make concrete progress, or finish your turn with a concise final answer.`,
            }],
            source: AGENT_LOOP_NOTICE_SOURCE,
          }), { surfaceOp: 'append' })
          continue
        }
        this.todoGuardCount = 0
        this.repetitionGuardCount = 0
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
