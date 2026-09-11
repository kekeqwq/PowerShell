# Windows SSH + Tmux (psmux) 远程环境

在全新 Windows 上恢复「从 Linux / macOS SSH 进来，和本机打开终端同一套会话」的环境，替代并优于原 Zellij 方案。

个人配置（PowerShell profile、TmuxRelay 模块、`~/.tmux.conf`）放在本仓库对应路径，本文包含完整的环境安装顺序、系统服务配置、核心原理与排障验收。

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

## 最终效果

- Linux / macOS 用密钥 SSH 登录 Windows，免密码
- `sshd` 开机自启，防火墙放行 22 端口
- 交互登录自动进入 Tmux `main` 会话
- **创建会话发生在本机已登录的桌面会话**，而非 sshd 的 elevated / 无桌面会话
- SSH 断开只 detach，再连回去还是同一个 `main`
- 在最后一个窗口/分屏退出后会话自动销毁，下次 SSH 再走计划任务新建
- 类似 Fish 的历史命令浅色预测提示与补全（`InlineView` + 右箭头 / `Ctrl+f` 采纳）
- 计划任务只有一条 `TmuxRelay-main`，无触发器，平时不跑、不占资源

---

## 限制（先看）

桌面会话创建依赖本机 **已经有人登录在 console**，且不是 `Disc`：

```powershell
query session
```

需要输出类似：

```text
console    keke    1    Active
```

锁屏可以，只要用户桌面会话还在。  
刚重启停在登录界面、console 不存在时，无法「模拟本地创建」，这是 Windows 会话隔离机制，非脚本错误。

**不要做**：
- 开机自动启动 Tmux
- 在 SSH 进程里直接 `tmux new -s main`（会得到 Administrator 标题、桌面命令与部分环境变量不可用的受限会话）

---

## 1. 安装 OpenSSH Server

管理员权限打开 PowerShell：

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

若 `State : NotPresent`，执行安装：

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

确认 `State : Installed`。

---

## 2. 启动 sshd 并设为开机自启

```powershell
Start-Service sshd
Set-Service sshd -StartupType Automatic
Get-Service sshd | Select-Object Name, StartType, Status
```

应输出 `Automatic` + `Running`。

---

## 3. 配置防火墙放行 22 端口

```powershell
Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue
```

若不存在则创建规则：

```powershell
New-NetFirewallRule `
    -Name OpenSSH-Server-In-TCP `
    -DisplayName "OpenSSH Server (sshd)" `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort 22 `
    -Action Allow
```

---

## 4. 将 sshd 默认壳改为 pwsh

Win32-OpenSSH 默认登录 Shell 是 `cmd.exe`。管理员执行：

```powershell
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell `
    -Value (Get-Command pwsh).Source -PropertyType String -Force
Restart-Service sshd
```

注：若 `pwsh` 不在系统默认路径，可指定实际绝对路径（如 `C:\Users\<user>\Downloads\pwsh\pwsh.exe`）。

---

## 5. 公钥免密登录与权限

客户端生成密钥（若已有可跳过）：

```bash
ssh-keygen -t ed25519
```

将客户端公钥 `id_ed25519.pub` 内容追加写入 Windows 目标用户：

```text
C:\Users\<username>\.ssh\authorized_keys
```

**管理员组用户注意**：Windows 默认 `sshd_config` 会对 Administrators 组改读：

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

推荐直接编辑 `C:\ProgramData\ssh\sshd_config`，注释掉末尾这两行：

```text
# Match Group administrators
#     AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

然后重启服务：`Restart-Service sshd`。

收紧 ACL 权限：

```powershell
icacls "$HOME\.ssh" /inheritance:r /grant "$($env:USERNAME):(OI)(CI)F" "SYSTEM:(OI)(CI)F"
icacls "$HOME\.ssh\authorized_keys" /inheritance:r /grant "$($env:USERNAME):F" "SYSTEM:F"
```

客户端测试免密登录：

```bash
ssh username@windows-host
```

应免密直接进入 pwsh。

---

## 6. 安装必备依赖项

在 Windows 本机安装以下依赖：

1. **PowerShell 7 (pwsh)**：
   ```powershell
   winget install --id Microsoft.PowerShell --source winget
   ```
2. **psmux (原生 Windows Tmux 实现)**：
   ```powershell
   winget install --id marlocarlo.psmux --source winget
   ```
3. **oh-my-posh (提示符主题渲染)**：
   ```powershell
   winget install --id JanDeDobbeleer.OhMyPosh --source winget
   ```

---

## 7. 恢复本仓库用户环境

克隆本仓库到用户的 `Documents` 目录：

```powershell
cd C:\Users\$env:USERNAME\Documents
git clone https://github.com/kekeqwq/PowerShell.git PowerShell
```

对应组件：

| 路径 | 作用 |
| --- | --- |
| `Microsoft.PowerShell_profile.ps1` | 交互 Profile，加载 TmuxRelay、配置预测补全与快捷键 |
| `Modules/TmuxRelay/` | 跨桌面会话创建与挂载 Tmux 会话核心模块 |
| `~/.tmux.conf` / `~/.psmux.conf` | Windows Tmux 主配置，包含 Prefix、Catppuccin 主题与快捷键 |

### 关键配置说明：
1. **预测补全**：在 `~/.tmux.conf` 顶部必须包含 `set -g allow-predictions on`，防止 `psmux` 自动重置 PSReadLine 的预测配置。
2. **鼠标报告规避**：Windows ConPTY 在通过 SSH 传输鼠标输入时可能丢失转义前缀，导致鼠标移动时在命令行残留 `35;xx;xxM` 等字符。因此在 Windows 端配置 `set -g mouse off`，并在 profile 中强制 `$env:PSMUX_FORCE_MOUSE = '0'`。

---

## 8. 新电脑恢复操作清单

```text
1. 管理员运行 PowerShell，安装 OpenSSH.Server 功能
2. 启动 sshd，并将 StartupType 设为 Automatic
3. 防火墙放行 TCP 22 端口
4. 修改注册表 HKLM:\SOFTWARE\OpenSSH DefaultShell 为 pwsh.exe
5. 导入 authorized_keys，修正 sshd_config 中管理员组公钥文件规则
6. 客户端验证免密 SSH 登录成功
7. winget 安装 pwsh、psmux、oh-my-posh
8. 克隆本仓库至 ~/Documents/PowerShell
9. 部署 ~/.tmux.conf（或创建软链接）
10. 本机先登录桌面（确认 query session 显示 console Active）
11. 远端 SSH 连接，自动进入 Tmux main 会话
12. 在 Tmux 中退出后再次 SSH，验证能否重新在桌面会话中拉起新会话
```

---

## 9. 日常维护与命令

```powershell
# 查看所有 tmux 会话
tmux list-sessions

# 手动连接到 main 会话
tmux attach-session -t main

# 查看中转计划任务
Get-ScheduledTask -TaskName TmuxRelay-main
schtasks /query /tn TmuxRelay-main /fo LIST /v

# 强制清理会话服务（遇到僵死时）
tmux kill-server

# 强制重建计划任务
Unregister-ScheduledTask -TaskName TmuxRelay-main -Confirm:$false
```

---

## 10. 排障速查表

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 标题显示 `Administrator: ...pwsh.exe`，桌面命令失败 | 在 SSH 会话中直接新建了会话 | 不要直接执行 `tmux new`，退出后通过 `Enter-TmuxRelay` 经计划任务创建 |
| 报 `failed to create desktop tmux session` | console 不在，或任务没跑起来 | 检查 `query session`，确认计划任务设置允许电池运行 |
| 终端偶尔自动输入 `35;xx;xxM` 字符 | ConPTY 在 SSH 下漏掉鼠标 SGR 转义头 | 确保 `.tmux.conf` 中 `set -g mouse off` 且 profile 包含鼠标模式重置 |
| 缺少类似 Fish 的浅色命令预测补全 | psmux 默认关闭了预测选项 | 确保 `.tmux.conf` 顶部有 `set -g allow-predictions on` |
| 弹出粉框窗口或红字 Exception | 计划任务加载了 profile 导致嵌套 | 计划任务参数必须包含 `-NoProfile -WindowStyle Hidden` |
| 提示符路径在 `C:\Windows\System32` | 任务默认工作目录不正确 | 检查任务 Action 的 WorkingDirectory 是否为 `$HOME` |
| 任务状态为 `267011` / 任务不运行 | 笔记本/Surface 处于电池供电状态 | 在任务 Settings 中开启 `AllowStartIfOnBatteries` |
| `No mapping between account names and security IDs` | UserId 写成了 `WORKGROUP\user` | 使用 `$env:COMPUTERNAME\$env:USERNAME` 形式 |
