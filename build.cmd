@echo off
setlocal
title Windows SSH + Tmux 环境一键部署

if exist "%USERPROFILE%\Downloads\pwsh\pwsh.exe" (
    "%USERPROFILE%\Downloads\pwsh\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
    goto :check_error
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*

:check_error
if %ERRORLEVEL% neq 0 (
    echo.
    echo ========================================================
    echo 脚本执行异常退出，返回代码: %ERRORLEVEL%
    echo ========================================================
    pause
)

