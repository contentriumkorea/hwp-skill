Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop

$compoundReaderType = 'Contentrium.HwpSkill.CompoundFileReader' -as [type]
if ($null -eq $compoundReaderType) {
    Add-Type -Path (Join-Path $PSScriptRoot 'HwpCompoundFile.cs') -ErrorAction Stop
}

function Expand-HwpPortableDeflate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateRange(1, 1073741824)][long]$MaximumBytes = 268435456
    )

    $input = [IO.MemoryStream]::new($Bytes, $false)
    $output = [IO.MemoryStream]::new()
    try {
        $deflate = [IO.Compression.DeflateStream]::new(
            $input,
            [IO.Compression.CompressionMode]::Decompress,
            $true
        )
        try {
            $buffer = [byte[]]::new(81920)
            while (($read = $deflate.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $read)
                if ($output.Length -gt $MaximumBytes) {
                    throw [IO.InvalidDataException]::new('압축 해제된 HWP 스트림이 안전 한도를 초과했습니다.')
                }
            }
        }
        finally {
            $deflate.Dispose()
        }
        return ,$output.ToArray()
    }
    finally {
        $output.Dispose()
        $input.Dispose()
    }
}

function ConvertFrom-HwpPortableParagraphText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    if (($Bytes.Length % 2) -ne 0) {
        throw [IO.InvalidDataException]::new('HWP 문단 텍스트의 UTF-16LE 바이트 길이가 올바르지 않습니다.')
    }

    $builder = [Text.StringBuilder]::new()
    $extendedOrInline = [Collections.Generic.HashSet[uint16]]::new()
    foreach ($code in @(1,2,3,4,5,6,7,8,9,11,12,14,15,16,17,18,19,20,21,22,23)) {
        $null = $extendedOrInline.Add([uint16]$code)
    }

    $offset = 0
    while ($offset -lt $Bytes.Length) {
        $code = [BitConverter]::ToUInt16($Bytes, $offset)
        if ($code -ge 32) {
            $null = $builder.Append([char]$code)
            $offset += 2
            continue
        }

        switch ($code) {
            9  { $null = $builder.Append("`t") }
            10 { $null = $builder.Append("`n") }
            24 { $null = $builder.Append('-') }
            30 { $null = $builder.Append(' ') }
            31 { $null = $builder.Append(' ') }
        }

        if ($extendedOrInline.Contains([uint16]$code)) {
            if (($offset + 16) -gt $Bytes.Length) {
                throw [IO.InvalidDataException]::new("HWP 제어 문자 $code 데이터가 중간에서 끝났습니다.")
            }
            $offset += 16
        }
        else {
            $offset += 2
        }
    }

    $builder.ToString()
}

function Get-HwpPortableSectionData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Controls,
        [ValidateRange(1, 2000000)][int]$MaximumRecords = 1000000,
        [ValidateRange(1, 1000000)][int]$MaximumControls = 100000,
        [ValidateRange(1, 268435456)][long]$MaximumTextCharacters = 67108864
    )

    $paragraphs = [Collections.Generic.List[string]]::new()
    [long]$textCharacterCount = 0
    $offset = 0
    $recordCount = 0
    while ($offset -lt $Bytes.Length) {
        if (($Bytes.Length - $offset) -lt 4) {
            throw [IO.InvalidDataException]::new("$SectionName 레코드 헤더가 중간에서 끝났습니다.")
        }
        if ($recordCount -ge $MaximumRecords) {
            throw [IO.InvalidDataException]::new("$SectionName 레코드 수가 안전 한도를 초과했습니다.")
        }

        $header = [BitConverter]::ToUInt32($Bytes, $offset)
        $offset += 4
        $tagId = [int]($header -band 0x3FF)
        $size = [long](($header -shr 20) -band 0xFFF)
        if ($size -eq 0xFFF) {
            if (($Bytes.Length - $offset) -lt 4) {
                throw [IO.InvalidDataException]::new("$SectionName 확장 레코드 길이가 중간에서 끝났습니다.")
            }
            $size = [long][BitConverter]::ToUInt32($Bytes, $offset)
            $offset += 4
        }
        if ($size -lt 0 -or ($offset + $size) -gt $Bytes.Length) {
            throw [IO.InvalidDataException]::new("$SectionName 레코드 길이가 스트림 범위를 벗어났습니다.")
        }

        if ($tagId -eq 0x43) {
            $payload = [byte[]]::new([int]$size)
            if ($size -gt 0) {
                [Array]::Copy($Bytes, $offset, $payload, 0, [int]$size)
            }
            $paragraph = ConvertFrom-HwpPortableParagraphText -Bytes $payload
            if (($textCharacterCount + $paragraph.Length) -gt $MaximumTextCharacters) {
                throw [IO.InvalidDataException]::new("$SectionName 추출 텍스트가 문서 전체 안전 한도를 초과했습니다.")
            }
            $paragraphs.Add($paragraph)
            $textCharacterCount += $paragraph.Length
        }
        elseif ($tagId -in @(0x4D, 0x55, 0x58)) {
            if ($Controls.Count -ge $MaximumControls) {
                throw [IO.InvalidDataException]::new("$SectionName 개체 수가 문서 전체 안전 한도를 초과했습니다.")
            }
            $controlType = switch ($tagId) {
                0x4D { @('tbl', '표') }
                0x55 { @('pic', '그림') }
                0x58 { @('eqed', '수식') }
            }
            $Controls.Add([pscustomobject]@{
                index = $Controls.Count
                ctrlId = $controlType[0]
                userDesc = $controlType[1]
                instanceId = ''
                section = $SectionName
                source = 'hwp-portable'
            })
        }

        $offset += [int]$size
        $recordCount++
    }

    [pscustomobject]@{
        Paragraphs = @($paragraphs)
        RecordCount = $recordCount
        TextCharacterCount = $textCharacterCount
    }
}

function Get-HwpPortableInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [ValidateRange(256, 536870912)][long]$MaximumFileBytes = 268435456,
        [ValidateRange(256, 268435456)][int]$MaximumStreamBytes = 134217728,
        [ValidateRange(1, 4096)][int]$MaximumSections = 1024,
        [ValidateRange(1, 1073741824)][long]$MaximumExpandedBytes = 536870912,
        [ValidateRange(1, 2000000)][int]$MaximumTotalRecords = 2000000,
        [ValidateRange(1, 1000000)][int]$MaximumControls = 100000,
        [ValidateRange(1, 268435456)][long]$MaximumTextCharacters = 67108864,
        [ValidatePattern('^$|^[0-9a-fA-F]{64}$')][string]$ExpectedSha256 = ''
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
            '현재 hwp-portable 읽기 엔진은 Windows 기본 OLE 복합파일 API가 필요합니다.'
        )
    }

    $resolvedPath = Resolve-HwpLiteralPath -LiteralPath $LiteralPath
    if ((Get-Item -LiteralPath $resolvedPath).Length -gt $MaximumFileBytes) {
        return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
            'HWP 파일이 휴대형 읽기 안전 한도를 초과했습니다.'
        )
    }

    $compoundSession = $null
    try {
        $compoundSession = [Contentrium.HwpSkill.CompoundFileReader]::Open($resolvedPath)
        $lockedHash = Get-HwpSha256 -LiteralPath $resolvedPath
        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and
                $lockedHash -ne $ExpectedSha256.ToLowerInvariant()) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'HWP 파일이 형식 확인 이후 변경되어 휴대형 읽기를 중단했습니다.'
            )
        }

        $headerBytes = $compoundSession.ReadStream('', 'FileHeader', $MaximumStreamBytes)
        if ($headerBytes.Length -lt 256) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'HWP FileHeader 스트림이 256바이트보다 짧습니다.'
            )
        }

        $signature = [Text.Encoding]::ASCII.GetString($headerBytes, 0, 32).TrimEnd([char]0)
        if ($signature -ne 'HWP Document File') {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'FileHeader 시그니처가 HWP Document File이 아닙니다.'
            )
        }

        $version = '{0}.{1}.{2}.{3}' -f $headerBytes[35], $headerBytes[34], $headerBytes[33], $headerBytes[32]
        if ($headerBytes[35] -ne 5) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                "현재 휴대형 읽기는 HWP 5.x만 지원합니다. 감지 버전: $version"
            )
        }

        $properties = [BitConverter]::ToUInt32($headerBytes, 36)
        $compressed = ($properties -band 0x1) -ne 0
        $protectedFlags = [ordered]@{
            '암호 설정' = 1
            '배포용 문서' = 2
            'DRM 보안 문서' = 4
            '전자 서명 정보' = 7
            '공인 인증서 암호화' = 8
            '전자 서명 예비 저장소' = 9
            '공인 인증서 DRM' = 10
            '개인정보 보안 문서' = 13
        }
        $detectedProtection = @(
            foreach ($name in $protectedFlags.Keys) {
                if (($properties -band (1 -shl $protectedFlags[$name])) -ne 0) { $name }
            }
        )
        if ($detectedProtection.Count -gt 0) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Data ([pscustomobject]@{
                Version = $version
                Protection = @($detectedProtection)
            }) -Errors @(
                "보호된 HWP는 우회하지 않습니다: $($detectedProtection -join ', ')"
            )
        }

        $sectionElements = @(
            $compoundSession.ListElements('BodyText') |
                Where-Object { $_.Type -eq 2 -and $_.Name -match '^Section(?<number>\d+)$' } |
                Sort-Object @{ Expression = { [int]([regex]::Match($_.Name, '\d+$').Value) } }
        )
        if ($sectionElements.Count -eq 0) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'HWP BodyText에 SectionN 본문 스트림이 없습니다.'
            )
        }
        if ($sectionElements.Count -gt $MaximumSections) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'HWP 구역 수가 휴대형 읽기 안전 한도를 초과했습니다.'
            )
        }

        $paragraphs = [Collections.Generic.List[string]]::new()
        $controls = [Collections.Generic.List[object]]::new()
        $recordCount = 0
        [long]$expandedByteCount = 0
        [long]$textCharacterCount = 0
        foreach ($element in $sectionElements) {
            [byte[]]$sectionBytes = $compoundSession.ReadStream(
                'BodyText', [string]$element.Name, $MaximumStreamBytes
            )
            if ($compressed) {
                $remainingExpandedBytes = $MaximumExpandedBytes - $expandedByteCount
                if ($remainingExpandedBytes -lt 1) {
                    throw [IO.InvalidDataException]::new('HWP 문서 전체 압축 해제 크기가 안전 한도를 초과했습니다.')
                }
                try {
                    [byte[]]$sectionBytes = Expand-HwpPortableDeflate -Bytes $sectionBytes `
                        -MaximumBytes $remainingExpandedBytes
                }
                catch [IO.InvalidDataException] {
                    throw [IO.InvalidDataException]::new(
                        'HWP 문서 전체 압축 해제 크기가 안전 한도를 초과했습니다.',
                        $_.Exception
                    )
                }
            }
            $expandedByteCount += $sectionBytes.Length
            if ($expandedByteCount -gt $MaximumExpandedBytes) {
                throw [IO.InvalidDataException]::new('HWP 문서 전체 압축 해제 크기가 안전 한도를 초과했습니다.')
            }

            $remainingRecords = $MaximumTotalRecords - $recordCount
            if ($remainingRecords -lt 1) {
                throw [IO.InvalidDataException]::new('HWP 문서 전체 레코드 수가 안전 한도를 초과했습니다.')
            }
            $remainingTextCharacters = $MaximumTextCharacters - $textCharacterCount
            if ($remainingTextCharacters -lt 1) {
                throw [IO.InvalidDataException]::new('HWP 문서 전체 추출 텍스트가 안전 한도를 초과했습니다.')
            }
            $section = Get-HwpPortableSectionData -Bytes $sectionBytes -SectionName ([string]$element.Name) `
                -Controls $controls -MaximumRecords $remainingRecords -MaximumControls $MaximumControls `
                -MaximumTextCharacters $remainingTextCharacters
            foreach ($paragraph in @($section.Paragraphs)) {
                $paragraphs.Add([string]$paragraph)
            }
            $recordCount += [int]$section.RecordCount
            $textCharacterCount += [long]$section.TextCharacterCount
        }

        $finalHash = Get-HwpSha256 -LiteralPath $resolvedPath
        if ($finalHash -ne $lockedHash) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'HWP 파일이 읽는 동안 변경되어 일관된 결과를 만들 수 없습니다.'
            )
        }

        $warnings = @(
            'HWP 5.x를 Windows 기본 OLE 복합파일 API로 읽었으며 한컴오피스는 실행하지 않았습니다.',
            '본문 텍스트와 표·그림·수식 개체를 구조적으로 읽었습니다. 페이지 수와 최종 레이아웃은 별도 렌더러로 확인해야 합니다.'
        )
        New-HwpResult -Status PASS_WITH_WARNINGS -Command inspect-hwp-portable -Data ([pscustomobject]@{
            Path = $resolvedPath
            Version = $version
            Compressed = $compressed
            Text = $paragraphs -join "`r`n"
            Fields = [pscustomobject]@{}
            Controls = @($controls)
            PageCount = 0
            SectionCount = $sectionElements.Count
            RecordCount = $recordCount
            ExpandedBytes = $expandedByteCount
            TextCharacterCount = $textCharacterCount
            NativeLayoutVerified = $false
        }) -Warnings $warnings
    }
    catch [IO.InvalidDataException] {
        New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
            "HWP 복합파일 구조를 안전하게 읽을 수 없습니다: $($_.Exception.Message)"
        )
    }
    catch [Runtime.InteropServices.COMException] {
        New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
            "HWP OLE 스트림을 읽을 수 없습니다: $($_.Exception.Message)"
        )
    }
    catch {
        New-HwpResult -Status FAILED -Command inspect-hwp-portable -Errors @(
            "HWP 휴대형 읽기 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        if ($null -ne $compoundSession) {
            $compoundSession.Dispose()
        }
    }
}

Export-ModuleMember -Function @(
    'Get-HwpPortableInspection'
)
