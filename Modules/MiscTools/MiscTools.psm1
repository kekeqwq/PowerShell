function Start-Aria2Download {
    aria2c.exe -x 10 @args
}

function Remove-ItemRecursively {
    Remove-Item -Recurse -Force -Verbose -Confirm:$false @args
}

function Open-Explorer {
    explorer.exe .
}

function Edit-Profile {
    code-insiders $profile
}

function Compress-Video {
    # TODO Need format output file name
    ffmpeg.exe -i @args -s 1920x1080 -acodec copy -y outp.mp4
}

function Expand-ZipArchiveAll {
    Get-ChildItem -Path .\*zip -Recurse | ForEach-Object { Expand-Archive -Path $_.FullName -DestinationPath $_.Directory }
}
