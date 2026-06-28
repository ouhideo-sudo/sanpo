param(
    [string]$BackupPath,
    [string]$DeviceSerial,
    [string]$DebugApkPath = (Join-Path $PSScriptRoot '..\build\app\outputs\flutter-apk\app-debug.apk'),
    [string]$ReleaseApkPath = (Join-Path $PSScriptRoot '..\build\app\outputs\flutter-apk\app-release.apk'),
    [string]$PackageName = 'com.sanpo.app.sanpo',
    [switch]$SkipReleaseInstall
)

$ErrorActionPreference = 'Stop'

function Get-OnlineDeviceSerial {
    $lines = & adb devices
    $devices = @()

    foreach ($line in $lines) {
        if ($line -match '^(\S+)\s+device$') {
            $devices += $matches[1]
        }
    }

    if ($devices.Count -ne 1) {
        throw 'Specify -DeviceSerial because adb could not identify exactly one online device.'
    }

    return $devices[0]
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & adb @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed with exit code $LASTEXITCODE"
    }
}

function Invoke-AdbWithInputFile {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$InputFile
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'adb'
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    $inputStream = [System.IO.File]::OpenRead($InputFile)
    try {
        $inputStream.CopyTo($process.StandardInput.BaseStream)
    }
    finally {
        $inputStream.Dispose()
        $process.StandardInput.Close()
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "adb failed with exit code $($process.ExitCode): $stderr"
    }

    return $stdout
}

function Invoke-AdbPush {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalPath,
        [Parameter(Mandatory = $true)]
        [string]$DeviceSerial,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath
    )

    & adb -s $DeviceSerial push $LocalPath $RemotePath
    if ($LASTEXITCODE -ne 0) {
        throw "adb push failed with exit code $LASTEXITCODE"
    }
}

function Invoke-FlutterBuild {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('debug', 'release')]
        [string]$Mode
    )

    $args = @('build', 'apk')
    if ($Mode -eq 'debug') {
        $args += '--debug'
    }
    else {
        $args += '--release'
    }

    & flutter @args
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build apk --$Mode failed with exit code $LASTEXITCODE"
    }
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label was not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

if (-not $DeviceSerial) {
    $DeviceSerial = Get-OnlineDeviceSerial
}

if (-not $BackupPath) {
    $backupRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\device_backup')
    $latestBackup = Get-ChildItem -LiteralPath $backupRoot.Path -Filter '*.tar.gz' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestBackup) {
        throw 'No backup archive was found in device_backup. Pass -BackupPath explicitly.'
    }

    $BackupPath = $latestBackup.FullName
}

if (-not (Test-Path -LiteralPath $DebugApkPath)) {
    Invoke-FlutterBuild -Mode 'debug'
}

$DebugApkPath = Resolve-ExistingPath -Path $DebugApkPath -Label 'Debug APK'
$BackupPath = Resolve-ExistingPath -Path $BackupPath -Label 'Backup archive'

if (-not $SkipReleaseInstall) {
    if (-not (Test-Path -LiteralPath $ReleaseApkPath)) {
        Invoke-FlutterBuild -Mode 'release'
    }

    $ReleaseApkPath = Resolve-ExistingPath -Path $ReleaseApkPath -Label 'Release APK'
}

Write-Host "Installing debug APK on $DeviceSerial..."
Invoke-Adb -Arguments @('-s', $DeviceSerial, 'install', '-r', $DebugApkPath)

Write-Host 'Verifying run-as availability...'
Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'run-as', $PackageName, 'id')

Write-Host 'Removing current app data directories...'
Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'run-as', $PackageName, 'rm', '-rf', 'shared_prefs', 'databases', 'files', 'app_', 'app_flutter', 'no_backup')

Write-Host "Restoring backup from $BackupPath..."
$remoteBackupPath = "/sdcard/Android/data/$PackageName/files/restore_backup.tar.gz"
Invoke-AdbPush -LocalPath $BackupPath -DeviceSerial $DeviceSerial -RemotePath $remoteBackupPath
Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'sh', '-c', "cat '$remoteBackupPath' | run-as $PackageName tar -xzf -")
Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'rm', '-f', $remoteBackupPath)

if (-not $SkipReleaseInstall) {
    Write-Host "Returning to release APK on $DeviceSerial..."
    Invoke-Adb -Arguments @('-s', $DeviceSerial, 'install', '-r', $ReleaseApkPath)
}

Write-Host 'Restore completed successfully.'