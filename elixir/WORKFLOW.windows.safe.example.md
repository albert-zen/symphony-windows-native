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
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
polling:
  interval_ms: 10000
workspace:
  # Use a dedicated automation root. Do not point this at a personal development checkout.
  root: "D:/code/symphony-safe-workspaces"
hooks:
  timeout_ms: 300000
  after_create: |
    $ErrorActionPreference = "Stop"
    git clone --depth 1 https://github.com/YOUR_ORG/YOUR_REPO.git .
    git config user.email "codex-symphony@example.invalid"
    git config user.name "Codex Symphony"
  before_remove: |
    $ErrorActionPreference = "Stop"
    git status --short
agent:
  max_concurrent_agents: 1
  max_turns: 10
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  # Reject Codex approval escalations in this safer profile. Commands that need broader
  # permission fail closed instead of widening access during an unattended run.
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write
  # turn_sandbox_policy is intentionally omitted. Symphony resolves it at runtime to a
  # workspaceWrite policy rooted at the current generated issue workspace with network disabled.
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
6. Make focused changes and run targeted validation.
7. Do not move the issue to review unless the configured validation has passed.
