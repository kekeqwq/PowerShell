# scp / sftp / ssh host <command>：整文件退出，禁止任何输出
if ($env:SSH_ORIGINAL_COMMAND) { return }

$argv = [Environment]::GetCommandLineArgs()
if ($argv | Where-Object { $_ -in '-Command', '-c', '-File' }) { return }

# --- 交互环境：ZELLIJ 内外都要加载 ---

oh-my-posh init pwsh --config 'catppuccin_mocha' | Invoke-Expression

function Test-ZellijLastTerminalPane {
    if (-not $env:ZELLIJ) { return $false }

    $tabs = @(
        & zellij action query-tab-names 2>$null |
            Where-Object { $_ -and $_.Trim() }
    )
    if ($tabs.Count -gt 1) { return $false }

    $name = $env:ZELLIJ_SESSION_NAME
    $dump = if ($name) {
        & zellij -s $name action dump-layout 2>$null | Out-String
    } else {
        & zellij action dump-layout 2>$null | Out-String
    }
    if (-not $dump) { return $false }

    $noPlugin = [regex]::Replace($dump, '(?s)plugin\s+[^\n]*(\{.*?\})?', '')
    return ([regex]::Matches($noPlugin, '(?m)^\s+pane\b')).Count -le 1
}

Set-PSReadLineKeyHandler -Chord Ctrl+d -ScriptBlock {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ($line.Length -gt 0) {
        [Microsoft.PowerShell.PSConsoleReadLine]::DeleteChar()
        return
    }
    if ($env:ZELLIJ -and (Test-ZellijLastTerminalPane)) {
        $name = $env:ZELLIJ_SESSION_NAME
        if ($name) { & zellij delete-session --force $name 2>$null | Out-Null }
        else { & zellij action quit 2>$null | Out-Null }
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
    [Microsoft.PowerShell.PSConsoleReadLine]::Insert('exit')
    [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
}

$env:SHELL = Join-Path $PSHOME 'pwsh.exe'

Import-Module WallpaperTools
Import-Module MiscTools
Import-Module ZellijRelay -Force

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

# 1. Get the current User PATH
$oldPath = [Environment]::GetEnvironmentVariable("Path", "User")

# 2. Append the new folder
$newPath = $oldPath + ";C:\Users\keke\Downloads\emacs\bin"

# 3. Save it back to the environment
[Environment]::SetEnvironmentVariable("Path", $newPath, "User")


# 只在「还没进 Zellij」时 attach；不要用 TERM 短路上面的函数
#
if (-not $env:ZELLIJ -and -not $env:SSH_ORIGINAL_COMMAND -and -not $env:ZELLIJ_SKIP) {
    Enter-ZellijRelay
}
