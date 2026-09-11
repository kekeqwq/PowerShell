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

### 2. 准备公钥
将客户端公钥保存至例如 `~/Downloads/authorized_keys`（或 `id_ed25519.pub`）。

### 3. 运行一键构建脚本

> **注意（关于脚本执行策略）**：  
> Windows 默认禁止运行 `.ps1` 脚本（`Restricted` 策略）。本仓库提供了两种执行方式：

#### 方式 A（推荐，CMD 包装器自动绕过策略）：
```powershell
./build.cmd ~/Downloads/authorized_keys
```

#### 方式 B（原生 PowerShell 脚本）：
如直接运行 `./build.ps1`，需先开启当前用户脚本执行权限：
```powershell
# 开启脚本执行开关（仅需运行一次）
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force

# 运行构建脚本
./build.ps1 ~/Downloads/authorized_keys
```

脚本若未在管理员权限下运行，会自动弹出 UAC 提权窗口；若在无图形环境下请直接以管理员身份打开终端运行。

---

## 脚本自动完成的操作

运行脚本后，将全自动完成以下所有配置：

1. **PowerShell Preview 下载部署**：
   - 自动识别系统架构（ARM64 / x64）；
   - 从微软官方发布源直接获取最新 Preview 版本（无需鉴权，不触发 GitHub API 速率限制）；
   - 下载 ZIP 绿色包并解压部署到 `~/Downloads/pwsh`。
2. **依赖组件静默安装**：
   - 通过 WinGet 自动安装 `marlocarlo.psmux` (Windows 原生 Tmux)；
   - 通过 WinGet 自动安装 `JanDeDobbeleer.OhMyPosh` 提示符工具。
3. **OpenSSH Server 服务配置**：
   - 安装 `OpenSSH.Server` 系统功能并设为开机自启；
   - 防火墙放行 TCP 22 端口入站连接；
   - 修改注册表 `HKLM:\SOFTWARE\OpenSSH` 的 `DefaultShell`，指定为 `~/Downloads/pwsh/pwsh.exe`；
   - 优化 `sshd_config`（解除管理员组公钥重定向限制，支持全局读取 `~/.ssh/authorized_keys`）；
   - 导入公钥并设置规范的 Windows ACL 权限。
4. **Tmux / psmux 配置文件部署**：
   - 将移植自 Omarchy 的 Catppuccin 主题部署至 `~/.tmux.conf`、`~/.psmux.conf`；
   - 配置 `set -g allow-predictions on`（启用类似 fish 的浅色历史预测与右箭头补全）；
   - 配置 `set -g mouse off`（避免 Windows ConPTY 在 SSH 模式下产生 `35;xx;xxM` 鼠标转义字符泄漏）。
5. **桌面挂载计划任务就绪**：
   - 导入 `TmuxRelay` 模块并预注册 `TmuxRelay-main` 交互式桌面计划任务；
   - 确保从远端 SSH 连入时直接穿透进本地桌面的 Session，具备完整的图形桌面令牌、GPU 加速与交互权限。

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