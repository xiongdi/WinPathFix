<#
.SYNOPSIS
    WinPathFix - Automated Priority-Based Path Repair with Dynamic Discovery.
#>

param (
    [switch]$BackupOnly,
    [switch]$NonInteractive # Kept for backward compatibility
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
    return $backupFile
}

# --- 动态路径发现逻辑 ---

function Get-OrderedTargetPaths {
    $orderedList = New-Object System.Collections.Generic.List[string]

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

    # 2. Scoop
    $scoopDir = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    $orderedList.Add("$scoopDir\shims")
    $orderedList.Add("$env:ProgramData\scoop\shims")

    # 3. Chocolatey
    $orderedList.Add("$env:ALLUSERSPROFILE\chocolatey\bin")

    # 4. Npm
    $npmPrefix = Invoke-Expression "npm config get prefix 2>$null"
    if ($npmPrefix) {
        $orderedList.Add($npmPrefix.Trim())
        $orderedList.Add((Join-Path $npmPrefix.Trim() "bin"))
    }
    $orderedList.Add("$env:APPDATA\npm")

    # 5. Pip
    $pyUserBase = Invoke-Expression "python -m site --user-base 2>$null"
    if ($pyUserBase) {
        $orderedList.Add((Join-Path $pyUserBase.Trim() "Scripts"))
    }
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

# --- 核心校验报告逻辑 ---

function Show-RepairReport {
    $commands = @{
        "WinGet" = "winget"; "Scoop" = "scoop"; "Choco" = "choco";
        "Npm" = "npm"; "Pip" = "pip"; "Cargo" = "cargo";
        "vcpkg" = "vcpkg"; ".NET" = "dotnet"; "PS7" = "pwsh";
        "PS5" = "powershell"
    }

    Write-Host "`n" + ("="*40) -ForegroundColor Cyan
    Write-Host "         WINPATHFIX REPAIR REPORT        " -ForegroundColor Cyan
    Write-Host ("="*40) -ForegroundColor Cyan
    
    foreach ($name in ("WinGet","Scoop","Choco","Npm","Pip","Cargo","vcpkg",".NET","PS7","PS5")) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            Write-Host " [OK] " -NoNewline -ForegroundColor Green
            Write-Host "$($name.PadRight(10)) -> " -NoNewline
            Write-Host $found.Source -ForegroundColor Gray
        } else {
            Write-Host " [!!] " -NoNewline -ForegroundColor Red
            Write-Host "$($name.PadRight(10)) -> " -NoNewline
            Write-Host "Not found in PATH" -ForegroundColor DarkGray
        }
    }
    Write-Host ("-"*40) -ForegroundColor Cyan
    Write-Host "[i] All targets have been prioritized at the top of your PATH." -ForegroundColor Gray
    Write-Host "[i] Restart your terminal to apply changes." -ForegroundColor Yellow
    Write-Host ("="*40) -ForegroundColor Cyan
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
        Set-EnvPath -Target $EnvTarget -PathArray $newPathArray
        return $true
    }
    return $false
}

# --- 主执行流程 ---

Clear-Host
Write-Host "WinPathFix: Starting Automated Repair..." -ForegroundColor Cyan

if ($BackupOnly) {
    Invoke-BackupPath
    exit
}

# 1. 自动备份
Invoke-BackupPath | Out-Null

# 2. 自动修复
Write-Host "[*] Discovering and prioritizing paths..." -ForegroundColor Gray
$userChanged = Repair-And-Prioritize-Paths -EnvTarget User
$machineChanged = $false
try {
    $machineChanged = Repair-And-Prioritize-Paths -EnvTarget Machine
} catch {
    Write-Host "[!] Run as Administrator to repair Machine PATH." -ForegroundColor Yellow
}

# 3. 输出报告
Show-RepairReport

if (-not $NonInteractive) {
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
