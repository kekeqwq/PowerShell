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
    $downloadPwsh = Join-Path $HOME 'Downloads\pwsh\pwsh.exe'
    if (Test-Path $downloadPwsh) { return $downloadPwsh }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'pwsh.exe not found'
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
        # 优化：先尝试直接触发已存在的计划任务（40ms），若任务不存在再走慢速注册逻辑
        $run = schtasks.exe /run /tn $script:TaskName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Install-TmuxRelayTask -Session $Session
            $run = schtasks.exe /run /tn $script:TaskName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "schtasks /run failed: $run"
            }
        }

        # 毫秒级轮询（100ms 步长，响应更快）
        $ok = $false
        foreach ($i in 1..40) {
            Start-Sleep -Milliseconds 100
            if (Get-TmuxAlive $Session) { $ok = $true; break }
        }
        if (-not $ok) {
            throw "TmuxSpawnOnce ran but session '$Session' did not appear"
        }
    }

    $env:TERM = 'xterm-256color'
    & (Get-TmuxPath) attach-session -t $Session
    # 退出 tmux 会话时，顺带关闭 SSH 外层外壳，不掉落到非 relay 环境
    exit
}

Export-ModuleMember -Function Enter-TmuxRelay
