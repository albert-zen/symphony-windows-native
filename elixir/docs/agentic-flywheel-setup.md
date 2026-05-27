# Agentic flywheel setup and operations

This playbook describes how to set up and operate an agentic build loop using
Linear, GitHub, Symphony, and Codex. It covers project setup, the runtime loop,
manager responsibilities, worker and reviewer handoff, pause and resume, and
how to reuse the pattern on another repository.

Use this pattern when a project has enough repeatable engineering work for
automation, but still needs human product judgment, review, and prioritization.
The canonical state machine and role boundaries live under
[`docs/agents/`](agents/). For the quality discipline that makes the loop safe,
read [agentic-flywheel-quality.md](agentic-flywheel-quality.md).

## Roles

- Linear project: the private operating queue and state machine.
- GitHub issues: the durable public implementation backlog and acceptance
  criteria.
- Worker Symphony: a dispatcher that polls `Ready for Agent` and `Rework`,
  creates isolated workspaces, and starts implementer Codex sessions.
- Reviewer Symphony: a dispatcher that polls `Agent Review` and starts
  reviewer Codex sessions.
- Worker Codex agents: implementers that make scoped changes, validate them,
  open PRs, and leave evidence.
- Reviewer Codex agents: reviewers that do not edit code and instead report
  standards/spec findings and move issues to the next review state.
- Human manager: the upper-level product and quality owner who orders work,
  handles ambiguous tradeoffs, reviews results, and keeps production saturated.
- Codex Worker Note: one append-only Linear comment per worker round that
  records plan, validation, blockers, PR, and handoff evidence.
- Codex Review Note: one append-only Linear comment per review round that
  records standards/spec findings and state decision.

## The loop

1. The manager keeps the GitHub issue backlog healthy.
2. The manager mirrors or routes one small piece of work into the Linear
   flywheel project.
3. Backlog work stays parked in `Backlog`; Symphony does not poll it.
4. The manager moves ready DAG nodes to `Ready for Agent` when they are eligible
   for automation.
5. Worker Symphony claims eligible `Ready for Agent` or `Rework` issues and
   starts a Codex session in a fresh workspace.
6. The agent moves the issue to `In Progress`, creates a new
   `## Codex Worker Note` for that worker round, and implements only the linked issue.
7. The agent pushes a focused branch, opens a PR, records validation and review
   evidence, and waits for required checks.
8. The issue moves to `Agent Review` only after the PR exists and required
   checks pass. Reviewer Symphony then runs an independent standards/spec
   review.
9. Passing review moves the issue to `Human Review`; blocking findings move it
   to `Rework`; missing spec context moves it to `Needs Human Context`.
10. Defects discovered while running the loop become new GitHub issues and, when
   appropriate, Linear mirrors in the flywheel project.

This makes the flywheel self-improving: the system uses normal engineering
artifacts to capture the problems it discovers while building itself.

## Starting a flywheel run

Before starting unattended work, prepare the project:

1. Create or choose a Linear project dedicated to the flywheel.
2. Configure states so parked work is not eligible for polling:
   - `Backlog`: parked, not polled.
   - `Needs Human Context`: missing spec, acceptance criteria, dependency
     state, or decision authority.
   - `Ready for Agent`: eligible for worker Symphony.
   - `In Progress`: active worker implementation.
   - `Blocked`: missing dependency, credentials, environment, or orchestration
     capability.
   - `Agent Review`: PR exists, required checks passed, and reviewer Symphony
     should inspect the result.
   - `Rework`: reviewer found bounded blocking findings for a worker to fix.
   - `Human Review`: reviewer passed the work and human acceptance remains.
   - `Done`, `Canceled`, `Cancelled`, `Duplicate`: terminal states.
3. Keep GitHub issues as the durable implementation specs. Linear descriptions
   can mirror GitHub, but implementation discussion should stay in GitHub when
   it needs to be public or reviewable later.
4. Configure the worker workflow prompt to require append-only `## Codex Worker Note`
   comments, focused branches, validation evidence, PR creation, and no `Agent Review`
   transition while required checks are pending or failing.
5. Configure a reviewer workflow prompt that performs review only and moves
   issues to `Human Review`, `Rework`, `Needs Human Context`, or `Blocked`.
6. On Windows, copy the worker and reviewer workflow examples, edit them for
   the project, and run preflight from `elixir/`:

   ```powershell
   Copy-Item .\WORKFLOW.optimization.windows.example.md .\WORKFLOW.optimization.windows.md
   Copy-Item .\WORKFLOW.optimization.reviewer.windows.example.md .\WORKFLOW.optimization.reviewer.windows.md
   notepad .\WORKFLOW.optimization.windows.md
   notepad .\WORKFLOW.optimization.reviewer.windows.md
   mise exec -- mix symphony.preflight.windows .\WORKFLOW.optimization.windows.md
   mise exec -- mix symphony.preflight.windows .\WORKFLOW.optimization.reviewer.windows.md
   ```

7. Start with `agent.max_concurrent_agents: 1`. Increase concurrency only after
   claim behavior, review readiness, and CI reporting are reliable.
8. Move the next issue from `Backlog` to `Ready for Agent`.
9. Start the worker and reviewer Symphony instances and monitor the dashboards
   and Linear agent notes.

For the Windows-native optimization project, use
[`WORKFLOW.optimization.windows.example.md`](../WORKFLOW.optimization.windows.example.md)
as the worker baseline and
[`WORKFLOW.optimization.reviewer.windows.example.md`](../WORKFLOW.optimization.reviewer.windows.example.md)
as the reviewer baseline. Start both local files together with
`scripts/start-agent-flywheel.ps1` after editing the Linear project slug,
repository URL, workspace roots, and required checks.

The flywheel start script treats the two instances as one startup unit by
default: both worker and reviewer must start, publish PID metadata, and listen
on their configured ports. If reviewer startup fails after the worker is up, the
script stops the worker and prints the failed phase, reason, worker/reviewer log
roots, and cleanup status. Use `-AllowPartial` only for explicit debugging when
you want to keep a successfully started worker while investigating reviewer
startup; the script reports `Partial startup` in that mode.

## Smoke testing a running flywheel

Run a real Linear smoke after workflow, launcher, claim, review-readiness, or
agent note changes. Local unit tests can prove pieces of the runtime, but the
flywheel contract is the Linear state loop plus the two live Symphony instances.

Use a disposable issue in the configured Linear project:

1. Put the issue in `Ready for Agent` with a small, reversible spec that cannot
   affect production work.
2. Start both instances with `scripts/start-agent-flywheel.ps1`, unless they are
   already running on the intended runtime commit.
3. Watch the worker dashboard and Linear. The issue should move
   `Ready for Agent` -> `In Progress`, receive a new `## Codex Worker Note`,
   then move to `Agent Review`.
4. Watch the reviewer dashboard. The reviewer should create a new
   `## Codex Review Note` and move the issue to `Human Review`, `Rework`,
   `Needs Human Context`, or `Blocked` with an explicit reason.
5. Confirm prior worker/review notes were not edited. Rework should create the
   next worker/review round as new comments.
6. Confirm normal dispatch does not append human-facing claim lease/release
   comments. Runtime-owned `## Symphony Control` comments may appear while a
   claim is active and should be deleted or compacted on normal release.

For a fake or no-op smoke, the loop should normally settle within a few minutes
after both instances are listening. A real implementation issue may take much
longer, but ten minutes with no state change, no new agent note, and no active
dashboard activity is an incident to debug, not a normal wait. Start by checking
both dashboard ports, PID metadata, runtime logs, the Linear issue comments, and
whether the issue is held by an external `## Symphony Control` claim.

## Keeping production saturated

The manager's job is not to hand-edit every solution. The manager keeps the
system fed with well-shaped work and intervenes when the loop cannot resolve a
decision itself.

Good saturation looks like:

- A small number of active issues, each scoped to one PR.
- A ready queue of `Backlog` issues that can be promoted one at a time.
- Clear GitHub acceptance criteria before an issue reaches `Ready for Agent`.
- Explicit dependency notes so prerequisite work lands or deploys before
  dependent issues are released to `Ready for Agent`.
- Fast human responses to true blockers.
- Follow-up issues for discovered defects instead of broadening the active PR.

Avoid moving many speculative issues to `Ready for Agent` before the claim,
lease, and quality gates are proven. A small team gets better throughput from
predictable handoffs than from maximum parallelism.

Dependent work is not independent capacity. If issue B depends on issue A,
keep B parked in `Backlog` until A is merged and deployed when deployment is
part of the unblock condition. Releasing both into `Ready for Agent` at the
same time usually creates stale branches, repeated validation, and misleading
`Blocked` states.

## Quality discipline

Generated work compounds quickly when low-quality PRs are allowed to become the
base for later agents. Keep this document focused on setup and operating rhythm;
put quality rules, local validation fallback, blocker protocol, agent note
discipline, review readiness, and PR conventions in
[agentic-flywheel-quality.md](agentic-flywheel-quality.md).

Managers should use [manager-agent-runbook.md](manager-agent-runbook.md) for the
operational loop: review completed work, investigate blockers, release ready
issues into `Ready for Agent`, keep workers saturated, and verify deployed
system changes.

## Pausing safely

Pause the flywheel by stopping new dispatch first, then letting active work land
or park cleanly:

1. Stop moving new issues from `Backlog` to `Ready for Agent`.
2. If immediate pause is needed, remove `Ready for Agent` from the worker
   `tracker.dispatch_states` or stop the worker Symphony process.
3. Let active agents finish their current turn when possible.
4. For unfinished active issues, create a worker note with the current branch,
   last validation result, exact blocker or pause reason, and next resume step.
5. Move truly blocked work to `Blocked` when that state exists. If it does not,
   record `Blocked state missing` and keep the issue active for manager triage.
6. Do not move issues to `Agent Review` only because a branch or PR exists.

When resuming, inspect the latest worker/review notes first, then the PR or branch, then restart
Symphony with the same workflow boundaries.

## Reusing the playbook on another project

To reuse this pattern outside Symphony:

1. Create a dedicated Linear project or label route for agentic work.
2. Decide which Linear states are active and terminal, using
   [`agents/issue-tracker.md`](agents/issue-tracker.md) as the default state
   model.
3. Add a workflow prompt that encodes the team's branch, commit, validation,
   worker/review note, blocker, and review rules.
4. Add a project-local quality document equivalent to
   `agentic-flywheel-quality.md`.
5. Start with one trusted repository and one agent at a time.
6. Make every automation defect visible as a normal backlog issue.
7. Expand concurrency only after the team trusts the claim behavior, CI signal,
   review loop, and pause procedure.

### Project configuration checklist

Before moving real work into `Ready for Agent`, make these project-specific
settings explicit. Treat this as the minimum hard configuration for a new repo:

- **Linear routing:** project slug, team, eligible labels if any, and exact state
  names. Keep `Backlog` out of `tracker.dispatch_states`; worker instances
  normally dispatch only `Ready for Agent` and `Rework`; reviewer instances
  normally dispatch only `Agent Review`.
- **GitHub routing:** repository owner/name, trusted issue labels, branch base,
  PR template, and required checks. Required check names must match the checks
  GitHub actually reports.
- **Workflow file:** copy the closest `WORKFLOW.*.example.md`, then replace
  `tracker.project_slug`, `workspace.root`, clone URL, prompt body, concurrency,
  timeout, sandbox, and review-readiness settings.
- **Workspace bootstrap:** `hooks.after_create` must clone or prepare the target
  repo, install only required dependencies, and leave the workspace on the
  intended base branch with `origin` pointing at the canonical repository.
- **Quality gates:** define the local focused checks, broad repo gate, CI checks,
  coverage policy, formatter/lint commands, and any platform-specific lane such
  as a Windows-native test profile.
- **Agent entrypoint:** add a repo-level `AGENTS.md` that names the project
  commands, branch/commit/PR rules, worker/review note rules, blocker protocol, and known
  local pitfalls. Add language- or package-specific nested `AGENTS.md` files
  when needed.
- **Manager ownership:** define which work is worker-safe and which must stay
  manager-owned, such as dependency release decisions, policy changes, CI gate
  changes, privacy/history cleanup, deployment/restart decisions, and blocker
  root-cause ownership.
- **Secrets and auth:** keep tokens in environment variables or local secret
  stores, not committed workflow files. Preflight should verify Linear, GitHub,
  Codex, shell, and platform capabilities before unattended dispatch.
- **Runtime operations:** choose logs root, PID file, dashboard port, workflow
  path, reload/restart procedure, and how to verify the running process commit
  after system changes.

If any item is still unknown, keep the project at `agent.max_concurrent_agents:
1` and release only low-risk, clearly scoped issues until the missing contract is
proven.

The important property is not the exact tool stack. The important property is
that work enters through a queue, agents operate in isolated branches with
evidence, humans manage priority and quality, and the system turns its own
defects into future work.
