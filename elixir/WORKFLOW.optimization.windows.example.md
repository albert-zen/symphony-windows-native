---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "YOUR_LINEAR_PROJECT_SLUG"
  # Optional: uncomment only if this project is shared with unrelated work.
  # labels:
  #   - symphony-optimization
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
  root: "D:/code/symphony-optimization-workspaces"
hooks:
  timeout_ms: 300000
  after_create: |
    $ErrorActionPreference = "Stop"
    git clone --depth 1 https://github.com/albert-zen/symphony-windows-native.git .
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
   `albert-zen/symphony-windows-native`.
9. Open a GitHub pull request against `main` and link it in the Linear workpad.
10. Wait for required GitHub checks to complete before moving the Linear issue to `In Review`.
    If checks cannot be verified, record the exact reason in the workpad and PR, then keep the
    issue in `In Progress` or return it to `Todo`; only a manager may explicitly override this.
11. Do not move unrelated Backlog issues to Todo.
12. If you discover an automation/system defect, create a GitHub issue with label `symphony-optimization` and add a Linear mirror in project `YOUR_LINEAR_PROJECT_NAME` if the Linear tool is available.
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
