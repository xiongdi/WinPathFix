# WinPathFix Project Context

## Project Overview
WinPathFix is a lightweight PowerShell utility designed to repair and optimize Windows `PATH` environment variables. It focuses on recovering and prioritizing paths for popular package managers and development tools, ensuring they are correctly ordered for optimal command resolution.

### Key Technologies
- **PowerShell**: Core script logic.
- **Batch Script**: Administrator privilege escalation and launcher.
- **JSON**: Used for environment variable backups.

### Supported Tools & Priority Order
1.  **WinGet** (Windows Package Manager)
2.  **Scoop**
3.  **Chocolatey**
4.  **Npm** (Node.js)
5.  **Pip** (Python)
6.  **Cargo** (Rust)
7.  **vcpkg**
8.  **.NET Tool**
9.  **PowerShell 7.x**
10. **PowerShell 5.x**

## Building and Running
As a script-based project, no building is required.

### Key Commands
- **Interactive Menu (Recommended)**:
  - Run `WinPathFix.bat` (automatically requests Administrator privileges).
  - Or in PowerShell: `.\WinPathFix.ps1`
- **Automated Fix (Non-Interactive)**:
  - `.\WinPathFix.ps1 -FixPackageManagers -NonInteractive`
- **Backup Current PATH**:
  - `.\WinPathFix.ps1 -Backup`

## Development Conventions
- **Surgical Updates**: When adding new tools, update `Get-OrderedTargetPaths` in `WinPathFix.ps1`.
- **Safety First**: All modifications must be preceded by an automatic backup using `Invoke-BackupPath`.
- **Disk Verification**: Only paths that exist on the local disk (`Test-Path`) should be added to the environment.
- **Priority Enforcement**: The tool doesn't just add paths; it extracts existing target paths and re-inserts them at the front of the list to ensure the specified priority.
- **Environment Scope**: Supports both `User` and `Machine` (requires Admin) environment scopes.
