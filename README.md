# Windows SSH + Tmux (psmux) 远程环境一键配置

在全新 Windows 电脑上快速恢复「从 Linux / macOS SSH 进来，与本机桌面共享同一套会话」的环境，使用原生 `psmux` (Tmux) 方案。

---

## 快速开始（新电脑部署）

在一台全新的 Windows 电脑上，只需执行以下步骤：

### 1. 克隆本仓库
打开系统自带的 PowerShell（推荐右键选择 **以管理员身份运行**）：

```powershell
# 1. 安装 Git（若未安装）
winget install --id Git.Git -e --source winget

# 2. 克隆本仓库到用户 Documents 目录
cd ~/Documents
git clone https://github.com/kekeqwq/PowerShell.git PowerShell
cd ~/Documents/PowerShell
```

### 2. 准备连入公钥
将准备连入此机器的客户端公钥（例如 `id_ed25519.pub` 或 `authorized_keys`）放置在任意路径（如 `~/Downloads/id_ed25519.pub`）。

### 3. 运行一键构建脚本

> **注意（关于脚本执行策略）**：  
> Windows 默认禁止运行 `.ps1` 脚本（`Restricted` 策略）。本仓库提供了两种执行方式：

#### 方式 A（推荐，CMD 包装器自动绕过策略）：
```powershell
./build.cmd ~/Downloads/id_ed25519.pub
```

#### 方式 B（原生 PowerShell 脚本）：
如直接运行 `./build.ps1`，需先开启当前用户脚本执行权限：
```powershell
# 开启脚本执行开关（仅需运行一次）
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

# 运行构建脚本
./build.ps1 ~/Downloads/id_ed25519.pub
```

> **说明**：
> - 传入参数支持公钥文件（如 `id_ed25519.pub`）或多密钥的 `authorized_keys` 文件，支持直接路径、相对路径或 `~` 简写；
> - 若不带参数执行，脚本会自动搜索 `~/Downloads` 和 `~/.ssh` 目录下的 `id_ed25519.pub` / `authorized_keys`；
> - 脚本若未在管理员终端下执行，会自动请求 UAC 提权。若在无图形环境下请以管理员身份打开终端后执行。

---

## 脚本自动完成的操作

运行脚本后，将全自动完成以下所有配置：

1. **PowerShell Preview 下载部署（写死预览版）**：
   - 自动识别系统架构（ARM64 / x64）；
   - 严格绑定官方最新 Preview 版本，从官方发布源直接获取绿色 ZIP 包解压至 `~/Downloads/pwsh`；
   - 若本地已是最新 Preview 版本则自动跳过重复下载，避免冗余消耗。
2. **依赖组件静默安装**：
   - 通过 WinGet 自动安装 `marlocarlo.psmux` (Windows 原生 Tmux 移植版)；
   - 通过 WinGet 自动安装 `JanDeDobbeleer.OhMyPosh` 提示符工具。
3. **OpenSSH Server 服务跨系统容错配置**：
   - **Windows 正式版系统**（如 21H2 / 22H2 / 23H2 / 24H2 / Win10）：优先调用系统原生 `OpenSSH.Server` 系统功能（FoD），并支持 WinGet / 官方独立 MSI 兜底；
   - **Windows Insider 预览版系统**（如 Dev / Canary 分支）：智能规避 DISM 云端 FoD 缺失挂起缺陷，直接通过 WinGet / 官方独立 MSI 安装，带实时下载进度；
   - 防火墙自动放行 TCP 22 端口入站连接；
   - 修改注册表 `HKLM:\SOFTWARE\OpenSSH` 的 `DefaultShell`，硬编码指定为 `~/Downloads/pwsh/pwsh.exe`；
   - 优化 `sshd_config`（解除管理员组公钥重定向限制，支持全局读取 `~/.ssh/authorized_keys`）；
   - 导入公钥并设置规范严苛的 Windows ACL 安全权限。
4. **桌面挂载计划任务就绪 (TmuxRelay)**：
   - 导入 `TmuxRelay` 模块并注册 `TmuxRelay-main` 交互式桌面计划任务；
   - 确保从远端 SSH 连入时直接穿透进本地交互式桌面的 Session，具备完整的图形桌面令牌、GPU 加速与交互权限；
   - 本仓库保持纯粹的 PowerShell 身份，不硬编码外部 tmux 配置文件，连入后可自由配置个人专属 `~/.tmux.conf`。

---

## 远端连接与验证

构建完成后，控制台将输出本机的局域网 IP 地址。在 macOS / Linux 端直接连接：

```bash
ssh <username>@<windows-ip>
```

- **免密接入**：直接进入 Tmux `main` 会话。
- **共享环境**：与 Windows 物理屏幕打开的终端完全同源。
- **持久运行**：断开 SSH 会话不中断后台进程，再次连入自动 Attach。

---

## 常见维护命令

```powershell
# 查看所有 tmux 会话
tmux list-sessions

# 手动连接到 main 会话
tmux attach-session -t main

# 强制重置 tmux 服务（会话异常时）
tmux kill-server

# 查看中转计划任务状态
Get-ScheduledTask -TaskName TmuxRelay-main
```