param(
  [string]$WorkflowPath = "",
  [string]$WorkspaceRoot = "",
  [string]$LogsRoot = "$env:LOCALAPPDATA\Symphony\logs",
  [string]$IssueIdentifier = "",
  [switch]$AllWorkspaces,
  [switch]$Logs,
  [switch]$BuildArtifacts,
  [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

function Resolve-SymphonyPath {
  param([string]$Path)

  if (-not $Path) {
    return ""
  }

  $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-SafeIssueIdentifier {
  param([string]$Identifier)

  $safeIdentifier = ($Identifier -replace "[^a-zA-Z0-9._-]", "_")

  if ($safeIdentifier -eq "." -or $safeIdentifier -eq "..") {
    throw "Refusing unsafe issue identifier: $Identifier"
  }

  return $safeIdentifier
}

function Resolve-EnvBackedValue {
  param([string]$Value)

  if ($Value -match '^\$([A-Za-z_][A-Za-z0-9_]*)$') {
    $resolved = [Environment]::GetEnvironmentVariable($Matches[1], "Process")
    if (-not $resolved) {
      $resolved = [Environment]::GetEnvironmentVariable($Matches[1], "User")
    }

    return $resolved
  }

  return $Value
}

function Get-WorkspaceRootFromWorkflow {
  param([string]$Path)

  if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }

  $lines = Get-Content -LiteralPath $Path
  $inWorkspace = $false

  foreach ($line in $lines) {
    if ($line -match "^\S") {
      $inWorkspace = $line -match "^workspace:\s*$"
      continue
    }

    if ($inWorkspace -and $line -match "^\s+root:\s*(.+?)\s*$") {
      return Resolve-EnvBackedValue $Matches[1].Trim().Trim("'").Trim('"')
    }
  }

  return ""
}

function Assert-SafeCleanupRoot {
  param(
    [string]$Path,
    [string]$Purpose,
    [switch]$AllowSourceCheckout
  )

  if (-not $Path) {
    throw "$Purpose path is required."
  }

  $resolved = Resolve-SymphonyPath $Path
  $driveRoot = [System.IO.Path]::GetPathRoot($resolved)

  if ($resolved.TrimEnd("\", "/") -eq $driveRoot.TrimEnd("\", "/")) {
    throw "Refusing to clean drive root for $Purpose`: $resolved"
  }

  $scriptCheckout = Resolve-SymphonyPath (Join-Path $PSScriptRoot "..")
  $current = Resolve-SymphonyPath "."

  $protectedPaths =
    if ($AllowSourceCheckout) {
      @($env:USERPROFILE)
    } else {
      @($scriptCheckout, $current, $env:USERPROFILE)
    }

  foreach ($protected in $protectedPaths) {
    if ($protected -and ($resolved.TrimEnd("\", "/") -ieq $protected.TrimEnd("\", "/"))) {
      throw "Refusing to clean protected $Purpose path: $resolved"
    }
  }

  if ((-not $AllowSourceCheckout) -and (Test-Path -LiteralPath (Join-Path $resolved ".git"))) {
    throw "Refusing to clean $Purpose because it looks like a Git checkout: $resolved"
  }

  if ((-not $AllowSourceCheckout) -and
      (Test-Path -LiteralPath (Join-Path $resolved "mix.exs")) -and
      (Test-Path -LiteralPath (Join-Path $resolved "scripts\start-windows-native.ps1"))) {
    throw "Refusing to clean $Purpose because it looks like the Symphony source checkout: $resolved"
  }

  return $resolved
}

function Assert-SafeCleanupTarget {
  param(
    [string]$Path,
    [string]$SafeRoot,
    [string]$Purpose
  )

  $resolved = Assert-SafeCleanupRoot -Path $Path -Purpose $Purpose
  $root = Resolve-SymphonyPath $SafeRoot
  $resolvedWithSlash = $resolved.Replace("\", "/").TrimEnd("/") + "/"
  $rootWithSlash = $root.Replace("\", "/").TrimEnd("/") + "/"

  if ($resolvedWithSlash -ieq $rootWithSlash) {
    throw "Refusing to clean $Purpose because it is the workspace root: $resolved"
  }

  if (-not $resolvedWithSlash.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean $Purpose outside workspace root: $resolved"
  }

  return $resolved
}

function Remove-SymphonyPath {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "Already absent: $Path"
    return
  }

  if ($WhatIf) {
    Write-Host "Would remove: $Path"
  } else {
    Remove-Item -LiteralPath $Path -Recurse -Force
    Write-Host "Removed: $Path"
  }
}

if (-not ($AllWorkspaces -or $IssueIdentifier -or $Logs -or $BuildArtifacts)) {
  throw "Choose at least one cleanup target: -IssueIdentifier, -AllWorkspaces, -Logs, or -BuildArtifacts."
}

if (-not $WorkspaceRoot -and $WorkflowPath) {
  $WorkspaceRoot = Get-WorkspaceRootFromWorkflow (Resolve-SymphonyPath $WorkflowPath)
}

if ($IssueIdentifier -or $AllWorkspaces) {
  $safeWorkspaceRoot = Assert-SafeCleanupRoot -Path $WorkspaceRoot -Purpose "workspace root"

  if ($IssueIdentifier) {
    $target = Assert-SafeCleanupTarget -Path (Join-Path $safeWorkspaceRoot (ConvertTo-SafeIssueIdentifier $IssueIdentifier)) -SafeRoot $safeWorkspaceRoot -Purpose "issue workspace"
    Remove-SymphonyPath $target
  } elseif ($AllWorkspaces) {
    Get-ChildItem -LiteralPath $safeWorkspaceRoot -Directory -Force | ForEach-Object {
      $target = Assert-SafeCleanupTarget -Path $_.FullName -SafeRoot $safeWorkspaceRoot -Purpose "workspace child"
      Remove-SymphonyPath $target
    }
  }
}

if ($Logs) {
  $safeLogsRoot = Assert-SafeCleanupRoot -Path $LogsRoot -Purpose "logs root"
  Remove-SymphonyPath $safeLogsRoot
}

if ($BuildArtifacts) {
  $sourceRoot = Assert-SafeCleanupRoot -Path (Join-Path $PSScriptRoot "..") -Purpose "build artifact root" -AllowSourceCheckout
  foreach ($relative in @("_build", "deps", "bin\symphony")) {
    Remove-SymphonyPath (Join-Path $sourceRoot $relative)
  }
}
