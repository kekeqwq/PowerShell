# scp / sftp / ssh host <command>：非交互式调用整文件立即退出，禁止任何输出
if ($env:SSH_ORIGINAL_COMMAND) { return }

$argv = [Environment]::GetCommandLineArgs()
if (($argv | Where-Object { $_ -in '-Command', '-c', '/c', '-File' }) -and ($argv -notcontains '-NoExit')) {
    return
}

$env:TERM = 'xterm-256color'
$env:PSMUX_FORCE_MOUSE = '0'

# 关闭终端可能残留的鼠标跟踪模式，防止 ConPTY 漏码产生类似 35;xx;xxM 的字符（仅在交互式会话中输出）
if ($Host.UI.RawUI) {
    [Console]::Write("`e[?1000l`e[?1002l`e[?1003l`e[?1006l")
}

# 1. 快速注入 tmux 原生路径
$knownTmuxDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\marlocarlo.psmux_Microsoft.Winget.Source_8wekyb3d8bbwe'
if ((Test-Path $knownTmuxDir) -and ($env:PATH -notlike "*$knownTmuxDir*")) {
    $env:PATH = "$knownTmuxDir;$env:PATH"
}

# --- 交互环境：TMUX 内外都要加载 ---

$ompCache = Join-Path $env:TEMP 'omp-catppuccin_mocha.ps1'
$ompCmd = Get-Command oh-my-posh -ErrorAction SilentlyContinue
$ompExe = if ($ompCmd) { $ompCmd.Source } else { $null }
if ($ompExe -and (Test-Path $ompCache) -and ((Get-Item $ompCache).LastWriteTime -gt (Get-Item $ompExe).LastWriteTime)) {
    . $ompCache
} else {
    oh-my-posh init pwsh --config 'catppuccin_mocha' | Out-File $ompCache -Encoding utf8
    . $ompCache
}

function Test-TmuxLastTerminalPane {
    if (-not $env:TMUX) { return $false }

    try {
        # 统计整个 session 中所有的 pane 数量
        $allPanes = @(
            & tmux list-panes -s 2>&1 |
                Where-Object { $_ -and $_ -is [string] -and $_.Trim() }
        )
        if ($allPanes.Count -ne 1) { return $false }

        # 统计整个 session 中所有的 window 数量
        $windows = @(
            & tmux list-windows 2>&1 |
                Where-Object { $_ -and $_ -is [string] -and $_.Trim() }
        )
        if ($windows.Count -ne 1) { return $false }

        return $true
    } catch {
        return $false
    }
}

Set-PSReadLineKeyHandler -Chord Ctrl+d -ScriptBlock {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($line.Length -gt 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteChar()
        return
    }
    if ($env:TMUX -and (Test-TmuxLastTerminalPane)) {
        & tmux kill-session 2>$null | Out-Null
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert('exit')
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

# 类似 fish 的历史命令浅色预测提示与补全（支持右箭头直接补全整句，Ctrl+f 亦可补全）
if ($Host.UI.RawUI) {
    try {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Set-PSReadLineOption -PredictionViewStyle InlineView
        Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -Function ForwardChar
    } catch {
        try {
            Set-PSReadLineOption -PredictionSource History
            Set-PSReadLineOption -PredictionViewStyle InlineView
            Set-PSReadLineKeyHandler -Chord 'Ctrl+f' -Function ForwardChar
        } catch {}
    }
}

$env:SHELL = Join-Path $PSHOME 'pwsh.exe'

# WallpaperTools 和 MiscTools 通过 PowerShell 的 Module Auto-Loading 自动按需加载
# 无需在 Profile 启动时同步导入，节省启动耗时

Import-Module TmuxRelay

function Set-All-Alias {
    Set-Alias -Scope Global -Name op -Value Open-Explorer
    Set-Alias -Scope Global -Name rrr -Value Remove-ItemRecursively
    Set-Alias -Scope Global -Name eee -Value Edit-Profile
    Set-Alias -Scope Global -Name cvd -Value Compress-Video
    Set-Alias -Scope Global -Name aaa -Value Start-Aria2Download
    Set-Alias -Scope Global -Name uncomzipall -Value Expand-ZipArchiveAll
    Set-Alias -Scope Global -Name cwall -Value Set-Wallpaper
    Set-Alias -Scope Global -Name safemode -Value Set-SafeWallpaper
    Set-Alias -Scope Global -Name deadmode -Value Set-DeadWallpaper
}

Set-All-Alias

# PATH 进程内补充（去重且不写注册表）
$extraPaths = @('C:\Users\keke\Downloads\emacs\bin', 'C:\msys64\clangarm64\bin')
foreach ($p in $extraPaths) {
    if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
        $env:PATH = "$p;$env:PATH"
    }
}

# 只在「还没进 TMUX」时 attach；不要用 TERM 短路上面的函数
if (-not $env:TMUX -and -not $env:SSH_ORIGINAL_COMMAND -and -not $env:TMUX_SKIP) {
    Enter-TmuxRelay
}
