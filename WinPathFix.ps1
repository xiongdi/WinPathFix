<#
.SYNOPSIS
    WinPathFix - Automated Priority-Based Path Repair with Deep Package Reporting.
#>

param (
    [switch]$BackupOnly,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# --- 核心数据结构：用于存储发现的路径及其归属 ---
$Global:DiscoveryData = @{}

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

# --- 深度路径探测逻辑 ---

function Get-OrderedTargetPaths {
    $Global:DiscoveryData = @{}
    $allPaths = New-Object System.Collections.Generic.List[string]

    function Add-Path {
        param($Name, $Path)
        if (Test-Path $Path) {
            $cleanP = $Path.TrimEnd('\')
            $allPaths.Add($cleanP)
            if (-not $Global:DiscoveryData.ContainsKey($Name)) { $Global:DiscoveryData[$Name] = New-Object System.Collections.Generic.List[string] }
            if ($Global:DiscoveryData[$Name] -notcontains $cleanP) { $Global:DiscoveryData[$Name].Add($cleanP) }
        }
    }

    # 1. WinGet
    Add-Path "WinGet" "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    $wingetPkg = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkg) {
        Get-ChildItem -Path $wingetPkg -Directory | ForEach-Object {
            Add-Path "WinGet" $_.FullName
            $bin = Join-Path $_.FullName "bin"
            if (Test-Path $bin) { Add-Path "WinGet" $bin }
        }
    }

    # 2. Scoop
    $scoopDir = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    Add-Path "Scoop" "$scoopDir\shims"
    Add-Path "Scoop" "$env:ProgramData\scoop\shims"

    # 3. Chocolatey
    Add-Path "Choco" "$env:ALLUSERSPROFILE\chocolatey\bin"

    # 4. Npm
    $npmPrefix = Invoke-Expression "npm config get prefix 2>$null"
    if ($npmPrefix) {
        $prefix = $npmPrefix.Trim()
        Add-Path "Npm" $prefix
        Add-Path "Npm" (Join-Path $prefix "bin")
    }
    Add-Path "Npm" "$env:APPDATA\npm"

    # 5. Pip
    $pyUserBase = Invoke-Expression "python -m site --user-base 2>$null"
    if ($pyUserBase) {
        Add-Path "Pip" (Join-Path $pyUserBase.Trim() "Scripts")
    }
    $pythonBase = "$env:LOCALAPPDATA\Programs\Python"
    if (Test-Path $pythonBase) {
        Get-ChildItem -Path $pythonBase -Directory | ForEach-Object { Add-Path "Pip" "$($_.FullName)\Scripts" }
    }

    # 6. Cargo
    Add-Path "Cargo" "$env:USERPROFILE\.cargo\bin"

    # 7. vcpkg
    if ($env:VCPKG_ROOT) { Add-Path "vcpkg" $env:VCPKG_ROOT }
    Add-Path "vcpkg" "C:\vcpkg"

    # 8. .NET Tool
    Add-Path "dotnet" "$env:USERPROFILE\.dotnet\tools"

    # 9. PS7
    Add-Path "PS7" "$env:ProgramFiles\PowerShell\7"

    # 10. PS5
    Add-Path "PS5" "$env:SystemRoot\System32\WindowsPowerShell\v1.0"

    return $allPaths | Select-Object -Unique
}

# --- 深度校验报告逻辑 ---

function Show-RepairReport {
    $commands = @{
        "WinGet" = "winget"; "Scoop" = "scoop"; "Choco" = "choco";
        "Npm" = "npm"; "Pip" = "pip"; "Cargo" = "cargo";
        "vcpkg" = "vcpkg"; "dotnet" = "dotnet"; "PS7" = "pwsh";
        "PS5" = "powershell"
    }

    $order = @("WinGet","Scoop","Choco","Npm","Pip","Cargo","vcpkg","dotnet","PS7","PS5")

    Write-Host "`n" + ("="*60) -ForegroundColor Cyan
    Write-Host "             WINPATHFIX DEEP REPAIR REPORT             " -ForegroundColor Cyan
    Write-Host ("="*60) -ForegroundColor Cyan
    
    foreach ($name in $order) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        
        # 状态标头
        if ($found) {
            Write-Host " [OK] " -NoNewline -ForegroundColor Green
        } else {
            Write-Host " [!!] " -NoNewline -ForegroundColor Red
        }
        Write-Host "$($name.PadRight(10))" -ForegroundColor White
        
        # 展示该工具管理的所有路径
        if ($Global:DiscoveryData.ContainsKey($name)) {
            foreach ($path in $Global:DiscoveryData[$name]) {
                Write-Host "      -> $path" -ForegroundColor Gray
            }
        } else {
            Write-Host "      -> No valid directories found on disk." -ForegroundColor DarkRed
        }
        Write-Host ""
    }
    
    Write-Host ("-"*60) -ForegroundColor Cyan
    Write-Host "[i] Priority enforced: Above paths are now at the START of your PATH." -ForegroundColor Gray
    Write-Host "[i] Restart your terminal to refresh the environment." -ForegroundColor Yellow
    Write-Host ("="*60) -ForegroundColor Cyan
}

function Repair-And-Prioritize-Paths {
    param ([System.EnvironmentVariableTarget]$EnvTarget)
    
    $targetPaths = Get-OrderedTargetPaths
    $currentPaths = Get-EnvPath -Target $EnvTarget
    
    $validTargets = @()
    foreach ($p in $targetPaths) {
        if (Test-Path $p) { $validTargets += $p }
    }

    $remainingPaths = New-Object System.Collections.Generic.List[string]
    foreach ($cp in $currentPaths) {
        $cleanCP = $cp.TrimEnd('\')
        if ($validTargets -notcontains $cleanCP) { $remainingPaths.Add($cp) }
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
Write-Host "WinPathFix: Initializing Deep Discovery..." -ForegroundColor Cyan

if ($BackupOnly) {
    Invoke-BackupPath | Out-Null
    exit
}

# 1. 自动备份
Invoke-BackupPath | Out-Null

# 2. 自动修复（此处会填充 DiscoveryData）
Write-Host "[*] Scanning for package manager installations..." -ForegroundColor Gray
Repair-And-Prioritize-Paths -EnvTarget User | Out-Null
try {
    Repair-And-Prioritize-Paths -EnvTarget Machine | Out-Null
} catch {}

# 3. 输出深度报告
Show-RepairReport

if (-not $NonInteractive) {
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
