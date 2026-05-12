<#
.SYNOPSIS
    WinPathFix - Hierarchical Priority-Based Path Repair (Manager vs Installed Apps).
#>

param (
    [switch]$BackupOnly,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

# --- 核心数据结构 ---
# 结构: @{ "WinGet" = @{ "Manager" = @(); "Apps" = @() } }
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

# --- 增强的路径发现逻辑 ---

function Add-Path {
    param($Name, $Type, $Path)
    if (Test-Path $Path) {
        $cleanP = ($Path).TrimEnd('\')
        if (-not $Global:DiscoveryData.ContainsKey($Name)) { 
            $Global:DiscoveryData[$Name] = @{ "Manager" = New-Object System.Collections.Generic.List[string]; "Apps" = New-Object System.Collections.Generic.List[string] }
        }
        if ($Global:DiscoveryData[$Name][$Type] -notcontains $cleanP) { 
            $Global:DiscoveryData[$Name][$Type].Add($cleanP) 
        }
        return $cleanP
    }
    return $null
}

function Get-OrderedTargetPaths {
    $allPaths = New-Object System.Collections.Generic.List[string]

    # 1. WinGet
    $res = Add-Path "WinGet" "Manager" "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    if ($res) { $allPaths.Add($res) }
    $wingetPkg = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkg) {
        Get-ChildItem -Path $wingetPkg -Directory | ForEach-Object {
            $res = Add-Path "WinGet" "Apps" $_.FullName; if ($res) { $allPaths.Add($res) }
            Get-ChildItem -Path $_.FullName -Directory | ForEach-Object {
                if ($_.Name -match "bin|v\d+|\d+\.\d+") { $res = Add-Path "WinGet" "Apps" $_.FullName; if ($res) { $allPaths.Add($res) } }
            }
        }
    }

    # 2. Scoop
    $scoopBase = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    $res = Add-Path "Scoop" "Manager" "$scoopBase\shims"; if ($res) { $allPaths.Add($res) }
    $res = Add-Path "Scoop" "Apps" "$scoopBase\apps"; if ($res) { $allPaths.Add($res) } # Scoop apps root for reference

    # 3. Chocolatey
    $res = Add-Path "Choco" "Manager" "$env:ALLUSERSPROFILE\chocolatey\bin"; if ($res) { $allPaths.Add($res) }

    # 4. Npm
    $res = Add-Path "Npm" "Manager" "$env:ProgramFiles\nodejs"; if ($res) { $allPaths.Add($res) }
    try {
        $npmPrefix = (npm config get prefix).Trim()
        if ($npmPrefix) { 
            $res = Add-Path "Npm" "Apps" $npmPrefix; if ($res) { $allPaths.Add($res) }
            $res = Add-Path "Npm" "Apps" (Join-Path $npmPrefix "bin"); if ($res) { $allPaths.Add($res) }
        }
    } catch {}
    $res = Add-Path "Npm" "Apps" "$env:APPDATA\npm"; if ($res) { $allPaths.Add($res) }

    # 5. Pip
    $pythonBase = "$env:LOCALAPPDATA\Programs\Python"
    if (Test-Path $pythonBase) {
        Get-ChildItem -Path $pythonBase -Directory | ForEach-Object { 
            $res = Add-Path "Pip" "Manager" $_.FullName; if ($res) { $allPaths.Add($res) }
            $res = Add-Path "Pip" "Apps" (Join-Path $_.FullName "Scripts"); if ($res) { $allPaths.Add($res) }
        }
    }
    try {
        $pyUserBase = (python -m site --user-base).Trim()
        if ($pyUserBase) { $res = Add-Path "Pip" "Apps" (Join-Path $pyUserBase "Scripts"); if ($res) { $allPaths.Add($res) } }
    } catch {}

    # 6. Cargo
    $res = Add-Path "Cargo" "Manager" "$env:USERPROFILE\.cargo\bin"; if ($res) { $allPaths.Add($res) } # Cargo apps are in bin

    # 7. vcpkg
    $vcpkgPaths = @($env:VCPKG_ROOT, "C:\vcpkg", "$env:USERPROFILE\vcpkg")
    foreach ($p in $vcpkgPaths) { if ($p) { $res = Add-Path "vcpkg" "Manager" $p; if ($res) { $allPaths.Add($res) } } }

    # 8. .NET Tool
    $res = Add-Path "dotnet" "Manager" "$env:USERPROFILE\.dotnet\tools"; if ($res) { $allPaths.Add($res) }

    # 9. PS7
    $res = Add-Path "PS7" "Manager" "$env:ProgramFiles\PowerShell\7"; if ($res) { $allPaths.Add($res) }

    # 10. PS5
    $res = Add-Path "PS5" "Manager" "$env:SystemRoot\System32\WindowsPowerShell\v1.0"; if ($res) { $allPaths.Add($res) }

    return $allPaths | Select-Object -Unique
}

# --- 层次化报告逻辑 ---

function Show-RepairReport {
    $commands = @{
        "WinGet" = "winget"; "Scoop" = "scoop"; "Choco" = "choco";
        "Npm" = "npm"; "Pip" = "pip"; "Cargo" = "cargo";
        "vcpkg" = "vcpkg"; "dotnet" = "dotnet"; "PS7" = "pwsh";
        "PS5" = "powershell"
    }

    $order = @("WinGet","Scoop","Choco","Npm","Pip","Cargo","vcpkg","dotnet","PS7","PS5")

    Write-Host "`n" + ("="*80) -ForegroundColor Cyan
    Write-Host "             WINPATHFIX HIERARCHICAL REPAIR REPORT             " -ForegroundColor Cyan
    Write-Host ("="*80) -ForegroundColor Cyan
    
    foreach ($name in $order) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        
        # 1. 一级：管理器状态
        if ($found) {
            Write-Host " [OK] " -NoNewline -ForegroundColor Green
        } else {
            Write-Host " [!!] " -NoNewline -ForegroundColor Red
        }
        Write-Host "$($name.PadRight(10))" -ForegroundColor White
        
        if ($Global:DiscoveryData.ContainsKey($name)) {
            # 2. 展示管理器自身路径
            if ($Global:DiscoveryData[$name]["Manager"].Count -gt 0) {
                Write-Host "      [Manager Path]" -ForegroundColor DarkCyan
                foreach ($path in $Global:DiscoveryData[$name]["Manager"]) {
                    Write-Host "      -> $path" -ForegroundColor Gray
                }
            }

            # 3. 展示安装的软件路径
            if ($Global:DiscoveryData[$name]["Apps"].Count -gt 0) {
                Write-Host "      [Installed Software Paths]" -ForegroundColor DarkYellow
                foreach ($path in $Global:DiscoveryData[$name]["Apps"]) {
                    Write-Host "      -> $path" -ForegroundColor Gray
                }
            }
        } else {
            Write-Host "      -> No valid directories found on disk." -ForegroundColor DarkRed
        }
        Write-Host ""
    }
    
    Write-Host ("-"*80) -ForegroundColor Cyan
    Write-Host "[i] Priority enforced: All paths moved to the START of your PATH." -ForegroundColor Gray
    Write-Host "[i] Manager Paths have higher priority than App Paths within the same tool." -ForegroundColor DarkGray
    Write-Host ("="*80) -ForegroundColor Cyan
}

function Repair-And-Prioritize-Paths {
    param ([System.EnvironmentVariableTarget]$EnvTarget)
    
    $targetPaths = Get-OrderedTargetPaths
    $currentPaths = Get-EnvPath -Target $EnvTarget
    
    $validTargets = @()
    foreach ($p in $targetPaths) {
        if (Test-Path $p) { $validTargets += $p.TrimEnd('\') }
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
Write-Host "WinPathFix: Initializing Hierarchical Discovery..." -ForegroundColor Cyan

# 初始化全局数据
$Global:DiscoveryData = @{}

# 1. 自动备份
Invoke-BackupPath | Out-Null

# 2. 自动修复
Write-Host "[*] Analyzing and prioritizing environment variables..." -ForegroundColor Gray
Repair-And-Prioritize-Paths -EnvTarget User | Out-Null
try {
    Repair-And-Prioritize-Paths -EnvTarget Machine | Out-Null
} catch {}

# 3. 输出层次化报告
Show-RepairReport

if (-not $NonInteractive) {
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
