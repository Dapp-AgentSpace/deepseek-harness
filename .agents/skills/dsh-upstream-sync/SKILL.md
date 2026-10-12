---
name: dsh-upstream-sync
description: Use when merging upstream deepseek-ai/deepseek-harness master (or any upstream release branch) into this Dapp-AgentSpace fork, syncing upstream capabilities while preserving this fork's custom optimizations. Covers regular upstream sync, per-merge duplicate-optimization analysis (has upstream already built the same feature?), conflict resolution, and the merge-correctness gate suite. Requires owner authorization before any merge or commit.
---

# DSH Upstream Sync

Regularly fold upstream `deepseek-ai/deepseek-harness` capabilities into this fork
**without losing this fork's custom optimizations**. This skill is the execution
manual for the strategy in [upstream-sync-strategy.md](../../../.harness/reports/upstream-sync-strategy.md);
read that document for the full analysis (topology, branch model, decision matrices)
before starting a sync.

## Hard constraints (non-negotiable)

1. **Custom optimizations are never lost.** Every sync must snapshot the custom-asset
   manifest before merging and verify each asset still exists and still binds after merging.
2. **Capabilities never regress.** Typecheck, lint, unit tests, and the documented gate
   modes must be at least as green after the merge as before it.
3. **Every changed commit carries its supporting tests; after merging upstream, run the
   full test suite.** A merge that changes behavior without accompanying tests is a failed merge.
4. **Merge correctness is validated by the complete gate suite** — not by judgment.

Never `git commit` or `git push` without owner authorization (repository rule,
see AGENTS.md). This skill plans, rehearses, merges into a working branch, and
validates; committing/landing is the owner's call.

## Inspect the current state first

```sh
git status --short --branch
git rev-parse --show-toplevel
git remote -v
git log -1 --oneline
```

Require a clean worktree before starting. Record the current `HEAD`, the fork
`origin/master`, and whether an `upstream` remote exists. If no `upstream` remote:

```sh
git remote add upstream https://github.com/deepseek-ai/deepseek-harness.git
git fetch upstream
```

Never modify the `upstream/*` remote-tracking refs directly; they are a read-only
mirror of the official repo.

## 1. Snapshot the custom-asset manifest (定制功能不丢)

Before touching any merge, record proof that every custom optimization exists. The
executable gate is [verify-upstream-assets.sh](../../../scripts/verify-upstream-assets.sh) —
run it on the pre-merge `HEAD` and record the result:

```sh
bash scripts/verify-upstream-assets.sh HEAD
```

It greps every registered asset (below) and exits `1` (red) when any is missing. Any
`MISS` **before** the merge is a pre-existing problem to resolve first — never start a
merge with a missing asset. The registered assets:

| Asset | Proof of existence (in the script) |
|---|---|
| `wait_settlement` model-visible tool | `packages/subagent/tool-subagent-control/src/wait-settlement.ts` |
| `ctx.subagents.waitSettlement()` service API | `git grep waitSettlement packages/subagent/subagent/src` |
| `SubagentWaitOutcome` type | `packages/subagent/subagent/src` |
| agent-loop hardening (STALL/STREAMING limits, progress notices, repetition guard) | `git grep STALL_HARD_LIMIT_MS\|STREAMING_HARD_LIMIT_MS\|PROGRESS_INTERVAL_MS\|REPETITION_GUARD packages/core/agent-loop/src/agent.ts` |
| typecheck signature fix (`whenIdle` union return, required `lastActivityAt`) | `git grep whenIdle\|lastActivityAt packages/core/agent/src/runtime-types.ts` |

When new custom work lands, register it in the script **and** this table so future
syncs prove it too.

Also record the pre-merge gate baseline:

```sh
git log -1 --format='%H %s'                          # pre-merge HEAD
pnpm --silent run change-scope --base <current-head> # pre-merge scope (empty)
```

## 2. Rehearse the merge before executing (merge-tree, zero-write)

Always rehearse with `git merge-tree --write-tree` before a real merge. It computes
the merge in memory, reports conflicts, and writes nothing:

```sh
git merge-tree --write-tree --messages HEAD upstream/master
```

Exit `1` means conflicts; the message lists conflict paths and any `CONFLICT`
markers. A successful merge prints the resulting tree id. Record the conflict list
in the sync report. **Never run a real `git merge` before this rehearsal.**

## 3. Duplicate-optimization analysis (has upstream already built it?)

For each custom asset, decide whether upstream now implements an equivalent. This
answers "if official built the same optimization, whose is better" — see
[upstream-sync-strategy.md §5](../../../.harness/reports/upstream-sync-strategy.md).

```sh
# a) Symbol scan on upstream (empty = upstream lacks the feature)
git grep -n 'waitSettlement' upstream/master -- packages/subagent/ || echo 'NOT FOUND upstream'

# b) Commit-topic scan
git log upstream/master --oneline --grep='settle\|continuation\|progress\|stall' | head -30

# c) Upstream refactors: files upstream added (A) or deleted (D)
git log --diff-filter=A upstream/master -- packages/subagent/
git log --diff-filter=D upstream/master -- packages/subagent/
```

Decide per asset (decision matrix in the strategy doc §5.3):

- **Upstream has no equivalent** → keep ours; verify our API mount points survive the
  upstream refactor (custom assets often attach to upstream-rebuilt surfaces).
- **Upstream has an equivalent and is clearly better** (coverage + robustness +
  design, weighted heavily by maintenance cost of keeping a fork-local copy) →
  drop ours, adopt upstream, migrate our tests to the upstream API.
- **Ours is clearly better on ≥2 high-weight dimensions** → keep ours **and** open an
  upstream PR contributing it; when upstream merges it, ours dies naturally.
- **Complementary** → adopt upstream's skeleton, port our incremental layer on top.

Record the decision per asset in the sync report. Never silently drop a custom asset.

## 4. Merge upstream (owner-authorized, batched)

Only after rehearsal + duplicate analysis pass, and with owner authorization, perform
the merge. Prefer merging in small batches (one logical area at a time) over one
giant merge so each conflict is attributable.

```sh
git merge upstream/master     # on a working branch, not upstream/* refs
```

For each conflict, classify it (strategy doc §2.4):

- **Upstream functional evolution** → take upstream, re-apply our adapter on top.
- **Both sides, different areas** → manual merge keeping both.
- **Upstream now equivalent** → drop ours, adopt upstream (per §3 decision).
- **Our asset's mount point refactored upstream** → port/re-attach ours to the new structure.

Resolve with `git checkout --ours/--theirs` for one-sided files; hand-edit files both
sides changed, then `git add`. Never use a global `-X theirs`/`-X ours` strategy.

## 5. Supporting tests for every change (每次改动的提交要有配套测试)

Every commit that changes behavior must include (or pair with) tests that would fail
for its regression. After each resolved conflict and before committing each change:

- Identify the owning Vitest file for each modified behavior.
- Add/extend the test that proves the new merged behavior (or our re-applied adapter).
- Run the owning test file — not a partial subset that hides the failure.

```sh
pnpm exec vitest run packages/<group>/<package>/tests/<behavior>.spec.ts
```

A merged change with no test for its behavior is a failed merge. This rule applies to
both upstream-adopted changes and our re-applied adapters.

## 6. Merge-correctness gate suite (完整门禁校验合并正确性)

After the merge (and before declaring readiness), run the full gate suite. The
repository's `scripts/run-gates.ts` owns the aggregates; run the complete local
approximation:

```sh
pnpm run check:all        # full suite: tests, build, build:web, hygiene, doc-sync, module-graph
```

`check:all` (package script → `tsx scripts/run-gates.ts check-all`) runs the complete
local gate matrix (`tests` + `build` + hygiene + doc-sync + module-graph). If the user
only asks for a lighter pass or time is tight, `pnpm run hygiene` covers the static
hygiene leaves; but **a sync is not ready without `check:all`** unless the owner
explicitly accepts the lighter evidence.

Then re-verify the custom-asset manifest from §1 — every asset must still be present
and still bind. Run the same executable gate on the merged tree:

```sh
bash scripts/verify-upstream-assets.sh HEAD
```

Any `MISS` after the merge means the sync regressed a custom optimization — stop,
restore or re-port it, re-run its owning tests, and re-run the gate suite.

## 7. Report and hand to owner

Write the sync report to `.harness/reports/upstream-sync-<date>.md` containing:

- Pre-merge `HEAD`, upstream ref merged, rehearsal conflict list.
- Per-asset manifest: pre-merge state → post-merge state (all `FOUND`).
- Per-asset duplicate-optimization decision (upstream equivalent? adopted/dropped/kept).
- Conflicts resolved, with the classification for each.
- Tests added per merged change, and the owning test runs.
- Gate results: `check:all` (and `hygiene` if run) with exit codes; any failures and fixes.
- Remaining owner actions: authorize the merge commit, push, open PR.

Stop here. Do not `git commit` or `git push`; landing is the owner's call.

## Checklist

- [ ] Clean worktree; `upstream` remote exists; upstream ref fetched.
- [ ] Custom-asset manifest snapshotted with all `FOUND` before the merge.
- [ ] `git merge-tree` rehearsal run; conflict list recorded before any real merge.
- [ ] Duplicate-optimization analysis completed per asset; decisions recorded.
- [ ] Merge performed only with owner authorization, in batches, on a working branch.
- [ ] Every merged change carries its owning test; owning test runs passed.
- [ ] `pnpm run check:all` passed after the merge.
- [ ] Custom-asset manifest re-verified after the merge; every asset `FOUND` and binding.
- [ ] Sync report written; owner actions listed; no commit/push performed.
