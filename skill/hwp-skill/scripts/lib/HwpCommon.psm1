Set-StrictMode -Version Latest

$script:SupportedExtensions = @('.hwp', '.hwt', '.hwpx')

function Resolve-HwpLiteralPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath
    )

    $resolved = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "문서 파일이 아닙니다: $resolved"
    }

    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($extension -notin $script:SupportedExtensions) {
        throw 'HWP, HWT 또는 HWPX 파일만 지원합니다.'
    }

    $resolved
}

function Get-HwpFileKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath
    )

    $resolved = Resolve-HwpLiteralPath -LiteralPath $LiteralPath
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $buffer = [byte[]]::new(8)
        $length = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally {
        $stream.Dispose()
    }

    $isOle = $length -ge 8 -and
        [BitConverter]::ToString($buffer, 0, 8) -eq 'D0-CF-11-E0-A1-B1-1A-E1'
    $isZip = $length -ge 4 -and
        $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and
        $buffer[2] -in 0x03,0x05,0x07 -and $buffer[3] -in 0x04,0x06,0x08

    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    $kind = if ($isOle) {
        'HWP-BINARY'
    }
    elseif ($isZip) {
        'HWPX-ZIP'
    }
    else {
        'UNKNOWN'
    }

    $matches = ($kind -eq 'HWP-BINARY' -and $extension -in '.hwp', '.hwt') -or
        ($kind -eq 'HWPX-ZIP' -and $extension -eq '.hwpx')

    [pscustomobject]@{
        Path = $resolved
        Extension = $extension
        DetectedKind = $kind
        ExtensionMatches = [bool]$matches
        Signature = if ($length -gt 0) {
            [BitConverter]::ToString($buffer, 0, [Math]::Min($length, 8))
        }
        else {
            ''
        }
    }
}

function Get-HwpSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath
    )

    $resolved = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "해시를 계산할 파일이 아닙니다: $resolved"
    }

    (Get-FileHash -LiteralPath $resolved -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-HwpVersionedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [datetime]$Now = (Get-Date)
    )

    $resolved = [IO.Path]::GetFullPath($LiteralPath)
    $directory = [IO.Path]::GetDirectoryName($resolved)
    $name = [IO.Path]::GetFileNameWithoutExtension($resolved)
    $extension = [IO.Path]::GetExtension($resolved)
    $stem = '{0}_수정본_{1}' -f $name, $Now.ToString('yyyyMMdd_HHmmss')
    $candidate = [IO.Path]::Combine($directory, "$stem$extension")
    $sequence = 1

    while (Test-Path -LiteralPath $candidate) {
        $candidate = [IO.Path]::Combine($directory, ('{0}_{1:D2}{2}' -f $stem, $sequence, $extension))
        $sequence++
    }

    if ([string]::Equals($resolved, $candidate, [StringComparison]::OrdinalIgnoreCase)) {
        throw '원본과 같은 결과 경로를 만들 수 없습니다.'
    }

    $candidate
}

function New-HwpResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')]
        [string]$Status,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [AllowNull()]
        [object]$Data = $null,

        [string[]]$Warnings = @(),

        [string[]]$Errors = @()
    )

    [pscustomobject][ordered]@{
        status = $Status
        command = $Command
        data = $Data
        warnings = @($Warnings)
        errors = @($Errors)
    }
}

Export-ModuleMember -Function @(
    'Resolve-HwpLiteralPath',
    'Get-HwpFileKind',
    'Get-HwpSha256',
    'Get-HwpVersionedPath',
    'New-HwpResult'
)
