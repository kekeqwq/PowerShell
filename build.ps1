[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$AuthorizedKeysPath,

    [switch]$SkipAdminCheck,
    [switch]$InstallPreview,
    [string]$CustomPwshPath
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

# 查找系统中可用的 PowerShell 7+ 解释器（Preview、稳定版、PATH 或安装目录）
function Find-Pwsh {
    if ($CustomPwshPath -and (Test-Path $CustomPwshPath)) {
        return [System.IO.Path]::GetFullPath($CustomPwshPath)
    }

    # 1. 注册表登记的 OpenSSH DefaultShell
    try {
        $regPwsh = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue).DefaultShell
        if ($regPwsh -and (Test-Path $regPwsh)) {
            return [System.IO.Path]::GetFullPath($regPwsh)
        }
    } catch {}

    # 2. 系统 PATH 中的 pwsh
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd -and (Test-Path $pwshCmd.Source)) {
        return [System.IO.Path]::GetFullPath($pwshCmd.Source)
    }

    # 3. 常见候选路径 (Downloads 绿色版、Program Files 稳定版、Program Files 预览版、Local AppData)
    $candidates = @(
        (Join-Path $HOME "Downloads\pwsh\pwsh.exe"),
        "C:\Program Files\PowerShell\7\pwsh.exe",
        "C:\Program Files\PowerShell\7-preview\pwsh.exe",
        (Join-Path $env:LOCALAPPDATA "Microsoft\PowerShell\pwsh.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) {
            return [System.IO.Path]::GetFullPath($c)
        }
    }

    # 4. 当前运行中的进程
    try {
        $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match 'pwsh' -and (Test-Path $proc.Path)) {
            return [System.IO.Path]::GetFullPath($proc.Path)
        }
    } catch {}

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
    if ($InstallPreview) {
        $argList += "-InstallPreview"
    }
    if ($CustomPwshPath) {
        $argList += @("-CustomPwshPath", "`"$CustomPwshPath`"")
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

# 2. 检查与配置 PowerShell (容错支持：Preview 版、稳定版、现有环境)
Write-Host "`n[1/7] 检查 PowerShell 运行环境..." -ForegroundColor Yellow
$isArm64 = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') -or
           ([System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432') -eq 'ARM64')
$arch = if ($isArm64) { 'arm64' } else { 'x64' }
$targetPwshDir = Join-Path $HOME "Downloads\pwsh"
$targetPwshExe = Join-Path $targetPwshDir "pwsh.exe"

$currentPwsh = Find-Pwsh
if ($currentPwsh -and -not $InstallPreview) {
    $currVer = (& $currentPwsh --version 2>$null)
    Write-Host "[+] 检测到当前已有可用 PowerShell: $currentPwsh ($currVer)" -ForegroundColor Green
    Write-Host "    (若需强制下载更新 Preview 版，可在执行时附加 -InstallPreview 参数)" -ForegroundColor Gray
} else {
    if ($InstallPreview) {
        Write-Host "[*] 已指定 -InstallPreview，准备下载/更新最新 Preview 版 PowerShell..." -ForegroundColor Cyan
    } else {
        Write-Host "[*] 系统中未检测到 PowerShell 7+，开始自动安装..." -ForegroundColor Cyan
    }

    $installedPwsh = $false

    # 尝试方案 1: 下载微软官方 Preview 绿色版到 ~/Downloads/pwsh
    try {
        $httpClient = [System.Net.Http.HttpClient]::new()
        $resp = $httpClient.GetAsync("https://aka.ms/powershell-release?tag=preview").Result
        $tag = $resp.RequestMessage.RequestUri.Segments[-1].TrimEnd('/')
        $version = $tag.TrimStart('v')
        Write-Host "[+] 官方最新 Preview 版本: $tag ($arch)" -ForegroundColor Green

        $needDownload = $true
        if (Test-Path $targetPwshExe) {
            $currVer = (& $targetPwshExe --version 2>$null) -replace 'PowerShell\s*', ''
            if ($currVer -like "*$version*") {
                Write-Host "[+] 当前 $targetPwshExe 已是最新版 ($currVer)，跳过下载" -ForegroundColor Green
                $needDownload = $false
                $installedPwsh = $true
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
            Write-Host "[+] PowerShell Preview 安装完成" -ForegroundColor Green
            $installedPwsh = $true
        }
    } catch {
        Write-Warning "[-] Preview 版直接下载失败: $_"
    }

    # 尝试方案 2: 若 Preview 下载失败且系统尚无 pwsh，通过 WinGet 安装稳定版 Microsoft.PowerShell
    if (-not $installedPwsh -and -not (Find-Pwsh)) {
        try {
            Write-Host "[*] 正在尝试通过 WinGet 安装标准稳定版 PowerShell..." -ForegroundColor Cyan
            & winget install --id Microsoft.PowerShell -e --source winget --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -eq 0 -or (Find-Pwsh)) {
                Write-Host "[+] WinGet 稳定版 PowerShell 安装完成" -ForegroundColor Green
                $installedPwsh = $true
            }
        } catch {
            Write-Warning "[-] WinGet 安装稳定版失败: $_"
        }
    }

    # 尝试方案 3: 若稳定版也失败，尝试通过 WinGet 安装 Preview 版
    if (-not $installedPwsh -and -not (Find-Pwsh)) {
        try {
            Write-Host "[*] 正在尝试通过 WinGet 安装 Preview 版 PowerShell..." -ForegroundColor Cyan
            & winget install --id Microsoft.PowerShell.Preview -e --source winget --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -eq 0 -or (Find-Pwsh)) {
                Write-Host "[+] WinGet Preview 版 PowerShell 安装完成" -ForegroundColor Green
                $installedPwsh = $true
            }
        } catch {
            Write-Warning "[-] WinGet 安装 Preview 版失败: $_"
        }
    }

    $finalCheck = Find-Pwsh
    if ($finalCheck) {
        $v = (& $finalCheck --version 2>$null)
        Write-Host "[+] PowerShell 环境就绪: $finalCheck ($v)" -ForegroundColor Green
    } else {
        Write-Warning "[-] 自动安装 PowerShell 7+ 未成功，稍后可手动安装或由系统继续使用老版本 PowerShell"
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

# 4. 安装 OpenSSH.Server 功能
Write-Host "`n[3/7] 配置 OpenSSH Server 服务功能..." -ForegroundColor Yellow

$isSshdInstalled = (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe") -or 
                   (Test-Path "C:\Program Files\OpenSSH\sshd.exe") -or 
                   (Test-Path "C:\Program Files\OpenSSH-ARM64\sshd.exe") -or 
                   (Test-Path "C:\Program Files\OpenSSH-Win64\sshd.exe") -or 
                   (Get-Command sshd.exe -ErrorAction SilentlyContinue) -or 
                   (Get-Service sshd -ErrorAction SilentlyContinue)

if ($isSshdInstalled) {
    Write-Host "[+] OpenSSH.Server 服务已在系统中安装就绪，跳过重复安装" -ForegroundColor Green
} else {
    Write-Host "[*] 检测到系统中尚未安装 OpenSSH.Server，开始安装..." -ForegroundColor Cyan
    $installed = $false

    # 方式 1：优先通过 WinGet 安装 Microsoft 官方 OpenSSH 包（独立 MSI 包，不受系统 Insider/Canary 版本限制，自带下载进度）
    try {
        Write-Host "[*] 正在通过 WinGet 安装 Microsoft 官方 OpenSSH（显示下载安装进度）..." -ForegroundColor Cyan
        & winget install --id Microsoft.OpenSSH.Preview -e --source winget --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -eq 0 -or (Get-Service sshd -ErrorAction SilentlyContinue) -or (Test-Path "C:\Program Files\OpenSSH\sshd.exe")) {
            $installed = $true
            Write-Host "[+] OpenSSH WinGet 安装完成" -ForegroundColor Green
        }
    } catch {
        Write-Warning "[-] WinGet 安装异常: $_"
    }

    # 方式 2：若 WinGet 安装受限，直接从官方 GitHub 发行源下载独立 MSI 安装包
    if (-not $installed) {
        try {
            Write-Host "[*] 正在从 Microsoft GitHub 发行源直接下载独立 OpenSSH MSI 安装包..." -ForegroundColor Cyan
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

    # 方式 3：若前两者均未安装，尝试 DISM Windows 功能安装
    if (-not $installed) {
        Write-Host "[*] 尝试通过 DISM 功能在线安装..." -ForegroundColor Cyan
        & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart
        if ($LASTEXITCODE -eq 0 -or (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe") -or (Get-Service sshd -ErrorAction SilentlyContinue)) {
            $installed = $true
            Write-Host "[+] OpenSSH.Server DISM 安装完成" -ForegroundColor Green
        }
    }

    # 确保 C:\Program Files\OpenSSH 在 PATH 中
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
$finalPwsh = Find-Pwsh

if ($finalPwsh) {
    if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) {
        New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
    }
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $finalPwsh -PropertyType String -Force | Out-Null
    Write-Host "[+] OpenSSH DefaultShell 已设置为: $finalPwsh" -ForegroundColor Green
} else {
    Write-Warning "[-] 未检测到 PowerShell 7+，DefaultShell 将保留系统默认 Shell"
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