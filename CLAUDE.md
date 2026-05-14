# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WinPathFix is a PowerShell-based Windows PATH repair and optimization utility. It discovers and reorders package manager paths (WinGet, Scoop, Chocolatey, npm, pip, Cargo, vcpkg, dotnet, PowerShell) to the front of the PATH environment variable, ensuring correct priority resolution.

## Running

- **Interactive (recommended)**: Double-click `WinPathFix.bat` or run `.\WinPathFix.ps1`
- **Non-interactive automated fix**: `.\WinPathFix.ps1 -NonInteractive`
- **Backup only**: `.\WinPathFix.ps1 -BackupOnly`
- **Dry-run (no changes)**: `.\WinPathFix.ps1 -DryRun`

## Architecture

- `WinPathFix.ps1` — Core script containing all logic: path discovery, prioritization, backup, and the hierarchical repair report.
- `WinPathFix.bat` — Admin privilege escalation launcher.
- `PathBackup_*.json` — Auto-generated JSON backups of PATH before each run.

### Key Functions in WinPathFix.ps1

| Function | Purpose |
|----------|---------|
| `Get-OrderedTargetPaths` | Discovers all known package manager and tool paths, returns deduplicated list in priority order. |
| `Repair-And-Prioritize-Paths` | Takes existing PATH entries, extracts known tool paths, prepends them, appends remaining entries. |
| `Invoke-BackupPath` | Creates timestamped JSON backup of User and Machine PATH before any modification. |
| `Show-RepairReport` | Displays the hierarchical report: manager status → installed packages per manager. |
| `Set-EnvPath` | Writes PATH to registry and updates current process PATH immediately. |

### Priority Order (Manager → Installed Apps)

WinGet → Scoop → Chocolatey → Npm → Pip → Cargo → vcpkg → dotnet → PS7 → PS5

When a manager is found, `Show-RepairReport` enumerates packages installed through that manager and displays them alphabetically.

### Data Structures

- `$Global:DiscoveryData` — Hash table keyed by manager name, each value has `"Manager"` and `"Apps"` lists. Tracks discovered paths for the repair report.
- Path entries use `TrimEnd('\')` normalization throughout.

## Adding a New Tool

1. Add the command name to the `$commands` hash table in `Get-OrderedTargetPaths`.
2. Add discovery logic and `Add-Path` calls following the same pattern used by existing tools.
3. Add the tool name to the `$order` array in `Show-RepairReport`.
4. (Optional) Add package enumeration in the `switch` block inside `Show-RepairReport` if package listing is desired.

## Notes

- Backup files are created at `$PSScriptRoot` with pattern `PathBackup_YYYYMMDD_HHmmss.json`.
- Both User and Machine PATH are processed; Machine requires admin privileges via the `.bat` launcher.
- Path existence is validated with `Test-Path` before any path is added.
- Dry-run mode uses `-DryRun` switch; no registry changes occur when enabled.