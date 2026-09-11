# Windows SSH + Tmux (psmux) 远程环境

在 Windows 上实现「从 Linux / macOS SSH 进来，和本机打开终端同一套会话」的环境，替代并优于 Zellij 方案。

```text
Linux / macOS
      |
      | SSH
      v
Windows OpenSSH (sshd)
      |
      | profile → Enter-TmuxRelay
      v
计划任务 TmuxRelay-main
      |
      | 在 console 桌面会话里 new-session -d
      v
Tmux session `main`
      |
      | SSH 只 attach-session
      v
远端终端 (完整桌面交互环境)
```

---

## 核心设计与优势

1. **统一的 Tmux 体验**：全平台（Linux、macOS、Windows）统一使用 Tmux 肌肉记忆快捷键（默认 Prefix 为 `Ctrl+Space`，次 Prefix 为 `Ctrl+b`）。
2. **桌面会话穿透**：通过计划任务以登录用户的桌面交互 Session（Session ID > 0）创建后台 tmux 服务，避免 OpenSSH 非交互式会话缺少桌面令牌、GPU 加速及环境变量不一致的问题。
3. **类似 Fish 的预测补全**：开启 `set -g allow-predictions on` 并配置 PSReadLine，终端内呈现浅色历史预测，支持使用 `RightArrow` 或 `Ctrl+f` 补全。
4. **智能关闭检测**：在最后一个窗口/分屏执行 `Ctrl+D` 时直接退出并清理会话；在多窗口/分屏时只关闭当前分屏。

---

## 文件结构

| 路径 | 说明 |
| --- | --- |
| `Microsoft.PowerShell_profile.ps1` | PowerShell 交互 Profile，加载 TmuxRelay、配置预测补全与快捷键 |
| `Modules/TmuxRelay/` | `Enter-TmuxRelay` 等会话检测、桌面计划任务托管与接入逻辑 |
| `~/.tmux.conf` / `~/.psmux.conf` | Windows 端 tmux (psmux) 配置，移植自 Omarchy 美化方案 |

---

## 排障与常用命令

```powershell
# 查看当前 tmux 运行会话
tmux list-sessions

# 手动接入会话
tmux attach-session -t main

# 查看后台计划任务
Get-ScheduledTask -TaskName TmuxRelay-main

# 强制重启会话服务
tmux kill-server
```
