---
prompt_context:
  linear_project_name: YOUR_LINEAR_PROJECT_NAME
  github_issue_label: symphony-optimization
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
  # Poll only worker-ready work. Keep Backlog and In Progress out of dispatch_states.
  dispatch_states:
    - Ready for Agent
    - Rework
  # Keep In Progress active so workers are not stopped after they claim an issue.
  active_states:
    - Ready for Agent
    - In Progress
    - Rework
  terminal_states:
    - Agent Review
    - Human Review
    - Needs Human Context
    - Blocked
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
  read_timeout_ms: 30000
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
  review_readiness_guarded_states:
    - Agent Review
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
2. If the Linear issue is `Ready for Agent` or `Rework`, move it to `In Progress` before implementation.
3. Create a new append-only Linear comment for this worker round whose first line is
   `## Codex Worker Note`. Do not edit or overwrite previous worker or reviewer notes.
   Include `Round: <n>` when a prior `## Codex Worker Note` or `## Codex Review Note`
   exists for this issue.
4. Use the linked GitHub issue or embedded `## Agent Brief` as the durable implementation spec.
   If the issue lacks enough context, acceptance criteria, dependency state, testing intent, or
   decision authority, write the missing context into a new worker note and move it to `Needs Human Context`.
5. Keep changes focused on the current Linear/GitHub issue.
6. Create a branch named `codex/<linear-identifier>-<short-topic>`.
7. Run focused validation before committing.
8. Commit with lightweight Conventional Commits, for example
   `docs(quality): add agent PR quality policy`, and push the branch to
   the configured GitHub repository.
9. Open a GitHub pull request against `main` and link it in the worker note.
   If the Linear issue has one unambiguous origin GitHub issue, include a supported closing keyword
   in the PR body, for example `Fixes #NN`.
10. Wait for required GitHub checks to complete before moving the Linear issue to `Agent Review`.
    If checks cannot be verified, record the exact reason in a worker note and PR, then keep the
    issue in `In Progress` or return it to `Rework`; only a manager may explicitly override this.
    When checks are verified through GitHub CLI, connector, or another non-REST path, record this
    exact machine-readable evidence in the latest `## Codex Worker Note`:
    `PR: https://github.com/{{ workflow.codex.review_readiness_repository }}/pull/<number>`
    `Head \`<full-head-sha>\``
    `- make-all run <run-id>: success.`
    `- validate-pr-description run <run-id>: success.`
    `- windows-native-test run <run-id>: success.`
11. Do not move unrelated Backlog issues to `Ready for Agent`.
12. If you discover an automation/system defect:
    - Search existing open and recently closed GitHub issues plus Linear mirrors for the same root
      cause before creating anything new.
    - If a canonical issue exists, add a concise comment there with the new evidence, affected
      issue/PR/log, and impact instead of creating a duplicate.
    - If no canonical issue exists, create a GitHub issue with label `{{ workflow.prompt_context.github_issue_label }}`,
      including observed symptoms, suspected root cause, impact, and acceptance criteria, then add a
      Linear mirror in project `{{ workflow.prompt_context.linear_project_name }}` if the Linear tool is available.
    - If you discover duplicates, link them back to the canonical issue and leave final duplicate
      cleanup to the manager.
13. Leave problem breadcrumbs without spamming:
    - Create a new `## Codex Worker Note` for each worker round, including recovered transient noise,
      retries, routine validation fixes, and the final handoff evidence for that round.
    - Add a separate concise Linear problem comment only for notable environment, validation, auth,
      dependency, or orchestration failures that changed the plan, required a workaround, or need
      the next operator's attention.
    - Problem comments must include what failed, the command/subsystem involved, whether recovery
      succeeded, and the next thing an operator should inspect.
14. For environment or pipeline blockers, include capability/preflight evidence before handoff:
    - Run or cite `mix symphony.preflight.windows --capabilities-only --json <WORKFLOW>` when the
      blocker may involve OS, shell, PowerShell, tasklist, GitHub CLI, Linear auth, coverage policy,
      or line endings.
    - Write these exact worker note fields: failed command, capability result, local recovery attempted,
      and manager action needed.
    - If a canonical issue exists for the same shared friction, comment there with the new evidence
      instead of creating a duplicate.
15. If a true blocker prevents completion, create a worker note, then try to move the issue to
    `Blocked`. If the Linear team has no `Blocked` state, record `Blocked state missing` in the
    worker note or problem comment and keep the issue in its active state unless a manager explicitly moves
    it elsewhere.

Quality bar:

- Prefer small, reviewable changes.
- Treat `origin/main` in the configured GitHub repository as the canonical
  GitHub base ref for manager-side stale-base checks unless the workflow
  explicitly configures another trusted remote.
- Run `mix format` for touched Elixir files.
- Follow `docs/agentic-flywheel-quality.md` for PR quality gates, review loop rules, and defect
  protocol.
- Run focused Windows shell and workspace/config tests when touching Windows runtime or workflow
  behavior:
  `make windows-native-test`.
- Do not move the issue to `Agent Review` while required checks are pending or failing.
- `Agent Review` is the reviewer-agent queue. Do not move directly to `Human Review` unless a
  manager explicitly instructs you to do so.
- If review finds blocking issues, move through `Rework`, address only those findings, and return
  to `Agent Review` after required checks pass.
- Write CI/runtime failures back to a Linear worker note or linked GitHub issue before ending.
- Do not broaden scope to multiple optimization issues in one PR.
- If blocked by credentials or permissions, record the exact blocker in a worker note and keep the
  issue out of `Agent Review` unless a manager explicitly moves it there.
