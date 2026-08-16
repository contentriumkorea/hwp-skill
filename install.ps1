[CmdletBinding()]
param(
    [string]$DestinationRoot,
    [switch]$Update,
    [scriptblock]$InstallValidator
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-HwpNativeInstallResult {
    param(
        [ValidateSet('PASS','BLOCKED','FAILED')][string]$Status,
        [string]$InstallPath = '',
        [string]$BackupPath = '',
        [ValidateSet('NOT_REQUIRED','PASS','FAILED')][string]$RollbackStatus = 'NOT_REQUIRED',
        [string]$FailedInstallPath = '',
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    [pscustomobject]@{
        Status = $Status
        InstallPath = $InstallPath
        BackupPath = $BackupPath
        RollbackStatus = $RollbackStatus
        FailedInstallPath = $FailedInstallPath
        Warnings = @($Warnings | Where-Object { $null -ne $_ })
        Errors = @($Errors | Where-Object { $null -ne $_ })
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
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-HwpNativeItemIsReparsePoint {
    param([Parameter(Mandatory)]$Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
}

function Test-HwpNativePathHasReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    $currentPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )

    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and (Test-HwpNativeItemIsReparsePoint -Item $item)) {
            return $true
        }

        $parent = [IO.Directory]::GetParent($currentPath)
        if ($null -eq $parent -or [string]::Equals($parent.FullName, $currentPath, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $currentPath = $parent.FullName
    }

    return $false
}

function Test-HwpNativeTreeHasReparsePoint {
    param([Parameter(Mandatory)][string]$Root)

    if (Test-HwpNativePathHasReparsePoint -Path $Root) {
        return $true
    }

    $pending = New-Object System.Collections.Stack
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $current = [string]$pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if (Test-HwpNativeItemIsReparsePoint -Item $child) {
                return $true
            }
            if ($child.PSIsContainer) {
                $pending.Push($child.FullName)
            }
        }
    }

    return $false
}

function Assert-HwpNativeRequiredFiles {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($required in 'SKILL.md','agents\openai.yaml','scripts\Invoke-HwpSkill.ps1') {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $required) -PathType Leaf)) {
            throw "설치본에 필수 파일이 없습니다: $required"
        }
    }
    return $true
}

function Invoke-HwpNativeInstallValidation {
    param(
        [Parameter(Mandatory)][scriptblock]$Validator,
        [Parameter(Mandatory)][string]$Path
    )

    $validationOutput = @(& $Validator $Path)
    if ($validationOutput.Count -eq 0 -or -not [bool]$validationOutput[-1]) {
        throw "설치본 검증기가 실패를 반환했습니다: $Path"
    }
}

function New-HwpNativeUniqueChildPath {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Prefix
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $candidate = [IO.Path]::GetFullPath((Join-Path $Parent "$Prefix-$timestamp"))
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $Parent "$Prefix-$timestamp-$suffix"))
        $suffix++
    }
    return $candidate
}

if ($null -eq $InstallValidator) {
    $InstallValidator = {
        param([string]$Path)
        Assert-HwpNativeRequiredFiles -Path $Path
    }
}

$sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'skill\hwp-skill'))
if (-not (Test-Path -LiteralPath (Join-Path $sourcePath 'SKILL.md') -PathType Leaf)) {
    return New-HwpNativeInstallResult -Status FAILED -Errors @('배포본에서 skill/hwp-skill/SKILL.md를 찾지 못했습니다.')
}
if (Test-HwpNativeTreeHasReparsePoint -Root $sourcePath) {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @(
        '배포 원본 경로에 reparse point, junction 또는 심볼릭 링크가 있어 설치를 중단했습니다.'
    )
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
if (Test-HwpNativePathHasReparsePoint -Path $rootPath) {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @(
        '설치 대상 경로 또는 상위 경로에 reparse point, junction 또는 심볼릭 링크가 있어 설치를 중단했습니다.'
    )
}

$installPath = [IO.Path]::GetFullPath((Join-Path $rootPath 'hwp-skill'))
$backupRoot = [IO.Path]::GetFullPath((Join-Path $rootPath '.hwp-skill-backups'))
if (-not (Test-HwpNativePathInsideRoot -Path $installPath -Root $rootPath)) {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @('계산된 설치 경로가 설치 대상 폴더 밖에 있습니다.')
}
if (-not (Test-HwpNativePathInsideRoot -Path $backupRoot -Root $rootPath)) {
    return New-HwpNativeInstallResult -Status BLOCKED -Errors @('계산된 백업 경로가 설치 대상 폴더 밖에 있습니다.')
}
if (Test-HwpNativePathHasReparsePoint -Path $installPath) {
    return New-HwpNativeInstallResult -Status BLOCKED -InstallPath $installPath -Errors @(
        '설치 경로에 reparse point, junction 또는 심볼릭 링크가 있어 설치를 중단했습니다.'
    )
}

$hadExisting = Test-Path -LiteralPath $installPath
if ($hadExisting -and -not $Update) {
    return New-HwpNativeInstallResult -Status BLOCKED -InstallPath $installPath -Errors @(
        'hwp-skill이 이미 설치되어 있습니다. 기존 설치를 백업하고 갱신하려면 -Update를 지정하세요.'
    )
}
if ($hadExisting -and (Test-HwpNativePathHasReparsePoint -Path $backupRoot)) {
    return New-HwpNativeInstallResult -Status BLOCKED -InstallPath $installPath -Errors @(
        '백업 경로에 reparse point, junction 또는 심볼릭 링크가 있어 업데이트를 중단했습니다.'
    )
}

$stagePath = [IO.Path]::GetFullPath((Join-Path $rootPath ('.hwp-skill.install-' + [guid]::NewGuid().ToString('n'))))
$backupPath = ''
$failedInstallPath = ''
$movedExisting = $false
$candidatePromoted = $false
try {
    $null = New-Item -ItemType Directory -Path $rootPath -Force
    if (Test-HwpNativePathHasReparsePoint -Path $rootPath) {
        throw '설치 대상 경로를 만든 뒤 reparse point, junction 또는 심볼릭 링크가 발견되었습니다.'
    }
    if (-not (Test-HwpNativePathInsideRoot -Path $stagePath -Root $rootPath)) {
        throw '임시 설치 경로가 설치 대상 폴더 밖에 있습니다.'
    }

    if ($hadExisting) {
        if (Test-HwpNativePathHasReparsePoint -Path $backupRoot) {
            throw '백업 경로에 reparse point, junction 또는 심볼릭 링크가 있습니다.'
        }
        $null = New-Item -ItemType Directory -Path $backupRoot -Force
        if (Test-HwpNativePathHasReparsePoint -Path $backupRoot) {
            throw '백업 폴더를 만든 뒤 reparse point, junction 또는 심볼릭 링크가 발견되었습니다.'
        }
    }

    Copy-Item -LiteralPath $sourcePath -Destination $stagePath -Recurse -ErrorAction Stop
    if (Test-HwpNativeTreeHasReparsePoint -Root $stagePath) {
        throw '임시 설치본에 reparse point, junction 또는 심볼릭 링크가 발견되었습니다.'
    }
    Invoke-HwpNativeInstallValidation -Validator $InstallValidator -Path $stagePath

    if ($hadExisting) {
        $backupPath = New-HwpNativeUniqueChildPath -Parent $backupRoot -Prefix 'hwp-skill'
        if (-not (Test-HwpNativePathInsideRoot -Path $backupPath -Root $backupRoot)) {
            throw '백업 경로가 백업 폴더 밖에 있습니다.'
        }
        Move-Item -LiteralPath $installPath -Destination $backupPath -ErrorAction Stop
        $movedExisting = $true
    }

    Move-Item -LiteralPath $stagePath -Destination $installPath -ErrorAction Stop
    $candidatePromoted = $true
    if (Test-HwpNativeTreeHasReparsePoint -Root $installPath) {
        throw '설치 후 경로에 reparse point, junction 또는 심볼릭 링크가 발견되었습니다.'
    }
    Invoke-HwpNativeInstallValidation -Validator $InstallValidator -Path $installPath
}
catch {
    $message = $_.Exception.Message
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    $rollbackWarnings = New-Object System.Collections.Generic.List[string]
    $rollbackRequired = $movedExisting -or $candidatePromoted
    $activePathIsCandidate = $candidatePromoted -or ($movedExisting -and (Test-Path -LiteralPath $installPath))

    if ($activePathIsCandidate -and (Test-Path -LiteralPath $installPath)) {
        $rollbackRequired = $true
        try {
            if (Test-HwpNativePathHasReparsePoint -Path $backupRoot) {
                throw '실패한 설치본을 격리할 백업 경로가 reparse point, junction 또는 심볼릭 링크입니다.'
            }
            $null = New-Item -ItemType Directory -Path $backupRoot -Force
            if (Test-HwpNativePathHasReparsePoint -Path $backupRoot) {
                throw '실패한 설치본의 격리 폴더를 안전하게 만들지 못했습니다.'
            }
            $failedInstallPath = New-HwpNativeUniqueChildPath -Parent $backupRoot -Prefix 'failed-install'
            if (-not (Test-HwpNativePathInsideRoot -Path $failedInstallPath -Root $backupRoot)) {
                throw '실패한 설치본의 격리 경로가 백업 폴더 밖에 있습니다.'
            }
            Move-Item -LiteralPath $installPath -Destination $failedInstallPath -ErrorAction Stop
            $rollbackWarnings.Add("검증에 실패한 설치본을 격리했습니다: $failedInstallPath")
        }
        catch {
            $rollbackErrors.Add("실패한 설치본 격리에 실패했습니다: $($_.Exception.Message)")
        }
    }

    if ($movedExisting) {
        $rollbackRequired = $true
        try {
            if (Test-Path -LiteralPath $installPath) {
                throw '활성 설치 경로가 비어 있지 않아 기존 설치본을 복원할 수 없습니다.'
            }
            if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
                throw '복원할 기존 설치본 백업을 찾지 못했습니다.'
            }
            if (Test-HwpNativeTreeHasReparsePoint -Root $backupPath) {
                throw '기존 설치본 백업에 reparse point, junction 또는 심볼릭 링크가 발견되었습니다.'
            }
            Move-Item -LiteralPath $backupPath -Destination $installPath -ErrorAction Stop
            $null = Assert-HwpNativeRequiredFiles -Path $installPath
        }
        catch {
            $rollbackErrors.Add("기존 설치본 복원에 실패했습니다: $($_.Exception.Message)")
        }
    }

    if (Test-Path -LiteralPath $stagePath) {
        try {
            if (-not (Test-HwpNativePathInsideRoot -Path $stagePath -Root $rootPath)) {
                throw '임시 설치 경로가 설치 대상 폴더 밖에 있습니다.'
            }
            if (Test-HwpNativeTreeHasReparsePoint -Root $stagePath) {
                throw '임시 설치 경로에 reparse point, junction 또는 심볼릭 링크가 있어 자동 삭제하지 않았습니다.'
            }
            Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction Stop
        }
        catch {
            $rollbackErrors.Add("임시 설치본 정리에 실패했습니다: $($_.Exception.Message)")
        }
    }

    $rollbackStatus = if (-not $rollbackRequired) {
        'NOT_REQUIRED'
    }
    elseif ($rollbackErrors.Count -eq 0) {
        'PASS'
    }
    else {
        'FAILED'
    }

    $allErrors = New-Object System.Collections.Generic.List[string]
    $allErrors.Add("설치에 실패했습니다: $message")
    foreach ($rollbackError in $rollbackErrors) {
        $allErrors.Add($rollbackError)
    }
    return New-HwpNativeInstallResult -Status FAILED -InstallPath $installPath -BackupPath $backupPath `
        -RollbackStatus $rollbackStatus -FailedInstallPath $failedInstallPath `
        -Warnings @($rollbackWarnings) -Errors @($allErrors)
}

$warnings = if ([string]::IsNullOrWhiteSpace($backupPath)) {
    @()
}
else {
    @("기존 설치본을 삭제하지 않고 백업했습니다: $backupPath")
}
New-HwpNativeInstallResult -Status PASS -InstallPath $installPath -BackupPath $backupPath -Warnings $warnings
