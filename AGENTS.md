# Agent Entry Point

Read this first when working as a Windows-native Symphony/Codex worker. Keep the
run scoped to the current Linear/GitHub issue and update this file when workflow
policy or recurring pitfalls change.

## Repo Layout

- `README.md`: project overview and Windows-native starting links.
- `SPEC.md`: upstream behavior contract; implementation must not conflict with it.
- `elixir/`: current Symphony implementation and the directory for most commands.
- `elixir/AGENTS.md`: Elixir-specific coding, spec, PR, and validation rules.
- `elixir/docs/windows-native.md`: Windows runtime setup, paths, preflight, and pitfalls.
- `elixir/docs/small-team-agentic-flywheel.md`: Linear/GitHub flywheel operating model.
- `elixir/docs/agent-quality-flywheel.md`: PR quality gates and review readiness policy.
- `.github/pull_request_template.md`: required PR body headings.

## Windows Paths And Commands

- Work from the generated issue workspace, not a normal source checkout.
- Treat `albert-zen/symphony-windows-native` and `origin/main` as the canonical
  repo/base unless the workflow explicitly says otherwise.
- Run repo commands from `elixir/` unless the command says otherwise.
- Prefer PowerShell syntax on Windows. If GNU Make is unavailable, use `make.cmd`.

Useful commands:

```powershell
cd elixir
make all
make windows-native-test
make.cmd all
make.cmd windows-native-test
mise exec -- mix symphony.preflight.windows .\WORKFLOW.optimization.windows.md
```

## Validation

- Run focused checks while iterating, then record exact commands and outcomes in
  the PR body and Linear `## Codex Workpad`.
- `make all` is the broad local gate when the environment supports it.
- `make windows-native-test` is required for Windows shell, workspace/config,
  workflow, or path-handling changes.
- Run `mix format` for touched Elixir files and `mix specs.check` when public
  `lib/` functions are added or changed.
- Do not skip, weaken, disable, or hide failures from format, lint, coverage,
  tests, CI, review-readiness, or PR-body checks.

## Branches, Commits, And PRs

- Branch format: `codex/<linear-identifier>-<short-topic>`.
- Commit format: lightweight Conventional Commits, for example
  `docs(windows): add agent entrypoint playbook`.
- Keep one issue, one branch, one PR.
- PR body must preserve `.github/pull_request_template.md` headings exactly and
  include concrete validation evidence.
- Avoid GitHub issue-closing keywords unless the issue should close on merge.

## Linear And GitHub Flow

- If a Linear issue starts in `Todo`, move it to `In Progress` before editing.
- Use exactly one Linear comment whose first line is `## Codex Workpad`; update
  it instead of creating progress spam.
- Use the linked GitHub issue as the public implementation spec.
- Open the PR against `main`, link it in the Workpad, and wait for required
  GitHub checks before moving Linear to `In Review`.
- If checks are pending, failing, or unverifiable, record the exact reason in the
  Workpad or PR and keep the issue active.

## SubAgent Review

Request an independent SubAgent review before handoff for meaningful changes:
runtime orchestration, worker startup, Linear state transitions, Codex
app-server protocol, CI, merge/review policy, more than one subsystem, or docs
that encode operating decisions. Record the request and findings in the PR or
Workpad. Blocking findings keep the issue in `In Progress` or return it to
`Todo` until fixed and checks pass.

## Blockers Protocol

- Keep ordinary retries and recovered failures in the Workpad.
- For a true blocker, state what failed, the command/subsystem, recovery status,
  and the next operator action in the Workpad and, when useful for public review,
  the linked GitHub issue or PR.
- Move the issue to `Blocked` when that state exists. If it does not, record
  `Blocked state missing` and keep the issue active for manager triage.
- If you discover a Symphony automation/system defect, create a GitHub issue
  labeled `symphony-optimization` and mirror it into the Linear project when the
  Linear tool is available.

## Known Pitfalls

- PowerShell wrappers can corrupt `codex app-server` JSON-RPC stdio; start Codex
  directly unless the wrapper is proven quiet.
- Windows CRLF and snapshot rendering can differ from Unix expectations.
- Fake `ssh`, `gh`, and Codex fixtures may assume Unix shebang/chmod behavior.
- Stale `main` or noncanonical upstreams can hide newer `origin/main`; fetch and
  compare against the canonical base before review handoff.
- `WorkflowStore` and other global/stateful runtime paths can leak state across
  tests; preserve cleanup and isolation semantics.
- Coverage threshold or ignore-list changes are quality-gate changes and need
  explicit review; do not add changed production modules to coverage ignores.
- Path and environment handling must preserve Windows drive paths, forward-slash
  compatibility, `$VAR` workflow expansion rules, and secret redaction.
