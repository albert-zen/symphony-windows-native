# Manager agent runbook

This runbook describes the orchestration layer for the Symphony optimization
flywheel. It is written for a manager agent running the loop on Windows or on a
fresh machine where the operator needs to understand the expected rhythm before
touching the queue.

The manager agent is not primarily an implementer. Its job is to keep the
flywheel honest: shape the next work, keep parallel workers fed, review finished
work against the original intent, investigate blockers to root cause, and turn
system defects into durable issues.

## Operating posture

- Treat `Backlog` as parked work. Symphony claims `Todo` and active work, not
  Backlog.
- Move work forward only after the public GitHub issue has a clear spec,
  testing intent, and acceptance criteria.
- Prefer orchestration over hand repair. If a worker can finish the issue after
  clearer instructions or a fixed system capability, send it back through the
  flywheel.
- Hand-edit production code only for urgent privacy, deployment, or orchestration
  defects where waiting for a worker would increase risk.
- Review is intent-based. Passing tests and green CI are required evidence, but
  they do not prove the human request was satisfied.
- Worker completion is a manager handoff, not a done state. A PR that reaches
  review still needs manager review, state cleanup, and sometimes deployment.
- Keep the system saturated, not chaotic. Raise concurrency only after claim
  behavior, review readiness, and CI signal are trustworthy.
- Treat repeated pipeline friction as a product defect in the flywheel, not as a
  worker performance problem. If multiple workers are debugging the same CI,
  auth, rate-limit, deployment, or queue-control failure, stop feeding that wall
  and fix the shared path.

## Manager-owned work

Some issues should stay with the manager instead of being released to an
ordinary worker. Keep work manager-owned when success depends on global context
across the live dashboard, GitHub, Linear, previous operator intent, or recent
flywheel incidents.

Examples:

- Choosing the canonical issue for a repeated system defect, marking duplicates,
  or defining defect intake policy.
- Deciding whether a dependency chain is resolved enough to release downstream
  work to `Todo`.
- Applying privacy-sensitive history cleanup or deployment/restart changes.
- Root-causing why active work is `Blocked`, stale, duplicated, or running on
  old code.
- Changing manager automation, concurrency policy, release criteria, or review
  policy.

Workers are a good fit for bounded implementation tasks with a complete public
spec, test intent, acceptance criteria, and no need to decide cross-system
policy. If a manager-owned issue can be decomposed, create narrower worker-safe
subtasks and keep the policy decision in the manager Workpad.

## Worker blocker handoff

Workers should not burn long sessions rediscovering orchestration failures. When
a worker hits a blocker it cannot resolve within its issue scope, the desired
handoff is:

1. Update the single `## Codex Workpad` with the exact failure, command or
   subsystem, affected PR/check/log, local recovery attempted, and the next
   operator action needed.
   For environment or pipeline blockers, the Workpad should also include
   capability/preflight evidence from
   `mix symphony.preflight.windows --capabilities-only --json <WORKFLOW>` or a
   manager-approved equivalent. The minimum fields are failed command,
   capability result, local recovery attempted, and manager action needed.
2. Add a short Linear comment only when the Workpad is not enough to make the
   blocker visible to a manager scanning the board.
3. Move the issue to `Blocked` when that state exists, then release any durable
   claim so another worker does not immediately reclaim it.
4. Do not repeatedly retry a failing shared gate unless the Workpad records new
   evidence that the root cause changed.

The manager owns the next step after this handoff. The manager should classify
the blocker, find or create the canonical system issue, and decide whether to
deploy a fix, add a narrow worker-safe follow-up, or return the original issue
to `Backlog` until the road is clear.

Good blocker reports are small and concrete. They name the failed command or
API, include the PR/check URL when available, distinguish local pass from CI
failure, and say whether the current worker can continue after an operator
action. Vague reports such as "GitHub failed" or "CI flaky" are not enough.
Reports for shared environment friction should cite the relevant capability
result, such as missing `tasklist`, unauthenticated `gh`, unavailable Linear
viewer probe, risky `core.autocrlf`, CRLF formatter inputs, or coverage policy
evidence.

## Main loop

Run this loop until the operator deliberately pauses the flywheel.

1. Inspect the live system.
   - Check the dashboard for active workers, queue depth, token pressure, retry
     noise, and rate-limit status.
   - Check GitHub PRs, checks, mergeability, and recently changed issues.
   - Check Linear state across `Backlog`, `Todo`, `In Progress`, `In Review`,
     `Blocked`, and terminal states.
   - Check runtime logs, PID files, workflow config, and the deployed commit
     when the runtime may be stale.
2. Review completed work first.
   - Read the original human request, the GitHub issue, the Linear Workpad, the
     PR diff, CI results, and review evidence.
   - Request independent SubAgent review for meaningful changes before handoff.
   - Merge only when the implementation satisfies intent and required checks are
     green, or return the issue to active work with concrete findings.
3. Investigate blockers immediately.
   - A blocked issue needs a root cause, not just a label.
   - Classify the blocker as worker implementation, stale base, failing CI,
     missing config, connector/API failure, credentials, runtime deployment, or
     duplicate/canonical issue confusion.
   - If several workers hit the same class of blocker, pause release of related
     work and solve the shared system defect before increasing concurrency.
   - Record the exact failure and next operator action in the Workpad.
   - Create or update one canonical GitHub issue labeled
     `symphony-optimization`, plus a Linear mirror, for system defects.
4. Feed the next work.
   - Choose the next Backlog issue after completed work is reviewed and blockers
     are root-caused, owned, or confirmed not to affect available capacity.
   - Classify whether the issue is worker-safe or manager-owned before moving
     it. Do not release manager-owned work merely to fill a concurrency slot.
   - Complete the GitHub issue spec, testing intent, and acceptance criteria.
   - Add links between GitHub and Linear.
   - Move it to `Todo` only when there is available capacity and the task is
     ready for an isolated worker.
5. Wait deliberately.
   - Worker runs commonly take 10 to 20 minutes.
   - During long waits, use a heartbeat automation or a local sleep interval,
     then re-enter the loop from inspection.
   - Do not interrupt active workers unless the task is unsafe, clearly obsolete,
     or consuming credentials/tokens incorrectly.

## Review checklist

Use this checklist before accepting a PR:

- The PR implements the linked GitHub issue and does not quietly broaden scope.
- The final behavior satisfies the original human intent.
- The branch is current enough for the touched files and has no stale-base
  overlap.
- The PR body preserves the repository template headings and records concrete
  validation.
- Required checks passed; pending, failing, or missing checks are explained and
  resolved before review state.
- Windows-specific behavior was validated when paths, shells, workflow config,
  workspace cleanup, or runtime orchestration changed.
- Coverage, lint, formatter, CI, review-readiness, and PR-body gates were not
  weakened.
- SubAgent review was requested for meaningful changes and blocking findings
  were resolved.
- Follow-up defects are filed as GitHub issues with Linear mirrors when they
  describe system behavior beyond the active PR.

When a PR fails this checklist, leave a specific GitHub PR review comment and
update the Linear Workpad with the review outcome before moving the issue back
to active work. Do not leave it in `In Review` just because a branch exists.

## Blocker investigation

Blocked work is manager-owned until the root cause is understood.

Start with the latest `## Codex Workpad`, then inspect the PR, CI logs, worker
logs, dashboard state, and runtime logs. Ask these questions:

- Did the worker finish but fail a quality gate?
- Is the branch dirty or behind the current base?
- Did review readiness fail because the runtime is missing repository, token, or
  state configuration?
- Did Linear/GitHub connector lookup fail while direct API access would work?
- Is the failure caused by CI running on a different OS than the local worker,
  such as Windows-only commands executed on Ubuntu?
- Is a merged system fix still absent from the running runtime?
- Did the issue duplicate a known canonical defect?
- Did the runtime run old code after a system fix was merged?

If the blocker is a system defect, file or update one canonical GitHub issue
labeled `symphony-optimization` and mirror it into Linear. If a canonical issue
already exists, comment there with new evidence instead of creating another
issue. Mark duplicates explicitly and link them back to the canonical issue.

## Duplicate issue discipline

Before creating a new system issue:

1. Search open and recently closed GitHub issues with the
   `symphony-optimization` label.
2. Search the Linear project for similar titles, GitHub links, and blocker text.
3. If a canonical issue exists, add a comment with the new evidence and link the
   affected PR, Workpad, or log excerpt.
4. If no canonical issue exists, create a GitHub issue labeled
   `symphony-optimization` with spec, testing intent, and acceptance criteria,
   then create the Linear mirror.
5. Move redundant Linear mirrors to `Duplicate` when that state exists, and close
   redundant GitHub issues as duplicates.

This keeps the flywheel from manufacturing review debt while it is trying to fix
itself.

## Releasing work to Todo

Backlog issues are not ready by default. Before moving an issue to `Todo`, the
manager should ensure the public GitHub issue includes:

- Problem statement and user-facing intent.
- Scope boundaries and explicit non-goals.
- Dependencies, unresolved blockers, and the exact unblock condition.
- Implementation hints only when they reduce ambiguity without over-prescribing
  the solution.
- Testing intent: focused local checks, broad gates, and Windows-specific checks
  when relevant.
- Acceptance criteria that a reviewer can verify from the final behavior.
- Links to related issues, PRs, prior failures, and Linear mirror.

Use a `## Dependencies` section or an explicit `Depends on:` line in the GitHub
issue when the work must wait for another issue, PR, deployment, credential, or
system capability. Do not move that issue to `Todo` while the dependency is
active, unmerged, blocked, or merged-but-not-deployed when deployment matters.
After the dependency is resolved, mark it with `[x]`, `resolved by`, `merged in`,
or `deployed in`, then record the dependency resolution in the Workpad when
releasing the issue.

Before release, run the local dry-run guard against the shaped GitHub issue text
or an exported copy of it:

```powershell
cd elixir
mise exec -- mix symphony.manager.release_check --file ..\issue-body.md
```

The guard intentionally fails on unresolved dependency declarations. It is not a
substitute for manager judgment across Dashboard, GitHub, and Linear; it is a
tripwire that prevents known dependency chains from being released as if they
were independent work.

After the worker claims the issue, avoid changing the task underneath it. If the
intent changes, update the GitHub issue and Workpad, then decide whether to let
the current worker continue or return the issue to `Todo`.

## Saturation and waiting

The manager should keep enough ready work in motion for the configured
concurrency, while preserving review quality.

- Start with low concurrency on a new deployment.
- Increase concurrency after the runtime proves it can claim, run, report, and
  hand off reliably.
- Keep a small prepared Backlog so the next issue can move to `Todo` quickly
  after a review or merge.
- Prefer reviewing finished work over launching new work.
- During quiet periods, wait 5 to 10 minutes and inspect again.

Useful local wait command:

```powershell
Start-Sleep -Seconds 600
```

For longer unattended stretches, create a heartbeat automation attached to the
current thread that wakes the manager and resumes inspection. Use automation for
continuity, not as a substitute for recording blockers and review outcomes.

## Deployment responsibility

System-level changes are not complete when merged. After major orchestration,
runtime, workflow, credential, review-readiness, or concurrency changes land:

1. Prefer the dashboard `Runtime deploy` panel or
   `POST /api/v1/runtime/reload` when the runtime has no active workers and the
   checkout is clean. Managed reload requires an operator token even on
   loopback.
2. Confirm the managed reload fetched `origin/main`, rebuilt the escript,
   restarted with the same workflow, port, logs root, and PID file, and verified
   the running commit through `/api/v1/state`. If it fails, inspect the reload
   status and log for rollback evidence before attempting another reload.
3. If the managed reload is unavailable, fall back to the manual path: fetch the
   latest canonical `origin/main`, rebuild from `elixir/`, stop the old process,
   start with the intended workflow file, and verify the dashboard responds.
4. Verify sensitive settings are redacted and not committed.
5. Update Linear and GitHub with deployment evidence.

Only then should the manager consider the system fix operational.

## Portable startup checklist

On a new machine or fresh deployment, confirm:

- Repository checkout points at the Windows-native `origin/main`.
- Runtime directory and workflow file paths match the local machine.
- GitHub CLI is installed and authenticated.
- Linear access works through the connector or `LINEAR_API_KEY`.
- The Linear project has the expected active, review, blocked, duplicate, and
  terminal states.
- The workflow config sets the intended concurrency and worker reasoning effort.
- Dashboard URL, PID files, logs, and workspace root are known.
- `Backlog` remains parked and `Todo` is the release valve.
- The manager has a plan for review, blockers, deployment, and waiting before
  launching many workers.

The flywheel succeeds when every environment can recover the same rhythm:
inspect, review, root-cause, feed, wait, and deploy verified system changes.
