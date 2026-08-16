[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'source'),
    [switch]$Force,
    [switch]$Visible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libraryRoot = Join-Path $PSScriptRoot '../../skill/hwp-native/scripts/lib'
Import-Module (Join-Path $libraryRoot 'HwpCommon.psm1') -Force
Import-Module (Join-Path $libraryRoot 'HwpSession.psm1') -Force

function Write-FixtureResult {
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')]
        [string]$Status,
        [object]$Data = $null,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @(),
        [int]$ExitCode = 0
    )

    New-HwpResult -Status $Status -Command create-test-fixtures -Data $Data `
        -Warnings $Warnings -Errors $Errors | ConvertTo-Json -Depth 10
    exit $ExitCode
}

function Invoke-HwpInsertText {
    param([object]$Hwp, [string]$Text)

    $parameterSet = $Hwp.HParameterSet.HInsertText
    $null = $Hwp.HAction.GetDefault('InsertText', $parameterSet.HSet)
    $parameterSet.Text = $Text
    if (-not $Hwp.HAction.Execute('InsertText', $parameterSet.HSet)) {
        throw '가상 문서 본문 삽입에 실패했습니다.'
    }
}

function Add-HwpFixtureStructure {
    param(
        [object]$Hwp,
        [string]$ImagePath,
        [switch]$IncludeImage
    )

    if ($IncludeImage) {
        $null = $Hwp.HAction.Run('MoveDocEnd')
        $null = $Hwp.HAction.Run('BreakPara')
        $picture = $Hwp.InsertPicture($ImagePath, $true, 1, $false, $false, 0, 20, 20)
        if ($null -eq $picture) {
            throw '가상 문서 그림 삽입에 실패했습니다.'
        }
    }

    $null = $Hwp.HAction.Run('MoveDocEnd')
    $null = $Hwp.HAction.Run('BreakPara')
    $table = $Hwp.HParameterSet.HTableCreation
    $null = $Hwp.HAction.GetDefault('TableCreate', $table.HSet)
    $table.Rows = [uint16]2
    $table.Cols = [uint16]2
    $table.WidthType = 0
    $table.HeightType = 0
    if (-not $Hwp.HAction.Execute('TableCreate', $table.HSet)) {
        throw '가상 문서 표 삽입에 실패했습니다.'
    }
}

function New-HwpFixtureFile {
    param(
        [string]$LiteralPath,
        [ValidateSet('HWP','HWPX')]
        [string]$Format,
        [string]$ImagePath,
        [switch]$Visible
    )

    $session = New-HwpSession -Visible ([bool]$Visible)
    try {
        $memoryMode = $Format -eq 'HWP'
        $security = $null
        if (-not $memoryMode) {
            $security = Register-HwpSecurityModules -Session $session
            if ($security.Status -eq 'BLOCKED' -or $security.Status -eq 'FAILED') {
                return [pscustomobject]@{
                    Status = 'BLOCKED'
                    Path = $LiteralPath
                    Warnings = @()
                    Errors = @($security.Errors)
                    Security = $security
                }
            }
        }

        $bodyPrefix = @(
            'HWP 네이티브 통합 시험',
            '기존 문구를 안전하게 변경합니다.',
            '중복 문구',
            '중복 문구',
            '담당자: '
        ) -join "`r`n"
        Invoke-HwpInsertText -Hwp $session.Hwp -Text $bodyPrefix

        if (-not $session.Hwp.CreateField('{{담당자}}', '시험용 담당자 필드', '담당자')) {
            throw '가상 담당자 누름틀을 만들지 못했습니다.'
        }
        $null = $session.Hwp.PutFieldText('담당자', '시험 담당자')
        if ([string]$session.Hwp.GetFieldText('담당자') -ne '시험 담당자') {
            throw '가상 담당자 누름틀의 값 사후검증에 실패했습니다.'
        }
        if (-not $session.Hwp.MoveToField('담당자', $false, $false, $false)) {
            throw '가상 담당자 누름틀의 끝으로 이동하지 못했습니다.'
        }

        $bodySuffix = "`r`n" + (@(
            '표 삽입 위치',
            '이미지 삽입 위치',
            '쪽 나누기 위치'
        ) -join "`r`n")
        Invoke-HwpInsertText -Hwp $session.Hwp -Text $bodySuffix
        Add-HwpFixtureStructure -Hwp $session.Hwp -ImagePath $ImagePath -IncludeImage:(-not $memoryMode)

        if ($memoryMode) {
            $base64 = [string]$session.Hwp.GetTextFile('HWP', '')
            if ([string]::IsNullOrWhiteSpace($base64)) {
                throw '한컴오피스가 가상 HWP 메모리 데이터를 반환하지 않았습니다.'
            }
            $bytes = [Convert]::FromBase64String($base64)
            if ($bytes.Length -lt 8 -or [BitConverter]::ToString($bytes, 0, 8) -ne 'D0-CF-11-E0-A1-B1-1A-E1') {
                throw '가상 HWP 메모리 데이터의 OLE 시그니처가 올바르지 않습니다.'
            }
            [IO.File]::WriteAllBytes($LiteralPath, $bytes)
            return [pscustomobject]@{
                Status = 'PASS_WITH_WARNINGS'
                Path = $LiteralPath
                Warnings = @('보안 모듈 없이 생성하여 외부 그림은 포함하지 않았습니다.')
                Errors = @()
                Security = $null
            }
        }

        if (-not $session.Hwp.SaveAs($LiteralPath, $Format, 'lock:false;backup:false')) {
            throw "가상 문서 저장에 실패했습니다: $LiteralPath"
        }

        [pscustomobject]@{
            Status = 'PASS'
            Path = $LiteralPath
            Warnings = @($security.Warnings)
            Errors = @()
            Security = $security
        }
    }
    finally {
        Close-HwpSession -Session $session
    }
}

$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$expected = @(
    (Join-Path $outputRoot 'native-fixture.hwp'),
    (Join-Path $outputRoot 'native-template.hwt'),
    (Join-Path $outputRoot 'native-fixture.hwpx')
)
$existing = @($expected | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -gt 0 -and -not $Force) {
    Write-FixtureResult -Status BLOCKED -Data @{ ExistingFiles=$existing } `
        -Errors @('기존 가상 시험 문서를 덮어쓰지 않습니다. 다시 만들려면 -Force를 명시하십시오.') -ExitCode 2
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

try {
    Add-Type -AssemblyName System.Drawing
    $imagePath = Join-Path $outputRoot 'fixture-blue.png'
    $bitmap = [Drawing.Bitmap]::new(32, 32)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::FromArgb(34, 92, 180))
        }
        finally {
            $graphics.Dispose()
        }
        $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }

    $jobs = @(
        @{ Path=$expected[0]; Format='HWP' },
        @{ Path=$expected[1]; Format='HWP' },
        @{ Path=$expected[2]; Format='HWPX' }
    )
    $results = foreach ($job in $jobs) {
        New-HwpFixtureFile -LiteralPath $job.Path -Format $job.Format -ImagePath $imagePath -Visible:$Visible
    }
    $blocked = @($results | Where-Object Status -eq 'BLOCKED')
    $failed = @($results | Where-Object Status -eq 'FAILED')
    if ($failed.Count -gt 0) {
        Write-FixtureResult -Status FAILED -Data @{ Results=@($results) } `
            -Errors @($failed.Errors) -ExitCode 1
    }

    $createdPaths = @($expected | Where-Object { Test-Path -LiteralPath $_ })
    $evidence = foreach ($path in $createdPaths) {
        [pscustomobject]@{
            Path = $path
            Sha256 = Get-HwpSha256 -LiteralPath $path
            FileKind = Get-HwpFileKind -LiteralPath $path
        }
    }
    $warnings = [Collections.Generic.List[string]]::new()
    foreach ($item in $results) {
        foreach ($warning in @($item.Warnings)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                $warnings.Add([string]$warning)
            }
        }
    }
    if ($blocked.Count -gt 0) {
        $warnings.Add('공식 보안 모듈이 없어 HWPX 가상 문서는 생성하지 않았습니다.')
    }
    $status = if ($warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }
    Write-FixtureResult -Status $status -Data @{
        Files = @($evidence)
        Image = $imagePath
        Results = @($results)
        MissingFiles = @($expected | Where-Object { -not (Test-Path -LiteralPath $_) })
    } -Warnings @($warnings)
}
catch {
    Write-FixtureResult -Status FAILED -Errors @($_.Exception.Message) -ExitCode 1
}
