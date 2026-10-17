#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Block network access for all Sogou Pinyin executable components.

.DESCRIPTION
    Creates idempotent Windows Firewall rules for every .exe found below the
    installed Sogou Input Method directories, including old versions and the
    Windows IME broker directory. A SYSTEM monitor also terminates a Sogou
    process as soon as it opens a TCP connection, including connections to a
    local HTTP/SOCKS/VPN proxy. This is required because Windows Firewall does
    not reliably filter per-program loopback connections.

    The script installs itself under C:\ProgramData\SogouNetworkBlock and
    registers a SYSTEM scheduled task that reapplies the rules and keeps the
    monitor running at startup and at logon. It does not modify Sogou files or
    registry settings.

.PARAMETER Mode
    Install, Apply, Monitor, Status, or Uninstall. Install is the default.
#>

param(
    [ValidateSet('Install', 'Apply', 'Monitor', 'Status', 'Uninstall')]
    [string] $Mode = 'Install'
)

$ErrorActionPreference = 'Stop'

$script:GroupName = 'SogouNetworkBlock'
$script:TaskName = 'Sogou Network Block - Reapply Firewall Rules'
$script:InstallDir = Join-Path $env:ProgramData 'SogouNetworkBlock'
$script:InstalledScript = Join-Path $script:InstallDir 'SogouNetworkBlock.ps1'
$script:StateFile = Join-Path $script:InstallDir 'firewall-profile-state.json'
$script:LogFile = Join-Path $script:InstallDir 'activity.log'

function Write-Log {
    param([string] $Message)

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $line
    try {
        if (Test-Path -LiteralPath $script:InstallDir) {
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        }
    }
    catch {
        # Logging must never prevent firewall rules from being applied.
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run as Administrator.'
    }
}

function ConvertTo-ExecutablePath {
    param([AllowNull()][string] $CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($expanded -match '^"([^"]+\.exe)"') {
        return $matches[1]
    }
    if ($expanded -match '^([^\s]+\.exe)') {
        return $matches[1]
    }
    return $null
}

function Get-SogouInstallRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $candidateRoots = @(
        (Join-Path $env:ProgramData 'SogouInput'),
        (Join-Path $env:ProgramFiles 'SogouInput'),
        (Join-Path ${env:ProgramFiles(x86)} 'SogouInput'),
        (Join-Path $env:WINDIR 'System32\IME\SogouPY'),
        (Join-Path $env:WINDIR 'SysWOW64\IME\SogouPY')
    )

    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            $candidateRoots += Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match '(?i)sogou|搜狗' -or $_.InstallLocation -match '(?i)sogou|搜狗' } |
                ForEach-Object { $_.InstallLocation }
        }
        catch {
            Write-Log "Registry scan skipped: $key"
        }
    }

    try {
        $services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)sogou' -or $_.DisplayName -match '(?i)sogou|搜狗' -or $_.PathName -match '(?i)sogou|搜狗' }
        foreach ($service in $services) {
            $serviceExe = ConvertTo-ExecutablePath $service.PathName
            if ($serviceExe) {
                $candidateRoots += Split-Path -Parent $serviceExe
            }
        }
    }
    catch {
        Write-Log 'Service scan skipped.'
    }

    foreach ($candidate in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        $fullPath = [Environment]::ExpandEnvironmentVariables(([string]$candidate).Trim())
        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            $normalized = (Resolve-Path -LiteralPath $fullPath).Path.TrimEnd('\')
            if (-not ($roots -contains $normalized)) {
                $roots.Add($normalized)
            }
        }
    }

    return @($roots)
}

function Get-SogouExecutableFiles {
    $files = New-Object System.Collections.Generic.List[string]
    $roots = Get-SogouInstallRoots

    foreach ($root in $roots) {
        try {
            Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if (-not ($files -contains $_.FullName)) {
                        $files.Add($_.FullName)
                    }
                }
        }
        catch {
            Write-Log "Directory scan failed: $root :: $($_.Exception.Message)"
        }
    }

    try {
        $services = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)sogou' -or $_.DisplayName -match '(?i)sogou|搜狗' -or $_.PathName -match '(?i)sogou|搜狗' }
        foreach ($service in $services) {
            $serviceExe = ConvertTo-ExecutablePath $service.PathName
            if ($serviceExe -and (Test-Path -LiteralPath $serviceExe -PathType Leaf) -and -not ($files -contains $serviceExe)) {
                $files.Add($serviceExe)
            }
        }
    }
    catch {
        Write-Log 'Service executable scan skipped.'
    }

    try {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $processPath = $_.Path
                if ($processPath -and $processPath -match '(?i)sogouinput|sogoupy' -and (Test-Path -LiteralPath $processPath -PathType Leaf) -and -not ($files -contains $processPath)) {
                    $files.Add($processPath)
                }
            }
            catch {
                # Some protected processes do not expose Path.
            }
        }
    }
    catch {
        Write-Log 'Process executable scan skipped.'
    }

    return @($files | Sort-Object)
}

function Save-FirewallProfileState {
    if (Test-Path -LiteralPath $script:StateFile) {
        return
    }

    $state = @{}
    foreach ($profile in Get-NetFirewallProfile -Profile Domain,Private,Public) {
        $state[$profile.Name] = [bool]$profile.Enabled
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Enable-FirewallProfiles {
    foreach ($profileName in @('Domain', 'Private', 'Public')) {
        try {
            Set-NetFirewallProfile -Profile $profileName -Enabled True -ErrorAction Stop
        }
        catch {
            throw "Unable to enable Windows Firewall profile ${profileName}: $($_.Exception.Message)"
        }
    }
}

function Remove-ManagedRules {
    $rules = Get-NetFirewallRule -Group $script:GroupName -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

function Get-PathToken {
    param([Parameter(Mandatory = $true)][string] $Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function Add-BlockRule {
    param(
        [Parameter(Mandatory = $true)][string] $ProgramPath,
        [Parameter(Mandatory = $true)][string] $Direction,
        [string] $Suffix = 'All'
    )

    $directionLabel = if ($Direction -eq 'Outbound') { 'OUT' } else { 'IN' }
    $displayName = "$script:GroupName $directionLabel $Suffix $(Get-PathToken $ProgramPath)"

    $params = @{
        DisplayName       = $displayName
        Group             = $script:GroupName
        Direction         = $Direction
        Action            = 'Block'
        Program           = $ProgramPath
        Profile           = 'Any'
        Protocol          = 'Any'
        Enabled           = 'True'
        EdgeTraversalPolicy = 'Block'
        ErrorAction       = 'Stop'
    }

    if ($Suffix -eq 'LoopbackIPv4') {
        $params.RemoteAddress = '127.0.0.0/8'
    }
    elseif ($Suffix -eq 'LoopbackIPv6') {
        $params.RemoteAddress = '::1/128'
    }

    New-NetFirewallRule @params | Out-Null
}

function Get-SogouProcessTable {
    $processes = New-Object System.Collections.Generic.List[object]

    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $processPath = $_.Path
            if ($processPath -and $processPath -match '(?i)\\SogouInput\\|\\IME\\SogouPY\\|\\Sogou') {
                $processes.Add([pscustomobject]@{
                    Id = $_.Id
                    Name = $_.ProcessName
                    Path = $processPath
                })
            }
        }
        catch {
            # Some protected processes do not expose Path.
        }
    }

    return $processes.ToArray()
}

function Stop-ConnectedSogouProcesses {
    param([object[]] $SogouProcesses = (Get-SogouProcessTable))

    if (-not $SogouProcesses -or $SogouProcesses.Count -eq 0) {
        return
    }

    $sogouById = @{}
    foreach ($process in $SogouProcesses) {
        $sogouById[[int]$process.Id] = $process
    }

    $connectedProcessIds = New-Object System.Collections.Generic.HashSet[int]
    Get-NetTCPConnection -State Established,SynSent,SynReceived -ErrorAction SilentlyContinue | ForEach-Object {
        if ($sogouById.ContainsKey([int]$_.OwningProcess)) {
            [void]$connectedProcessIds.Add([int]$_.OwningProcess)
        }
    }

    foreach ($processId in $connectedProcessIds) {
        try {
            $process = $sogouById[[int]$processId]
            Stop-Process -Id $processId -Force -ErrorAction Stop
            Write-Log "Stopped connected Sogou process: $($process.Name) [$processId] ($($process.Path))"
        }
        catch {
            # The process may have exited or may be protected.
        }
    }
}

function Apply-BlockRules {
    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    Enable-FirewallProfiles
    Remove-ManagedRules

    $exeFiles = Get-SogouExecutableFiles
    if (-not $exeFiles -or $exeFiles.Count -eq 0) {
        throw 'No Sogou executable files were found.'
    }

    $ruleCount = 0
    foreach ($exe in $exeFiles) {
        try {
            Add-BlockRule -ProgramPath $exe -Direction Outbound -Suffix 'All'
            Add-BlockRule -ProgramPath $exe -Direction Inbound -Suffix 'All'
            Add-BlockRule -ProgramPath $exe -Direction Outbound -Suffix 'LoopbackIPv4'
            $ruleCount += 3
        }
        catch {
            Write-Log "Rule creation failed for $exe :: $($_.Exception.Message)"
        }
    }

    Stop-ConnectedSogouProcesses
    Write-Log "Applied $ruleCount firewall rules for $($exeFiles.Count) executable files."
}

function Monitor-Blocker {
    Apply-BlockRules
    Write-Log 'Network monitor started.'

    $lastExecutableScan = [DateTime]::MinValue
    $blockedPaths = @()
    while ($true) {
        try {
            $now = Get-Date
            if (($now - $lastExecutableScan).TotalSeconds -ge 30 -or $blockedPaths.Count -eq 0) {
                $blockedPaths = @(Get-SogouExecutableFiles)
                $lastExecutableScan = $now
            }

            $sogouProcesses = @(Get-SogouProcessTable)
            Stop-ConnectedSogouProcesses -SogouProcesses $sogouProcesses
        }
        catch {
            Write-Log "Network monitor iteration failed: $($_.Exception.Message)"
        }

        Start-Sleep -Milliseconds 750
    }
}

function Register-ReapplyTask {
    $actionArgs = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script:InstalledScript`" -Mode Monitor"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
}

function Start-InstalledMonitor {
    try {
        Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    }
    catch { }

    Start-Sleep -Milliseconds 300
    Start-ScheduledTask -TaskName $script:TaskName
}

function Install-Blocker {
    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    Save-FirewallProfileState

    if ($PSCommandPath -and ((Resolve-Path -LiteralPath $PSCommandPath).Path -ne $script:InstalledScript)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledScript -Force
    }

    Register-ReapplyTask
    Apply-BlockRules
    Start-InstalledMonitor
    Write-Log "Installed. Scheduled task: $script:TaskName"
}

function Show-Status {
    $profiles = Get-NetFirewallProfile -Profile Domain,Private,Public |
        Select-Object Name,Enabled,DefaultOutboundAction
    $ruleCount = @(Get-NetFirewallRule -Group $script:GroupName -ErrorAction SilentlyContinue).Count
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    $connections = @()

    Get-NetTCPConnection -State Established,SynSent,SynReceived -ErrorAction SilentlyContinue | ForEach-Object {
        $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($process) {
            try {
                if ($process.Path -match '(?i)sogouinput|sogoupy|sogou') {
                    $connections += [pscustomobject]@{
                        Process = $process.ProcessName
                        PID = $process.Id
                        Path = $process.Path
                        Remote = "$($_.RemoteAddress):$($_.RemotePort)"
                        State = $_.State
                    }
                }
            }
            catch { }
        }
    }

    [pscustomobject]@{
        FirewallProfiles = ($profiles | Out-String).Trim()
        ManagedRuleCount = $ruleCount
        ScheduledTask = if ($task) { $task.State } else { 'Missing' }
        ActiveSogouConnections = if ($connections.Count) { ($connections | Out-String).Trim() } else { 'None' }
    } | Format-List
}

function Uninstall-Blocker {
    Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-ManagedRules

    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $savedState = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
            foreach ($property in $savedState.PSObject.Properties) {
                Set-NetFirewallProfile -Profile $property.Name -Enabled ([bool]$property.Value)
            }
        }
        catch {
            Write-Log "Could not restore firewall profile state: $($_.Exception.Message)"
        }
    }

    if ($PSCommandPath -ne $script:InstalledScript -and (Test-Path -LiteralPath $script:InstallDir)) {
        Remove-Item -LiteralPath $script:InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'SogouNetworkBlock rules and scheduled task removed.'
}

Assert-Administrator

switch ($Mode) {
    'Install' { Install-Blocker }
    'Apply' { Apply-BlockRules }
    'Monitor' { Monitor-Blocker }
    'Status' { Show-Status }
    'Uninstall' { Uninstall-Blocker }
}




