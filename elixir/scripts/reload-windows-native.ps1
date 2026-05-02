param(
  [Parameter(Mandatory = $true)]
  [string]$RequestFile
)

$ErrorActionPreference = "Stop"

function Write-ReloadStatus {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Status,
    [string]$Message = "",
    [string]$Commit = ""
  )

  $payload = [ordered]@{
    request_id = $Request.request_id
    status = $Status
    message = $Message
    requested_at = $Request.requested_at
    updated_at = (Get-Date).ToUniversalTime().ToString("o")
    target_ref = $Request.target_ref
    current_commit = $Request.current_commit
    deployed_commit = $Commit
    repo_root = $Request.repo_root
    workflow_path = $Request.workflow_path
    log_file = $Request.log_file
  }

  $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Request.status_file -Encoding UTF8
}

function Write-ReloadLog {
  param([string]$Message)

  $line = "$(Get-Date -Format o) $Message"
  Add-Content -LiteralPath $Request.log_file -Value $line -Encoding UTF8
}

function Invoke-Logged {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [Parameter(Mandatory = $true)]
    [string[]]$ArgumentList,
    [string]$WorkingDirectory = $Request.repo_root
  )

  Write-ReloadLog "RUN $FilePath $($ArgumentList -join ' ')"
  Push-Location $WorkingDirectory
  try {
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }

  if ($output) {
    $output | ForEach-Object { Write-ReloadLog $_.ToString() }
  }

  if ($exitCode -ne 0) {
    throw "Command failed with exit code $exitCode`: $FilePath $($ArgumentList -join ' ')"
  }
}

function Test-Healthy {
  param(
    [int]$Port,
    [string]$ExpectedCommit
  )

  $url = "http://127.0.0.1:$Port/api/v1/state"

  for ($attempt = 1; $attempt -le 45; $attempt++) {
    try {
      $response = Invoke-RestMethod -Uri $url -TimeoutSec 3
      if ($response.runtime.commit -eq $ExpectedCommit) {
        return $true
      }

      Write-ReloadLog "Health attempt $attempt responded but commit was '$($response.runtime.commit)'."
    } catch {
      Write-ReloadLog "Health attempt $attempt failed: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 1
  }

  return $false
}

function Test-NoActiveWorkers {
  param([int]$Port)

  if ($Request.force) {
    Write-ReloadLog "Skipping final active-worker check because force=true."
    return
  }

  $url = "http://127.0.0.1:$Port/api/v1/state"

  try {
    $response = Invoke-RestMethod -Uri $url -TimeoutSec 5
  } catch {
    throw "Unable to inspect active workers before stopping runtime: $($_.Exception.Message)"
  }

  $running = @()
  if ($null -ne $response.running) {
    $running = @($response.running)
  }

  if ($running.Count -gt 0) {
    throw "Reload is blocked because $($running.Count) worker(s) became active before restart."
  }

  Write-ReloadLog "Final active-worker check passed."
}

$RequestFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RequestFile)
$Request = Get-Content -Raw -LiteralPath $RequestFile | ConvertFrom-Json
$PowerShellExe = (Get-Process -Id $PID).Path
$ElixirRoot = Join-Path $Request.repo_root "elixir"
$StopScript = Join-Path $ElixirRoot "scripts\stop-windows-native.ps1"
$StartScript = Join-Path $ElixirRoot "scripts\start-windows-native.ps1"
$TargetCheckedOut = $false
$RuntimeStopped = $false
$TargetCommit = ""

function Invoke-BuildRuntime {
  param([string]$Commit)

  Write-ReloadStatus -Status "running" -Message "Building runtime at $Commit." -Commit $Commit
  Invoke-Logged -FilePath "mise" -ArgumentList @("exec", "--", "mix", "deps.get") -WorkingDirectory $ElixirRoot
  Invoke-Logged -FilePath "mise" -ArgumentList @("exec", "--", "mix", "escript.build") -WorkingDirectory $ElixirRoot
}

function Stop-Runtime {
  Invoke-Logged -FilePath $PowerShellExe -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $StopScript,
    "-PidFile",
    $Request.pid_file,
    "-WorkflowPath",
    $Request.workflow_path,
    "-Force"
  )
}

function Start-Runtime {
  Invoke-Logged -FilePath $PowerShellExe -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $StartScript,
    "-WorkflowPath",
    $Request.workflow_path,
    "-Port",
    ([string]$Request.port),
    "-LogsRoot",
    $Request.logs_root,
    "-PidFile",
    $Request.pid_file,
    "-Background"
  ) -WorkingDirectory $ElixirRoot
}

function Restore-PreviousRuntime {
  param(
    [string]$FailureMessage,
    [bool]$RestartRuntime
  )

  if ([string]::IsNullOrWhiteSpace($Request.current_commit)) {
    Write-ReloadLog "Rollback skipped because current_commit was unavailable."
    return $false
  }

  try {
    Write-ReloadStatus -Status "rolling_back" -Message "Restoring previous runtime after failure." -Commit $Request.current_commit
    Write-ReloadLog "Attempting rollback to $($Request.current_commit) after failure: $FailureMessage"

    Invoke-Logged -FilePath "git" -ArgumentList @("-C", $Request.repo_root, "checkout", "--detach", $Request.current_commit)
    Invoke-BuildRuntime -Commit $Request.current_commit

    if ($RestartRuntime) {
      Write-ReloadLog "Restarting previous runtime for rollback."
      Stop-Runtime
      Start-Runtime

      if (-not (Test-Healthy -Port ([int]$Request.port) -ExpectedCommit $Request.current_commit)) {
        throw "Previous runtime did not become healthy with commit $($Request.current_commit)."
      }
    }

    Write-ReloadStatus -Status "failed" -Message "Reload failed; restored previous commit $($Request.current_commit): $FailureMessage" -Commit $Request.current_commit
    Write-ReloadLog "Rollback to $($Request.current_commit) completed."
    return $true
  } catch {
    Write-ReloadLog "ROLLBACK FAILED $($_.Exception.Message)"
    return $false
  }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Request.status_file) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Request.log_file) | Out-Null

try {
  Write-ReloadStatus -Status "queued" -Message "Reload helper started."
  Write-ReloadLog "Managed reload helper started for $($Request.target_ref)."

  if ($Request.delay_seconds -gt 0) {
    Start-Sleep -Seconds ([int]$Request.delay_seconds)
  }

  Write-ReloadStatus -Status "running" -Message "Checking repository status."

  $dirty = git -C $Request.repo_root status --porcelain
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect git status."
  }

  if ($dirty) {
    throw "Repository has uncommitted changes; refusing managed reload."
  }

  Write-ReloadStatus -Status "running" -Message "Fetching latest origin/main."
  Invoke-Logged -FilePath "git" -ArgumentList @("-C", $Request.repo_root, "fetch", "origin", "main")

  $TargetCommit = (& git -C $Request.repo_root rev-parse $Request.target_ref).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $TargetCommit) {
    throw "Unable to resolve $($Request.target_ref)."
  }

  Write-ReloadStatus -Status "running" -Message "Checking out $($Request.target_ref)." -Commit $TargetCommit
  Invoke-Logged -FilePath "git" -ArgumentList @("-C", $Request.repo_root, "checkout", "--detach", $Request.target_ref)
  $TargetCheckedOut = $true

  Invoke-BuildRuntime -Commit $TargetCommit

  Write-ReloadStatus -Status "running" -Message "Checking for active workers before restart." -Commit $TargetCommit
  Test-NoActiveWorkers -Port ([int]$Request.port)

  Write-ReloadStatus -Status "running" -Message "Stopping old runtime." -Commit $TargetCommit
  Stop-Runtime
  $RuntimeStopped = $true

  Write-ReloadStatus -Status "running" -Message "Starting updated runtime." -Commit $TargetCommit
  Start-Runtime

  if (-not (Test-Healthy -Port ([int]$Request.port) -ExpectedCommit $TargetCommit)) {
    throw "Updated runtime did not become healthy with commit $TargetCommit."
  }

  Write-ReloadStatus -Status "succeeded" -Message "Runtime is serving latest target commit." -Commit $TargetCommit
  Write-ReloadLog "Managed reload succeeded at $TargetCommit."
} catch {
  $failureMessage = $_.Exception.Message
  Write-ReloadLog "FAILED $failureMessage"

  if ($TargetCheckedOut -and (Restore-PreviousRuntime -FailureMessage $failureMessage -RestartRuntime $RuntimeStopped)) {
    exit 1
  }

  Write-ReloadStatus -Status "failed" -Message $failureMessage
  exit 1
}
