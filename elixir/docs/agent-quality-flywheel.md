# Agent quality flywheel

This policy defines the minimum review and validation loop for Symphony-managed agent PRs. It is
intended to be copied into workflow prompts and used by humans when deciding whether an issue can
leave active work.

## Required gates

Every agent PR must record these checks in the PR body and the Linear `## Codex Workpad`:

- `validate-pr-description`: the PR body follows `.github/pull_request_template.md`.
- `make-all`: the repository gate runs `make all` from `elixir/`.
- `windows-native-test`: Windows CI runs the focused native startup/config profile.
- Targeted checks for the changed behavior, such as a single ExUnit file or mix task test.

Agents should run focused validation before committing. `make all` should run before handoff when
the local environment can support the full gate. If a gate cannot be run locally, the PR and workpad
must say why and rely on GitHub checks before review.

## Review loop

Use a manager or subagent review pass for non-trivial changes before merge. A change is non-trivial
when it touches runtime orchestration, worker startup, Linear state transitions, Codex app-server
protocol handling, CI, release/merge policy, or more than one subsystem.

The review pass should check:

- The implementation is scoped to the linked Linear/GitHub issue.
- The validation evidence matches the touched risk.
- CI failures and runtime defects are written back to GitHub or Linear before state changes.
- Follow-up work is filed instead of being left only in logs.

Docs-only changes may skip an extra subagent review when they only clarify existing behavior and
all required documentation checks pass.

## Linear and GitHub state rules

Agents must not move a Linear issue to `In Review` solely because a branch was pushed. They should
wait until required GitHub checks have completed and passed, or record the exact reason checks could
not be verified.

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
- Require `windows-native-test` for Windows runtime or workflow changes.
- Require at least one review for non-trivial agent PRs.
