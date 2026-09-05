Set-StrictMode -Version Latest

$script:TaskName = 'ZellijSpawnOnce'
$script:DefaultSession = 'main'

function Get-ZellijPath {
    $cmd = Get-Command zellij -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'Zellij\zellij.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'zellij.exe not found'
}

function Get-PwshPath {
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'pwsh.exe not found'
}

function Get-ZellijAlive {
    param([string]$Name)
    $raw = & (Get-ZellijPath) list-sessions --no-formatting 2>$null
    if (-not $raw) { return $false }
    return [bool](@($raw) | Select-String -SimpleMatch $Name | Where-Object { $_.Line -notmatch 'EXITED' })
}

function Install-ZellijRelayTask {
    param([string]$Session)

    $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        $exe = @($existing.Actions)[0].Execute
        if ($exe -and (Test-Path $exe)) { return }
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }

    $pwsh    = Get-PwshPath
    $zellij  = Get-ZellijPath
    $user    = "$env:COMPUTERNAME\$env:USERNAME"
    $homeDir = $HOME
    $arg     = "-NoProfile -WindowStyle Hidden -Command `"Set-Location '$homeDir'; & '$zellij' attach --create-background $Session options --default-shell '$pwsh'`""

    $action = New-ScheduledTaskAction -Execute $pwsh -Argument $arg -WorkingDirectory $homeDir
    $prin   = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $set    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Principal $prin -Settings $set | Out-Null
}

function Enter-ZellijRelay {
    [CmdletBinding()]
    param([string]$Session = $script:DefaultSession)

    if ($env:ZELLIJ -or $env:ZELLIJ_SKIP) { return }

    if (-not (Get-ZellijAlive $Session)) {
        Install-ZellijRelayTask -Session $Session
        $run = schtasks.exe /run /tn $script:TaskName 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "schtasks /run failed: $run"
        }
        $ok = $false
        foreach ($i in 1..20) {
            Start-Sleep -Milliseconds 250
            if (Get-ZellijAlive $Session) { $ok = $true; break }
        }
        if (-not $ok) {
            throw "ZellijSpawnOnce ran but session '$Session' did not appear"
        }
    }

    & (Get-ZellijPath) attach $Session
}

Set-Alias -Name zj -Value Enter-ZellijRelay
Export-ModuleMember -Function Enter-ZellijRelay -Alias zj
