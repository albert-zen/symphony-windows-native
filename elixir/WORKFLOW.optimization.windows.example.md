---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "e4ea95122cf7"
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
8. Commit the change and push the branch to `albert-zen/symphony-windows-native`.
9. Open a GitHub pull request against `main` and link it in the Linear workpad.
10. Move the Linear issue to `In Review` after the PR exists and validation is recorded.
11. Do not move unrelated Backlog issues to Todo.
12. If you discover an automation/system defect, create a GitHub issue with label `symphony-optimization` and add a Linear mirror in project `Symphony 优化` if the Linear tool is available.

Quality bar:

- Prefer small, reviewable changes.
- Run `mix format` for touched Elixir files.
- Run focused Windows-native tests when touching Windows runtime behavior.
- Do not broaden scope to multiple optimization issues in one PR.
- If blocked by credentials or permissions, record the exact blocker in the Workpad and move the issue to In Review.
