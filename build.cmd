@echo off
setlocal

where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :eof
)

if exist "%USERPROFILE%\Downloads\pwsh\pwsh.exe" (
    "%USERPROFILE%\Downloads\pwsh\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :eof
)

if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    "%ProgramFiles%\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :eof
)

if exist "%ProgramFiles%\PowerShell\7-preview\pwsh.exe" (
    "%ProgramFiles%\PowerShell\7-preview\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :eof
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*

