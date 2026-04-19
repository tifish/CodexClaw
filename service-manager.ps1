[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('install', 'stop', 'restart', 'uninstall')]
  [string]$Action
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ServiceName = 'CodexClaw'
$RepoRoot = Split-Path -Parent $PSCommandPath
$AppEntry = Join-Path $RepoRoot 'node_modules\tsx\dist\cli.mjs'
$AppParameters = 'src\index.ts'
$LogDir = Join-Path $RepoRoot 'logs'
$StdoutLog = Join-Path $LogDir 'service.out.log'
$StderrLog = Join-Path $LogDir 'service.err.log'
$ServiceUsername = $env:CODEXCLAW_SERVICE_USERNAME
$ServicePassword = $env:CODEXCLAW_SERVICE_PASSWORD

function Fail {
  param([string]$Message)

  Write-Host "[ERROR] $Message"
  exit 1
}

function Write-Section {
  param([string]$Message)

  Write-Host $Message
}

function Invoke-SelfElevation {
  <#
    .SYNOPSIS
      Relaunches the calling script with administrator privileges via UAC,
      waits for the elevated process to exit, and propagates its exit code.
      Returns silently when the current session is already elevated.

    .DESCRIPTION
      Locates the outermost script frame on the call stack so callers can
      invoke it from any nesting level (including conditionally after other
      logic). Uses Win32 CommandLineToArgvW-compliant quoting to preserve
      the original parameters across the UAC boundary.
    #>
  if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    return
  }

  # The outermost frame with a ScriptName is the entry script of this process.
  $EntryFrame = Get-PSCallStack | Where-Object { $_.ScriptName } | Select-Object -Last 1
  if (-not $EntryFrame) {
    throw "Invoke-SelfElevation must be called from a script file."
  }
  $ScriptPath = $EntryFrame.ScriptName
  $BoundParameters = $EntryFrame.InvocationInfo.BoundParameters
  $UnboundArguments = $EntryFrame.InvocationInfo.UnboundArguments

  # Win32 CommandLineToArgvW-compliant quoting for a single argument.
  $EscapeArg = { param($Value)
    if ($null -eq $Value -or $Value -eq '' -or $Value -match '[\s"]') {
      '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    else { $Value }
  }

  $ForwardedArgs = @()
  foreach ($ParamName in $BoundParameters.Keys) {
    $ParamValue = $BoundParameters[$ParamName]
    if ($ParamValue -is [switch]) {
      if ($ParamValue.IsPresent) { $ForwardedArgs += "-$ParamName" }
    }
    else {
      $ForwardedArgs += "-$ParamName", [string]$ParamValue
    }
  }
  if ($UnboundArguments) {
    $ForwardedArgs += $UnboundArguments | ForEach-Object { [string]$_ }
  }

  $CommandLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ForwardedArgs |
    ForEach-Object { & $EscapeArg $_ }) -join ' '

  $ElevatedProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
    -ArgumentList $CommandLine `
    -Verb RunAs `
    -WorkingDirectory (Get-Location).ProviderPath `
    -PassThru
  $ElevatedProcess.WaitForExit()
  exit $ElevatedProcess.ExitCode
}

function Resolve-NssmPath {
  $localNssm = Join-Path $RepoRoot 'nssm.exe'
  if (Test-Path $localNssm) {
    return $localNssm
  }

  $command = Get-Command nssm.exe -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    $command = Get-Command nssm -ErrorAction SilentlyContinue
  }

  if ($null -eq $command) {
    Fail 'nssm was not found. Put nssm.exe next to this script or add nssm to PATH.'
  }

  return $command.Source
}

function Resolve-NodePath {
  try {
    $nodePath = (& node -p "process.execPath" 2>$null | Select-Object -First 1).Trim()
  }
  catch {
    $nodePath = $null
  }

  if ([string]::IsNullOrWhiteSpace($nodePath)) {
    Fail 'Failed to resolve the real node.exe path. Ensure Node.js is installed and node is available in PATH.'
  }

  if (-not (Test-Path $nodePath)) {
    Fail "node.exe resolved path does not exist: $nodePath"
  }

  return $nodePath
}

function Get-ServiceObject {
  Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

function Get-ServiceStatus {
  $service = Get-ServiceObject
  if ($null -eq $service) {
    return $null
  }

  $service.Refresh()
  return $service.Status
}

function Ensure-ServiceExists {
  if ($null -eq (Get-ServiceObject)) {
    Fail "Service `"$ServiceName`" does not exist."
  }
}

function Resolve-ServiceLogonConfiguration {
  $username = [string]$ServiceUsername
  $password = [string]$ServicePassword

  if ([string]::IsNullOrWhiteSpace($username)) {
    Write-Host 'Service logon account'
    Write-Host '  Enter a Windows user account such as COMPUTERNAME\Username.'
    $username = Read-Host 'Username'
  }

  if ([string]::IsNullOrWhiteSpace($username)) {
    Fail 'A Windows user account is required for the service logon.'
  }

  $trimmedUsername = $username.Trim()
  $builtInAccounts = @(
    'LocalSystem',
    'NT AUTHORITY\LocalService',
    'NT AUTHORITY\NetworkService'
  )

  if ($builtInAccounts -contains $trimmedUsername) {
    Fail 'Built-in service accounts are not supported here. Provide a regular Windows user account and password.'
  }

  if ([string]::IsNullOrWhiteSpace($password)) {
    $securePassword = Read-Host 'Password' -AsSecureString
    if ($null -eq $securePassword) {
      Fail 'A password is required for the specified service account.'
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
      $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }

  if ([string]::IsNullOrWhiteSpace($password)) {
    Fail 'A password is required for the specified service account.'
  }

  return @{
    Username = $trimmedUsername
    Password = $password
  }
}

function Invoke-Nssm {
  param(
    [string[]]$Arguments,
    [string]$ErrorMessage
  )

  & $script:NssmExe @Arguments *> $null
  if ($LASTEXITCODE -ne 0) {
    Fail $ErrorMessage
  }
}

function Wait-ForStatus {
  param(
    [System.ServiceProcess.ServiceControllerStatus]$DesiredStatus,
    [int]$TimeoutSeconds = 15
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $service = $null
  do {
    $service = Get-ServiceObject
    if ($null -eq $service) {
      break
    }

    $service.Refresh()
    if ($service.Status -eq $DesiredStatus) {
      return
    }

    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)

  $currentStatus = if ($null -eq $service) { 'Missing' } else { $service.Status }
  Fail "Service `"$ServiceName`" did not reach $DesiredStatus. Current status: $currentStatus."
}

function Show-Status {
  $status = Get-ServiceStatus
  Write-Host 'Status:'
  if ($null -eq $status) {
    Write-Host '  missing'
    return
  }

  Write-Host "  $status"
}

function Ensure-AppEntry {
  if (-not (Test-Path $AppEntry)) {
    Fail "App entry was not found: $AppEntry. Run setup.cmd or npm install first."
  }
}

function Ensure-LogDirectory {
  if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
  }
}

function Set-NssmParameter {
  param(
    [string]$Name,
    [string]$Value
  )

  Invoke-Nssm -Arguments @('set', $ServiceName, $Name, $Value) -ErrorMessage "Failed to set $Name for service `"$ServiceName`"."
}

function Set-ServiceLogonAccount {
  param([hashtable]$CredentialConfig)

  Invoke-Nssm -Arguments @(
    'set',
    $ServiceName,
    'ObjectName',
    [string]$CredentialConfig.Username,
    [string]$CredentialConfig.Password
  ) -ErrorMessage "Failed to set logon account for service `"$ServiceName`"."

  Write-Host "Service logon account:"
  Write-Host "  $($CredentialConfig.Username)"
}

function Start-ServiceInternal {
  if ((Get-ServiceStatus) -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
    Write-Section "Service `"$ServiceName`" is already running."
    return
  }

  Write-Section "Starting service `"$ServiceName`"..."
  Invoke-Nssm -Arguments @('start', $ServiceName) -ErrorMessage "Failed to start service `"$ServiceName`"."
  Wait-ForStatus -DesiredStatus Running
}

function Stop-ServiceInternal {
  param(
    [switch]$IgnoreErrors,
    [int]$TimeoutSeconds = 15
  )

  $status = Get-ServiceStatus
  if ($null -eq $status) {
    if ($IgnoreErrors) {
      return
    }

    Fail "Service `"$ServiceName`" does not exist."
  }

  if ($status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    return
  }

  if ($IgnoreErrors) {
    & $script:NssmExe stop $ServiceName *> $null
  }
  else {
    Invoke-Nssm -Arguments @('stop', $ServiceName) -ErrorMessage "Failed to stop service `"$ServiceName`"."
  }

  try {
    Wait-ForStatus -DesiredStatus Stopped -TimeoutSeconds $TimeoutSeconds
  }
  catch {
    if (-not $IgnoreErrors) {
      throw
    }
  }
}

function Install-Service {
  $nodeExe = Resolve-NodePath
  $serviceCredential = Resolve-ServiceLogonConfiguration
  Ensure-AppEntry
  Ensure-LogDirectory

  if ($null -eq (Get-ServiceObject)) {
    Write-Section "Installing service `"$ServiceName`"..."
    Invoke-Nssm -Arguments @('install', $ServiceName, $nodeExe) -ErrorMessage 'Failed to install service.'
  }
  else {
    Write-Section "Service `"$ServiceName`" already exists. Updating configuration..."
  }

  $settings = [ordered]@{
    AppDirectory    = $RepoRoot
    Application     = $nodeExe
    AppParameters   = "`"$AppEntry`" $AppParameters"
    AppStdout       = $StdoutLog
    AppStderr       = $StderrLog
    AppRotateFiles  = '1'
    AppRotateOnline = '1'
    Start           = 'SERVICE_AUTO_START'
  }

  foreach ($setting in $settings.GetEnumerator()) {
    Set-NssmParameter -Name $setting.Key -Value $setting.Value
  }

  Set-ServiceLogonAccount -CredentialConfig $serviceCredential

  Start-ServiceInternal

  Write-Host 'Service is configured.'
  Write-Host 'Name:'
  Write-Host "  $ServiceName"
  Write-Host 'Startup:'
  Write-Host '  automatic'
  Write-Host 'Start command:'
  Write-Host "  `"$nodeExe`" `"$AppEntry`" $AppParameters"
  Write-Host 'Logs:'
  Write-Host "  $StdoutLog"
  Write-Host "  $StderrLog"
  Show-Status
}

function Stop-ServiceAction {
  Ensure-ServiceExists

  if ((Get-ServiceStatus) -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    Write-Section "Service `"$ServiceName`" is already stopped."
    Show-Status
    return
  }

  Write-Section "Stopping service `"$ServiceName`"..."
  Stop-ServiceInternal
  Show-Status
}

function Restart-ServiceAction {
  Ensure-ServiceExists

  Write-Section "Restarting service `"$ServiceName`"..."
  if ((Get-ServiceStatus) -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
    Stop-ServiceInternal
  }

  Start-ServiceInternal
  Show-Status
}

function Uninstall-ServiceAction {
  Ensure-ServiceExists

  Write-Section "Stopping service `"$ServiceName`"..."
  Stop-ServiceInternal -IgnoreErrors -TimeoutSeconds 10

  Write-Section "Removing service `"$ServiceName`"..."
  Invoke-Nssm -Arguments @('remove', $ServiceName, 'confirm') -ErrorMessage 'Failed to remove service.'
  Write-Section 'Service removed.'
}

Invoke-SelfElevation
$script:NssmExe = Resolve-NssmPath

switch ($Action) {
  'install' { Install-Service }
  'stop' { Stop-ServiceAction }
  'restart' { Restart-ServiceAction }
  'uninstall' { Uninstall-ServiceAction }
  default { Fail "Unsupported action: $Action" }
}

exit 0
