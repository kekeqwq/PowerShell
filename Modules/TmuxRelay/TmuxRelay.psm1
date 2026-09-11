Set-StrictMode -Version Latest

$script:TaskName = 'TmuxSpawnOnce'
$script:DefaultSession = 'main'
$script:CachedTmuxPath = $null

function Get-TmuxPath {
    if ($script:CachedTmuxPath -and (Test-Path $script:CachedTmuxPath)) {
        return $script:CachedTmuxPath
    }

    # 1. 快速检查已知的 WinGet 原生 Packages 路径 (极速命中，避免通配符目录扫描)
    $knownPkg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\marlocarlo.psmux_Microsoft.Winget.Source_8wekyb3d8bbwe\tmux.exe'
    if (Test-Path $knownPkg) {
        $script:CachedTmuxPath = $knownPkg
        return $knownPkg
    }

    # 2. 回退通配符目录匹配
    $pkgDir = Get-ChildItem -Directory (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\marlocarlo.psmux*') -ErrorAction SilentlyContinue |
              Select-Object -Last 1
    if ($pkgDir) {
        $exe = Join-Path $pkgDir.FullName 'tmux.exe'
        if (Test-Path $exe) {
            $script:CachedTmuxPath = $exe
            return $exe
        }
    }

    # 3. 从 PATH 中查找真实二进制
    $cmd = Get-Command tmux, psmux -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        $item = Get-Item $cmd.Source -ErrorAction SilentlyContinue
        if ($item -and $item.LinkTarget -and (Test-Path $item.LinkTarget)) {
            $script:CachedTmuxPath = $item.LinkTarget
            return $item.LinkTarget
        }
        $script:CachedTmuxPath = $cmd.Source
        return $cmd.Source
    }

    throw 'tmux.exe or psmux.exe not found'
}

function Get-PwshPath {
    $previewPwsh = Join-Path $HOME 'Downloads\pwsh\pwsh.exe'
    if (Test-Path $previewPwsh) { return $previewPwsh }

    try {
        $regDefault = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue).DefaultShell
        if ($regDefault -and (Test-Path $regDefault)) { return $regDefault }
    } catch {}

    $currProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    if ($currProc -and $currProc.ProcessName -match 'pwsh' -and (Test-Path $currProc.Path)) {
        return $currProc.Path
    }
    throw "Preview pwsh.exe not found at $previewPwsh"
}

function Get-TmuxAlive {
    param([string]$Name)
    $tmux = Get-TmuxPath
    try {
        $null = & $tmux has-session -t $Name 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-TmuxRelayTask {
    param([string]$Session)

    $pwsh    = Get-PwshPath
    $tmux    = Get-TmuxPath
    $user    = "$env:COMPUTERNAME\$env:USERNAME"
    $homeDir = $HOME
    $arg     = "-NoProfile -WindowStyle Hidden -Command `"Set-Location '$homeDir'; `$env:TERM = 'xterm-256color'; & '$tmux' new-session -d -s $Session '$pwsh'`""

    $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        $exe = @($existing.Actions)[0].Execute
        $currentArg = @($existing.Actions)[0].Arguments
        if ($exe -and (Test-Path $exe) -and ($currentArg -eq $arg)) { return }
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }

    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg -WorkingDirectory $homeDir
    $prin   = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Principal $prin -Settings $set | Out-Null
}

function Enter-TmuxRelay {
    [CmdletBinding()]
    param([string]$Session = $script:DefaultSession)

    if ($env:TMUX -or $env:TMUX_SKIP) { return }

    if (-not (Get-TmuxAlive $Session)) {
        # 1. 尝试通过桌面计划任务（TmuxSpawnOnce）挂载到物理控制台会话
        $spawnOk = $false
        try {
            $run = schtasks.exe /run /tn $script:TaskName 2>&1
            if ($LASTEXITCODE -ne 0) {
                Install-TmuxRelayTask -Session $Session
                $run = schtasks.exe /run /tn $script:TaskName 2>&1
            }
            if ($LASTEXITCODE -eq 0) {
                foreach ($i in 1..25) {
                    Start-Sleep -Milliseconds 100
                    if (Get-TmuxAlive $Session) { $spawnOk = $true; break }
                }
            }
        } catch {}

        # 2. 容错降级：若系统刚重启、物理桌面尚未登录（console 未处于活跃状态），交互式计划任务无法拉起，
        # 则直接在后台拉起当前用户的 Tmux 会话，绝不抛出异常断开 SSH 连接！
        if (-not $spawnOk -and -not (Get-TmuxAlive $Session)) {
            $pwsh = Get-PwshPath
            $tmux = Get-TmuxPath
            try {
                & $tmux new-session -d -s $Session $pwsh 2>&1 | Out-Null
            } catch {}
        }
    }

    $env:TERM = 'xterm-256color'
    try {
        & (Get-TmuxPath) attach-session -t $Session
    } catch {
        Write-Warning "[-] Tmux attach 异常，回退至原生 PowerShell 会话。"
        return
    }
    exit
}

Export-ModuleMember -Function Enter-TmuxRelay
