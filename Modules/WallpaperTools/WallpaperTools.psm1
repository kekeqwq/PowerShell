function Set-Wallpaper {

    param(
        [Parameter(Mandatory = $true)]
        [Alias("ImagePath")]
        [string]$Path
    )


    $Path = (Resolve-Path $Path).Path


    if (-not (Test-Path $Path)) {
        throw "壁纸不存在: $Path"
    }


    Write-Host "[Desktop] 设置壁纸:"
    Write-Host "          $Path"


    if (-not ("WallpaperAPI" -as [type])) {

        Add-Type @"
using System;
using System.Runtime.InteropServices;

public class WallpaperAPI
{
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern bool SystemParametersInfo(
        uint uiAction,
        uint uiParam,
        string pvParam,
        uint fWinIni
    );
}
"@
    }


    # 桌面壁纸
    $desktopResult =
    [WallpaperAPI]::SystemParametersInfo(
        20,
        0,
        $Path,
        3
    )


    if ($desktopResult) {
        Write-Host "[Desktop] OK" -ForegroundColor Green
    }
    else {
        Write-Warning "[Desktop] Failed"
    }


    # 锁屏 helper
    $LockScreenTool =
    "C:\Users\keke\Repos\wallchanger\bin\Release\net11.0-windows10.0.26100.0\WallChanger.exe"


    if (Test-Path $LockScreenTool) {

        Write-Host "[LockScreen] 设置..."

        & $LockScreenTool $Path

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[LockScreen] OK" -ForegroundColor Green
        }
        else {
            Write-Warning "[LockScreen] Failed"
        }

    }
    else {

        Write-Warning "找不到 LockScreen helper"

    }
}

function Set-SafeWallpaper {

    $dir = Join-Path $HOME "Downloads\SafeWallpaper"


    $image =
    Get-ChildItem $dir -File |
    Where-Object {
        $_.Extension -match '\.(jpg|jpeg|png|bmp|webp)$'
    } |
    Get-Random


    if (-not $image) {
        throw "SafeWallpaper 没有图片"
    }


    Write-Host "SafeWallpaper:"
    Write-Host "  $($image.FullName)"


    Set-Wallpaper -Path $image.FullName
}

function Set-DeadWallpaper {

    $dir = Join-Path $HOME "Downloads\DeadWallpaper"


    $image =
    Get-ChildItem $dir -File |
    Where-Object {
        $_.Extension -match '\.(jpg|jpeg|png|bmp|webp)$'
    } |
    Get-Random


    if (-not $image) {
        throw "DeadWallpaper 没有图片"
    }


    Write-Host "DeadWallpaper:"
    Write-Host "  $($image.FullName)"


    Set-Wallpaper -Path $image.FullName
}
