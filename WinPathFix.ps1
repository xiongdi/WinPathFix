<#
.SYNOPSIS
    WinPathFix - Advanced Priority-Based Path Repair with Dynamic Discovery.
#>

param (
    [switch]$Backup,
    [switch]$FixPackageManagers,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# --- 核心工具函数 ---

function Get-EnvPath {
    param([System.EnvironmentVariableTarget]$Target)
    $path = [Environment]::GetEnvironmentVariable('Path', $Target)
    return if (-not $path) { @() } else { $path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) }
}

function Set-EnvPath {
    param([System.EnvironmentVariableTarget]$Target, [string[]]$PathArray)
    [Environment]::SetEnvironmentVariable('Path', ($PathArray -join ';'), $Target)
}

function Invoke-BackupPath {
    $date = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = "$PSScriptRoot\PathBackup_$date.json"
    $backupData = @{
        Date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        User = [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    $backupData | ConvertTo-Json | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Host "[+] Backup created: $backupFile" -ForegroundColor Green
}

# --- 动态路径发现逻辑 ---

function Get-OrderedTargetPaths {
    $orderedList = New-Object System.Collections.Generic.List[string]

    Write-Host "[*] Discovering paths from package managers..." -ForegroundColor Gray

    # 1. WinGet
    $orderedList.Add("$env:LOCALAPPDATA\Microsoft\WindowsApps")
    $wingetPkg = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkg) {
        Get-ChildItem -Path $wingetPkg -Directory | ForEach-Object {
            $orderedList.Add($_.FullName)
            $bin = Join-Path $_.FullName "bin"
            if (Test-Path $bin) { $orderedList.Add($bin) }
        }
    }

    # 2. Scoop (Dynamic detection)
    $scoopDir = $env:SCOOP ?: "$env:USERPROFILE\scoop"
    $orderedList.Add("$scoopDir\shims")
    $orderedList.Add("$env:ProgramData\scoop\shims")

    # 3. Chocolatey
    $orderedList.Add("$env:ALLUSERSPROFILE\chocolatey\bin")

    # 4. Npm (Ask npm for its prefix)
    $npmPrefix = Invoke-Expression "npm config get prefix"
    if ($npmPrefix) {
        $orderedList.Add($npmPrefix.Trim())
        $orderedList.Add((Join-Path $npmPrefix.Trim() "bin"))
    }
    $orderedList.Add("$env:APPDATA\npm")

    # 5. Pip (Ask Python for user base)
    $pyUserBase = Invoke-Expression "python -m site --user-base"
    if ($pyUserBase) {
        $orderedList.Add((Join-Path $pyUserBase.Trim() "Scripts"))
    }
    # Fallback to standard python paths
    $pythonBase = "$env:LOCALAPPDATA\Programs\Python"
    if (Test-Path $pythonBase) {
        Get-ChildItem -Path $pythonBase -Directory | ForEach-Object { $orderedList.Add("$($_.FullName)\Scripts") }
    }

    # 6. Cargo
    $orderedList.Add("$env:USERPROFILE\.cargo\bin")

    # 7. vcpkg
    if ($env:VCPKG_ROOT) { $orderedList.Add($env:VCPKG_ROOT) }
    $orderedList.Add("C:\vcpkg")

    # 8. .NET Tool
    $orderedList.Add("$env:USERPROFILE\.dotnet\tools")

    # 9 & 10. PowerShell
    $orderedList.Add("$env:ProgramFiles\PowerShell\7")
    $orderedList.Add("$env:SystemRoot\System32\WindowsPowerShell\v1.0")

    return $orderedList | Select-Object -Unique
}

# --- 核心校验逻辑 ---

function Verify-PackageManagers {
    $commands = @{
        "WinGet" = "winget"; "Scoop" = "scoop"; "Choco" = "choco";
        "Npm" = "npm"; "Pip" = "pip"; "Cargo" = "cargo";
        "vcpkg" = "vcpkg"; ".NET" = "dotnet"; "PS7" = "pwsh"
    }

    Write-Host "`n[*] Verifying installed commands in PATH:" -ForegroundColor Cyan
    foreach ($name in $commands.Keys) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host " [OK] $name -> $($found.Source)" -ForegroundColor Green
        } else {
            Write-Host " [MISSING] $name" -ForegroundColor Yellow
        }
    }
}

function Repair-And-Prioritize-Paths {
    param ([System.EnvironmentVariableTarget]$EnvTarget)
    
    $targetPaths = Get-OrderedTargetPaths
    $currentPaths = Get-EnvPath -Target $EnvTarget
    
    $validTargets = @()
    foreach ($p in $targetPaths) {
        $cleanP = $p.TrimEnd('\')
        if (Test-Path $cleanP -PathType Container) { $validTargets += $cleanP }
    }

    $remainingPaths = New-Object System.Collections.Generic.List[string]
    foreach ($cp in $currentPaths) {
        $cleanCP = $cp.TrimEnd('\')
        $isTarget = $false
        foreach ($vt in $validTargets) { if ($cleanCP -eq $vt) { $isTarget = $true; break } }
        if (-not $isTarget) { $remainingPaths.Add($cp) }
    }

    $newPathArray = $validTargets + $remainingPaths.ToArray()
    
    if (($currentPaths -join ';') -ne ($newPathArray -join ';')) {
        Write-Host "[*] Updating $EnvTarget PATH..." -ForegroundColor Yellow
        Set-EnvPath -Target $EnvTarget -PathArray $newPathArray
        Write-Host "[+] $EnvTarget PATH updated." -ForegroundColor Green
    } else {
        Write-Host "[i] $EnvTarget PATH is already optimal." -ForegroundColor DarkGray
    }
}

function Show-Menu {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "      WinPathFix: Dynamic Discovery      " -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "1. Backup PATH"
    Write-Host "2. Repair & Prioritize (Dynamic Discovery)"
    Write-Host "3. Verify Current Commands"
    Write-Host "4. Exit"
    Write-Host ""
    
    $choice = Read-Host "Select (1-4)"
    switch ($choice) {
        '1' { Invoke-BackupPath; Pause; Show-Menu }
        '2' { Invoke-BackupPath; Repair-And-Prioritize-Paths -EnvTarget User; 
             try { Repair-And-Prioritize-Paths -EnvTarget Machine } catch {}; 
             Verify-PackageManagers; Pause; Show-Menu }
        '3' { Verify-PackageManagers; Pause; Show-Menu }
        '4' { exit }
        default { Show-Menu }
    }
}

if ($Backup) { Invoke-BackupPath }
if ($FixPackageManagers) {
    Repair-And-Prioritize-Paths -EnvTarget User
    try { Repair-And-Prioritize-Paths -EnvTarget Machine } catch {}
}
if (-not $Backup -and -not $FixPackageManagers -and -not $NonInteractive) { Show-Menu }
