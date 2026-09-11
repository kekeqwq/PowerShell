@echo off
setlocal
if exist "%USERPROFILE%\Downloads\pwsh\pwsh.exe" (
    "%USERPROFILE%\Downloads\pwsh\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :eof
)
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% equ 0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :eof
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
