param(
  [string]$PidFile = "$env:LOCALAPPDATA\Symphony\logs\symphony.pid.json",
  [string]$WorkflowPath = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Resolve-SymphonyPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-ProcessCommandLine {
  param([int]$ProcessId)

  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  if ($process) {
    return $process.CommandLine
  }

  return ""
}

function Test-OwnedSymphonyProcess {
  param(
    [int]$ProcessId,
    [string]$ExpectedWorkflowPath
  )

  $commandLine = Get-ProcessCommandLine $ProcessId

  if (-not $commandLine) {
    return $false
  }

  $matchesScript = $commandLine -like "*start-windows-native.ps1*"
  $matchesWorkflow = (-not $ExpectedWorkflowPath) -or
    ($commandLine.IndexOf($ExpectedWorkflowPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)

  return ($matchesScript -and $matchesWorkflow)
}

function Stop-ProcessTree {
  param([int]$RootProcessId)

  $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $RootProcessId" -ErrorAction SilentlyContinue
  foreach ($child in $children) {
    Stop-ProcessTree -RootProcessId ([int]$child.ProcessId)
  }

  $process = Get-Process -Id $RootProcessId -ErrorAction SilentlyContinue
  if ($process) {
    Stop-Process -Id $RootProcessId -Force:$Force
  }
}

$PidFile = Resolve-SymphonyPath $PidFile
$WorkflowPath = Resolve-SymphonyPath $WorkflowPath
$targetPid = $null

if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
  $metadata = Get-Content -Raw -LiteralPath $PidFile | ConvertFrom-Json

  if ($metadata.Kind -ne "symphony-windows-native") {
    throw "PID file is not Symphony Windows-native metadata: $PidFile"
  }

  $targetPid = [int]$metadata.ProcessId

  if (-not $WorkflowPath -and $metadata.WorkflowPath) {
    $WorkflowPath = Resolve-SymphonyPath $metadata.WorkflowPath
  }
}

if (-not $targetPid) {
  if (-not $WorkflowPath) {
    throw "No PID file found at $PidFile. Pass -WorkflowPath to locate a matching Symphony launcher process."
  }

  $candidates =
    @(Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%start-windows-native.ps1%'" |
      Where-Object { $_.CommandLine.IndexOf($WorkflowPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })

  if ($candidates.Count -gt 1) {
    throw "Multiple Symphony launcher processes match $WorkflowPath. Use -PidFile to stop a specific run."
  }

  if ($candidates.Count -eq 1) {
    $targetPid = [int]$candidates[0].ProcessId
  }
}

if (-not $targetPid) {
  Write-Host "No matching Symphony Windows-native process is running."
  exit 0
}

if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
  Write-Host "Symphony process $targetPid is not running."
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  exit 0
}

if (-not (Test-OwnedSymphonyProcess -ProcessId $targetPid -ExpectedWorkflowPath $WorkflowPath)) {
  throw "Refusing to stop PID $targetPid because it is not a matching start-windows-native.ps1 process."
}

Stop-ProcessTree -RootProcessId $targetPid
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
Write-Host "Stopped Symphony Windows-native process tree rooted at PID $targetPid."
