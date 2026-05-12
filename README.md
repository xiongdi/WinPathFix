# WinPathFix 🛠️

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D4.svg)](https://www.microsoft.com/windows)

**WinPathFix** 是一个专为 Windows 用户设计的轻量级环境变量修复工具。它不仅能帮助你恢复丢失的包管理器路径，还能根据预设的优先级顺序重新排列你的 `PATH` 变量，确保开发环境的命令行工具（如 `winget`, `scoop`, `npm` 等）始终以正确的优先级运行。

## 🌟 核心特性

- **优先级置顶**: 强制将关键工具路径移动到 `PATH` 变量的最前端，避免同名命令冲突。
- **自动备份**: 任何修改前都会自动将当前的 `User` 和 `Machine` PATH 备份为 JSON 文件。
- **智能检测**: 仅添加在本地硬盘上真实存在的路径，避免 `PATH` 冗余和失效路径。
- **一键修复**: 提供交互式菜单，支持管理员权限自动提升，修复系统级环境变量。
- **包管理器支持**: 深度支持 WinGet, Scoop, Chocolatey, Npm, Pip, Cargo, vcpkg 等主流工具。

## 🔝 预设优先级顺序

当多个包管理器共存时，WinPathFix 按照以下顺序排列优先级：

1.  **WinGet** (最高优先级)
2.  **Scoop**
3.  **Chocolatey**
4.  **Npm** (Node.js)
5.  **Pip** (Python Scripts)
6.  **Cargo** (Rust)
7.  **vcpkg** (C++ Library Manager)
8.  **.NET Tool**
9.  **PowerShell 7.x** (pwsh)
10. **PowerShell 5.x** (powershell.exe)

## 🚀 使用方法

### 方式一：快捷运行 (推荐)
直接双击 **`WinPathFix.bat`**。
该脚本会自动申请管理员权限并启动交互式菜单。

### 方式二：PowerShell 命令行
```powershell
# 运行交互式菜单
.\WinPathFix.ps1

# 仅备份当前 PATH
.\WinPathFix.ps1 -Backup

# 非交互模式：自动修复并置顶所有工具路径
.\WinPathFix.ps1 -FixPackageManagers -NonInteractive
```

## 📂 项目结构

- `WinPathFix.ps1`: 核心逻辑脚本（优先级算法与路径检测）。
- `WinPathFix.bat`: 管理员权限引导器。
- `README.md`: 使用说明。
- `GEMINI.md`: 为 AI 助手提供的上下文指令。
- `PathBackup_*.json`: 自动生成的历史备份。

## ⚠️ 注意事项

- 修改系统级路径 (Machine PATH) 需要**管理员权限**。
- 如果发生意外，可以通过查看备份的 `.json` 文件手动还原先前的环境变量配置。

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 许可协议。
