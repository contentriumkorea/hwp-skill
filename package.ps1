[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist\hwp-skill.zip'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-HwpPackageReparsePoint {
    param([Parameter(Mandatory)]$Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-HwpPackagePathInsideRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

$sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'skills\hwp-skill'))
$skillFile = Join-Path $sourcePath 'SKILL.md'
if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    throw '배포본에서 skills/hwp-skill/SKILL.md를 찾지 못했습니다.'
}

$sourceItems = @((Get-Item -LiteralPath $sourcePath -Force)) + @(
    Get-ChildItem -LiteralPath $sourcePath -Recurse -Force -ErrorAction Stop
)
if (@($sourceItems | Where-Object { Test-HwpPackageReparsePoint -Item $_ }).Count -gt 0) {
    throw '스킬 원본에 reparse point, junction 또는 심볼릭 링크가 있어 패키징을 중단했습니다.'
}

try {
    $resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
}
catch {
    throw "출력 경로가 올바르지 않습니다: $($_.Exception.Message)"
}

if (Test-HwpPackagePathInsideRoot -Path $resolvedOutputPath -Root $sourcePath) {
    throw '출력 ZIP은 스킬 원본 폴더 밖에 저장해야 합니다.'
}
if ((Test-Path -LiteralPath $resolvedOutputPath) -and -not $Force) {
    throw "출력 ZIP이 이미 있습니다. 덮어쓰려면 -Force를 지정하세요: $resolvedOutputPath"
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$stagePath = [IO.Path]::GetFullPath((Join-Path $tempRoot ('hwp-skill-package-' + [guid]::NewGuid().ToString('n'))))
if (-not (Test-HwpPackagePathInsideRoot -Path $stagePath -Root $tempRoot)) {
    throw '임시 패키지 경로가 시스템 임시 폴더 밖에 있습니다.'
}

try {
    $null = New-Item -ItemType Directory -Path $stagePath -ErrorAction Stop
    $stagedSkillPath = Join-Path $stagePath 'hwp-skill'
    Copy-Item -LiteralPath $sourcePath -Destination $stagedSkillPath -Recurse -ErrorAction Stop

    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $resolvedOutputPath) {
        Remove-Item -LiteralPath $resolvedOutputPath -Force -ErrorAction Stop
    }
    Compress-Archive -LiteralPath $stagedSkillPath -DestinationPath $resolvedOutputPath -CompressionLevel Optimal -ErrorAction Stop

    Get-Item -LiteralPath $resolvedOutputPath
}
finally {
    if (Test-Path -LiteralPath $stagePath) {
        if (-not (Test-HwpPackagePathInsideRoot -Path $stagePath -Root $tempRoot)) {
            throw '검증되지 않은 임시 경로는 삭제하지 않았습니다.'
        }
        Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction Stop
    }
}
