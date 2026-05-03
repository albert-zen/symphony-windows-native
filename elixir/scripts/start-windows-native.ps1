param(
  [string]$WorkflowPath = "",
  [int]$Port = 4011,
  [string]$LogsRoot = "$env:LOCALAPPDATA\Symphony\logs",
  [string]$PidFile = "",
  [string]$Mise = "",
  [switch]$TerminalDashboard,
  [switch]$Background
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

function Resolve-SymphonyPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-SymphonyWorkflowPathDefault {
  param([string]$ResolvedLogsRoot)

  $defaultPath = Join-Path $ResolvedLogsRoot "symphony.workflow.json"

  if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
    try {
      $default = Get-Content -Raw -LiteralPath $defaultPath | ConvertFrom-Json

      if ($default.WorkflowPath) {
        return [string]$default.WorkflowPath
      }
    } catch {
      Write-Warning "Unable to read workflow default $defaultPath`: $($_.Exception.Message)"
    }
  }

  ".\WORKFLOW.windows.md"
}

function Test-SymphonyProcessAlive {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $false
  }

  try {
    $metadata = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if (-not $metadata.ProcessId) {
      return $false
    }

    return [bool](Get-Process -Id ([int]$metadata.ProcessId) -ErrorAction SilentlyContinue)
  } catch {
    return $false
  }
}

function Join-SymphonyArguments {
  param([string[]]$Arguments)

  ($Arguments | ForEach-Object {
    if ($_ -match "[\s`"]") {
      '"' + ($_.Replace('"', '\"')) + '"'
    } else {
      $_
    }
  }) -join " "
}

$LogsRoot = Resolve-SymphonyPath $LogsRoot

if (-not $PidFile) {
  $PidFile = Join-Path $LogsRoot "symphony.pid.json"
}

$PidFile = Resolve-SymphonyPath $PidFile

if (-not $WorkflowPath) {
  $WorkflowPath = Get-SymphonyWorkflowPathDefault $LogsRoot
}

$WorkflowPath = Resolve-SymphonyPath $WorkflowPath

if ($Background) {
  if (Test-SymphonyProcessAlive $PidFile) {
    throw "Symphony already appears to be running according to PID file: $PidFile"
  }

  New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PidFile) | Out-Null

  $stdoutPath = Join-Path $LogsRoot "symphony.stdout.log"
  $stderrPath = Join-Path $LogsRoot "symphony.stderr.log"
  $scriptPath = $PSCommandPath
  $pwsh = (Get-Process -Id $PID).Path
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $scriptPath,
    "-WorkflowPath",
    $WorkflowPath,
    "-Port",
    $Port,
    "-LogsRoot",
    $LogsRoot,
    "-PidFile",
    $PidFile
  )

  if ($Mise) {
    $arguments += @("-Mise", $Mise)
  }

  if ($TerminalDashboard) {
    $arguments += "-TerminalDashboard"
  }

  $process = Start-Process -FilePath $pwsh -ArgumentList (Join-SymphonyArguments $arguments) -WorkingDirectory (Get-Location).Path -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
  Write-Host "Symphony background launcher PID: $($process.Id)"
  Write-Host "PID metadata: $PidFile"
  Write-Host "Stdout: $stdoutPath"
  Write-Host "Stderr: $stderrPath"
  exit 0
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
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PidFile) | Out-Null

if (Test-SymphonyProcessAlive $PidFile) {
  throw "Symphony already appears to be running according to PID file: $PidFile"
}

$AuditLog = Join-Path $LogsRoot "log\symphony.log"
Write-Host "Symphony audit log: $AuditLog"
Write-Host "PID metadata: $PidFile"
Write-Host "Terminal dashboard: $(if ($TerminalDashboard) { 'enabled' } else { "disabled; open http://127.0.0.1:$Port/ or pass -TerminalDashboard" })"

$metadata = [ordered]@{
  ProcessId = $PID
  RuntimeProcessId = $null
  RuntimeStartedAt = $null
  StartedAt = (Get-Date).ToUniversalTime().ToString("o")
  WorkflowPath = $WorkflowPath
  LogsRoot = $LogsRoot
  Port = $Port
  RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
  ScriptPath = $PSCommandPath
  Kind = "symphony-windows-native"
}

$metadata | ConvertTo-Json | Set-Content -LiteralPath $PidFile -Encoding UTF8

try {
    & $Mise exec -- escript .\bin\symphony $WorkflowPath `
    --port $Port `
    --logs-root $LogsRoot `
    --pid-file $PidFile `
    --i-understand-that-this-will-be-running-without-the-usual-guardrails
} finally {
  if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
    try {
      $existing = Get-Content -Raw -LiteralPath $PidFile | ConvertFrom-Json
      if ([int]$existing.ProcessId -eq $PID) {
        Remove-Item -LiteralPath $PidFile -Force
      }
    } catch {
      Write-Warning "Unable to remove PID metadata $PidFile`: $($_.Exception.Message)"
    }
  }
}
