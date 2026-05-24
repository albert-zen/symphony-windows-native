param(
  [string]$WorkerWorkflowPath = ".\WORKFLOW.optimization.windows.md",
  [string]$ReviewerWorkflowPath = ".\WORKFLOW.optimization.reviewer.windows.md",
  [int]$WorkerPort = 4011,
  [int]$ReviewerPort = 4012,
  [string]$LogsRoot = "$env:LOCALAPPDATA\Symphony\agent-flywheel",
  [string]$Mise = "",
  [switch]$TerminalDashboard,
  [switch]$AllowPartial,
  [int]$StartupTimeoutSeconds = 60
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

function Resolve-AgentFlywheelPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  }

  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $BasePath $Path))
}

function Assert-AgentFlywheelFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Message`: $Path"
  }
}

function Get-AgentFlywheelProcessId {
  param([string]$PidFile)

  if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
    return $null
  }

  try {
    $metadata = Get-Content -Raw -LiteralPath $PidFile | ConvertFrom-Json
    if ($metadata.ProcessId) {
      return [int]$metadata.ProcessId
    }
  } catch {
    return $null
  }

  return $null
}

function Test-AgentFlywheelProcessAlive {
  param([string]$PidFile)

  $processId = Get-AgentFlywheelProcessId $PidFile
  if (-not $processId) {
    return $false
  }

  return [bool](Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

function Get-AgentFlywheelPortOwnerProcessId {
  param([int]$Port)

  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    return $null
  }

  $owners =
    @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty OwningProcess -Unique)

  if ($owners.Count -gt 1) {
    throw "Multiple processes are listening on port ${Port}: $($owners -join ', ')"
  }

  if ($owners.Count -eq 1) {
    return [int]$owners[0]
  }

  return $null
}

function Test-AgentFlywheelPortAvailable {
  param([int]$Port)

  -not (Get-AgentFlywheelPortOwnerProcessId $Port)
}

function Test-AgentFlywheelCanInspectPorts {
  [bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)
}

function Get-AgentFlywheelLastLogLine {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }

  try {
    $line =
      Get-Content -LiteralPath $Path -Tail 40 -ErrorAction Stop |
      Where-Object { $_ -and $_.Trim() } |
      Select-Object -Last 1

    return [string]$line
  } catch {
    return ""
  }
}

function Get-AgentFlywheelFailureReason {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$InstanceLogsRoot,

    [Parameter(Mandatory = $true)]
    [string]$Fallback
  )

  $stderrPath = Join-Path $InstanceLogsRoot "symphony.stderr.log"
  $stdoutPath = Join-Path $InstanceLogsRoot "symphony.stdout.log"
  $stderrLine = Get-AgentFlywheelLastLogLine $stderrPath

  if ($stderrLine) {
    return "$Name stderr: $stderrLine"
  }

  $stdoutLine = Get-AgentFlywheelLastLogLine $stdoutPath
  if ($stdoutLine) {
    return "$Name stdout: $stdoutLine"
  }

  return $Fallback
}

function Wait-AgentFlywheelInstance {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$InstanceLogsRoot,

    [Parameter(Mandatory = $true)]
    [string]$PidFile,

    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $sawPidFile = $false

  do {
    if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
      $sawPidFile = $true
      $processId = Get-AgentFlywheelProcessId $PidFile
      $process = $null

      if ($processId) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
      }

      if (-not $process) {
        $reason = Get-AgentFlywheelFailureReason $Name $InstanceLogsRoot "launcher process exited before port $Port became ready"
        throw $reason
      }

      if (Test-AgentFlywheelCanInspectPorts) {
        $portOwner = Get-AgentFlywheelPortOwnerProcessId $Port
        if ($portOwner) {
          return
        }
      } else {
        Write-Warning "Get-NetTCPConnection is unavailable; treating live $Name launcher PID $processId as started."
        return
      }
    }

    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)

  $fallback =
    if ($sawPidFile) {
      "timed out after ${TimeoutSeconds}s waiting for $Name port $Port to listen"
    } else {
      "timed out after ${TimeoutSeconds}s waiting for $Name PID metadata: $PidFile"
    }

  throw (Get-AgentFlywheelFailureReason $Name $InstanceLogsRoot $fallback)
}

function Start-AgentFlywheelInstance {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$WorkflowPath,

    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [string]$InstanceLogsRoot,

    [Parameter(Mandatory = $true)]
    [string]$PidFile,

    [Parameter(Mandatory = $true)]
    [string]$StartScript,

    [Parameter(Mandatory = $true)]
    [int]$StartupTimeoutSeconds,

    [string]$Mise,

    [switch]$TerminalDashboard
  )

  $arguments = @{
    WorkflowPath = $WorkflowPath
    Port = $Port
    LogsRoot = $InstanceLogsRoot
    PidFile = $PidFile
    Background = $true
  }

  if ($Mise) {
    $arguments.Mise = $Mise
  }

  if ($TerminalDashboard) {
    $arguments.TerminalDashboard = $true
  }

  Write-Host "Starting $Name Symphony instance..."
  & $StartScript @arguments
  Wait-AgentFlywheelInstance `
    -Name $Name `
    -InstanceLogsRoot $InstanceLogsRoot `
    -PidFile $PidFile `
    -Port $Port `
    -TimeoutSeconds $StartupTimeoutSeconds

  Write-Host "$Name dashboard: http://127.0.0.1:$Port/"
  Write-Host "$Name logs: $InstanceLogsRoot"
  Write-Host "$Name PID metadata: $PidFile"
}

function Invoke-AgentFlywheelStop {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$PidFile,

    [Parameter(Mandatory = $true)]
    [string]$StopScript
  )

  try {
    Write-Host "Stopping $Name Symphony instance..."
    & $StopScript -PidFile $PidFile -Force
    return $true
  } catch {
    Write-Warning "Unable to stop $Name instance: $($_.Exception.Message)"
    return $false
  }
}

function Write-AgentFlywheelStartupFailure {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Phase,

    [Parameter(Mandatory = $true)]
    [string]$Reason,

    [Parameter(Mandatory = $true)]
    [string]$WorkerLogsRoot,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerLogsRoot,

    [Parameter(Mandatory = $true)]
    [string]$WorkerCleanupStatus,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerCleanupStatus
  )

  Write-Host "Agent flywheel startup failed."
  Write-Host "Failure phase: $Phase"
  Write-Host "Failure reason: $Reason"
  Write-Host "Worker logs: $WorkerLogsRoot"
  Write-Host "Reviewer logs: $ReviewerLogsRoot"
  Write-Host "Worker cleanup: $WorkerCleanupStatus"
  Write-Host "Reviewer cleanup: $ReviewerCleanupStatus"
}

function Assert-AgentFlywheelPreflight {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StartScript,

    [Parameter(Mandatory = $true)]
    [string]$StopScript,

    [Parameter(Mandatory = $true)]
    [string]$WorkerWorkflowPath,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerWorkflowPath,

    [Parameter(Mandatory = $true)]
    [int]$WorkerPort,

    [Parameter(Mandatory = $true)]
    [int]$ReviewerPort,

    [Parameter(Mandatory = $true)]
    [string]$WorkerPidFile,

    [Parameter(Mandatory = $true)]
    [string]$ReviewerPidFile,

    [string]$Mise
  )

  if ($WorkerPort -eq $ReviewerPort) {
    throw "WorkerPort and ReviewerPort must be different."
  }

  if ($WorkerPort -le 0 -or $ReviewerPort -le 0) {
    throw "WorkerPort and ReviewerPort must be positive TCP ports."
  }

  Assert-AgentFlywheelFile $StartScript "Windows-native start script not found"
  Assert-AgentFlywheelFile $StopScript "Windows-native stop script not found"
  Assert-AgentFlywheelFile $WorkerWorkflowPath "Worker workflow file not found. Copy WORKFLOW.optimization.windows.example.md first"
  Assert-AgentFlywheelFile $ReviewerWorkflowPath "Reviewer workflow file not found. Copy WORKFLOW.optimization.reviewer.windows.example.md first"

  if (-not $env:LINEAR_API_KEY) {
    $env:LINEAR_API_KEY = [Environment]::GetEnvironmentVariable("LINEAR_API_KEY", "User")
  }

  if (-not $env:LINEAR_API_KEY) {
    throw "LINEAR_API_KEY is not set. Store it in the user environment or set it for this PowerShell session."
  }

  if ($Mise) {
    if ([System.IO.Path]::IsPathRooted($Mise) -or $Mise.Contains("\") -or $Mise.Contains("/")) {
      Assert-AgentFlywheelFile $Mise "mise executable not found"
    } elseif (-not (Get-Command $Mise -ErrorAction SilentlyContinue)) {
      throw "mise executable not found on PATH: $Mise"
    }
  } elseif (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    throw "mise was not found on PATH. Install it with: winget install --id jdx.mise -e"
  }

  if (Test-AgentFlywheelProcessAlive $WorkerPidFile) {
    throw "Worker PID file points at a running process: $WorkerPidFile"
  }

  if (Test-AgentFlywheelProcessAlive $ReviewerPidFile) {
    throw "Reviewer PID file points at a running process: $ReviewerPidFile"
  }

  if (-not (Test-AgentFlywheelPortAvailable $WorkerPort)) {
    $owner = Get-AgentFlywheelPortOwnerProcessId $WorkerPort
    throw "Worker port $WorkerPort is already in use by PID $owner."
  }

  if (-not (Test-AgentFlywheelPortAvailable $ReviewerPort)) {
    $owner = Get-AgentFlywheelPortOwnerProcessId $ReviewerPort
    throw "Reviewer port $ReviewerPort is already in use by PID $owner."
  }
}

# Entry point.
if ($WorkerPort -eq $ReviewerPort) {
  throw "WorkerPort and ReviewerPort must be different."
}

$scriptDir = Split-Path -Parent $PSCommandPath
$elixirRoot = Split-Path -Parent $scriptDir
$startScript = Join-Path $scriptDir "start-windows-native.ps1"
$stopScript = Join-Path $scriptDir "stop-windows-native.ps1"
$resolvedLogsRoot = Resolve-AgentFlywheelPath $LogsRoot $elixirRoot
$resolvedWorkerWorkflowPath = Resolve-AgentFlywheelPath $WorkerWorkflowPath $elixirRoot
$resolvedReviewerWorkflowPath = Resolve-AgentFlywheelPath $ReviewerWorkflowPath $elixirRoot
$workerLogsRoot = Join-Path $resolvedLogsRoot "worker"
$reviewerLogsRoot = Join-Path $resolvedLogsRoot "reviewer"
$workerPidFile = Join-Path $resolvedLogsRoot "symphony.worker.pid.json"
$reviewerPidFile = Join-Path $resolvedLogsRoot "symphony.reviewer.pid.json"

Assert-AgentFlywheelPreflight `
  -StartScript $startScript `
  -StopScript $stopScript `
  -WorkerWorkflowPath $resolvedWorkerWorkflowPath `
  -ReviewerWorkflowPath $resolvedReviewerWorkflowPath `
  -WorkerPort $WorkerPort `
  -ReviewerPort $ReviewerPort `
  -WorkerPidFile $workerPidFile `
  -ReviewerPidFile $reviewerPidFile `
  -Mise $Mise

New-Item -ItemType Directory -Force -Path $resolvedLogsRoot | Out-Null

$workerStarted = $false
$reviewerStarted = $false

Push-Location $elixirRoot
try {
  $workerInstance = @{
    Name = "worker"
    WorkflowPath = $resolvedWorkerWorkflowPath
    Port = $WorkerPort
    InstanceLogsRoot = $workerLogsRoot
    PidFile = $workerPidFile
    StartScript = $startScript
    StartupTimeoutSeconds = $StartupTimeoutSeconds
    Mise = $Mise
    TerminalDashboard = $TerminalDashboard
  }

  Start-AgentFlywheelInstance @workerInstance
  $workerStarted = $true

  $reviewerInstance = @{
    Name = "reviewer"
    WorkflowPath = $resolvedReviewerWorkflowPath
    Port = $ReviewerPort
    InstanceLogsRoot = $reviewerLogsRoot
    PidFile = $reviewerPidFile
    StartScript = $startScript
    StartupTimeoutSeconds = $StartupTimeoutSeconds
    Mise = $Mise
    TerminalDashboard = $TerminalDashboard
  }

  Start-AgentFlywheelInstance @reviewerInstance
  $reviewerStarted = $true
} catch {
  $phase = if ($workerStarted) { "reviewer startup" } else { "worker startup" }
  $reason = $_.Exception.Message
  $workerCleanupStatus = if ($workerStarted) { "not attempted" } else { "not needed" }
  $reviewerCleanupStatus = if ($reviewerStarted) { "not attempted" } else { "not needed" }

  if ($phase -eq "reviewer startup") {
    $reviewerCleaned = Invoke-AgentFlywheelStop -Name "reviewer" -PidFile $reviewerPidFile -StopScript $stopScript
    $reviewerCleanupStatus = if ($reviewerCleaned) { "completed" } else { "failed or not running" }

    if ($AllowPartial) {
      $workerCleanupStatus = "skipped by -AllowPartial"
      Write-AgentFlywheelStartupFailure `
        -Phase $phase `
        -Reason $reason `
        -WorkerLogsRoot $workerLogsRoot `
        -ReviewerLogsRoot $reviewerLogsRoot `
        -WorkerCleanupStatus $workerCleanupStatus `
        -ReviewerCleanupStatus $reviewerCleanupStatus
      Write-Warning "Partial startup: worker instance is still running; reviewer failed."
      return
    }

    $workerCleaned = Invoke-AgentFlywheelStop -Name "worker" -PidFile $workerPidFile -StopScript $stopScript
    $workerCleanupStatus = if ($workerCleaned) { "completed" } else { "failed or not running" }
  } else {
    $workerCleaned = Invoke-AgentFlywheelStop -Name "worker" -PidFile $workerPidFile -StopScript $stopScript
    $workerCleanupStatus = if ($workerCleaned) { "completed" } else { "failed or not running" }
  }

  Write-AgentFlywheelStartupFailure `
    -Phase $phase `
    -Reason $reason `
    -WorkerLogsRoot $workerLogsRoot `
    -ReviewerLogsRoot $reviewerLogsRoot `
    -WorkerCleanupStatus $workerCleanupStatus `
    -ReviewerCleanupStatus $reviewerCleanupStatus

  throw "Agent flywheel startup failed during $phase`: $reason"
} finally {
  Pop-Location
}

Write-Host "Agent flywheel started."
Write-Host "Worker:   http://127.0.0.1:$WorkerPort/"
Write-Host "Reviewer: http://127.0.0.1:$ReviewerPort/"
