# Agent quality flywheel

This policy defines the minimum review and validation loop for Symphony-managed agent PRs. It is
intended to be copied into workflow prompts and used by humans when deciding whether an issue can
leave active work.

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
must say why, and the issue must stay out of `In Review` until required GitHub checks pass or a
manager explicitly moves it.

Agents must not weaken, skip, disable, or relax CI, lint, formatter, or test gates to land agent
work. If a gate is wrong or flaky, file or link a follow-up defect and keep the current issue out of
`In Review` until the required checks pass or a manager explicitly overrides the state transition.

Coverage is a quality signal, not a mechanical target. The repository keeps a high total coverage
threshold, but it is intentionally below 100% so workers are not forced to add filler tests for
incidental branches. Review should still demand meaningful tests for the changed behavior, failure
modes, and public contracts. Coverage threshold changes are manager-owned policy work and must be
made through an explicit issue and review, not as a drive-by workaround in an unrelated PR.

Coverage ignore changes are gate changes. A PR must not add a production module to
`test_coverage.ignore_modules` when that same module is changed in the PR. The review-readiness
gate rejects that overlap before an agent can move the Linear issue to review. If a manager believes
an exception is justified, the manager must audit it outside the agent session and leave an explicit
approval note; the agent cannot self-approve the transition.

Stale-base overlap is also not review-ready. When the PR's recorded base SHA is behind the current
base branch and files changed on current base overlap files changed in the PR, the agent must merge
current base, resolve the overlap, and rerun validation before handoff.

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
blocking issues, keep the Linear issue in `In Progress` or return it to `Todo` until the findings are
addressed and required checks are green.

## Linear and GitHub state rules

Agents must not move a Linear issue to `In Review` solely because a branch was pushed. `In Review`
means a PR exists, required checks have completed and passed, and required manager/subagent review
findings have been addressed, unless a manager explicitly moves the issue there.

When a Linear issue has one unambiguous origin GitHub issue in the trusted repository, the linked PR
must close that GitHub issue through the PR body before review handoff. Use a supported closing
keyword such as `Fixes #NN`, `Closes #NN`, or `Resolves #NN`. Do not infer origins from reference-only
links, unrelated attachments, or multiple trusted issue URLs. Do not use a closing keyword for an
unrelated or still-active GitHub issue.

Pending, failing, or unverifiable required checks are not review-ready. The agent must write the
failure or blocker to the workpad and/or linked GitHub issue or PR, then keep the issue in
`In Progress` or return it to `Todo`. If a true blocker prevents completion, the agent should move
the issue to `Blocked` when that state exists. If Linear returns `:state_not_found` or the workflow
has no `Blocked` state, the agent must record `Blocked state missing` and keep the issue active for
manager triage.

Human triage for agent-written blocker comments:

- Read the latest `## Codex Workpad` first, then any separate problem comment.
- Confirm the comment states what failed, the command/subsystem involved, recovery status, and the
  next operator inspection target.
- If the blocker is real and `Blocked` exists, move the issue there; otherwise standardize the team
  workflow by adding `Blocked` or document the local alternative before rerunning agents.
- If the comment describes transient recovered noise, leave the issue active and ask the agent to
  consolidate future notes into the workpad.

If a required gate fails, the agent must summarize the failure in the workpad or linked GitHub issue
and keep the Linear issue in `In Progress` or return it to `Todo` for repair. Failures discovered by
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

## Problem comment scope

Agents should not create issue comments for every failed command. Use the persistent workpad for
ordinary retries, dependency installs that recover, and validation failures fixed within the same
plan. Create a separate problem comment only when the failure changes the plan, requires a
workaround, consumes operator attention, or blocks completion.

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
