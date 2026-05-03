# Symphony Elixir

This directory contains the Elixir agent orchestration service that polls
Linear, creates per-issue workspaces, and runs Codex in app-server mode.

Use this file as the worker-facing repo map. It should give enough local
orientation to choose the right module, command, and validation path without
forcing every worker to read every project document.

## Code Map

- `lib/symphony_elixir/orchestrator.ex`: polling loop, claim/retry/reconcile
  behavior, and tracker-driven dispatch.
- `lib/symphony_elixir/agent_runner.ex`: per-issue worker lifecycle and Codex
  session execution.
- `lib/symphony_elixir/codex/`: Codex app-server protocol, rollout/session
  readers, command watchdog, and validation evidence handling.
- `lib/symphony_elixir/linear/` and `lib/symphony_elixir/tracker*`: Linear
  GraphQL adapter, issue model, and tracker abstraction.
- `lib/symphony_elixir/workflow*.ex`, `config*.ex`: `WORKFLOW.md` parsing,
  runtime config, prompt loading, and workflow reload/edit support.
- `lib/symphony_elixir/workspace.ex` and `path_safety.ex`: generated workspace
  creation, safety checks, and path boundary enforcement.
- `lib/symphony_elixir/deployment/`, `runtime_info.ex`, and `scripts/*.ps1`:
  Windows-native start/stop/reload/runtime metadata.
- `lib/symphony_elixir_web/`: dashboard, worker detail pages, config editor,
  API payloads, and static dashboard assets.
- `test/symphony_elixir/`: focused ExUnit coverage for runtime, web, Linear,
  workspace, Windows, and Codex behavior.

Use [`../SPEC.md`](../SPEC.md) when changing public behavior or contracts. Use
[`docs/windows-native.md`](docs/windows-native.md) for Windows setup/runtime
details, and [`docs/agent-quality-flywheel.md`](docs/agent-quality-flywheel.md)
for PR quality policy.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Agent PRs must follow the quality policy in [`docs/agent-quality-flywheel.md`](docs/agent-quality-flywheel.md).
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

For Windows-native worker or workflow changes, also run the focused profile:

```bash
make windows-native-test
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Agent PR commits should use lightweight Conventional Commits such as
  `fix(app-server): resolve session startup lint`.
- Do not hand off an agent PR while required GitHub checks are still pending or failing unless a
  manager explicitly asks for that state; record blockers in the PR and Linear workpad.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
