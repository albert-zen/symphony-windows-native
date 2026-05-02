# Windows native Symphony

This guide documents a Windows-native path for running the Elixir reference
implementation of Symphony with Linear and Codex app-server.

It is intended for people who want to run Symphony directly in PowerShell
without WSL. The path is experimental, but the core local loop has been
validated on Windows:

1. Symphony polls a Linear project.
2. Symphony creates an isolated issue workspace.
3. A PowerShell `after_create` hook bootstraps the workspace.
4. Symphony starts `codex app-server` with clean stdio.
5. Codex updates the workspace and Linear issue.
6. Symphony stops the agent when the issue reaches a terminal state.

## What changed for Windows

The upstream prototype assumed a Unix shell in a few local-worker paths. This
branch adds a small host launcher:

- Local workspace hooks use PowerShell on Windows and `sh -lc` on Unix.
- Local Codex app-server startup avoids wrapping stdio in PowerShell or
  `cmd.exe`.
- Windows npm shims such as `codex.cmd` are resolved to
  `node.exe <codex.js> ...` before starting the port.
- Tests cover host shell selection, npm shim resolution, and stdio-preserving
  port startup.

This distinction matters because `codex app-server` speaks newline-delimited
JSON over stdio. Any wrapper that writes banners, warnings, prompts, or other
text onto stdio can make Symphony time out waiting for app-server responses.

## Requirements

- Windows 10/11
- PowerShell 5.1 or PowerShell 7
- Git
- Codex CLI logged in on the same Windows user account
- Node.js on `PATH`
- `mise` for Erlang/Elixir, or equivalent Erlang/Elixir installation
- A Linear personal API key stored in `LINEAR_API_KEY`

Install useful tooling:

```powershell
winget install --id Git.Git -e
winget install --id jdx.mise -e
winget install --id OpenJS.NodeJS.LTS -e
winget install --id GitHub.cli -e
```

Install and build Symphony:

```powershell
git clone https://github.com/albert-zen/symphony-windows-native.git
cd symphony-windows-native\elixir

mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
```

Set the Linear key in your user environment. Do not commit it to the repo.

```powershell
[Environment]::SetEnvironmentVariable("LINEAR_API_KEY", "YOUR_LINEAR_API_KEY", "User")
$env:LINEAR_API_KEY = [Environment]::GetEnvironmentVariable("LINEAR_API_KEY", "User")
```

Authenticate GitHub CLI for the same Windows user account that will run
Symphony:

```powershell
gh auth login
```

For day-to-day Windows-native work, `origin` should point at the repository you
intend agents to push branches and PRs to. If you also want to compare against
OpenAI's original prototype, keep that remote as `upstream`, not `origin`:

```powershell
git remote -v
git remote add upstream https://github.com/openai/symphony.git
git remote set-url --push upstream DISABLED
```

If you started from an OpenAI upstream clone and later moved to a Windows-native
fork, rename the remotes instead of leaving `origin` pointed at the upstream
prototype:

```powershell
git remote rename origin upstream
git remote add origin https://github.com/YOUR_GITHUB_OWNER/YOUR_REPO.git
git remote set-url --push upstream DISABLED
git fetch origin main
```

Manager-side stale-base checks should compare PR branches to `origin/main`
directly instead of assuming the local `main` branch tracks the canonical
remote.

## Configure a workflow

Start from the profile that matches the trust boundary for the run:

- `WORKFLOW.windows.safe.example.md`: recommended first-run profile. Codex runs with workspace-write
  thread sandboxing, approval escalations are rejected, and Symphony resolves each turn sandbox to
  the generated issue workspace with network access disabled.
- `WORKFLOW.windows.trusted.example.md`: unattended automation profile for trusted repositories and
  dedicated workspace roots. Codex runs with `approval_policy: never`, `danger-full-access`, and an
  explicit `dangerFullAccess` turn sandbox policy.
- `WORKFLOW.windows.example.md`: compact general example for adapting your own local policy.

For a safer first run:

```powershell
Copy-Item .\WORKFLOW.windows.safe.example.md .\WORKFLOW.windows.md
notepad .\WORKFLOW.windows.md
```

For trusted unattended automation:

```powershell
Copy-Item .\WORKFLOW.windows.trusted.example.md .\WORKFLOW.windows.md
notepad .\WORKFLOW.windows.md
```

You can still start from the compact example:

```powershell
Copy-Item .\WORKFLOW.windows.example.md .\WORKFLOW.windows.md
notepad .\WORKFLOW.windows.md
```

For the dedicated Symphony optimization flywheel, start from the fixed-project
example instead:

```powershell
Copy-Item .\WORKFLOW.optimization.windows.example.md .\WORKFLOW.optimization.windows.md
notepad .\WORKFLOW.optimization.windows.md
```

At minimum, change:

- `tracker.project_slug`
- `workspace.root`
- `hooks.after_create` clone URL
- the workflow prompt body to match your team's state flow

Use Windows paths in the YAML. Forward slashes are easiest:

```yaml
workspace:
  root: "D:/code/symphony-workspaces"
```

Keep secrets out of the workflow file:

```yaml
tracker:
  api_key: $LINEAR_API_KEY
```

### Choosing safe vs trusted profiles

The safe profile is intended for evaluating a repository or workflow prompt before giving an agent
broad local control. It still runs Symphony workspace hooks on the host, so inspect
`hooks.after_create` before starting the service, but Codex turns fail closed when they need
approval or access outside the generated issue workspace.

The trusted profile is for production-like automation after you trust all three boundaries:

- The Linear project only routes work you intend to automate.
- The repository cloned by `hooks.after_create` is trusted to contribute local `.codex` project
  configuration, hooks, and skills.
- `workspace.root` is a dedicated disposable automation directory, not a personal development
  checkout and not a directory shared with unrelated repositories.

The trusted profile includes a PowerShell trust step that writes a Codex project entry for the
current generated issue workspace after verifying that the workspace lives under the configured
trusted root. This avoids per-issue warnings such as `.codex` project configuration being disabled
for a newly generated workspace. If you change `workspace.root`, update the matching
`$TrustedWorkspaceRoot` value in `hooks.after_create`.

Do not add a broad trust entry for a drive root, home directory, or normal source tree. Trust only
the dedicated workspace root or the specific generated workspaces you are willing to let unattended
automation control.

## Run preflight

Before starting an unattended run, execute the Windows preflight from `elixir/`:

```powershell
mise exec -- mix symphony.preflight.windows .\WORKFLOW.windows.md
```

The command reports `PASS`, `WARN`, `FAIL`, or `SKIP` for each dependency and
exits non-zero when a required check fails. Warnings are operator-visible but do
not fail preflight. It verifies:

- `LINEAR_API_KEY` is available and Linear GraphQL is reachable.
- `git`, `gh`, `node`, and the configured Codex app-server command resolve on `PATH`.
- `gh auth status` succeeds for GitHub operations.
- After refreshing `origin/main`, the local checkout's `main` branch does not
  hide a newer canonical base behind a stale noncanonical remote.
- `codex app-server` can start without non-JSON startup output on stdio.
- The repository URL in `hooks.after_create` can be cloned by Git.
- `workspace.root` is writable.
- The configured dashboard port is available.
- PowerShell can parse configured workspace hooks.

If preflight reports the workspace root as writable but Codex later prints a
project trust warning for `.codex`, trust the configured `workspace.root` used
for Symphony issue workspaces. The workspace root should be a dedicated
automation directory, not your everyday development checkout.

If preflight prints `WARN` for `Git main remote`, update the manager checkout
or make stale-base checks explicit:

```powershell
git fetch origin main
git branch --set-upstream-to=origin/main main
git status --short --branch
```

When intentionally using a fork or mirror, make that repository `origin` for the
automation checkout. Keep other comparison sources as named remotes such as
`upstream`, and compare against their fully qualified refs only when that is the
explicit review target.

### Optimization flywheel routing

The optimization example is a fixed-project routing template. Replace
`YOUR_LINEAR_PROJECT_SLUG` with the slug for the Linear project you want
Symphony to poll. Keep `Backlog` out of `tracker.dispatch_states`; parked issues
remain invisible to Symphony until a human moves one issue at a time to `Todo`.

Keep the public example generic. Operator-specific project names, workspace
paths, and repository owners should live in a local workflow file such as
`WORKFLOW.optimization.windows.md`, which is ignored by git.

Use this fixed-project route as the default boundary. If the same Linear project
must later hold unrelated work, add `tracker.labels` to route only issues with
at least one configured label:

```yaml
tracker:
  project_slug: "YOUR_LINEAR_PROJECT_SLUG"
  labels:
    - symphony-optimization
  dispatch_states:
    - Todo
  active_states:
    - Todo
    - In Progress
```

The label match and `dispatch_states` apply only to candidate dispatch.
Already-running issues are still reconciled by `active_states` so Symphony keeps
valid workers alive after they move from `Todo` to `In Progress`, and stops them
cleanly when they move to a terminal state.

To find the right Linear values, use the Linear UI for the project slug when
possible, or query Linear GraphQL with your own API key. Do not commit API keys,
project-specific workflow files, or local runtime logs. When preparing a public
release, scan tracked files for obvious secrets and local markers before
pushing:

```powershell
$patterns = @('lin' + '_api_', 'github' + '_pat_', 'ghp_', 'YOUR_PRIVATE_WORKSPACE_MARKER')
git ls-files | ForEach-Object { Select-String -Path $_ -Pattern $patterns }
```

## Start Symphony

Use the helper script:

```powershell
.\scripts\start-windows-native.ps1 -WorkflowPath .\WORKFLOW.windows.md -Port 4011
```

The script writes PID metadata to `$env:LOCALAPPDATA\Symphony\logs\symphony.pid.json` by default.
Use `-Background` when you want the launcher to return after starting a hidden PowerShell process:

```powershell
.\scripts\start-windows-native.ps1 -WorkflowPath .\WORKFLOW.windows.md -Port 4011 -Background
```

Or run the escript directly:

```powershell
$env:LINEAR_API_KEY = [Environment]::GetEnvironmentVariable("LINEAR_API_KEY", "User")
mise exec -- escript .\bin\symphony .\WORKFLOW.windows.md --port 4011 --logs-root "$env:LOCALAPPDATA\Symphony\logs" --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Open the dashboard:

```text
http://127.0.0.1:4011/
```

## Stop Symphony

Stop a launcher started by `start-windows-native.ps1`:

```powershell
.\scripts\stop-windows-native.ps1 -Force
```

The stop script reads the PID metadata and verifies that the target command line is a
`start-windows-native.ps1` process before terminating that process tree. If the PID file is missing,
pass `-WorkflowPath` to locate a matching launcher process:

```powershell
.\scripts\stop-windows-native.ps1 -WorkflowPath .\WORKFLOW.windows.md -Force
```

Linear claim leases are also cleaned up as workers stop. If the host or runtime
exits before a release comment is written, the next runtime startup checks active
Linear claim comments before dispatch. A claim owned by the same Windows host is
released only when its recorded OS process ID is no longer alive; claims from
other hosts, malformed owners, or still-running local processes remain protected.
While another active lease is preserved, the issue appears in the dashboard
backoff queue with an `external_claim` reason instead of being shown as a local
running worker.

## Install a Windows long-running task

The recommended Windows-native long-running setup is Task Scheduler. It runs under the same
interactive Windows account that already has Codex, GitHub CLI, and `LINEAR_API_KEY` configured:

```powershell
.\scripts\install-windows-native-service.ps1 -WorkflowPath .\WORKFLOW.windows.md -Port 4011
Start-ScheduledTask -TaskName "Symphony Windows Native"
```

Remove the task with:

```powershell
.\scripts\install-windows-native-service.ps1 -Uninstall
```

This script intentionally installs a scheduled task rather than a Windows service wrapper. That keeps
the Codex and GitHub authentication context tied to the user account and avoids adding a service-host
dependency such as NSSM.

## Cleanup

Use the cleanup helper for explicit maintenance tasks:

```powershell
.\scripts\cleanup-windows-native.ps1 -WorkflowPath .\WORKFLOW.windows.md -IssueIdentifier ALB-11
.\scripts\cleanup-windows-native.ps1 -WorkflowPath .\WORKFLOW.windows.md -AllWorkspaces
.\scripts\cleanup-windows-native.ps1 -Logs
.\scripts\cleanup-windows-native.ps1 -BuildArtifacts
```

Cleanup refuses to treat the source checkout, a Git checkout, the current directory, the user profile,
or a drive root as a workspace/log root. Use `-WhatIf` to preview removals before deleting.

## Linear state flow

Symphony itself is a thin orchestrator. The workflow prompt tells the Codex
agent how to use Linear.

A practical flow is:

- `Backlog`: not picked up by Symphony.
- `Todo`: Symphony can pick this up. The agent should move it to `In Progress`.
- `In Progress`: the agent implements and validates.
- `Blocked`: the agent cannot complete because a required tool, auth grant,
  dependency, environment, or orchestration condition is missing. Add this state
  to the Linear team before enabling blocked-state transitions; if it is absent,
  agents must record `Blocked state missing` and leave the issue in its active
  state for a manager to triage.
- `Human Review`: the agent has created or updated a PR, required checks are passing, and review is
  requested or underway.
- `Rework`: the agent should handle reviewer feedback.
- `Merging`: the agent should run the repository's merge/land process.
- `Done`: terminal. Symphony stops the active agent.
- `Canceled`, `Cancelled`, `Duplicate`: terminal.

Set `tracker.dispatch_states` to the states Symphony should poll for new work,
`tracker.active_states` to the states where already-running agents remain valid,
and `tracker.terminal_states` to states where Symphony should stop.

## What each phase does

### Poll

Symphony queries Linear for issues in the configured project whose state is in
`dispatch_states`. If `tracker.labels` is configured, candidates must also have
at least one matching label.

### Claim and workspace

For each selected issue, Symphony creates a deterministic workspace directory
under `workspace.root`.

### Bootstrap

The local `hooks.after_create` command runs in that workspace. On Windows this
is PowerShell. Typical work:

- clone the target repository into `.`
- configure Git identity
- install project dependencies

### Agent run

Symphony starts `codex app-server` in the workspace and sends a prompt rendered
from the Linear issue. Codex receives the issue identifier, title, state, URL,
description, and labels.

The app-server session also exposes a `linear_graphql` dynamic tool so the
agent can update Linear comments and issue state without relying on a separate
MCP flow.

### Worker detail and steering

The observability dashboard links each running worker row to
`/workers/<issue-identifier>`. The detail page shows the issue identity, active
session id, workspace path, token totals, and a bounded timeline of recent Codex
app-server events. Timeline rows render a human-readable message first and keep
the sanitized payload in an expandable JSON panel for diagnosis. Symphony
redacts common secret keys, bearer/basic auth values, credential-bearing URLs,
and token-like query parameters before storing Codex event payloads in
orchestrator state or presenting them through the dashboard/API.

Managers can send a steer message from the detail page while the worker is
running. Symphony routes the message through the orchestrator to the worker task
that owns the Codex app-server port. The request is guarded twice: the dashboard
submits the current session id, and the app-server `turn/steer` request includes
the active `threadId` plus `expectedTurnId`. Symphony records queued and sent
steer messages in the worker timeline so later reviewers can see when a human
intervened.

If the dashboard is bound to a non-loopback host such as `0.0.0.0`, steering is
locked unless an operator token is configured with `observability.steer_token` or
the `SYMPHONY_STEER_TOKEN` environment variable. The token is required only for
steer submission; read-only dashboard and JSON views remain available.

### Review readiness

Agent-initiated moves to `In Review` are guarded by review readiness checks.
The tool only allows that transition when the issue has a linked GitHub PR and
the required checks on the PR head are complete and successful. If GitHub branch
protection metadata is private or unavailable to the Windows runtime, configure
`codex.review_readiness_repository` with the trusted `owner/repo` and
`codex.review_readiness_required_checks` with the required check names; the gate
then verifies those public PR check runs/statuses and still fails closed on
missing, pending, failing, or unverifiable results. Fallback required checks are
matched by check/status name because branch-protection app identity is not
available in that mode, so use the branch-protection source where app-bound
verification is required. Manager overrides must happen outside the agent tool
call and leave an audit note in Linear or GitHub.
The linked PR must come from Linear attachment metadata. Links written only in
agent-mutable comments, including the Codex Workpad, are useful for humans but
are not authoritative for the readiness gate. The linked PR must be in the
trusted repository and its head branch must include the Linear issue identifier
so an arbitrary green PR cannot satisfy another issue's readiness gate.

### Progress tracking

The recommended prompt pattern is to keep one persistent Linear comment whose
first line is:

```md
## Codex Workpad
```

The agent updates that comment with plan, acceptance criteria, validation
results, commits, blockers, and review status.

For routine failures that are recovered without changing the plan, the workpad is
enough. A separate Linear problem comment is reserved for notable environment,
validation, auth, dependency, or orchestration failures that changed the plan,
required a workaround, or need the next operator's attention. Keep each problem
comment concise and include:

- what failed,
- the command or subsystem involved,
- whether recovery succeeded,
- what the next operator should inspect.

If the run cannot complete because of a true blocker, the agent should update
the workpad, add the problem comment, and move the issue to `Blocked`. When the
team has not configured `Blocked`, the existing Linear adapter returns
`:state_not_found`; agents should record `Blocked state missing` and keep the
issue in `In Progress` unless a manager explicitly chooses another state.

### Completion

When the issue moves to a terminal state such as `Done`, Symphony stops the
active agent and runs `hooks.before_remove` before removing the workspace.
At startup, Symphony also queries terminal states and removes matching issue workspaces under the
configured `workspace.root`. The cleanup script above is for manual retention cleanup, log cleanup,
and operator-initiated workspace cleanup.

## Known Windows limitations

The local Windows loop is usable, but not every upstream Unix-oriented test
fixture has been ported yet.

- Fake `ssh` or `gh` scripts in tests often assume `#!/bin/sh` and `chmod`.
  Windows process launching and PATHEXT rules differ.
- Snapshot tests can differ because of CRLF line endings or terminal rendering.
- Some app-server tests use a Unix `fake-codex` script without a Windows
  executable wrapper.
- Remote SSH workers still assume a Unix shell on the remote host after
  `ssh.exe` connects.
- Windows symlink tests require developer mode or symlink privileges.

The important production path for local Windows workers is:

- PowerShell hooks
- direct Codex app-server process startup
- clean JSON-RPC stdio
- Linear issue state updates through `linear_graphql`

## Quality gates for Windows changes

Windows-native workers should start from the repository-level
[agent entrypoint playbook](../../AGENTS.md), then use this guide for detailed
runtime setup and troubleshooting.

Windows shell, workspace/config, workflow, or path-handling changes should run the focused native
profile:

```powershell
make windows-native-test
```

Agent PRs should also follow the [agent quality flywheel](agent-quality-flywheel.md): keep one
Linear workpad, use Conventional Commits, record validation in the PR body, and wait for required
GitHub checks before moving the Linear issue to review.
For the small-team manager and agent operating model, see the
[small-team agentic build flywheel playbook](small-team-agentic-flywheel.md).

## Troubleshooting

### `response_timeout` when starting Codex

Do not wrap `codex app-server` in a PowerShell script unless you are certain it
does not write anything to stdout/stderr before JSON-RPC begins. Prefer:

```yaml
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
```

### `codex.cmd` cannot be spawned

The Windows launcher resolves npm shims to Node. Make sure `node.exe` is on
`PATH`.

### Linear auth missing

Check:

```powershell
[bool][Environment]::GetEnvironmentVariable("LINEAR_API_KEY", "User")
```

Then restart the PowerShell session or set `$env:LINEAR_API_KEY` for the current
process.

### WSL fails with virtualization errors

This Windows-native path does not require WSL. If you prefer WSL2, enable CPU
virtualization in BIOS/UEFI first.

## Safety notes

- Use a dedicated Linear API key with the minimum permissions you need.
- Use a separate Codex profile or `CODEX_HOME` for unattended automation when
  possible.
- Never point `workspace.root` at your normal development checkout.
- Start with `agent.max_concurrent_agents: 1`.
- Keep `approval_policy: never` only for trusted repositories and trusted
  Linear projects.
