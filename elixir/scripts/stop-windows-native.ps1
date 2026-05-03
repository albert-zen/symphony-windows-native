param(
  [string]$PidFile = "$env:LOCALAPPDATA\Symphony\logs\symphony.pid.json",
  [string]$WorkflowPath = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$ProtectedProcessNames = @(
  "csrss",
  "wininit",
  "services",
  "lsass",
  "system",
  "idle"
)

$KnownChildProcessNames = @(
  "mise",
  "mise.exe",
  "escript",
  "escript.exe",
  "erl",
  "erl.exe",
  "inet_gethost",
  "inet_gethost.exe",
  "conhost",
  "conhost.exe"
)

function Resolve-SymphonyPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Normalize-SymphonyPathForMatch {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  (Resolve-SymphonyPath $Path).Replace("/", "\")
}

function Get-SymphonyProcessInfo {
  param([int]$ProcessId)

  Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
}

function Get-ProcessCommandLine {
  param([int]$ProcessId)

  $process = Get-SymphonyProcessInfo $ProcessId
  if ($process) {
    return [string]$process.CommandLine
  }

  return ""
}

function Test-CommandLineContains {
  param(
    [string]$CommandLine,
    [string]$Needle
  )

  if (-not $Needle) {
    return $true
  }

  if (-not $CommandLine) {
    return $false
  }

  return $CommandLine.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-CommandLineHasArgument {
  param(
    [string]$CommandLine,
    [string[]]$Names
  )

  if (-not $CommandLine) {
    return $false
  }

  foreach ($name in $Names) {
    $escapedName = [regex]::Escape($name)
    if ($CommandLine -match "(?i)(?:^|\s)$escapedName(?=\s|=|$)") {
      return $true
    }
  }

  return $false
}

function Test-CommandLineArgumentValue {
  param(
    [string]$CommandLine,
    [string[]]$Names,
    [string]$ExpectedValue
  )

  if (-not $ExpectedValue) {
    return $true
  }

  if (-not $CommandLine) {
    return $false
  }

  foreach ($name in $Names) {
    $escapedName = [regex]::Escape($name)
    $escapedValue = [regex]::Escape($ExpectedValue)
    $pattern = '(?i)(?:^|\s)' + $escapedName + '(?:\s+|=)(?:"' + $escapedValue + '"|''' + $escapedValue + '''|' + $escapedValue + ')(?=$|\s)'

    if ($CommandLine -match $pattern) {
      return $true
    }
  }

  return $false
}

function Test-OptionalCommandLineArgumentValue {
  param(
    [string]$CommandLine,
    [string[]]$Names,
    [string]$ExpectedValue
  )

  if (-not (Test-CommandLineHasArgument $CommandLine $Names)) {
    return $true
  }

  Test-CommandLineArgumentValue $CommandLine $Names $ExpectedValue
}

function Test-ProcessStartedNear {
  param(
    [object]$ProcessInfo,
    [string]$ExpectedStartedAt
  )

  if (-not $ExpectedStartedAt) {
    return $true
  }

  if (-not $ProcessInfo -or -not $ProcessInfo.CreationDate) {
    return $false
  }

  try {
    $actual = [System.Management.ManagementDateTimeConverter]::ToDateTime($ProcessInfo.CreationDate).ToUniversalTime()
    $expected = ([datetime]::Parse($ExpectedStartedAt)).ToUniversalTime()
    return [math]::Abs(($actual - $expected).TotalSeconds) -le 60
  } catch {
    return $false
  }
}

function Test-ProtectedProcess {
  param([object]$ProcessInfo)

  if (-not $ProcessInfo) {
    return $true
  }

  $name = [string]$ProcessInfo.Name
  if (-not $name) {
    return $true
  }

  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($name).ToLowerInvariant()
  return $ProtectedProcessNames -contains $baseName
}

function Test-SymphonyRuntimeProcess {
  param(
    [object]$ProcessInfo,
    [string]$ExpectedWorkflowPath,
    [string]$ExpectedLogsRoot,
    [int]$ExpectedPort
  )

  if (Test-ProtectedProcess $ProcessInfo) {
    return $false
  }

  $commandLine = [string]$ProcessInfo.CommandLine
  if (-not $commandLine) {
    return $false
  }

  $normalizedCommandLine = $commandLine.Replace("/", "\")
  $matchesBinary =
    (Test-CommandLineContains $normalizedCommandLine "bin\symphony") -or
    (Test-CommandLineContains $commandLine "bin/symphony")
  $matchesWorkflow = Test-CommandLineContains $normalizedCommandLine (Normalize-SymphonyPathForMatch $ExpectedWorkflowPath)
  $matchesLogs =
    (-not $ExpectedLogsRoot) -or
    (Test-CommandLineArgumentValue $normalizedCommandLine @("--logs-root") (Normalize-SymphonyPathForMatch $ExpectedLogsRoot))
  $matchesPort =
    ($ExpectedPort -le 0) -or
    (Test-CommandLineArgumentValue $commandLine @("--port") ([string]$ExpectedPort))

  return ($matchesBinary -and $matchesWorkflow -and $matchesLogs -and $matchesPort)
}

function Test-SymphonyWrapperProcess {
  param(
    [object]$ProcessInfo,
    [string]$ExpectedWorkflowPath,
    [string]$ExpectedLogsRoot,
    [int]$ExpectedPort,
    [string]$ExpectedStartedAt
  )

  if (Test-ProtectedProcess $ProcessInfo) {
    return $false
  }

  $commandLine = [string]$ProcessInfo.CommandLine
  if (-not $commandLine) {
    return $false
  }

  $normalizedCommandLine = $commandLine.Replace("/", "\")
  $matchesScript = Test-CommandLineContains $normalizedCommandLine "start-windows-native.ps1"
  $matchesWorkflow =
    (-not $ExpectedWorkflowPath) -or
    (Test-OptionalCommandLineArgumentValue $normalizedCommandLine @("-WorkflowPath") (Normalize-SymphonyPathForMatch $ExpectedWorkflowPath))
  $matchesLogs =
    (-not $ExpectedLogsRoot) -or
    (Test-OptionalCommandLineArgumentValue $normalizedCommandLine @("-LogsRoot") (Normalize-SymphonyPathForMatch $ExpectedLogsRoot))
  $matchesPort =
    ($ExpectedPort -le 0) -or
    (Test-OptionalCommandLineArgumentValue $commandLine @("-Port") ([string]$ExpectedPort))
  $matchesStart = Test-ProcessStartedNear $ProcessInfo $ExpectedStartedAt

  return ($matchesScript -and $matchesWorkflow -and $matchesLogs -and $matchesPort -and $matchesStart)
}

function Get-PortOwnerProcessId {
  param([int]$Port)

  if ($Port -le 0) {
    return $null
  }

  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    return $null
  }

  $connections =
    @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty OwningProcess -Unique)

  if ($connections.Count -gt 1) {
    throw "Multiple processes are listening on port ${Port}: $($connections -join ', ')"
  }

  if ($connections.Count -eq 1) {
    return [int]$connections[0]
  }

  return $null
}

function Stop-ValidatedProcess {
  param(
    [object]$ProcessInfo,
    [string]$Reason
  )

  if (-not $ProcessInfo) {
    return $false
  }

  if (Test-ProtectedProcess $ProcessInfo) {
    Write-Host "Skipped protected process pid=$($ProcessInfo.ProcessId) name=$($ProcessInfo.Name) reason=$Reason"
    return $false
  }

  $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction SilentlyContinue
  if (-not $process) {
    return $false
  }

  Stop-Process -Id ([int]$ProcessInfo.ProcessId) -Force:$Force
  Write-Host "Stopped $Reason pid=$($ProcessInfo.ProcessId) name=$($ProcessInfo.Name)"
  return $true
}

function Stop-KnownDirectChildren {
  param(
    [int]$ParentProcessId,
    [string]$ExpectedWorkflowPath,
    [string]$ExpectedLogsRoot,
    [int]$ExpectedPort,
    [string]$ExpectedStartedAt
  )

  if ($ParentProcessId -le 0) {
    return
  }

  $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentProcessId" -ErrorAction SilentlyContinue)

  foreach ($child in $children) {
    if (Test-ProtectedProcess $child) {
      Write-Host "Skipped protected child pid=$($child.ProcessId) name=$($child.Name)"
      continue
    }

    $name = ([string]$child.Name).ToLowerInvariant()
    if (-not ($KnownChildProcessNames -contains $name)) {
      Write-Host "Skipped child pid=$($child.ProcessId) name=$($child.Name) reason=unknown child executable"
      continue
    }

    $matchesRuntime = Test-SymphonyRuntimeProcess $child $ExpectedWorkflowPath $ExpectedLogsRoot $ExpectedPort
    $matchesWrapper = Test-SymphonyWrapperProcess $child $ExpectedWorkflowPath $ExpectedLogsRoot $ExpectedPort $ExpectedStartedAt
    $matchesParentChainHelper = $name -in @("conhost.exe", "conhost")

    if ($matchesRuntime -or $matchesWrapper -or $matchesParentChainHelper) {
      Stop-ValidatedProcess $child "known child"
    } else {
      Write-Host "Skipped child pid=$($child.ProcessId) name=$($child.Name) reason=command line mismatch"
    }
  }
}

$PidFile = Resolve-SymphonyPath $PidFile
$WorkflowPath = Resolve-SymphonyPath $WorkflowPath
$LogsRoot = ""
$Port = 0
$WrapperPid = $null
$RuntimePid = $null
$StartedAt = ""

if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
  $metadata = Get-Content -Raw -LiteralPath $PidFile | ConvertFrom-Json

  if ($metadata.Kind -ne "symphony-windows-native") {
    throw "PID file is not Symphony Windows-native metadata: $PidFile"
  }

  if ($metadata.ProcessId) {
    $WrapperPid = [int]$metadata.ProcessId
  }

  if ($metadata.RuntimeProcessId) {
    $RuntimePid = [int]$metadata.RuntimeProcessId
  }

  if (-not $WorkflowPath -and $metadata.WorkflowPath) {
    $WorkflowPath = Resolve-SymphonyPath $metadata.WorkflowPath
  }

  if ($metadata.LogsRoot) {
    $LogsRoot = Resolve-SymphonyPath $metadata.LogsRoot
  }

  if ($metadata.Port) {
    $Port = [int]$metadata.Port
  }

  if ($metadata.StartedAt) {
    $StartedAt = [string]$metadata.StartedAt
  }
}

$portOwnerPid = Get-PortOwnerProcessId $Port
if ($portOwnerPid) {
  $RuntimePid = $portOwnerPid
}

if (-not $RuntimePid -and -not $WrapperPid) {
  if (-not $WorkflowPath) {
    throw "No PID file found at $PidFile. Pass -WorkflowPath to locate a matching Symphony launcher process."
  }

  $candidates =
    @(Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%start-windows-native.ps1%'" |
      Where-Object {
        $_.CommandLine.IndexOf($WorkflowPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
      })

  if ($candidates.Count -gt 1) {
    throw "Multiple Symphony launcher processes match $WorkflowPath. Use -PidFile to stop a specific run."
  }

  if ($candidates.Count -eq 1) {
    $WrapperPid = [int]$candidates[0].ProcessId
  }
}

$stoppedAny = $false

if ($RuntimePid) {
  $runtime = Get-SymphonyProcessInfo $RuntimePid
  if (Test-SymphonyRuntimeProcess $runtime $WorkflowPath $LogsRoot $Port) {
    $stoppedAny = (Stop-ValidatedProcess $runtime "runtime port owner") -or $stoppedAny
  } elseif ($runtime) {
    throw "Refusing to stop PID $RuntimePid because it is not a matching Symphony runtime process."
  }
}

if ($WrapperPid) {
  $wrapper = Get-SymphonyProcessInfo $WrapperPid
  if (Test-SymphonyWrapperProcess $wrapper $WorkflowPath $LogsRoot $Port $StartedAt) {
    Stop-KnownDirectChildren -ParentProcessId $WrapperPid -ExpectedWorkflowPath $WorkflowPath -ExpectedLogsRoot $LogsRoot -ExpectedPort $Port -ExpectedStartedAt $StartedAt
    $stoppedAny = (Stop-ValidatedProcess $wrapper "wrapper") -or $stoppedAny
  } elseif ($wrapper) {
    if ($stoppedAny) {
      Write-Host "Skipped wrapper pid=$WrapperPid reason=command line mismatch after runtime stop"
    } else {
      throw "Refusing to stop PID $WrapperPid because it is not a matching start-windows-native.ps1 process."
    }
  }
}

if ($portOwnerPid) {
  $deadline = (Get-Date).AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 250
    $currentOwner = Get-PortOwnerProcessId $Port
  } while ($currentOwner -and (Get-Date) -lt $deadline)
}

if ($stoppedAny) {
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  Write-Host "Stopped Symphony Windows-native runtime."
} else {
  Write-Host "No matching Symphony Windows-native process is running."
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}
