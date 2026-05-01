# Agent quality flywheel

This policy defines the minimum review and validation loop for Symphony-managed agent PRs. It is
intended to be copied into workflow prompts and used by humans when deciding whether an issue can
leave active work.

## Required gates

Every agent PR must record these checks in the PR body and the Linear `## Codex Workpad`:

- `validate-pr-description`: the PR body follows `.github/pull_request_template.md`.
- `make-all`: the repository gate runs `make all` from `elixir/`.
- `diff-check`: the repository gate runs `git diff --check` through `make all`.
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
`In Progress` or return it to `Todo`. If a `Blocked` state exists, the manager may move the issue
there.

If a required gate fails, the agent must summarize the failure in the workpad or linked GitHub issue
and keep the Linear issue in `In Progress` or return it to `Todo` for repair. Failures discovered by
automation should create a GitHub issue with the `symphony-optimization` label when they describe a
system defect outside the current PR.

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
