---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  # Replace with your Linear project slug. The Windows preflight can verify
  # Linear connectivity, and the dashboard/logs will show which project is
  # being polled.
  project_slug: "YOUR_LINEAR_PROJECT_SLUG"
  # Optional: uncomment only if this project is shared with unrelated work.
  # labels:
  #   - symphony-optimization
  # Poll only release-ready work. Keep Backlog and In Progress out of dispatch_states.
  dispatch_states:
    - Todo
  # Keep In Progress active so workers are not stopped after they claim a Todo issue.
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  # Use a dedicated disposable automation root. Do not point this at your
  # everyday source checkout or a broad personal directory.
  root: "D:/code/symphony-workspaces"
hooks:
  timeout_ms: 300000
  after_create: |
    $ErrorActionPreference = "Stop"
    git clone --depth 1 https://github.com/YOUR_GITHUB_OWNER/YOUR_REPO.git .
    git remote set-url origin https://github.com/YOUR_GITHUB_OWNER/YOUR_REPO.git
    git fetch origin main
    git config user.email "codex-symphony@example.invalid"
    git config user.name "Codex Symphony"
    Set-Location elixir
    mise trust
    mise install
    mise exec -- mix deps.get
  before_remove: |
    $ErrorActionPreference = "Stop"
    git status --short
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model=gpt-5.5 --config model_reasoning_effort=medium app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  # Used when GitHub branch protection required-check metadata is private or unavailable.
  review_readiness_repository: YOUR_GITHUB_OWNER/YOUR_REPO
  command_watchdog_long_running_ms: 300000
  command_watchdog_idle_ms: 120000
  command_watchdog_stalled_ms: 300000
  command_watchdog_repeated_output_limit: 20
  command_watchdog_block_on_stall: false
  review_readiness_required_checks:
    - make-all
    - validate-pr-description
    - windows-native-test
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are running the Symphony optimization flywheel on Windows.

Issue:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- URL: {{ issue.url }}
- Labels: {{ issue.labels }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Operating model:

1. Work only in the current workspace.
2. If the Linear issue is Todo, move it to In Progress before implementation.
3. Use exactly one Linear comment whose first line is `## Codex Workpad`; update it instead of creating progress spam.
4. Use the linked GitHub issue as the durable public implementation spec.
5. Keep changes focused on the current Linear/GitHub issue.
6. Create a branch named `codex/<linear-identifier>-<short-topic>`.
7. Run focused validation before committing.
8. Commit with lightweight Conventional Commits, for example
   `docs(quality): add agent PR quality policy`, and push the branch to
   the configured GitHub repository.
9. Open a GitHub pull request against `main` and link it in the Linear workpad.
   If the Linear issue has one unambiguous origin GitHub issue, include a supported closing keyword
   in the PR body, for example `Fixes #NN`.
10. Wait for required GitHub checks to complete before moving the Linear issue to `In Review`.
    If checks cannot be verified, record the exact reason in the workpad and PR, then keep the
    issue in `In Progress` or return it to `Todo`; only a manager may explicitly override this.
    When checks are verified through GitHub CLI, connector, or another non-REST path, record this
    exact machine-readable evidence in the `## Codex Workpad`:
    `PR: https://github.com/albert-zen/symphony-windows-native/pull/<number>`
    `Head \`<full-head-sha>\``
    `- make-all run <run-id>: success.`
    `- validate-pr-description run <run-id>: success.`
    `- windows-native-test run <run-id>: success.`
11. Do not move unrelated Backlog issues to Todo.
12. If you discover an automation/system defect:
    - Search existing open and recently closed GitHub issues plus Linear mirrors for the same root
      cause before creating anything new.
    - If a canonical issue exists, add a concise comment there with the new evidence, affected
      issue/PR/log, and impact instead of creating a duplicate.
    - If no canonical issue exists, create a GitHub issue with the configured optimization label,
      including observed symptoms, suspected root cause, impact, and acceptance criteria, then add a
      Linear mirror in the configured Linear project if the Linear tool is available.
    - If you discover duplicates, link them back to the canonical issue and leave final duplicate
      cleanup to the manager.
13. Leave problem breadcrumbs without spamming:
    - Update the `## Codex Workpad` for recovered transient noise, retries, or routine validation fixes.
    - Add a separate concise Linear problem comment only for notable environment, validation, auth,
      dependency, or orchestration failures that changed the plan, required a workaround, or need
      the next operator's attention.
    - Problem comments must include what failed, the command/subsystem involved, whether recovery
      succeeded, and the next thing an operator should inspect.
14. If a true blocker prevents completion, update the workpad, then try to move the issue to
    `Blocked`. If the Linear team has no `Blocked` state, record `Blocked state missing` in the
    workpad/problem comment and keep the issue in its active state unless a manager explicitly moves
    it elsewhere.

Quality bar:

- Prefer small, reviewable changes.
- Treat `origin/main` in the configured GitHub repository as the canonical
  GitHub base ref for manager-side stale-base checks unless the workflow
  explicitly configures another trusted remote.
- Run `mix format` for touched Elixir files.
- Follow `docs/agent-quality-flywheel.md` for PR quality gates, review loop rules, and defect
  protocol.
- Run focused Windows shell and workspace/config tests when touching Windows runtime or workflow
  behavior:
  `make windows-native-test`.
- Do not move the issue to `In Review` while required checks are pending or failing.
- For non-trivial changes, request manager/subagent review before handoff and record the review
  request plus findings in the PR and/or Workpad.
- If review finds blocking issues, keep the issue in `In Progress` or return it to `Todo` until
  the findings are addressed and required checks pass.
- Write CI/runtime failures back to the Linear Workpad or linked GitHub issue before ending.
- Do not broaden scope to multiple optimization issues in one PR.
- If blocked by credentials or permissions, record the exact blocker in the Workpad and keep the
  issue out of `In Review` unless a manager explicitly moves it there.
