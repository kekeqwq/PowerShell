[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$AuthorizedKeysPath,

    [switch]$SkipAdminCheck,
    [switch]$ForceUpdatePwsh
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

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
Write-Host "`n[1/7] 检查并部署 Preview 版 PowerShell (写死 ~/Downloads/pwsh)..." -ForegroundColor Yellow
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
Write-Host "`n[2/7] 检查并安装 WinGet 依赖组件..." -ForegroundColor Yellow

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

# 4. 安装 OpenSSH.Server 功能（兼顾 Windows 正式版与 Insider 预览版系统的容错机制）
Write-Host "`n[3/7] 配置 OpenSSH Server 服务功能..." -ForegroundColor Yellow

# 检测 Windows 系统版本类型（正式版 vs Insider 预览版）
$winBuild = [System.Environment]::OSVersion.Version.Build
$currentVersionKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$displayVer = if ($currentVersionKey) { $currentVersionKey.DisplayVersion } else { '' }

# 判断是否为 Windows 预览版（Canary / Dev / 高于 26100 的预览 build）
$isWindowsPreview = ($winBuild -gt 26100) -or 
                    ($displayVer -in @('Dev', 'Canary')) -or
                    (Test-Path 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability')

if ($isWindowsPreview) {
    Write-Host "[*] 检测到 Windows 预览版/Insider 系统 (Build $winBuild, $displayVer)" -ForegroundColor Cyan
} else {
    Write-Host "[*] 检测到 Windows 正式版系统 (Build $winBuild, $displayVer)" -ForegroundColor Cyan
}

$isSshdInstalled = (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe") -or 
                   (Test-Path "C:\Program Files\OpenSSH\sshd.exe") -or 
                   (Test-Path "C:\Program Files\OpenSSH-ARM64\sshd.exe") -or 
                   (Test-Path "C:\Program Files\OpenSSH-Win64\sshd.exe") -or 
                   (Get-Command sshd.exe -ErrorAction SilentlyContinue) -or 
                   (Get-Service sshd -ErrorAction SilentlyContinue)

if ($isSshdInstalled) {
    Write-Host "[+] OpenSSH.Server 服务已在系统中安装就绪，跳过重复安装" -ForegroundColor Green
} else {
    Write-Host "[*] 系统中尚未检测到 sshd 服务，启动跨 Windows 版本的容错安装..." -ForegroundColor Cyan
    $installed = $false

    # 策略 1（针对 Windows 正式版优先）：正式版拥有官方 FoD 云端支持，使用原生功能安装
    if (-not $isWindowsPreview) {
        try {
            Write-Host "[*] [正式版优先] 正在安装 Windows 原生 OpenSSH.Server 系统功能..." -ForegroundColor Cyan
            $cap = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' -ErrorAction Stop
            if ($cap.State -eq 'Installed' -or (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe")) {
                $installed = $true
                Write-Host "[+] Windows 原生 OpenSSH.Server 功能安装成功" -ForegroundColor Green
            }
        } catch {
            Write-Warning "[-] 原生功能在线安装异常 ($_)，正在回退至 WinGet / 独立安装包..."
        }
    }

    # 策略 2（预览版首选 / 正式版回退）：通过 WinGet 安装 Microsoft 官方 OpenSSH 包（显示下载安装进度）
    if (-not $installed) {
        try {
            Write-Host "[*] 正在通过 WinGet 安装 Microsoft 官方 OpenSSH（显示实时下载进度）..." -ForegroundColor Cyan
            & winget install --id Microsoft.OpenSSH.Preview -e --source winget --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -eq 0 -or (Get-Service sshd -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\OpenSSH\sshd.exe")) {
                $installed = $true
                Write-Host "[+] OpenSSH WinGet 安装完成" -ForegroundColor Green
            }
        } catch {
            Write-Warning "[-] WinGet 安装异常: $_"
        }
    }

    # 策略 3：若 WinGet 失败，直接从 Microsoft GitHub 发行源下载独立 MSI 安装包（无视 Windows 版本与 Windows Update 限制，100% 独立可靠）
    if (-not $installed) {
        try {
            Write-Host "[*] 正在从 Microsoft GitHub 官方源直接下载独立 OpenSSH MSI 安装包..." -ForegroundColor Cyan
            $msiArch = if ($isArm64) { "ARM64" } else { "Win64" }
            $msiUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-$msiArch-v10.0.0.0.msi"
            $tempMsi = Join-Path $env:TEMP "OpenSSH-$msiArch.msi"
            Write-Host "[*] 下载地址: $msiUrl" -ForegroundColor Cyan
            Invoke-WebRequest -Uri $msiUrl -OutFile $tempMsi -UseBasicParsing
            Write-Host "[*] 正在运行 MSI 安装程序..." -ForegroundColor Cyan
            $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$tempMsi`"", "/passive", "/norestart") -PassThru -Wait
            Remove-Item $tempMsi -Force -ErrorAction SilentlyContinue
            if ($proc.ExitCode -eq 0 -or (Get-Service sshd -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\OpenSSH\sshd.exe")) {
                $installed = $true
                Write-Host "[+] OpenSSH MSI 独立安装完成" -ForegroundColor Green
            }
        } catch {
            Write-Warning "[-] 直接下载 MSI 安装包异常: $_"
        }
    }

    # 策略 4：若前述方案均未成功，尝试 DISM 命令行安装（最后的兜底）
    if (-not $installed) {
        Write-Host "[*] 尝试通过 DISM 在线安装..." -ForegroundColor Cyan
        & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart
        if ($LASTEXITCODE -eq 0 -or (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe") -or (Get-Service sshd -ErrorAction SilentlyContinue)) {
            $installed = $true
            Write-Host "[+] OpenSSH.Server DISM 安装完成" -ForegroundColor Green
        }
    }

    # 确保 C:\Program Files\OpenSSH 在 PATH 中并注册服务
    $progOpenSSH = "C:\Program Files\OpenSSH"
    if (Test-Path $progOpenSSH) {
        if ($env:PATH -notlike "*$progOpenSSH*") {
            $env:PATH = "$progOpenSSH;$env:PATH"
        }
        if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
            $installScript = Join-Path $progOpenSSH "install-sshd.ps1"
            if (Test-Path $installScript) {
                & powershell.exe -ExecutionPolicy Bypass -File $installScript | Out-Null
            }
        }
    }
}

# 5. 配置防火墙入站规则
Write-Host "`n[4/7] 配置防火墙 22 端口..." -ForegroundColor Yellow
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 22 `
        -Action Allow | Out-Null
    Write-Host "[+] 防火墙入站规则已添加" -ForegroundColor Green
} else {
    Write-Host "[+] 防火墙规则已存在" -ForegroundColor Green
}

# 6. 配置 sshd 默认 Shell 与公钥认证
Write-Host "`n[5/7] 配置 sshd 默认 Shell 及公钥认证..." -ForegroundColor Yellow
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

# 启动 sshd 服务
Set-Service sshd -StartupType Automatic
Restart-Service sshd
Write-Host "[+] sshd 服务已设置为开机自动启动并已启动" -ForegroundColor Green

# 7. 注册 TmuxRelay 桌面交互计划任务
Write-Host "`n[6/7] 注册 TmuxRelay 桌面交互计划任务..." -ForegroundColor Yellow
$modulePath = Join-Path $PSScriptRoot "Modules\TmuxRelay\TmuxRelay.psd1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
    Install-TmuxRelayTask -Session 'main'
    Write-Host "[+] TmuxRelay-main 计划任务已就绪" -ForegroundColor Green
}

# 8. 开启脚本执行策略
Write-Host "`n[7/7] 开启当前用户脚本执行权限 (RemoteSigned)..." -ForegroundColor Yellow
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
Write-Host "[+] ExecutionPolicy RemoteSigned 已生效" -ForegroundColor Green

# 获取本机局域网 IP 地址
$ips = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -notlike "169.254*" } |
        Select-Object -ExpandProperty IPAddress
)

Write-Host "`n=========================================" -ForegroundColor Cyan
Write-Host "            配置构建全部完成！" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "你现在可以从远端设备通过以下命令直接免密连接：" -ForegroundColor White
foreach ($ip in $ips) {
    Write-Host "  ssh $env:USERNAME@$ip" -ForegroundColor Yellow
}
Write-Host "-----------------------------------------" -ForegroundColor Gray
Write-Host "提示：首次连接前请确认本机已登录桌面（console Active）。" -ForegroundColor Gray