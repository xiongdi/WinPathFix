<#
.SYNOPSIS
    WinPathFix - Hierarchical Priority-Based Path Repair (Manager vs Installed Apps).
#>

param (
    [switch]$BackupOnly,
    [switch]$DryRun,
    [switch]$NonInteractive
)

# --- 解决 PowerShell 输出乱码 ---
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Continue'
$WarningPreference = 'Continue'

# --- 核心数据结构 ---
# 结构: @{ "WinGet" = @{ "Manager" = @(); "Apps" = @() } }
$Global:DiscoveryData = @{}

function Get-EnvPath {
    param([System.EnvironmentVariableTarget]$Target)
    $path = [Environment]::GetEnvironmentVariable('Path', $Target)
    if (-not $path) { return @() }
    return $path.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
}

function Set-EnvPath {
    param([System.EnvironmentVariableTarget]$Target, [string[]]$PathArray)
    $newPath = $PathArray -join ';'
    if ($DryRun) {
        Write-Host "[DryRun] Would set $Target Path ($($PathArray.Count) items)" -ForegroundColor Yellow
        return
    }
    [Environment]::SetEnvironmentVariable('Path', $newPath, $Target)
    
    # Update the current process PATH so the current shell is immediately aware of the changes
    $processPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
    if ($Target -eq 'Machine' -or $Target -eq 'User') {
        # Recalculate Process PATH by combining Machine and User paths
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$userPath", 'Process')
    }
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
    
    $commands = @{
        "WinGet" = "winget"; "Scoop" = "scoop"; "Choco" = "choco";
        "Npm" = "npm"; "Pip" = "pip"; "Cargo" = "cargo";
        "vcpkg" = "vcpkg"; "dotnet" = "dotnet"; "PS7" = "pwsh";
        "PS5" = "powershell"
    }

    # 1. First, check if commands are already in PATH and add them
    foreach ($name in $commands.Keys) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            $res = Add-Path $name "Manager" (Split-Path $found.Path)
            if ($res) { $allPaths.Add($res) }
        }
    }

    # 2. Add well-known paths
    # WinGet
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

    # Scoop
    $scoopBase = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    $res = Add-Path "Scoop" "Manager" "$scoopBase\shims"; if ($res) { $allPaths.Add($res) }
    $res = Add-Path "Scoop" "Apps" "$scoopBase\apps"; if ($res) { $allPaths.Add($res) }

    # Chocolatey
    $res = Add-Path "Choco" "Manager" "$env:ALLUSERSPROFILE\chocolatey\bin"; if ($res) { $allPaths.Add($res) }

    # Npm
    $res = Add-Path "Npm" "Manager" "$env:ProgramFiles\nodejs"; if ($res) { $allPaths.Add($res) }
    try {
        $npmPrefix = (npm config get prefix).Trim()
        if ($npmPrefix) { 
            $res = Add-Path "Npm" "Apps" $npmPrefix; if ($res) { $allPaths.Add($res) }
            $res = Add-Path "Npm" "Apps" (Join-Path $npmPrefix "bin"); if ($res) { $allPaths.Add($res) }
        }
    } catch {}
    $res = Add-Path "Npm" "Apps" "$env:APPDATA\npm"; if ($res) { $allPaths.Add($res) }

    # Pip
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

    # Cargo
    $res = Add-Path "Cargo" "Manager" "$env:USERPROFILE\.cargo\bin"; if ($res) { $allPaths.Add($res) }

    # vcpkg
    $vcpkgPaths = @($env:VCPKG_ROOT, "C:\vcpkg", "$env:USERPROFILE\vcpkg")
    foreach ($p in $vcpkgPaths) { if ($p) { $res = Add-Path "vcpkg" "Manager" $p; if ($res) { $allPaths.Add($res) } } }

    # .NET Tool
    $res = Add-Path "dotnet" "Manager" "$env:USERPROFILE\.dotnet\tools"; if ($res) { $allPaths.Add($res) }

    # PS7
    $res = Add-Path "PS7" "Manager" "$env:ProgramFiles\PowerShell\7"; if ($res) { $allPaths.Add($res) }

    # PS5
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
    Write-Host "                 WINPATHFIX: HIERARCHICAL REPAIR REPORT                 " -ForegroundColor Cyan
    Write-Host ("="*80) -ForegroundColor Cyan
    
    $stats = @{ "Found" = 0; "Missing" = 0; "Packages" = 0 }

    foreach ($name in $order) {
        $cmd = $commands[$name]
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        
        # 1. 一级：管理器状态
        if ($found) {
            Write-Host "  [v] " -NoNewline -ForegroundColor Green
            $stats["Found"]++
        } else {
            Write-Host "  [x] " -NoNewline -ForegroundColor Gray
            $stats["Missing"]++
        }
        Write-Host "$($name.PadRight(12))" -NoNewline -ForegroundColor White
        
        # 2. 一级展示包管理器执行文件的路径
        $managerExe = $null
        if ($found) {
            $managerExe = $found.Path
        } else {
            $exts = @('.exe', '.cmd', '.bat', '.ps1', '')
            if ($Global:DiscoveryData.ContainsKey($name)) {
                foreach ($dir in $Global:DiscoveryData[$name]["Manager"]) {
                    foreach ($ext in $exts) {
                        $testPath = Join-Path $dir "$cmd$ext"
                        if (Test-Path $testPath -PathType Leaf) {
                            $managerExe = $testPath
                            break
                        }
                    }
                    if ($managerExe) { break }
                }
            }
        }

        if ($managerExe) {
            Write-Host " -> $managerExe" -ForegroundColor DarkGray
        } else {
            Write-Host " -> (Not Found)" -ForegroundColor DarkRed
        }

        if ($Global:DiscoveryData.ContainsKey($name) -or $found) {
            # 3. 二级展示通过此包管理器安装的软件包（表格形式）
            $pkgList = @()
            try {
                if ($found) {
                    switch ($name) {
                        "WinGet" {
                            $res = winget list --accept-source-agreements 2>$null
                            $start = $false
                            foreach ($line in $res) {
                                if ($line -match "^-+") { $start = $true; continue }
                                if ($start -and $line.Trim()) {
                                    if ($line -match "^\s*(Name|Version|ID)\s" -or $line -match "^\s*---") { continue }
                                    $parts = $line -split '\s{2,}'
                                    if ($parts.Count -ge 3) {
                                        $pkgName = $parts[0].Trim(); $pkgVer = $parts[2].Trim(); $pkgId = $parts[1].Trim()
                                        if ($pkgName -and $pkgName -notmatch "^(名称|Name|版本)" -and $pkgName.Length -gt 1) {
                                            $pkgList += [PSCustomObject]@{ Name = $pkgName; Version = $pkgVer }
                                        }
                                    }
                                }
                            }
                        }
                        "Scoop" {
                            $res = scoop list 6>$null 2>$null
                            foreach ($item in $res) {
                                if ($item -and $item.Name) { $pkgList += [PSCustomObject]@{ Name = $item.Name; Version = $item.Version } }
                            }
                        }
                        "Choco" {
                            $res = choco list -l -r 2>$null
                            foreach ($line in $res) {
                                if ($line.Trim()) {
                                    $parts = $line.Split('|')
                                    $pkgList += [PSCustomObject]@{ Name = $parts[0].Trim(); Version = if ($parts.Length -gt 1) { $parts[1].Trim() } else { "" } }
                                }
                            }
                        }
                        "Npm" {
                            $res = npm ls -g --depth=0 2>$null | Select-Object -Skip 1
                            foreach ($line in $res) {
                                if ($line -match "(\+--|`--|├──|└──)\s+(.+)") {
                                    $pkgList += [PSCustomObject]@{ Name = $matches[2].Trim(); Version = "" }
                                }
                            }
                        }
                        "Pip" {
                            $res = pip list --format=columns 2>$null | Select-Object -Skip 2
                            foreach ($line in $res) {
                                if ($line.Trim()) {
                                    $parts = $line -split '\s{2,}'
                                    if ($parts.Count -ge 2) { $pkgList += [PSCustomObject]@{ Name = $parts[0].Trim(); Version = $parts[1].Trim() } }
                                }
                            }
                        }
                        "Cargo" {
                            $res = cargo install --list 2>$null
                            foreach ($line in $res) {
                                if ($line -match "^([a-zA-Z0-9_-]+)\s+(v[0-9.]+):") {
                                    $pkgList += [PSCustomObject]@{ Name = $matches[1]; Version = $matches[2] }
                                }
                            }
                        }
                        "vcpkg" {
                            $res = vcpkg list 2>$null
                            foreach ($line in $res) {
                                if ($line.Trim()) {
                                    $parts = $line -split '\s{2,}'
                                    if ($parts.Count -ge 2) { $pkgList += [PSCustomObject]@{ Name = $parts[0].Trim(); Version = $parts[1].Trim() } }
                                }
                            }
                        }
                        "dotnet" {
                            $res = dotnet tool list -g 2>$null
                            $start = $false
                            foreach ($line in $res) {
                                if ($line -match "^----+") { $start = $true; continue }
                                if ($start -and $line.Trim()) {
                                    $parts = $line -split '\s{2,}'
                                    if ($parts.Count -ge 2) { $pkgList += [PSCustomObject]@{ Name = $parts[0].Trim(); Version = $parts[1].Trim() } }
                                }
                            }
                        }
                    }
                }
            } catch {}

            if ($pkgList.Count -gt 0) {
                $stats["Packages"] += $pkgList.Count
                Write-Host "      [Packages: $($pkgList.Count)]" -ForegroundColor DarkYellow
                $displayList = $pkgList | Sort-Object Name
                foreach ($p in $displayList) {
                    $verInfo = if ($p.Version) { "($($p.Version))" } else { "" }
                    Write-Host "        - $($p.Name) $verInfo" -ForegroundColor Gray
                }
            }
        }
    }
    
    Write-Host ("-"*80) -ForegroundColor Cyan
    Write-Host " SUMMARY" -ForegroundColor Cyan
    Write-Host "  Managers Found:   $($stats['Found'])" -ForegroundColor Green
    Write-Host "  Managers Missing: $($stats['Missing'])" -ForegroundColor Gray
    Write-Host "  Total Packages:   $($stats['Packages'])" -ForegroundColor Yellow
    Write-Host ("-"*80) -ForegroundColor Cyan
    Write-Host "[i] All high-priority tool paths moved to the START of your PATH." -ForegroundColor Gray
    Write-Host "[i] Tool Path Order: $(($order -join ' > '))" -ForegroundColor DarkGray
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
$asciiArt = @"
  _      ___       ____       _   _     _____ _      
 | |    | (_)     |  _ \     | | | |   |  ___(_)     
 | |    | |_ _ __ | |_) |__ _| |_| |__ | |_   ___  __
 | |    | | | '_ \|  __/ _` | __| '_ \|  _| | \ \/ /
 | |____| | | | | | | | (_| | |_| | | | |   | |>  < 
 |______|_|_|_| |_|_|  \__,_|\__|_| |_|_|   |_/_/\_\
                                                     
     Windows PATH Repair & Optimization Utility
"@

Write-Host $asciiArt -ForegroundColor Cyan
Write-Host "`nInitializing Hierarchical Discovery..." -ForegroundColor Gray

# 初始化全局数据
$Global:DiscoveryData = @{}

# 1. 自动备份
Write-Host "[*] Creating safety backup..." -NoNewline -ForegroundColor Gray
$backup = Invoke-BackupPath
Write-Host " Done." -ForegroundColor Green

# 2. 自动修复
if (-not $BackupOnly) {
    Write-Host "[*] Analyzing and prioritizing environment variables..." -ForegroundColor Gray
    Repair-And-Prioritize-Paths -EnvTarget User | Out-Null
    try {
        Repair-And-Prioritize-Paths -EnvTarget Machine | Out-Null
    } catch {}
}

# 3. 输出层次化报告
Show-RepairReport

Write-Host "`n[!] IMPORTANT: PATH changes have been saved to the registry." -ForegroundColor Yellow
Write-Host "[!] You MUST RESTART any existing cmd or pwsh windows (or your IDE) for the changes to take effect." -ForegroundColor Yellow

if (-not $NonInteractive) {
    Write-Host "`nPress any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
