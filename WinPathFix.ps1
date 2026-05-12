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

# --- 核心数据结构 ---
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

function Add-To-Discovery {
    param($Name, $Path)
    if (Test-Path $Path) {
        $cleanP = ($Path).TrimEnd('\')
        if (-not $Global:DiscoveryData.ContainsKey($Name)) { 
            $Global:DiscoveryData[$Name] = New-Object System.Collections.Generic.List[string] 
        }
        if ($Global:DiscoveryData[$Name] -notcontains $cleanP) { 
            $Global:DiscoveryData[$Name].Add($cleanP) 
        }
        return $cleanP
    }
    return $null
}

function Get-OrderedTargetPaths {
    # 注意：不再在这里重置 $Global:DiscoveryData，以便多次调用累加
    $allPaths = New-Object System.Collections.Generic.List[string]

    # 1. WinGet (深度扫描所有子目录下的可执行目录)
    $wingetPaths = @("$env:LOCALAPPDATA\Microsoft\WindowsApps")
    $wingetPkg = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (Test-Path $wingetPkg) {
        # 扫描每个包的根目录以及可能包含 exe/dll 的子目录
        Get-ChildItem -Path $wingetPkg -Directory | ForEach-Object {
            $wingetPaths += $_.FullName
            # 搜索一级子目录，如果包含 bin 或符合版本号特征的目录
            Get-ChildItem -Path $_.FullName -Directory | ForEach-Object {
                if ($_.Name -match "bin|v\d+|\d+\.\d+") { $wingetPaths += $_.FullName }
            }
        }
    }
    foreach ($p in $wingetPaths) { $res = Add-To-Discovery "WinGet" $p; if ($res) { $allPaths.Add($res) } }

    # 2. Scoop
    $scoopBase = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    $scoopPaths = @("$scoopBase\shims", "$env:ProgramData\scoop\shims")
    foreach ($p in $scoopPaths) { $res = Add-To-Discovery "Scoop" $p; if ($res) { $allPaths.Add($res) } }

    # 3. Chocolatey
    $res = Add-To-Discovery "Choco" "$env:ALLUSERSPROFILE\chocolatey\bin"
    if ($res) { $allPaths.Add($res) }

    # 4. Npm
    $npmPaths = New-Object System.Collections.Generic.List[string]
    $npmPaths.Add("$env:APPDATA\npm")
    $npmPaths.Add("$env:ProgramFiles\nodejs")
    try {
        $npmPrefix = (npm config get prefix).Trim()
        if ($npmPrefix) { $npmPaths.Add($npmPrefix); $npmPaths.Add((Join-Path $npmPrefix "bin")) }
    } catch {}
    foreach ($p in $npmPaths) { $res = Add-To-Discovery "Npm" $p; if ($res) { $allPaths.Add($res) } }

    # 5. Pip
    $pipPaths = New-Object System.Collections.Generic.List[string]
    try {
        $pyUserBase = (python -m site --user-base).Trim()
        if ($pyUserBase) { $pipPaths.Add((Join-Path $pyUserBase "Scripts")) }
    } catch {}
    $pythonLocal = "$env:LOCALAPPDATA\Programs\Python"
    if (Test-Path $pythonLocal) {
        Get-ChildItem -Path $pythonLocal -Directory | ForEach-Object { $pipPaths.Add((Join-Path $_.FullName "Scripts")) }
    }
    foreach ($p in $pipPaths) { $res = Add-To-Discovery "Pip" $p; if ($res) { $allPaths.Add($res) } }

    # 6. Cargo
    $res = Add-To-Discovery "Cargo" "$env:USERPROFILE\.cargo\bin"
    if ($res) { $allPaths.Add($res) }

    # 7. vcpkg
    $vcpkgPaths = @($env:VCPKG_ROOT, "C:\vcpkg", "$env:USERPROFILE\vcpkg")
    foreach ($p in $vcpkgPaths) { if ($p) { $res = Add-To-Discovery "vcpkg" $p; if ($res) { $allPaths.Add($res) } } }

    # 8. .NET Tool
    $res = Add-To-Discovery "dotnet" "$env:USERPROFILE\.dotnet\tools"
    if ($res) { $allPaths.Add($res) }

    # 9. PS7
    $res = Add-To-Discovery "PS7" "$env:ProgramFiles\PowerShell\7"
    if ($res) { $allPaths.Add($res) }

    # 10. PS5
    $res = Add-To-Discovery "PS5" "$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    if ($res) { $allPaths.Add($res) }

    return $allPaths | Select-Object -Unique
}

# --- 深度报告逻辑 ---

function Show-RepairReport {
    $commands = @{
        "WinGet" = "winget"; "Scoop" = "scoop"; "Choco" = "choco";
        "Npm" = "npm"; "Pip" = "pip"; "Cargo" = "cargo";
        "vcpkg" = "vcpkg"; "dotnet" = "dotnet"; "PS7" = "pwsh";
        "PS5" = "powershell"
    }

    $order = @("WinGet","Scoop","Choco","Npm","Pip","Cargo","vcpkg","dotnet","PS7","PS5")

    Write-Host "`n" + ("="*70) -ForegroundColor Cyan
    Write-Host "             WINPATHFIX DEEP REPAIR REPORT (v2.0)             " -ForegroundColor Cyan
    Write-Host ("="*70) -ForegroundColor Cyan
    
    foreach ($name in $order) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        
        if ($found) {
            Write-Host " [OK] " -NoNewline -ForegroundColor Green
        } else {
            Write-Host " [!!] " -NoNewline -ForegroundColor Red
        }
        Write-Host "$($name.PadRight(10))" -ForegroundColor White
        
        if ($Global:DiscoveryData.ContainsKey($name) -and $Global:DiscoveryData[$name].Count -gt 0) {
            foreach ($path in $Global:DiscoveryData[$name]) {
                Write-Host "      -> $path" -ForegroundColor Gray
            }
        } else {
            # 兜底：如果命令存在但没找到目录，尝试从 Get-Command 获取
            if ($found) {
                $guessedDir = Split-Path $found.Source
                Write-Host "      -> $guessedDir (Detected via command source)" -ForegroundColor DarkGray
            } else {
                Write-Host "      -> No valid directories found on disk." -ForegroundColor DarkRed
            }
        }
        Write-Host ""
    }
    
    Write-Host ("-"*70) -ForegroundColor Cyan
    Write-Host "[i] Priority enforced: Above paths are now at the START of your PATH." -ForegroundColor Gray
    Write-Host "[i] Restart your terminal to refresh the environment." -ForegroundColor Yellow
    Write-Host ("="*70) -ForegroundColor Cyan
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
Write-Host "WinPathFix: Initializing Deep Discovery v2.0..." -ForegroundColor Cyan

if ($BackupOnly) {
    Invoke-BackupPath | Out-Null
    exit
}

# 初始化数据
$Global:DiscoveryData = @{}

# 1. 自动备份
Invoke-BackupPath | Out-Null

# 2. 自动修复
Write-Host "[*] Scanning and optimizing path priority..." -ForegroundColor Gray
# 按顺序运行，DiscoveryData 会在调用过程中被填充
Repair-And-Prioritize-Paths -EnvTarget User | Out-Null
try {
    Repair-And-Prioritize-Paths -EnvTarget Machine | Out-Null
} catch {}

# 3. 输出报告
Show-RepairReport

if (-not $NonInteractive) {
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
