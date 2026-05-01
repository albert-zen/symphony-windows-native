param(
  [string]$WorkflowPath = ".\WORKFLOW.windows.md",
  [int]$Port = 4011,
  [string]$LogsRoot = "$env:LOCALAPPDATA\Symphony\logs",
  [string]$Mise = ""
)

$ErrorActionPreference = "Stop"

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

& $Mise exec -- escript .\bin\symphony $WorkflowPath `
  --port $Port `
  --logs-root $LogsRoot `
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
