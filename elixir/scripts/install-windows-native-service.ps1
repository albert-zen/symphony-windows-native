param(
  [string]$TaskName = "Symphony Windows Native",
  [string]$WorkflowPath = ".\WORKFLOW.windows.md",
  [int]$Port = 4011,
  [string]$LogsRoot = "$env:LOCALAPPDATA\Symphony\logs",
  [string]$PidFile = "",
  [string]$User = "$env:USERDOMAIN\$env:USERNAME",
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

function Resolve-SymphonyPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
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

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Removed scheduled task: $TaskName"
  exit 0
}

$scriptPath = Join-Path $PSScriptRoot "start-windows-native.ps1"
$WorkflowPath = Resolve-SymphonyPath $WorkflowPath
$LogsRoot = Resolve-SymphonyPath $LogsRoot

if (-not $PidFile) {
  $PidFile = Join-Path $LogsRoot "symphony.pid.json"
}

$PidFile = Resolve-SymphonyPath $PidFile

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Workflow file not found: $WorkflowPath"
}

New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null

$powerShell = (Get-Process -Id $PID).Path
$argumentList = @(
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

$action = New-ScheduledTaskAction -Execute $powerShell -Argument (Join-SymphonyArguments $argumentList) -WorkingDirectory (Split-Path -Parent $PSScriptRoot)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Installed scheduled task: $TaskName"
Write-Host "Start manually: Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Stop manually: .\scripts\stop-windows-native.ps1 -PidFile '$PidFile' -Force"
