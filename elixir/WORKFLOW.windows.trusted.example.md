---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "your-linear-project-slug"
  # Optional: restrict candidate dispatch to issues with any of these labels.
  # labels:
  #   - symphony-optimization
  dispatch_states:
    - Todo
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
  # This root is trusted by the workflow. Keep it dedicated to disposable Symphony workspaces.
  root: "D:/code/symphony-trusted-workspaces"
hooks:
  timeout_ms: 300000
  after_create: |
    $ErrorActionPreference = "Stop"
    $TrustedWorkspaceRoot = "D:/code/symphony-trusted-workspaces"
    $WorkspacePath = (Get-Location).Path
    $TrustedRootPath = (Resolve-Path -LiteralPath $TrustedWorkspaceRoot).Path.TrimEnd('\', '/')
    if (-not $WorkspacePath.StartsWith($TrustedRootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to trust workspace outside configured root: $WorkspacePath"
    }

    git clone --depth 1 https://github.com/YOUR_ORG/YOUR_REPO.git .
    git config user.email "codex-symphony@example.invalid"
    git config user.name "Codex Symphony"

    if ($WorkspacePath.Contains("'")) {
      throw "Codex project trust setup does not support single quotes in workspace paths: $WorkspacePath"
    }

    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }
    $CodexConfig = Join-Path $CodexHome "config.toml"
    New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
    if (-not (Test-Path -LiteralPath $CodexConfig)) {
      New-Item -ItemType File -Force -Path $CodexConfig | Out-Null
    }

    $ProjectHeader = "[projects.'$WorkspacePath']"
    $AlreadyTrusted = Select-String -LiteralPath $CodexConfig -SimpleMatch $ProjectHeader -Quiet
    if (-not $AlreadyTrusted) {
      Add-Content -LiteralPath $CodexConfig -Value ""
      Add-Content -LiteralPath $CodexConfig -Value $ProjectHeader
      Add-Content -LiteralPath $CodexConfig -Value 'trust_level = "trusted"'
    }

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
  # Trusted unattended automation: Codex will not ask for approval, and shell commands run
  # without sandboxing. Use only with a trusted repository, dedicated workspace root, and
  # credentials scoped for automation.
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  review_readiness_repository: YOUR_ORG/YOUR_REPO
  review_readiness_required_checks: []
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
4. Keep that workpad updated with plan, acceptance criteria, validation, commits, blockers, and PR links.
5. Reproduce or inspect the issue before changing code.
6. Make focused changes, run targeted validation, commit, push, and open or update a PR.
7. Do not move the issue to review while required checks are pending, failing, or unverifiable.
