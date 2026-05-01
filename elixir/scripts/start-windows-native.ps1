param(
  [string]$WorkflowPath = ".\WORKFLOW.windows.md",
  [int]$Port = 4011,
  [string]$LogsRoot = "$env:LOCALAPPDATA\Symphony\logs",
  [string]$Mise = "",
  [switch]$TerminalDashboard
)

$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8NoBom

try {
  [Console]::InputEncoding = $utf8NoBom
  [Console]::OutputEncoding = $utf8NoBom
} catch {
  Write-Warning "Unable to force console UTF-8 encoding: $($_.Exception.Message)"
}

if (Get-Command chcp.com -ErrorAction SilentlyContinue) {
  & chcp.com 65001 | Out-Null
}

if ($TerminalDashboard) {
  Remove-Item Env:\SYMPHONY_DISABLE_TERMINAL_DASHBOARD -ErrorAction SilentlyContinue
} else {
  $env:SYMPHONY_DISABLE_TERMINAL_DASHBOARD = "1"
}

if (-not $env:LINEAR_API_KEY) {
  $env:LINEAR_API_KEY = [Environment]::GetEnvironmentVariable("LINEAR_API_KEY", "User")
}

if (-not $env:LINEAR_API_KEY) {
  throw "LINEAR_API_KEY is not set. Store it in the user environment or set it for this PowerShell session."
}

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Workflow file not found: $WorkflowPath"
}

if (-not $Mise) {
  $miseCommand = Get-Command mise -ErrorAction SilentlyContinue
  if (-not $miseCommand) {
    throw "mise was not found on PATH. Install it with: winget install --id jdx.mise -e"
  }

  $Mise = $miseCommand.Source
}

New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null

$AuditLog = Join-Path $LogsRoot "log\symphony.log"
Write-Host "Symphony audit log: $AuditLog"
Write-Host "Terminal dashboard: $(if ($TerminalDashboard) { 'enabled' } else { "disabled; open http://127.0.0.1:$Port/ or pass -TerminalDashboard" })"

& $Mise exec -- escript .\bin\symphony $WorkflowPath `
  --port $Port `
  --logs-root $LogsRoot `
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
