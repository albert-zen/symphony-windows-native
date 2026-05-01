# Agent quality flywheel

This policy defines the minimum review and validation loop for Symphony-managed agent PRs. It is
intended to be copied into workflow prompts and used by humans when deciding whether an issue can
leave active work.

## Required gates

Every agent PR must record these checks in the PR body and the Linear `## Codex Workpad`:

- `validate-pr-description`: the PR body follows `.github/pull_request_template.md`.
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

## Review loop

Request a manager or subagent review pass for non-trivial changes before handoff. A change is
non-trivial when it touches runtime orchestration, worker startup, Linear state transitions, Codex
app-server protocol handling, CI, release/merge policy, or more than one subsystem.

The review pass should check:

- The implementation is scoped to the linked Linear/GitHub issue.
- The validation evidence matches the touched risk.
- CI failures and runtime defects are written back to GitHub or Linear before state changes.
- Follow-up work is filed instead of being left only in logs.

Docs-only changes may skip an extra subagent review when they only clarify existing behavior and
all required documentation checks pass.

Record the review request and outcome in the PR conversation or Linear workpad. If the review finds
blocking issues, keep the Linear issue in `In Progress` or return it to `Todo` until the findings are
addressed and required checks are green.

## Linear and GitHub state rules

Agents must not move a Linear issue to `In Review` solely because a branch was pushed. `In Review`
means a PR exists, required checks have completed and passed, and required manager/subagent review
findings have been addressed, unless a manager explicitly moves the issue there.

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
