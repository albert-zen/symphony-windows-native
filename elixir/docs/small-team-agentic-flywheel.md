# Small-team agentic build flywheel

This playbook describes a lightweight agentic build loop for small teams using
Linear, GitHub, Symphony, and Codex. It is intentionally smaller than an
enterprise harness: the durable system is a queue, a thin orchestrator, clear
quality gates, and a human manager who keeps the loop pointed at the right work.

Use this pattern when a project has enough repeatable engineering work for
automation, but still needs human product judgment, review, and prioritization.

## Roles

- Linear project: the private operating queue and state machine.
- GitHub issues: the durable public implementation backlog and acceptance
  criteria.
- Symphony: a thin dispatcher that polls eligible Linear work, creates isolated
  workspaces, and starts Codex app-server sessions.
- Codex agents: implementers that make scoped changes, validate them, open PRs,
  and leave evidence.
- Human manager: the upper-level product and quality owner who orders work,
  handles ambiguous tradeoffs, reviews results, and keeps production saturated.
- Codex Workpad: one persistent Linear comment that records the current plan,
  validation, blockers, PR, and review status.

## The loop

1. The manager keeps the GitHub issue backlog healthy.
2. The manager mirrors or routes one small piece of work into the Linear
   flywheel project.
3. Backlog work stays parked in `Backlog`; Symphony does not poll it.
4. The manager moves one issue at a time to `Todo` when it is eligible for
   automation.
5. Symphony claims eligible `Todo` or active work and starts a Codex session in
   a fresh workspace.
6. The agent moves the issue to `In Progress`, creates or updates the single
   `## Codex Workpad`, and implements only the linked issue.
7. The agent pushes a focused branch, opens a PR, records validation and review
   evidence, and waits for required checks.
8. The issue moves to review only after the PR exists and required checks pass.
   If review finds blocking issues, the work stays in or returns to an active
   state until those findings are addressed.
9. Defects discovered while running the loop become new GitHub issues and, when
   appropriate, Linear mirrors in the flywheel project.

This makes the flywheel self-improving: the system uses normal engineering
artifacts to capture the problems it discovers while building itself.

## Starting a flywheel run

Before starting unattended work, prepare the project:

1. Create or choose a Linear project dedicated to the flywheel.
2. Configure states so parked work is not eligible for polling:
   - `Backlog`: parked, not polled.
   - `Todo`: eligible for Symphony.
   - `In Progress`: active agent work.
   - `Blocked`: missing dependency, credentials, environment, or orchestration
     capability.
   - `In Review`: PR exists, required checks passed, and review is requested or
     underway. Work with unresolved blocking review findings stays in or returns
     to an active work state.
   - `Done`, `Canceled`, `Cancelled`, `Duplicate`: terminal states.
3. Keep GitHub issues as the durable implementation specs. Linear descriptions
   can mirror GitHub, but implementation discussion should stay in GitHub when
   it needs to be public or reviewable later.
4. Configure the workflow prompt to require a single `## Codex Workpad`, focused
   branches, validation evidence, PR creation, and no review transition while
   required checks are pending or failing.
5. On Windows, copy the optimization workflow example, edit it for the project,
   and run preflight from `elixir/`:

   ```powershell
   Copy-Item .\WORKFLOW.optimization.windows.example.md .\WORKFLOW.optimization.windows.md
   notepad .\WORKFLOW.optimization.windows.md
   mise exec -- mix symphony.preflight.windows .\WORKFLOW.optimization.windows.md
   ```

6. Start with `agent.max_concurrent_agents: 1`. Increase concurrency only after
   claim behavior, review readiness, and CI reporting are reliable.
7. Move the next issue from `Backlog` to `Todo`.
8. Start Symphony and monitor the dashboard and Linear Workpad.

For the Windows-native optimization project, use
[`WORKFLOW.optimization.windows.example.md`](../WORKFLOW.optimization.windows.example.md)
as the baseline workflow.

## Keeping production saturated

The manager's job is not to hand-edit every solution. The manager keeps the
system fed with well-shaped work and intervenes when the loop cannot resolve a
decision itself.

Good saturation looks like:

- A small number of active issues, each scoped to one PR.
- A ready queue of `Backlog` issues that can be promoted one at a time.
- Clear GitHub acceptance criteria before an issue reaches `Todo`.
- Explicit dependency notes so prerequisite work lands or deploys before
  dependent issues are released to `Todo`.
- Fast human responses to true blockers.
- Follow-up issues for discovered defects instead of broadening the active PR.

Avoid moving many speculative issues to `Todo` before the claim, lease, and
quality gates are proven. A small team gets better throughput from predictable
handoffs than from maximum parallelism.

Dependent work is not independent capacity. If issue B depends on issue A,
keep B parked in `Backlog` until A is merged and deployed when deployment is
part of the unblock condition. Releasing both into `Todo` at the same time
usually creates stale branches, repeated validation, and misleading `Blocked`
states.

## Guardrails that stop quality debt from compounding

Generated work compounds quickly when low-quality PRs are allowed to become the
base for later agents. These guardrails are the minimum bar:

- Workers should start from the repository-level
  [agent entrypoint playbook](../../AGENTS.md) so recurring Windows and
  flywheel facts are not rediscovered every run.
- One issue, one branch, one PR.
- Branches use `codex/<linear-identifier>-<short-topic>`.
- Commits use lightweight Conventional Commits.
- The Linear Workpad records the plan, validation, blockers, PR link, review
  status, and any CI/runtime failures.
- The PR body follows the repository template and includes concrete validation
  evidence.
- PRs for Linear issues with one unambiguous origin GitHub issue include a closing
  keyword such as `Fixes #NN` in the PR body.
- `make all` is the repository gate when the local environment supports it.
- `windows-native-test` runs for Windows shell, workspace/config, workflow, or
  path-handling changes.
- CI, lint, formatter, and test gates must not be weakened, skipped, disabled,
  or relaxed to land agent work.
- Required GitHub checks must complete and pass before an agent moves Linear to
  `In Review`.
- Meaningful changes get an independent SubAgent review loop before handoff.
  This includes docs that encode operating decisions, workflow policy, state
  transitions, quality gates, or review rules. Manager review is still useful,
  but manager-only approval does not satisfy this gate.
- Blocking review findings keep the issue in `In Progress` or return it to
  `Todo` until fixed.

See [agent-quality-flywheel.md](agent-quality-flywheel.md) for the detailed PR
quality policy used by this repository.

See [manager-agent-runbook.md](manager-agent-runbook.md) for the manager
orchestration loop used to review completed work, investigate blockers, release
ready issues into `Todo`, keep workers saturated, and verify deployed system
changes.

## Workpad discipline

Use exactly one Linear comment whose first line is:

```md
## Codex Workpad
```

Update that comment instead of adding progress spam. A useful Workpad has:

- Status: current phase and whether the issue is blocked.
- Scope: GitHub issue, branch, PR, and linked acceptance criteria.
- Plan: the next few concrete steps.
- Validation: commands run and outcomes.
- Review: reviewer requested, findings, and resolution.
- Checks: required GitHub check status.
- Blockers: exact missing credential, permission, environment, dependency, or
  system condition.

Use a separate Linear problem comment only when a failure changes the plan,
requires a workaround, consumes operator attention, or blocks completion. Routine
retry noise belongs in the Workpad.

## Pausing safely

Pause the flywheel by stopping new dispatch first, then letting active work land
or park cleanly:

1. Stop moving new issues from `Backlog` to `Todo`.
2. If immediate pause is needed, remove `Todo` from `tracker.dispatch_states` or
   stop the Symphony process.
3. Let active agents finish their current turn when possible.
4. For unfinished active issues, update the Workpad with the current branch,
   last validation result, exact blocker or pause reason, and next resume step.
5. Move truly blocked work to `Blocked` when that state exists. If it does not,
   record `Blocked state missing` and keep the issue active for manager triage.
6. Do not move issues to `In Review` only because a branch or PR exists.

When resuming, inspect the Workpad first, then the PR or branch, then restart
Symphony with the same workflow boundaries.

## Reusing the playbook on another project

To reuse this pattern outside Symphony:

1. Create a dedicated Linear project or label route for agentic work.
2. Decide which Linear states are active and terminal.
3. Add a workflow prompt that encodes the team's branch, commit, validation,
   Workpad, blocker, and review rules.
4. Add a project-local quality document equivalent to
   `agent-quality-flywheel.md`.
5. Start with one trusted repository and one agent at a time.
6. Make every automation defect visible as a normal backlog issue.
7. Expand concurrency only after the team trusts the claim behavior, CI signal,
   review loop, and pause procedure.

The important property is not the exact tool stack. The important property is
that work enters through a queue, agents operate in isolated branches with
evidence, humans manage priority and quality, and the system turns its own
defects into future work.
