[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$AuthorizedKeysPath,

    [switch]$SkipAdminCheck,
    [switch]$ForceUpdatePwsh
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

# 全局异常捕获：防止窗口一闪而过，确保用户能清晰看到报错信息
trap {
    Write-Host "`n========================================================" -ForegroundColor Red
    Write-Host "[-] 脚本执行出现异常: $_" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    Write-Host "========================================================" -ForegroundColor Red
    Write-Host "`n按任意键退出窗口..." -ForegroundColor Yellow
    try { [void][System.Console]::ReadKey($true) } catch { Read-Host "按回车键退出..." }
    exit 1
}

# 智能解析公钥文件路径（支持直接路径、~、相对路径，以及自动定位常见文件名）
function Resolve-KeyPath {
    param([string]$Path)
    if ($Path) {
        # 1. 展开 ~
        if ($Path.StartsWith("~")) {
            $Path = Join-Path $HOME $Path.Substring(1).TrimStart('\', '/')
        }

        # 2. 直接检查完整路径
        if (Test-Path $Path) {
            return [System.IO.Path]::GetFullPath($Path)
        }

        # 3. 检查相对于当前工作目录的路径
        $cwdPath = Join-Path (Get-Location) $Path
        if (Test-Path $cwdPath) {
            return [System.IO.Path]::GetFullPath($cwdPath)
        }

        # 4. 容错处理：用户在 Documents\PowerShell 输入 ..\.ssh\... 时自动匹配用户目录
        $fileName = [System.IO.Path]::GetFileName($Path)
        $candidates = @(
            (Join-Path $HOME ".ssh\$fileName"),
            (Join-Path $HOME "Downloads\$fileName"),
            (Join-Path $HOME $Path.TrimStart('\', '/', '.'))
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) {
                return [System.IO.Path]::GetFullPath($c)
            }
        }
    }

    # 5. 未显式传入参数时，自动扫描默认路径下的公钥文件
    $defaultKeys = @(
        (Join-Path $HOME "Downloads\authorized_keys"),
        (Join-Path $HOME "Downloads\id_ed25519.pub"),
        (Join-Path $HOME "Downloads\id_rsa.pub"),
        (Join-Path $HOME ".ssh\id_ed25519.pub"),
        (Join-Path $HOME ".ssh\id_rsa.pub")
    )
    foreach ($k in $defaultKeys) {
        if (Test-Path $k) {
            return [System.IO.Path]::GetFullPath($k)
        }
    }

    return $null
}

$ResolvedKeyPath = Resolve-KeyPath -Path $AuthorizedKeysPath

# 1. 确保以管理员权限运行
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $SkipAdminCheck) {
    Write-Host "[*] 检测到当前非管理员权限，正在请求提升权限 (UAC)..." -ForegroundColor Yellow
    $callerExe = (Get-Process -Id $PID).Path
    $escapedScript = "`"$PSCommandPath`""
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $escapedScript)
    if ($ResolvedKeyPath) {
        $argList += "`"$ResolvedKeyPath`""
    }
    if ($ForceUpdatePwsh) {
        $argList += "-ForceUpdatePwsh"
    }
    try {
        $p = Start-Process -FilePath $callerExe -ArgumentList $argList -Verb RunAs -PassThru -Wait
        exit $p.ExitCode
    } catch {
        Write-Warning "[-] 无法自动拉起管理员提权窗口（可能在无图形界面的远程/后台终端中运行）。"
        Write-Warning "[-] 请右键选择『以管理员身份运行』PowerShell 终端后重新执行脚本。"
        exit 1
    }
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Windows SSH + Tmux 环境一键部署脚本" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

if ($ResolvedKeyPath -and (Test-Path $ResolvedKeyPath)) {
    Write-Host "[+] 识别到免密登录公钥: $ResolvedKeyPath" -ForegroundColor Green
} else {
    Write-Warning "[-] 未找到公钥文件，稍后需手动配置 ~/.ssh/authorized_keys"
}

# 2. 下载并部署最新 Preview 版 PowerShell 到 ~/Downloads/pwsh（写死 Preview 绿色版）
Write-Host "`n[1/6] 检查并部署 Preview 版 PowerShell (写死 ~/Downloads/pwsh)..." -ForegroundColor Yellow
$isArm64 = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or
           ([System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432') -eq 'ARM64')
$arch = if ($isArm64) { 'arm64' } else { 'x64' }
$targetPwshDir = Join-Path $HOME "Downloads\pwsh"
$targetPwshExe = Join-Path $targetPwshDir "pwsh.exe"

try {
    # 通过 aka.ms 获取最新 preview release 重定向标签（避免 GitHub API 速率限制）
    $httpClient = [System.Net.Http.HttpClient]::new()
    $resp = $httpClient.GetAsync("https://aka.ms/powershell-release?tag=preview").Result
    $tag = $resp.RequestMessage.RequestUri.Segments[-1].TrimEnd('/')
    $version = $tag.TrimStart('v')
    Write-Host "[+] 官方最新 Preview 版本: $tag ($arch)" -ForegroundColor Green

    $needDownload = $true
    if ((Test-Path $targetPwshExe) -and -not $ForceUpdatePwsh) {
        $currVer = (& $targetPwshExe --version 2>$null) -replace 'PowerShell\s*', ''
        if ($currVer -like "*$version*") {
            Write-Host "[+] 当前 $targetPwshExe 已是最新 Preview 版 ($currVer)，跳过重复下载" -ForegroundColor Green
            $needDownload = $false
        }
    }

    if ($needDownload) {
        $zipUrl = "https://github.com/PowerShell/PowerShell/releases/download/$tag/PowerShell-$version-win-$arch.zip"
        $tempZip = Join-Path $env:TEMP "PowerShell-$version-win-$arch.zip"
        Write-Host "[*] 正在下载 $zipUrl ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing

        if (-not (Test-Path $targetPwshDir)) {
            New-Item -Path $targetPwshDir -ItemType Directory -Force | Out-Null
        }
        Write-Host "[*] 正在解压到 $targetPwshDir ..." -ForegroundColor Cyan
        Expand-Archive -Path $tempZip -DestinationPath $targetPwshDir -Force
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Write-Host "[+] PowerShell Preview 部署就绪: $targetPwshExe" -ForegroundColor Green
    }
} catch {
    Write-Warning "[-] 下载最新 Preview 版失败: $_"
    if (Test-Path $targetPwshExe) {
        Write-Host "[*] 继续使用现有 $targetPwshExe" -ForegroundColor Cyan
    } else {
        throw "无法获取 Preview 版 PowerShell，请检查网络后重试"
    }
}

# 3. 安装其余依赖 (psmux, oh-my-posh)
Write-Host "`n[2/6] 检查并安装 WinGet 依赖组件..." -ForegroundColor Yellow

function Install-WinGetPackage {
    param([string]$Id, [string]$CommandCheck)
    if ($CommandCheck) {
        $foundCmd = Get-Command $CommandCheck -ErrorAction SilentlyContinue
        if ($foundCmd) {
            Write-Host "[+] $Id ($CommandCheck) 已就绪，跳过" -ForegroundColor Green
            return
        }
    }
    Write-Host "[*] 正在通过 winget 安装 $Id..." -ForegroundColor Cyan
    & winget install --id $Id -e --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 2316632065) {
        Write-Host "[+] $Id 安装成功" -ForegroundColor Green
    } else {
        Write-Warning "[-] winget 安装 $Id 返回代码: $LASTEXITCODE"
    }
}

Install-WinGetPackage -Id "marlocarlo.psmux" -CommandCheck "tmux"
Install-WinGetPackage -Id "JanDeDobbeleer.OhMyPosh" -CommandCheck "oh-my-posh"

# 4. 检查、安装并修复 OpenSSH.Server 服务功能
Write-Host "`n[3/6] 配置 OpenSSH Server 服务功能与持久化自启..." -ForegroundColor Yellow

$sysSshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
$progSshdExe = "C:\Program Files\OpenSSH\sshd.exe"

# 阶段 1：确保系统上存在 sshd.exe 可执行程序文件
$hasSshdBin = (Test-Path $sysSshdExe) -or (Test-Path $progSshdExe)
if (-not $hasSshdBin) {
    Write-Host "[*] 系统中尚未检测到 sshd 可执行程序，启动系统功能安装..." -ForegroundColor Cyan
    $installedFoD = $false

    # 1. 优先尝试 Windows 原生 Add-WindowsCapability（临时规避 WSUS 限制）
    $auKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $origWUServer = $null
    if (Test-Path $auKey) {
        $origWUServer = (Get-ItemProperty $auKey -Name UseWUServer -ErrorAction SilentlyContinue).UseWUServer
        if ($origWUServer -eq 1) {
            Set-ItemProperty $auKey -Name UseWUServer -Value 0 -Force
            Restart-Service wuauserv -ErrorAction SilentlyContinue
        }
    }

    try {
        Write-Host "[*] 正在通过 Add-WindowsCapability 安装原生 OpenSSH.Server 功能..." -ForegroundColor Cyan
        $result = Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop
        if ($result.State -eq 'Installed' -or (Test-Path $sysSshdExe)) {
            $installedFoD = $true
            Write-Host "[+] Windows 原生 OpenSSH.Server 功能安装成功" -ForegroundColor Green
        }
    } catch {
        Write-Warning "[-] Add-WindowsCapability 失败: $_"
    } finally {
        if ($origWUServer -eq 1) {
            Set-ItemProperty $auKey -Name UseWUServer -Value 1 -Force
            Restart-Service wuauserv -ErrorAction SilentlyContinue
        }
    }

    # 2. DISM 在线安装兜底
    if (-not $installedFoD -and -not (Test-Path $sysSshdExe)) {
        Write-Host "[*] 尝试通过 DISM 在线添加 OpenSSH.Server 功能..." -ForegroundColor Cyan
        & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart
        if (Test-Path $sysSshdExe) {
            $installedFoD = $true
            Write-Host "[+] DISM 安装 OpenSSH.Server 成功" -ForegroundColor Green
        }
    }

    # 3. 独立发布包兜底（如果系统 FoD 库损坏或网络受限）
    if (-not $installedFoD -and -not (Test-Path $sysSshdExe) -and -not (Test-Path $progSshdExe)) {
        Write-Warning "[-] 系统 FoD 功能安装未成功，正在回退至 Microsoft 官方 Win32-OpenSSH 独立包..."
        $zipArch = if ($isArm64) { "OpenSSH-ARM64.zip" } else { "OpenSSH-Win64.zip" }
        $tempZip = Join-Path $env:TEMP $zipArch
        $downloadSuccess = $false

        $githubUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/$zipArch"
        try {
            Write-Host "[*] 正在下载 $githubUrl ..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $githubUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 60
            $downloadSuccess = $true
        } catch {
            Write-Warning "[-] GitHub 下载失败: $_，尝试通过 winget 安装 OpenSSH..."
        }

        if ($downloadSuccess -and (Test-Path $tempZip)) {
            $progOpenSSH = "C:\Program Files\OpenSSH"
            if (-not (Test-Path $progOpenSSH)) { New-Item -Path $progOpenSSH -ItemType Directory -Force | Out-Null }
            Expand-Archive -Path $tempZip -DestinationPath $env:TEMP -Force
            $extractedFolder = Join-Path $env:TEMP ($zipArch -replace '\.zip$', '')
            Copy-Item -Path "$extractedFolder\*" -Destination $progOpenSSH -Recurse -Force
            Remove-Item $tempZip, $extractedFolder -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path "C:\Program Files\OpenSSH\install-sshd.ps1") {
                & powershell.exe -ExecutionPolicy Bypass -File "C:\Program Files\OpenSSH\install-sshd.ps1"
                Write-Host "[+] 官方独立版 OpenSSH 部署完成" -ForegroundColor Green
            }
        } else {
            Write-Host "[*] 正在通过 WinGet 部署 OpenSSH..." -ForegroundColor Cyan
            & winget install --id Microsoft.OpenSSH.Preview -e --source winget --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        }
    }
} else {
    Write-Host "[+] 检测到 sshd 程序文件已就绪" -ForegroundColor Green
}

# 阶段 2：定位实际可用的 sshd.exe 和 ssh-agent.exe 路径
$activeSshdBin = $null
$activeAgentBin = $null

if (Test-Path $sysSshdExe) {
    $activeSshdBin = $sysSshdExe
    $activeAgentBin = "$env:SystemRoot\System32\OpenSSH\ssh-agent.exe"
} elseif (Test-Path $progSshdExe) {
    $activeSshdBin = $progSshdExe
    $activeAgentBin = "C:\Program Files\OpenSSH\ssh-agent.exe"
    $progOpenSSH = "C:\Program Files\OpenSSH"
    if ($env:PATH -notlike "*$progOpenSSH*") {
        $env:PATH = "$progOpenSSH;$env:PATH"
    }
}

if (-not $activeSshdBin) {
    throw "未能在系统中找到可用的 sshd.exe，请检查网络后重新运行构建脚本！"
}

# 阶段 3：确保 Windows 服务管理器中已正确注册 sshd 与 ssh-agent 服务
$sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshdSvc) {
    Write-Host "[*] 检测到 sshd 尚未注册为 Windows 服务，正在立即向系统注册服务..." -ForegroundColor Cyan
    if (Test-Path "C:\Program Files\OpenSSH\install-sshd.ps1") {
        & powershell.exe -ExecutionPolicy Bypass -File "C:\Program Files\OpenSSH\install-sshd.ps1" | Out-Null
    } else {
        & sc.exe create sshd binPath= "`"$activeSshdBin`"" start= auto DisplayName= "OpenSSH SSH Server" | Out-Null
        & sc.exe description sshd "SSH protocol based service to provide secure encrypted communications between two untrusted hosts over an insecure network." | Out-Null
        & sc.exe privs sshd SeAssignPrimaryTokenPrivilege/SeTcbPrivilege/SeBackupPrivilege/SeRestorePrivilege/SeImpersonatePrivilege | Out-Null
    }
    $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
}

$agentSvc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
if (-not $agentSvc -and $activeAgentBin -and (Test-Path $activeAgentBin)) {
    & sc.exe create ssh-agent binPath= "`"$activeAgentBin`"" start= auto DisplayName= "OpenSSH Authentication Agent" | Out-Null
    & sc.exe description ssh-agent "Agent to hold private keys used for public key authentication." | Out-Null
    & sc.exe privs ssh-agent SeAssignPrimaryTokenPrivilege/SeTcbPrivilege/SeBackupPrivilege/SeRestorePrivilege/SeImpersonatePrivilege | Out-Null
    $agentSvc = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
}

# 阶段 4：确保主机密钥生成与权限修复（避免因密钥缺失或权限问题导致 sshd 启动失败）
$progDataSsh = Join-Path $env:ProgramData "ssh"
if (-not (Test-Path $progDataSsh)) {
    New-Item -Path $progDataSsh -ItemType Directory -Force | Out-Null
}

$hostKeys = Get-ChildItem -Path $progDataSsh -Filter "ssh_host_*_key" -ErrorAction SilentlyContinue
if (-not $hostKeys -or $hostKeys.Count -eq 0) {
    Write-Host "[*] 检测到主机密钥不存在，正在生成主机密钥 (ssh-keygen -A)..." -ForegroundColor Cyan
    $keygenExe = if (Test-Path "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe") {
        "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe"
    } elseif (Test-Path "C:\Program Files\OpenSSH\ssh-keygen.exe") {
        "C:\Program Files\OpenSSH\ssh-keygen.exe"
    } else {
        (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
    }
    if ($keygenExe) {
        & $keygenExe -A 2>&1 | Out-Null
    }
}

# 严格收紧 %ProgramData%\ssh 与主机私钥 ACL 权限（OpenSSH 强制安全检查）
try {
    & icacls "$progDataSsh" /inheritance:r /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" 2>&1 | Out-Null
    Get-ChildItem -Path "$progDataSsh\ssh_host_*_key" -ErrorAction SilentlyContinue | ForEach-Object {
        & icacls $_.FullName /inheritance:r /grant "SYSTEM:F" "Administrators:F" 2>&1 | Out-Null
    }
} catch {}

# 阶段 5：配置服务为自动启动、崩溃自愈策略并启动服务
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
& sc.exe config sshd start= auto | Out-Null
& sc.exe failure sshd reset= 86400 actions= restart/2000/restart/5000/restart/10000 | Out-Null

Set-Service ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
& sc.exe config ssh-agent start= auto | Out-Null

Start-Service ssh-agent -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue

# 阶段 6：启动状态校验与自愈重试
$currentSshd = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $currentSshd -or $currentSshd.Status -ne 'Running') {
    Write-Warning "[-] sshd 尚未处于运行状态，正在进行诊断与重新拉起..."
    Restart-Service sshd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $currentSshd = Get-Service sshd -ErrorAction SilentlyContinue
}

if ($currentSshd -and $currentSshd.Status -eq 'Running') {
    Write-Host "[+] sshd 服务已就绪并正常运行 (PID: $((Get-Process sshd -ErrorAction SilentlyContinue).Id | Select-Object -First 1))" -ForegroundColor Green
} else {
    Write-Warning "[-] sshd 服务未能成功启动，请在完成后查看控制台诊断信息"
}

# 5. 配置防火墙入站规则（确保放行所有网络类型：Domain, Private, Public）
Write-Host "`n[4/6] 配置防火墙 22 端口 (放行所有网络类型: 局域网/公用网络)..." -ForegroundColor Yellow
$fwRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 22 `
        -Profile Any `
        -Action Allow | Out-Null
    Write-Host "[+] 防火墙入站规则已添加 (Profile: Any)" -ForegroundColor Green
} else {
    Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -Enabled True -Profile Any -Action Allow | Out-Null
    Write-Host "[+] 防火墙入站规则已更新并放行所有网络类型 (Profile: Any)" -ForegroundColor Green
}

# 将当前局域网连接类别设置为专用网络 (Private)，避免公用网络防火墙阻断局域网连接
try {
    Get-NetConnectionProfile | Where-Object { $_.InterfaceAlias -notmatch 'tun|loopback' } |
        Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    Write-Host "[+] 已将当前局域网连接设为 Private (专用网络)" -ForegroundColor Green
} catch {}

# 6. 配置 sshd 默认 Shell 与公钥认证
Write-Host "`n[5/6] 配置 sshd 默认 Shell 及公钥认证..." -ForegroundColor Yellow
if (Test-Path $targetPwshExe) {
    if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) {
        New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
    }
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $targetPwshExe -PropertyType String -Force | Out-Null
    Write-Host "[+] OpenSSH DefaultShell 已设置为 Preview 版: $targetPwshExe" -ForegroundColor Green
} else {
    Write-Warning "[-] 未检测到 $targetPwshExe，请检查 Preview 版安装情况"
}

# 修正 sshd_config，允许管理员账户正常读取 ~/.ssh/authorized_keys
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (Test-Path $sshdConfig) {
    $cfg = Get-Content $sshdConfig -Raw
    $cfg = $cfg -replace '(?m)^(Match Group administrators\b)', '#$1'
    $cfg = $cfg -replace '(?m)^(\s*AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys\b)', '#$1'
    Set-Content -Path $sshdConfig -Value $cfg -Encoding utf8
    Write-Host "[+] 已更新 sshd_config（支持全局使用 ~/.ssh/authorized_keys）" -ForegroundColor Green
}

# 导入公钥
if ($ResolvedKeyPath -and (Test-Path $ResolvedKeyPath)) {
    $sshDir = Join-Path $HOME ".ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
    }
    $authKeysFile = Join-Path $sshDir "authorized_keys"
    $newKeys = Get-Content -Path $ResolvedKeyPath | Where-Object { $_ -and $_.Trim() -and ($_ -match '^(ssh-|ecdsa-|sk-)') }

    $existingKeys = @()
    if (Test-Path $authKeysFile) {
        $existingKeys = Get-Content -Path $authKeysFile
    }
    foreach ($nk in $newKeys) {
        if ($existingKeys -notcontains $nk) {
            Add-Content -Path $authKeysFile -Value $nk
        }
    }

    # 同时写入 administrators_authorized_keys 备份以保证双重稳妥
    $adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
    if (Test-Path "C:\ProgramData\ssh") {
        foreach ($nk in $newKeys) {
            Add-Content -Path $adminKeys -Value $nk -ErrorAction SilentlyContinue
        }
        icacls $adminKeys /inheritance:r /grant "Administrators:F" "SYSTEM:F" 2>&1 | Out-Null
    }

    # 规范化 ACL 权限（OpenSSH 强制要求密钥文件权限收紧）
    icacls $sshDir /inheritance:r /grant "$($env:USERNAME):(OI)(CI)F" "SYSTEM:(OI)(CI)F" 2>&1 | Out-Null
    icacls $authKeysFile /inheritance:r /grant "$($env:USERNAME):F" "SYSTEM:F" 2>&1 | Out-Null
    Write-Host "[+] 公钥已导入并配置安全权限" -ForegroundColor Green
}

# 启动并确认 sshd 服务
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
Restart-Service sshd -ErrorAction SilentlyContinue
Write-Host "[+] sshd 服务已重启并确认开机自启生效" -ForegroundColor Green

# 7. 开启脚本执行策略
Write-Host "`n[6/6] 开启当前用户脚本执行权限 (RemoteSigned)..." -ForegroundColor Yellow
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
Write-Host "[+] ExecutionPolicy RemoteSigned 已生效" -ForegroundColor Green

# 获取本机局域网 IP 地址
$ips = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.254*" } |
        Select-Object -ExpandProperty IPAddress
)

# 9. 输出 OpenSSH 服务状态与配置验收报告
$finalSshd = Get-Service sshd -ErrorAction SilentlyContinue
$finalAgent = Get-Service "ssh-agent" -ErrorAction SilentlyContinue
$port22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "       OpenSSH 服务状态与配置报告" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

if ($finalSshd) {
    $statusText = if ($finalSshd.Status -eq 'Running') { "运行中 (Running)" } else { "未运行 ($($finalSshd.Status))" }
    $statusColor = if ($finalSshd.Status -eq 'Running') { "Green" } else { "Red" }
    Write-Host "sshd 服务状态 : " -NoNewline
    Write-Host $statusText -ForegroundColor $statusColor

    $startTypeText = if ($finalSshd.StartType -eq 'Automatic') { "已设为开机自启 (Automatic)" } else { "未设自启 ($($finalSshd.StartType))" }
    $startTypeColor = if ($finalSshd.StartType -eq 'Automatic') { "Green" } else { "Red" }
    Write-Host "sshd 启动类型 : " -NoNewline
    Write-Host $startTypeText -ForegroundColor $startTypeColor

    Write-Host "sshd 程序路径 : $($finalSshd.BinaryPathName)" -ForegroundColor Gray
} else {
    Write-Host "sshd 服务状态 : " -NoNewline
    Write-Host "未检测到 sshd 服务！请检查系统组件" -ForegroundColor Red
}

if ($finalAgent) {
    Write-Host "ssh-agent状态 : " -NoNewline
    Write-Host "$($finalAgent.Status) (启动类型: $($finalAgent.StartType))" -ForegroundColor Gray
}

Write-Host "TCP 22 端口   : " -NoNewline
if ($port22) {
    Write-Host "已正常监听 (TCP 22)" -ForegroundColor Green
} else {
    Write-Host "未处于监听状态（若刚启动可能需稍等 1-2 秒）" -ForegroundColor Yellow
}

$defaultShell = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue).DefaultShell
if ($defaultShell) {
    Write-Host "登录默认Shell : $defaultShell" -ForegroundColor Cyan
}

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "            配置构建全部完成！" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "你现在可以从远端设备通过以下命令直接免密连接：" -ForegroundColor White
foreach ($ip in $ips) {
    Write-Host "  ssh $env:USERNAME@$ip" -ForegroundColor Yellow
}
Write-Host "-----------------------------------------" -ForegroundColor Gray
Write-Host "提示：首次连接前请确认本机已登录物理桌面（console Active）。" -ForegroundColor Gray

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "  配置已全部就绪，请按任意键退出窗口..." -ForegroundColor Yellow
Write-Host "=========================================" -ForegroundColor Cyan
try {
    [void][System.Console]::ReadKey($true)
} catch {
    Read-Host "按回车键退出..."
}