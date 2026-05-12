<#
.SYNOPSIS
    WinPathFix - A utility to repair and restore Windows PATH environment variables.

.DESCRIPTION
    This script helps Windows users recover missing PATH variables, specifically 
    targeting package managers and tools in a specific priority order:
    1. WinGet, 2. Scoop, 3. Chocolatey, 4. Npm, 5. Pip, 6. Cargo, 7. vcpkg, 
    8. .NET Tool, 9. PowerShell 7.x, 10. PowerShell 5.x.

.EXAMPLE
    .\WinPathFix.ps1
    Runs the interactive menu.
#>

param (
    [switch]$Backup,
    [switch]$FixPackageManagers,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

function Get-EnvPath {
    param([System.EnvironmentVariableTarget]$Target)
    $path = [Environment]::GetEnvironmentVariable('Path', $Target)
    if (-not $path) { $path = "" }
    return $path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
}

function Set-EnvPath {
    param(
        [System.EnvironmentVariableTarget]$Target,
        [string[]]$PathArray
    )
    $newPath = $PathArray -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, $Target)
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
    Write-Host "[+] PATH variables successfully backed up to:" -ForegroundColor Green
    Write-Host "    $backupFile" -ForegroundColor Cyan
}

# Returns an ORDERED list of paths based on user priority
function Get-OrderedTargetPaths {
    $orderedList = New-Object System.Collections.Generic.List[string]

    # 1. WinGet
    $orderedList.Add("$env:LOCALAPPDATA\Microsoft\WindowsApps")

    # 2. Scoop
    $orderedList.Add("$env:USERPROFILE\scoop\shims")

    # 3. Chocolatey
    $orderedList.Add("$env:ALLUSERSPROFILE\chocolatey\bin")

    # 4. Npm
    $orderedList.Add("$env:APPDATA\npm")
    $orderedList.Add("$env:ProgramFiles\nodejs")

    # 5. Pip (Python Scripts)
    $pythonBase = "$env:LOCALAPPDATA\Programs\Python"
    if (Test-Path $pythonBase) {
        Get-ChildItem -Path $pythonBase -Directory | ForEach-Object { $orderedList.Add("$($_.FullName)\Scripts") }
    }
    $pythonRoaming = "$env:APPDATA\Python"
    if (Test-Path $pythonRoaming) {
        Get-ChildItem -Path $pythonRoaming -Directory | ForEach-Object { $orderedList.Add("$($_.FullName)\Scripts") }
    }

    # 6. Cargo
    $orderedList.Add("$env:USERPROFILE\.cargo\bin")

    # 7. vcpkg
    $vcpkgRoots = @("C:\vcpkg", "$env:USERPROFILE\vcpkg", "$env:SystemDrive\src\vcpkg")
    if ($env:VCPKG_ROOT) { $vcpkgRoots = @($env:VCPKG_ROOT) + $vcpkgRoots }
    foreach ($root in $vcpkgRoots) {
        if (Test-Path $root) { 
            $orderedList.Add($root) 
            break # Only add the first valid vcpkg found to respect priority
        }
    }

    # 8. .NET Tool
    $orderedList.Add("$env:USERPROFILE\.dotnet\tools")

    # 9. PowerShell 7.x
    $orderedList.Add("$env:ProgramFiles\PowerShell\7")

    # 10. PowerShell 5.x
    $orderedList.Add("$env:SystemRoot\System32\WindowsPowerShell\v1.0")

    return $orderedList
}

function Repair-And-Prioritize-Paths {
    param (
        [System.EnvironmentVariableTarget]$EnvTarget
    )
    
    $targetPaths = Get-OrderedTargetPaths
    $currentPaths = Get-EnvPath -Target $EnvTarget
    
    # 1. Filter target paths that actually exist on disk
    $validTargets = @()
    foreach ($p in $targetPaths) {
        $cleanP = $p.TrimEnd('\')
        if (Test-Path $cleanP -PathType Container) {
            $validTargets += $cleanP
        }
    }

    # 2. Remove these targets from the current PATH to avoid duplicates and reset their position
    $remainingPaths = New-Object System.Collections.Generic.List[string]
    foreach ($cp in $currentPaths) {
        $cleanCP = $cp.TrimEnd('\')
        $isTarget = $false
        foreach ($vt in $validTargets) {
            if ($cleanCP -eq $vt) {
                $isTarget = $true
                break
            }
        }
        if (-not $isTarget) {
            $remainingPaths.Add($cp)
        }
    }

    # 3. New PATH = Valid Targets (in priority order) + Remaining Paths
    $newPathArray = $validTargets + $remainingPaths.ToArray()

    # 4. Check if anything actually changed
    $oldPathStr = $currentPaths -join ';'
    $newPathStr = $newPathArray -join ';'

    if ($oldPathStr -ne $newPathStr) {
        Write-Host "[*] Updating $EnvTarget PATH to enforce priority..." -ForegroundColor Yellow
        foreach ($vt in $validTargets) {
            Write-Host "    [Priority] $vt" -ForegroundColor Cyan
        }
        Set-EnvPath -Target $EnvTarget -PathArray $newPathArray
        Write-Host "[+] Successfully updated $EnvTarget environment." -ForegroundColor Green
    } else {
        Write-Host "[i] $EnvTarget PATH is already optimal." -ForegroundColor DarkGray
    }
}

function Show-Menu {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "          WinPathFix Utility             " -ForegroundColor Cyan
    Write-Host "    (Priority-Based Path Repair)         " -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Priority Order:"
    Write-Host "1. WinGet      2. Scoop       3. Chocolatey"
    Write-Host "4. Npm         5. Pip         6. Cargo"
    Write-Host "7. vcpkg       8. .NET Tool   9. PS 7.x"
    Write-Host "10. PS 5.x"
    Write-Host ""
    Write-Host "1. Backup current PATH variables"
    Write-Host "2. Repair and Prioritize Paths (Recommended)"
    Write-Host "3. Exit"
    Write-Host ""
    
    $choice = Read-Host "Select an option (1-3)"
    
    switch ($choice) {
        '1' {
            Invoke-BackupPath
            Pause
            Show-Menu
        }
        '2' {
            Write-Host "`n[*] Starting repair and prioritization..." -ForegroundColor Cyan
            Invoke-BackupPath
            
            # User Level
            Repair-And-Prioritize-Paths -EnvTarget User
            
            # Machine Level
            try {
                Repair-And-Prioritize-Paths -EnvTarget Machine
            } catch {
                Write-Host "[!] Note: Administrator privileges are required to prioritize Machine PATH." -ForegroundColor Gray
            }
            
            Pause
            Show-Menu
        }
        '3' {
            exit
        }
        default {
            Write-Host "Invalid selection." -ForegroundColor Red
            Start-Sleep -Seconds 1
            Show-Menu
        }
    }
}

# Main Execution
if ($Backup) {
    Invoke-BackupPath
}

if ($FixPackageManagers) {
    Repair-And-Prioritize-Paths -EnvTarget User
    try {
        Repair-And-Prioritize-Paths -EnvTarget Machine
    } catch {}
}

if (-not $Backup -and -not $FixPackageManagers -and -not $NonInteractive) {
    Show-Menu
}
