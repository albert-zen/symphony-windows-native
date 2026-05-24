# Agent Quality Gates

This file points agent workflow skills at the repo-specific gates. The detailed
policy remains in `../agentic-flywheel-quality.md`.

## Required Evidence

Every worker handoff must record these in the PR body and Linear Workpad:

- PR body follows `.github/pull_request_template.md`.
- Local focused validation for the changed behavior.
- `make all` from `elixir/` when the environment supports it, or the documented
  CI handoff reason and log path.
- `make.cmd windows-native-test` for Windows shell, workspace/config, workflow,
  path-handling, or runtime orchestration changes.
- `mix format` for touched Elixir files.
- `mix specs.check` when public `lib/` functions are added or changed.
- Required GitHub checks complete and pass before `Agent Review`.

## Review Readiness

The readiness gate should protect `Agent Review`, not `Todo` or `Human Review`.
Set `codex.review_readiness_guarded_states` in the workflow config to the
machine review queue states that require PR/check evidence. The default remains
`In Review` for compatibility with older workflow files; the optimization
flywheel config should set it to `Agent Review`.

The readiness policy requires:

- linked PR from Linear attachment metadata,
- trusted repository configured in workflow,
- PR branch containing the Linear issue identifier,
- PR body validation evidence,
- required checks from branch protection or workflow config,
- no changed production module added to coverage ignores,
- no stale-base overlap against the current base branch.

## Skip Policy

Agents must not weaken, disable, skip, or hide failures from tests, lint,
formatting, coverage, review readiness, or PR-body checks to land unrelated
work. A wrong or flaky gate is a separate manager-owned issue unless the current
issue is explicitly about that gate.

When broad local gates time out or are ambiguous, inspect the log and residual
processes before retrying. Rerun at most once when a local result is required
before pushing; otherwise hand off to CI with exact evidence.

For Codex app-server automation, do not set `model_reasoning_effort` to
`minimal`. Current app-server sessions can include default tools such as
`image_gen` or `web_search`, and the API rejects that combination before the
agent emits any useful message. Use `low` or higher for worker and reviewer
instances.
