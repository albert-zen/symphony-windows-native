# Agentic flywheel quality discipline

This policy defines the minimum validation, Workpad, blocker, review, and state
discipline for Symphony-managed agent PRs. It is the companion to
[agentic-flywheel-setup.md](agentic-flywheel-setup.md), which covers
project setup and operating rhythm.

The canonical Linear state machine lives in
[`agents/issue-tracker.md`](agents/issue-tracker.md). In the current target
workflow, `Agent Review` is the machine review queue and `Human Review` is the
human acceptance queue. Older workflow files may still use `In Review`; the
protected review destination is configured through
`codex.review_readiness_guarded_states`.

## Required gates

Every agent PR must record these checks in the PR body and the Linear `## Codex Workpad`:

- `validate-pr-description`: the PR body follows `.github/pull_request_template.md`.
- `linked-issue-close`: when the Linear issue has one unambiguous origin GitHub issue in the
  trusted repository, the PR body includes a GitHub closing keyword such as `Fixes #NN`.
- `make-all`: the repository gate runs `make all` from `elixir/`.
- `diff-check`: the repository gate runs `git diff --check` through `make all`. In CI it
  must check the committed PR diff with `DIFF_RANGE=<base>...HEAD`; locally, set
  `DIFF_RANGE` or let the target check uncommitted working-tree changes.
- `windows-native-test`: Windows CI runs the focused native shell and workspace/config profile.
- Targeted checks for the changed behavior, such as a single ExUnit file or mix task test.

Agents should run focused validation before committing. `make all` should run before handoff when
the local environment can support the full gate. If a gate cannot be run locally, the PR and workpad
must say why, and the issue must stay out of `Agent Review` until required GitHub checks pass or a
manager explicitly moves it.

Agents must not weaken, skip, disable, or relax CI, lint, formatter, or test gates to land agent
work. If a gate is wrong or flaky, file or link a follow-up defect and keep the current issue out of
`Agent Review` until the required checks pass or a manager explicitly overrides the state transition.

Coverage is a quality signal, not a mechanical target. The repository keeps a high total coverage
threshold, but it is intentionally below 100% so workers are not forced to add filler tests for
incidental branches. Review should still demand meaningful tests for the changed behavior, failure
modes, and public contracts. Coverage threshold changes are manager-owned policy work and must be
made through an explicit issue and review, not as a drive-by workaround in an unrelated PR.

Coverage ignore changes are gate changes. A PR must not add a production module to
`test_coverage.ignore_modules` when that same module is changed in the PR. The review-readiness
gate rejects that overlap before an agent can move the Linear issue to `Agent Review`. If a manager
believes an exception is justified, the manager must audit it outside the agent session and leave an
explicit approval note; the agent cannot self-approve the transition.

Stale-base overlap is also not review-ready. When the PR's recorded base SHA is behind the current
base branch and files changed on current base overlap files changed in the PR, the agent must merge
current base, resolve the overlap, and rerun validation before handoff.

## Local validation fallback

Focused local checks are preferred while iterating. Broad or coverage-heavy
gates should run locally when the environment supports them, but workers should
not burn repeated turns on ambiguous local tooling failures.

In Codex App sessions, run broad gates such as `make all`, `make.cmd
windows-native-test`, or `mix test --cover` with stdout/stderr redirected to a
log file. If the tool call times out or is interrupted:

1. Inspect the log tail and search for final result markers such as `Coverage`,
   `Threshold`, `failures`, and `Generated HTML coverage results`.
2. Check for residual `mix`, `beam`, `erl`, `elixir`, or `mise` processes.
3. If the log contains a final result, use that result instead of rerunning.
4. If the log is incomplete and no matching process remains, rerun at most once
   with a fresh log path only when a local result is required before pushing.
5. Otherwise push and use formal GitHub CI as the verification source, recording
   the command, log path, process check, and CI handoff reason.

This is not permission to skip quality gates. It is a token-control policy for
unreliable local broad-gate execution.

## Review loop

Workers should start from the repository-level
[agent entrypoint playbook](../../AGENTS.md), which summarizes this policy for
every run.

Request an independent SubAgent review pass for meaningful changes before handoff. A change is
meaningful when it touches runtime orchestration, worker startup, Linear state transitions, Codex
app-server protocol handling, CI, release/merge policy, more than one subsystem, or docs that encode
operating decisions. Manager review remains valuable, but manager-only approval does not satisfy the
SubAgent review gate for these changes.

The review pass should check:

- The implementation is scoped to the linked Linear/GitHub issue.
- The validation evidence matches the touched risk.
- The PR does not weaken coverage, CI, lint, formatter, review, or readiness gates.
- The PR branch is current enough for the touched files, with no stale-base overlap against newer
  merged work.
- Deleted tests or removed public message handlers are in scope for the issue and backed by clear
  replacement coverage or explicit manager approval.
- CI failures and runtime defects are written back to GitHub or Linear before state changes.
- Follow-up work is filed instead of being left only in logs.

Docs-only changes may skip an extra SubAgent review only when they clarify existing behavior without
changing or encoding operating policy, workflow expectations, state transitions, quality gates, or
review rules, and all required documentation checks pass.

Record the review request and outcome in the PR conversation or Linear workpad. If the review finds
blocking issues, move the Linear issue to `Rework` when the fix is bounded, or `Needs Human Context`
when the spec is incomplete. Keep it out of `Human Review` until findings are addressed and required
checks are green.

## Workpad and blocker discipline

Use exactly one Linear comment whose first line is:

```md
## Codex Workpad
```

Update that comment instead of adding progress spam. Runtime-owned
`## Symphony Control` comments are the exception to the single-comment rule:
they are reserved for durable claim coordination and must not be used for human
progress notes. A useful Workpad records:

- Status: current phase and whether the issue is blocked.
- Scope: GitHub issue, branch, PR, and linked acceptance criteria.
- Plan: the next concrete steps.
- Validation: commands run, outcomes, log paths, and CI handoff reason when
  local broad gates are ambiguous.
- Review: reviewer requested, findings, and resolution.
- Checks: required GitHub check status.
- Blockers: exact missing credential, permission, environment, dependency, or
  system condition.

Routine retries and recovered failures belong in the Workpad. Create a separate
problem comment only when the failure changes the plan, requires a workaround,
consumes operator attention, or blocks completion.

Environment and pipeline blockers need capability evidence, not repeated blind
retries. Before handoff, run or cite
`mix symphony.preflight.windows --capabilities-only --json <WORKFLOW>` when the
failure may involve OS, shell, PowerShell, `tasklist`, GitHub CLI, Linear auth,
coverage policy, or line endings. The Workpad entry must state the failed
command, capability result, local recovery attempted, and manager action needed.
If the blocker matches an existing canonical system issue, comment there with
the new evidence instead of creating a duplicate.

## Linear and GitHub state rules

Agents must not move a Linear issue to `Agent Review` solely because a branch was pushed. `Agent
Review` means a PR exists, required checks have completed and passed, and the Workpad contains
enough validation evidence for a reviewer agent to inspect the work. `Human Review` means the
reviewer agent found no blocking standards or spec findings and human acceptance remains.

When a Linear issue has one unambiguous origin GitHub issue in the trusted repository, the linked PR
must close that GitHub issue through the PR body before review handoff. Use a supported closing
keyword such as `Fixes #NN`, `Closes #NN`, or `Resolves #NN`. Do not infer origins from reference-only
links, unrelated attachments, or multiple trusted issue URLs. Do not use a closing keyword for an
unrelated or still-active GitHub issue.

Pending, failing, or unverifiable required checks are not review-ready. The agent must write the
failure or blocker to the workpad and/or linked GitHub issue or PR, then keep the issue in
`In Progress` or return it to `Rework` when it was already in a repair loop. If the issue brief is
insufficient, move it to `Needs Human Context`. If a true blocker prevents completion, the agent
should move the issue to `Blocked` when that state exists. If Linear returns `:state_not_found` or
the workflow has no `Blocked` state, the agent must record `Blocked state missing` and keep the issue
active for manager triage.

Human triage for agent-written blocker comments:

- Read the latest `## Codex Workpad` first, then any separate problem comment.
- Confirm the comment states what failed, the command/subsystem involved, recovery status, and the
  next operator inspection target.
- If the blocker is real and `Blocked` exists, move the issue there; otherwise standardize the team
  workflow by adding `Blocked` or document the local alternative before rerunning agents.
- If the comment describes transient recovered noise, leave the issue active and ask the agent to
  consolidate future notes into the workpad.

If a required gate fails, the agent must summarize the failure in the workpad or linked GitHub issue
and keep the Linear issue in `In Progress` or move it to `Rework` for repair. Failures discovered by
automation should create a GitHub issue with the `symphony-optimization` label when they describe a
system defect outside the current PR.

## GitHub issue reconciliation

Use this manager-run path only for already completed work:

1. Query Done Linear issues and inspect each issue's linked GitHub issue and merged PR.
2. Confirm the Linear issue is terminal `Done`, the PR is merged, and the PR or Workpad clearly
   matches exactly one GitHub issue.
3. Close the GitHub issue with a comment linking the merged PR and Linear issue.
4. Skip any item whose Linear issue is not Done, whose PR is unmerged, or whose mapping is ambiguous.
5. Record permission failures in the Linear Workpad or manager notes instead of guessing.

This reconciliation is intentionally explicit. Agents should prevent new stale issues with PR closing
keywords; they should not bulk-close GitHub issues for active or ambiguous Linear work.

## Commit and PR conventions

Use lightweight Conventional Commits for agent work:

```text
<type>(<scope>): <imperative summary>
```

Accepted types are `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, and `ci`. Scopes should name
the touched area, such as `windows`, `ci`, `quality`, `tracker`, or `app-server`.

Every PR body must keep the template headings exactly as written and include concrete validation
results. Recommended branch protection for `main` is:

- Require pull requests before merge.
- Require `make-all` and `validate-pr-description`.
- Require `windows-native-test` for Windows shell, workspace/config, or workflow changes.
- Require at least one review for non-trivial agent PRs.
