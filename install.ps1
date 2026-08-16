[CmdletBinding()]
param(
    [string]$DestinationRoot,
    [switch]$Update
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-HwpNativeInstallResult {
    param(
        [ValidateSet('PASS','BLOCKED','FAILED')][string]$Status,
        [string]$InstallPath = '',
        [string]$BackupPath = '',
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    [pscustomobject]@{
        Status = $Status
        InstallPath = $InstallPath
        BackupPath = $BackupPath
        Warnings = @($Warnings)
        Errors = @($Errors)
    }
}

function Test-HwpNativePathInsideRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

$sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'skill\hwp-native'))
if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'SKILL.md') -PathType Leaf)) {
    return New-HwpNativeInstallResult -Status FAILED -Errors @('배포본에서 skill/hwp-native/SKILL.md를 찾지 못했습니다.')
}

if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $DestinationRoot = Join-Path $env:CODEX_HOME 'skills'
    }
    else {
        $userProfilePath = [Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($userProfilePath)) {
            return New-HwpNativeInstallResult -Status BLOCKED -Errors @('사용자 프로필 경로를 확인하지 못했습니다. -DestinationRoot를 지정해 주세요.')
        }
        $DestinationRoot = Join-Path (Join-Path $userProfilePath '.codex') 'skills'
    }
}

try {
    $rootPath = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
}
catch {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @("설치 대상 경로가 올바르지 않습니다: $($_.Exception.Message)")
}

$driveRoot = [IO.Path]::GetPathRoot($rootPath).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
if ([string]::Equals($rootPath, $driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @('드라이브 루트는 설치 대상 폴더로 사용할 수 없습니다.')
}

$installPath = [IO.Path]::GetFullPath((Join-Path $rootPath 'hwp-native'))
if (-not (Test-HwpNativePathInsideRoot -Path $installPath -Root $rootPath)) {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @('계산된 설치 경로가 설치 대상 폴더 밖에 있습니다.')
}
if ((Test-Path -LiteralPath $installPath) -and -not $Update) {
    return New-HwpNativeInstallResult -Status BLOCKED -InstallPath $installPath -Errors @(
        'hwp-native가 이미 설치되어 있습니다. 기존 설치를 백업하고 갱신하려면 -Update를 지정하세요.'
    )
}

$stagePath = [IO.Path]::GetFullPath((Join-Path $rootPath ('.hwp-native.install-' + [guid]::NewGuid().ToString('n'))))
$backupPath = ''
$movedExisting = $false
try {
    $null = New-Item -ItemType Directory -Path $rootPath -Force
    if (-not (Test-HwpNativePathInsideRoot -Path $stagePath -Root $rootPath)) {
        throw '임시 설치 경로가 설치 대상 폴더 밖에 있습니다.'
    }

    Copy-Item -LiteralPath $sourcePath -Destination $stagePath -Recurse -ErrorAction Stop
    foreach ($required in 'SKILL.md','agents\openai.yaml','scripts\Invoke-HwpNative.ps1') {
        if (-not (Test-Path -LiteralPath (Join-Path $stagePath $required) -PathType Leaf)) {
            throw "임시 설치본에 필수 파일이 없습니다: $required"
        }
    }

    if (Test-Path -LiteralPath $installPath) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupRoot = [IO.Path]::GetFullPath((Join-Path $rootPath '.hwp-native-backups'))
        if (-not (Test-HwpNativePathInsideRoot -Path $backupRoot -Root $rootPath)) {
            throw '백업 폴더가 설치 대상 폴더 밖에 있습니다.'
        }
        $null = New-Item -ItemType Directory -Path $backupRoot -Force
        $backupPath = [IO.Path]::GetFullPath((Join-Path $backupRoot "hwp-native-$timestamp"))
        $suffix = 1
        while (Test-Path -LiteralPath $backupPath) {
            $backupPath = [IO.Path]::GetFullPath((Join-Path $backupRoot "hwp-native-$timestamp-$suffix"))
            $suffix++
        }
        if (-not (Test-HwpNativePathInsideRoot -Path $backupPath -Root $rootPath)) {
            throw '백업 경로가 설치 대상 폴더 밖에 있습니다.'
        }
        Move-Item -LiteralPath $installPath -Destination $backupPath -ErrorAction Stop
        $movedExisting = $true
    }

    Move-Item -LiteralPath $stagePath -Destination $installPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath (Join-Path $installPath 'SKILL.md') -PathType Leaf)) {
        throw '설치 후 SKILL.md 확인에 실패했습니다.'
    }
}
catch {
    $message = $_.Exception.Message
    if (Test-Path -LiteralPath $stagePath) {
        if (Test-HwpNativePathInsideRoot -Path $stagePath -Root $rootPath) {
            Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($movedExisting -and -not (Test-Path -LiteralPath $installPath) -and (Test-Path -LiteralPath $backupPath)) {
        Move-Item -LiteralPath $backupPath -Destination $installPath -ErrorAction SilentlyContinue
    }
    return New-HwpNativeInstallResult -Status FAILED -InstallPath $installPath -BackupPath $backupPath -Errors @(
        "설치에 실패했습니다: $message"
    )
}

$warnings = if ([string]::IsNullOrWhiteSpace($backupPath)) {
    @()
}
else {
    @("기존 설치본을 삭제하지 않고 백업했습니다: $backupPath")
}
New-HwpNativeInstallResult -Status PASS -InstallPath $installPath -BackupPath $backupPath -Warnings $warnings
