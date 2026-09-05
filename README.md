# Windows SSH + Zellij 远程环境

在全新 Windows 上恢复「从 Linux / macOS SSH 进来，和本机打开终端同一套会话」的环境。

个人配置（PowerShell profile、ZellijRelay 模块、`config.kdl`）放在本仓库对应路径，本文只写安装顺序、原理和验收。

```text
Linux / macOS
      |
      | SSH
      v
Windows OpenSSH (sshd)
      |
      | profile → Enter-ZellijRelay
      v
计划任务 ZellijSpawnOnce
      |
      | 在 console 桌面会话里 create
      v
Zellij session `main`
      |
      | SSH 只 attach
      v
远端终端
```

---

## 最终效果

- Linux / macOS 用密钥 SSH 登录 Windows，免密码
- `sshd` 开机自启，防火墙放行 22
- 交互登录自动进入 Zellij `main`
- **创建会话发生在本机已登录的桌面会话**，不是 sshd 那个 elevated / 无桌面会话
- SSH 断开只 detach，再连回去还是同一个 `main`
- 在 Zellij 里 `quit` 后会话消失，下次 SSH 再走计划任务新建
- 计划任务只有一条 `ZellijSpawnOnce`，无触发器，平时不跑、不占资源

---

## 限制（先看）

桌面会话创建依赖本机 **已经有人登录在 console**，且不是 `Disc`：

```powershell
query session
```

需要类似：

```text
console    keke    1    Active
```

锁屏可以，只要用户会话还在。  
刚重启停在登录界面、console 不存在时，无法「模拟本地创建」，这是 Windows 会话隔离，不是脚本写错。

不要做：

- 开机自动启动 Zellij
- 在 SSH 进程里 `zellij attach --create`（会得到 Administrator 标题、桌面命令不可用的那套会话）

---

## 1. 安装 OpenSSH Server

管理员 PowerShell：

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

`State : NotPresent` 时：

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

确认 `State : Installed`。

---

## 2. 启动并设为开机自启

```powershell
Start-Service sshd
Set-Service sshd -StartupType Automatic
Get-Service sshd | Select-Object Name, StartType, Status
```

应为 `Automatic` + `Running`。

---

## 3. 防火墙

```powershell
Get-NetFirewallRule -Name OpenSSH-Server-In-TCP
```

没有则：

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

## 4. 默认壳改为 pwsh

sshd 默认是 `cmd.exe`。管理员：

```powershell
New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell `
    -Value (Get-Command pwsh).Source -PropertyType String -Force
Restart-Service sshd
```

`pwsh` 不在标准路径时，写成实际 exe，例如：

```text
C:\Users\<user>\Downloads\pwsh\pwsh.exe
```

---

## 5. 公钥登录

客户端（已有密钥可跳过）：

```bash
ssh-keygen -t ed25519
```

把 `~/.ssh/id_ed25519.pub` 写入 Windows：

```text
C:\Users\<username>\.ssh\authorized_keys
```

管理员组用户注意：默认 `sshd_config` 可能改读

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

要么把公钥放到那个文件并收紧 ACL，要么注释掉 `sshd_config` 末尾的：

```text
Match Group administrators
    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

然后 `Restart-Service sshd`。

权限：

```powershell
icacls "$HOME\.ssh"
icacls "$HOME\.ssh\authorized_keys"
```

当前用户 + SYSTEM（管理员组场景按 Microsoft 文档处理 `administrators_authorized_keys`）。

客户端测试：

```bash
ssh username@windows-host
```

应免密进入 pwsh。

重启后确认 `sshd` 仍 Running，再 SSH 一次。

---

## 6. 为什么 SSH 里直接开 Zellij 是错的

管理员账户走 Win32-OpenSSH 时，当前壳是 **High** 完整性（elevated）。`query session` 能看到桌面在 `console`，但 SSH 进程不在那个会话里。

因此在 SSH / profile 里执行：

```powershell
zellij attach --create main
```

会得到：

- 窗口标题类似 `Administrator: ...\pwsh.exe`
- 桌面相关命令不可用
- 和本机 Windows Terminal 里开的 Zellij 不是同一类 logon，named pipe 还可能互相看不见

正确做法：用 **交互式、Limited、无触发器** 的计划任务，在 console 会话里执行 create；SSH 只 `attach`。

---

## 7. 恢复本仓库用户环境

SSH 系统层完成后，再拉本仓库，对齐：

| 路径 | 作用 |
| --- | --- |
| `Microsoft.PowerShell_profile.ps1` | 加载模块并调用 `Enter-ZellijRelay` |
| `Modules/ZellijRelay/` | 有会话则 attach，无则跑任务创建再 attach |
| Zellij `config.kdl` | `on_force_close "detach"`、`default_shell`、`default_cwd` |
| 本机 PATH 中的 `pwsh`、`zellij` | 任务和模块都按全路径调用 |

模块行为：

```text
已在 Zellij 内（$env:ZELLIJ）     → 什么都不做
已有未 EXITED 的 main            → zellij attach main
否则                             → 清掉残留
                                 → 确认 console Active
                                 → 使用或重建唯一任务 ZellijSpawnOnce
                                 → schtasks /run
                                 → 等到 list-sessions 看到 main
                                 → attach
任务不健康或 run 失败             → 只删除 ZellijSpawnOnce，再建这一条，再 run 一次
仍然没有                         → 报错退出（绝不在 SSH 里 attach --create）
```

任务本身：

- 名称固定 `ZellijSpawnOnce`，不会堆出一堆任务
- `LogonType = Interactive`，`RunLevel = Limited`
- 允许电池启动（Surface 否则会静默不跑）
- `pwsh -NoProfile -WindowStyle Hidden`，避免再加载 profile 套娃、避免弹出粉框
- 工作目录和 `Set-Location` 都是 `$HOME`，避免从 `System32` 起
- 显式 `options --default-shell <pwsh全路径>`，避免 pane 变成 `cmd.exe`
- 无触发器：不占 CPU / 内存，只在 SSH 需要新建时跑几秒

Zellij 配置要点：

```kdl
on_force_close "detach"
default_shell "C:\\path\\to\\pwsh.exe"
default_cwd "C:\\Users\\<user>"
```

`default_shell` / `default_cwd` 只作用于 **新会话**。改完后要在 Zellij 里 `quit` 再连。

---

## 8. 日常使用

```text
ssh user@host          # 没有 main 就桌面创建，有就接上
关掉 SSH 再连          # 同一条 main
在 Zellij 里 quit      # 会话结束，本机不再挂 zellij
再次 ssh               # 再走一次任务创建
```

不需要单独的 down 命令。拆会话用 Zellij 自己的 quit。

确认 server 在桌面会话（`SI` 应等于 console 的 ID，一般是 `1`）：

```powershell
query session
Get-Process zellij | Format-Table Id, SI, ProcessName
```

---

## 9. 新电脑恢复顺序

```text
1. 安装 OpenSSH Server
2. 启动 sshd，设为 Automatic
3. 防火墙放行 22
4. DefaultShell → pwsh
5. 导入 authorized_keys（注意管理员组路径）
6. 客户端免密 SSH 成功
7. 安装 pwsh 7、Zellij，加入 PATH
8. 拉本仓库，profile / Modules / zellij config 就位
9. 本机先登录桌面（console Active）
10. SSH 进入，应落到 Zellij main
11. quit 后再 SSH，应重新创建且仍是桌面会话
```

---

## 10. 维护

```powershell
Get-Service sshd
Restart-Service sshd
Get-WinEvent -LogName "OpenSSH/Operational" -MaxEvents 20

Get-ScheduledTask -TaskName ZellijSpawnOnce
schtasks /query /tn ZellijSpawnOnce /fo LIST /v
Get-Process zellij -ErrorAction SilentlyContinue
zellij list-sessions
```

任务坏了不必手删多条。模块发现参数/电池设置不对，会只拆 `ZellijSpawnOnce` 再建一次。要强制重建：

```powershell
Unregister-ScheduledTask -TaskName ZellijSpawnOnce -Confirm:$false
```

下次 `Enter-ZellijRelay` 会注册回来。

---

## 11. 排障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 标题 `Administrator: ...pwsh.exe`，桌面命令失败 | 在 SSH 会话里 create 了 | 不要 `attach --create`；quit 掉后用模块走任务 |
| `failed to create desktop zellij session` | console 不在，或任务没跑起来 | `query session`；任务允许电池；确认 zellij 全路径 |
| 桌面弹出粉框 pwsh，红字 Exception | 任务加载了 profile | 任务参数必须有 `-NoProfile -WindowStyle Hidden` |
| pane 是 cmd | 隐藏任务没有可继承的壳 | `config.kdl` 的 `default_shell` + 任务里 `--default-shell` |
| 提示符在 `System32` | 任务默认工作目录 | 任务 `WorkingDirectory` + `Set-Location $HOME` + `default_cwd` |
| `Last Result 267011` / 任务不跑 | Surface 电池策略 | `AllowStartIfOnBatteries` |
| `No mapping between account names and security IDs` | UserId 写成 `WORKGROUP\user` | 用 `COMPUTERNAME\USERNAME` |
| SSH `list-sessions` 看不到桌面建的 session | 跨 logon 的 pipe（少见） | 先看 `Get-Process zellij` 的 `SI`；新版 Zellij 一般可 attach |
| `whoami` 变成 `WORKGROUP\...` | 函数/别名覆盖 | 用 `whoami.exe` |

完整性检查（SSH 里 High 是正常的，真正看的是 zellij 进程的 `SI`）：

```powershell
whoami.exe
whoami /groups | findstr "Mandatory Label"
query session
```
