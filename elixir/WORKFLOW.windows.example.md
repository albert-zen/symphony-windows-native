---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "your-linear-project-slug"
  # Optional: restrict candidate dispatch to issues with any of these labels.
  # labels:
  #   - symphony-optimization
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: "D:/code/symphony-workspaces"
hooks:
  timeout_ms: 300000
  after_create: |
    $ErrorActionPreference = "Stop"
    git clone --depth 1 https://github.com/YOUR_ORG/YOUR_REPO.git .
    git config user.email "codex-symphony@example.invalid"
    git config user.name "Codex Symphony"
    if (Test-Path -LiteralPath "package.json") {
      npm install
    }
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

You are working on a Linear issue through Symphony on Windows.

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

Instructions:

1. Work only in the current workspace.
2. If the issue is `Todo`, move it to `In Progress` before implementation.
3. Find or create exactly one Linear comment whose first line is `## Codex Workpad`.
4. Keep that workpad updated with plan, acceptance criteria, validation, commits, and blockers.
5. Reproduce or inspect the issue before changing code.
6. Make focused changes, run targeted validation, and commit the result.
7. For real repositories, push a branch and open or update a pull request when appropriate.
8. Move the issue to `Human Review` when it is ready for a person.
9. Move the issue to `Done` only when the workflow's completion criteria are satisfied.
10. Do not ask for human input unless a required secret, permission, or external system is missing.
11. For recovered transient failures, update only the `## Codex Workpad`; do not create extra comments.
12. For notable environment, validation, auth, dependency, or orchestration failures that change the
    plan or require operator attention, add one concise problem comment describing what failed, the
    command/subsystem involved, whether you recovered, and what to inspect next.
13. If a true blocker prevents completion, update the workpad and try to move the issue to
    `Blocked`. If the team has no `Blocked` state, record `Blocked state missing` and leave the
    issue in its active state unless a manager says otherwise.

Recommended workpad shape:

````md
## Codex Workpad

```text
<hostname>:<abs-workdir>@<short-sha>
```

### Plan

- [ ] ...

### Acceptance Criteria

- [ ] ...

### Validation

- [ ] ...

### Notes

- ...
````
