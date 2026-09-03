Set-StrictMode -Version Latest

$script:HwpLanguageNames = @('HANGUL', 'LATIN', 'HANJA', 'JAPANESE', 'OTHER', 'SYMBOL', 'USER')
$script:HwpLanguagePropertyNames = @('Hangul', 'Latin', 'Hanja', 'Japanese', 'Other', 'Symbol', 'User')
$script:HwpBorderTypes = @(
    'SOLID', 'DASH', 'DOT', 'DASH_DOT', 'DASH_DOT_DOT', 'LONG_DASH', 'CIRCLE',
    'DOUBLE', 'THIN_THICK', 'THICK_THIN', 'THIN_THICK_THIN', 'WAVE', 'DOUBLE_WAVE',
    'THICK_3D', 'THICK_3D_REVERSE', 'SOLID_3D', 'SOLID_3D_REVERSE'
)
$script:HwpBorderWidthsMm = @(0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0)

function ConvertFrom-HwpColorRef {
    param([Parameter(Mandatory)][uint32]$Value)

    if ($Value -eq [uint32]::MaxValue) { return 'none' }
    $red = $Value -band 0xFF
    $green = ($Value -shr 8) -band 0xFF
    $blue = ($Value -shr 16) -band 0xFF
    '#{0:X2}{1:X2}{2:X2}' -f $red, $green, $blue
}

function ConvertFrom-HwpSignedByte {
    param([Parameter(Mandatory)][byte]$Value)
    if ($Value -gt 127) { return [int]$Value - 256 }
    [int]$Value
}

function New-HwpMeasurement {
    param([Parameter(Mandatory)][long]$Raw)

    [pscustomobject][ordered]@{
        raw = $Raw
        point = [Math]::Round($Raw / 100.0, 4)
        millimeter = [Math]::Round($Raw / 283.4645669, 4)
    }
}

function Get-HwpPortableRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateRange(1, 2000000)][int]$MaximumRecords = 1000000,
        [string]$StreamName = 'HWP stream'
    )

    $records = [Collections.Generic.List[object]]::new()
    $offset = 0
    while ($offset -lt $Bytes.Length) {
        if ($records.Count -ge $MaximumRecords) {
            throw [IO.InvalidDataException]::new("$StreamName 레코드 수가 안전 한도를 초과했습니다.")
        }
        if (($Bytes.Length - $offset) -lt 4) {
            throw [IO.InvalidDataException]::new("$StreamName 레코드 헤더가 중간에서 끝났습니다.")
        }
        $recordOffset = $offset
        $header = [BitConverter]::ToUInt32($Bytes, $offset)
        $offset += 4
        $tagId = [int]($header -band 0x3FF)
        $level = [int](($header -shr 10) -band 0x3FF)
        [long]$size = [long](($header -shr 20) -band 0xFFF)
        if ($size -eq 0xFFF) {
            if (($Bytes.Length - $offset) -lt 4) {
                throw [IO.InvalidDataException]::new("$StreamName 확장 레코드 길이가 중간에서 끝났습니다.")
            }
            $size = [long][BitConverter]::ToUInt32($Bytes, $offset)
            $offset += 4
        }
        if ($size -gt [int]::MaxValue -or ($offset + $size) -gt $Bytes.Length) {
            throw [IO.InvalidDataException]::new("$StreamName 레코드 길이가 스트림 범위를 벗어났습니다.")
        }
        $payload = [byte[]]::new([int]$size)
        if ($size -gt 0) { [Array]::Copy($Bytes, $offset, $payload, 0, [int]$size) }
        $records.Add([pscustomobject][ordered]@{
            index = $records.Count
            offset = $recordOffset
            tagId = $tagId
            level = $level
            size = [int]$size
            payload = $payload
        })
        $offset += [int]$size
    }
    @($records)
}

function Read-HwpPortableUtf16String {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][string]$Label
    )

    if (($Offset + 2) -gt $Bytes.Length) {
        throw [IO.InvalidDataException]::new("$Label 길이가 중간에서 끝났습니다.")
    }
    $length = [int][BitConverter]::ToUInt16($Bytes, $Offset)
    [long]$byteLength = [long]$length * 2
    if (($Offset + 2 + $byteLength) -gt $Bytes.Length) {
        throw [IO.InvalidDataException]::new("$Label 문자열이 중간에서 끝났습니다.")
    }
    [pscustomobject]@{
        value = [Text.Encoding]::Unicode.GetString($Bytes, $Offset + 2, [int]$byteLength)
        nextOffset = $Offset + 2 + [int]$byteLength
    }
}

function ConvertFrom-HwpPortableFaceNamePayload {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$RecordIndex
    )

    if ($Bytes.Length -lt 3) {
        throw [IO.InvalidDataException]::new('HWP 글꼴 레코드가 최소 길이보다 짧습니다.')
    }
    $attributes = [int]$Bytes[0]
    $nameResult = Read-HwpPortableUtf16String -Bytes $Bytes -Offset 1 -Label 'HWP 글꼴 이름'
    $cursor = [int]$nameResult.nextOffset
    $alternateFont = $null
    if (($attributes -band 0x80) -ne 0) {
        if (($cursor + 1) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 대체 글꼴 유형이 중간에서 끝났습니다.') }
        $alternateTypeCode = [int]$Bytes[$cursor]
        $cursor++
        $alternateResult = Read-HwpPortableUtf16String -Bytes $Bytes -Offset $cursor -Label 'HWP 대체 글꼴 이름'
        $cursor = [int]$alternateResult.nextOffset
        $alternateFont = [pscustomobject][ordered]@{
            typeCode = $alternateTypeCode
            type = switch ($alternateTypeCode) { 1 { 'TTF' } 2 { 'HFT' } default { 'UNKNOWN' } }
            name = [string]$alternateResult.value
        }
    }
    $typeInfo = $null
    if (($attributes -band 0x40) -ne 0) {
        if (($cursor + 10) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 글꼴 유형 정보가 중간에서 끝났습니다.') }
        $typeInfo = [pscustomobject][ordered]@{
            family = [int]$Bytes[$cursor]
            serif = [int]$Bytes[$cursor + 1]
            weight = [int]$Bytes[$cursor + 2]
            proportion = [int]$Bytes[$cursor + 3]
            contrast = [int]$Bytes[$cursor + 4]
            strokeVariation = [int]$Bytes[$cursor + 5]
            armStyle = [int]$Bytes[$cursor + 6]
            letterform = [int]$Bytes[$cursor + 7]
            midline = [int]$Bytes[$cursor + 8]
            xHeight = [int]$Bytes[$cursor + 9]
        }
        $cursor += 10
    }
    $defaultFont = ''
    if (($attributes -band 0x20) -ne 0) {
        $defaultResult = Read-HwpPortableUtf16String -Bytes $Bytes -Offset $cursor -Label 'HWP 기본 글꼴 이름'
        $cursor = [int]$defaultResult.nextOffset
        $defaultFont = [string]$defaultResult.value
    }
    [pscustomobject][ordered]@{
        index = $RecordIndex
        id = -1
        languageIndex = -1
        language = 'UNKNOWN'
        name = [string]$nameResult.value
        attributesRaw = $attributes
        alternateFont = $alternateFont
        typeInfo = $typeInfo
        defaultFont = $defaultFont
        parsedBytes = $cursor
    }
}

function Get-HwpBorderTypeName {
    param([Parameter(Mandatory)][int]$Code)
    if ($Code -ge 0 -and $Code -lt $script:HwpBorderTypes.Count) { return $script:HwpBorderTypes[$Code] }
    "UNKNOWN_$Code"
}

function Get-HwpBorderWidthMillimeter {
    param([Parameter(Mandatory)][int]$Code)
    if ($Code -ge 0 -and $Code -lt $script:HwpBorderWidthsMm.Count) { return [double]$script:HwpBorderWidthsMm[$Code] }
    $null
}

function ConvertFrom-HwpPortableBorderFillPayload {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$RecordIndex
    )

    if ($Bytes.Length -lt 32) {
        throw [IO.InvalidDataException]::new('HWP 테두리/배경 레코드가 32바이트보다 짧습니다.')
    }
    $attributes = [int][BitConverter]::ToUInt16($Bytes, 0)
    $names = @('Left', 'Right', 'Top', 'Bottom')
    $borders = [ordered]@{}
    for ($index = 0; $index -lt 4; $index++) {
        $typeCode = [int]$Bytes[2 + $index]
        $widthCode = [int]$Bytes[6 + $index]
        $colorRaw = [BitConverter]::ToUInt32($Bytes, 10 + (4 * $index))
        $borders[$names[$index]] = [pscustomobject][ordered]@{
            typeCode = $typeCode
            type = Get-HwpBorderTypeName -Code $typeCode
            widthCode = $widthCode
            widthMm = Get-HwpBorderWidthMillimeter -Code $widthCode
            colorRaw = [uint32]$colorRaw
            color = ConvertFrom-HwpColorRef -Value $colorRaw
        }
    }
    $diagonalTypeCode = [int]$Bytes[26]
    $diagonalWidthCode = [int]$Bytes[27]
    $diagonalColorRaw = [BitConverter]::ToUInt32($Bytes, 28)
    $fill = [pscustomobject][ordered]@{
        typeRaw = [uint32]0
        types = @()
        solid = $null
        gradient = $null
        image = $null
    }
    if ($Bytes.Length -ge 36) {
        $fillType = [BitConverter]::ToUInt32($Bytes, 32)
        $cursor = 36
        $fill.typeRaw = [uint32]$fillType
        $fillTypes = [Collections.Generic.List[string]]::new()
        if (($fillType -band 0x1) -ne 0) {
            $fillTypes.Add('SOLID')
            if (($cursor + 12) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 단색 채우기 정보가 중간에서 끝났습니다.') }
            $backgroundRaw = [BitConverter]::ToUInt32($Bytes, $cursor)
            $patternRaw = [BitConverter]::ToUInt32($Bytes, $cursor + 4)
            $fill.solid = [pscustomobject][ordered]@{
                backgroundColorRaw = [uint32]$backgroundRaw
                backgroundColor = ConvertFrom-HwpColorRef -Value $backgroundRaw
                patternColorRaw = [uint32]$patternRaw
                patternColor = ConvertFrom-HwpColorRef -Value $patternRaw
                patternType = [BitConverter]::ToInt32($Bytes, $cursor + 8)
            }
            $cursor += 12
        }
        if (($fillType -band 0x4) -ne 0) {
            $fillTypes.Add('GRADIENT')
            if (($cursor + 12) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 그러데이션 정보가 중간에서 끝났습니다.') }
            $gradientType = [BitConverter]::ToInt16($Bytes, $cursor)
            $angle = [BitConverter]::ToInt16($Bytes, $cursor + 2)
            $centerX = [BitConverter]::ToInt16($Bytes, $cursor + 4)
            $centerY = [BitConverter]::ToInt16($Bytes, $cursor + 6)
            $blur = [BitConverter]::ToInt16($Bytes, $cursor + 8)
            $colorCount = [int][BitConverter]::ToInt16($Bytes, $cursor + 10)
            if ($colorCount -lt 0 -or $colorCount -gt 4096) { throw [IO.InvalidDataException]::new('HWP 그러데이션 색상 수가 올바르지 않습니다.') }
            $cursor += 12
            $positions = [Collections.Generic.List[int]]::new()
            if ($colorCount -gt 2) {
                [long]$positionBytes = [long]$colorCount * 4
                if (($cursor + $positionBytes) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 그러데이션 위치 정보가 중간에서 끝났습니다.') }
                for ($index = 0; $index -lt $colorCount; $index++) {
                    $positions.Add([BitConverter]::ToInt32($Bytes, $cursor + (4 * $index)))
                }
                $cursor += [int]$positionBytes
            }
            [long]$colorBytes = [long]$colorCount * 4
            if (($cursor + $colorBytes) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 그러데이션 색상 정보가 중간에서 끝났습니다.') }
            $colors = [Collections.Generic.List[string]]::new()
            for ($index = 0; $index -lt $colorCount; $index++) {
                $colors.Add((ConvertFrom-HwpColorRef -Value ([BitConverter]::ToUInt32($Bytes, $cursor + (4 * $index)))))
            }
            $cursor += [int]$colorBytes
            $fill.gradient = [pscustomobject][ordered]@{
                typeCode = [int]$gradientType
                angle = [int]$angle
                centerX = [int]$centerX
                centerY = [int]$centerY
                blur = [int]$blur
                colorCount = $colorCount
                positions = @($positions)
                colors = @($colors)
            }
        }
        if (($fillType -band 0x2) -ne 0) {
            $fillTypes.Add('IMAGE')
            if (($cursor + 6) -gt $Bytes.Length) { throw [IO.InvalidDataException]::new('HWP 이미지 채우기 정보가 중간에서 끝났습니다.') }
            $fill.image = [pscustomobject][ordered]@{
                modeCode = [int]$Bytes[$cursor]
                brightness = ConvertFrom-HwpSignedByte -Value $Bytes[$cursor + 1]
                contrast = ConvertFrom-HwpSignedByte -Value $Bytes[$cursor + 2]
                effectCode = [int]$Bytes[$cursor + 3]
                binDataId = [int][BitConverter]::ToUInt16($Bytes, $cursor + 4)
            }
            $cursor += 6
        }
        $fill.types = @($fillTypes)
    }
    [pscustomobject][ordered]@{
        index = $RecordIndex
        id = $RecordIndex + 1
        attributesRaw = $attributes
        threeD = ($attributes -band 0x1) -ne 0
        shadow = ($attributes -band 0x2) -ne 0
        slashCode = ($attributes -shr 2) -band 0x7
        backSlashCode = ($attributes -shr 5) -band 0x7
        centerLine = ($attributes -band 0x2000) -ne 0
        borders = [pscustomobject]$borders
        diagonal = [pscustomobject][ordered]@{
            typeCode = $diagonalTypeCode
            type = switch ($diagonalTypeCode) { 0 { 'SLASH' } 1 { 'BACK_SLASH' } 2 { 'CROOKED_SLASH' } default { "UNKNOWN_$diagonalTypeCode" } }
            widthCode = $diagonalWidthCode
            widthMm = Get-HwpBorderWidthMillimeter -Code $diagonalWidthCode
            colorRaw = [uint32]$diagonalColorRaw
            color = ConvertFrom-HwpColorRef -Value $diagonalColorRaw
        }
        fill = $fill
    }
}

function New-HwpLanguageValues {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset,
        [ValidateSet('UInt16', 'Byte', 'SByte')][string]$Kind
    )

    $values = [ordered]@{}
    for ($index = 0; $index -lt 7; $index++) {
        $value = switch ($Kind) {
            'UInt16' { [int][BitConverter]::ToUInt16($Bytes, $Offset + (2 * $index)) }
            'SByte' { ConvertFrom-HwpSignedByte -Value $Bytes[$Offset + $index] }
            default { [int]$Bytes[$Offset + $index] }
        }
        $values[$script:HwpLanguagePropertyNames[$index]] = $value
    }
    [pscustomobject]$values
}

function ConvertFrom-HwpPortableCharShapePayload {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$RecordIndex,
        [Collections.Generic.Dictionary[string, string]]$FontNameMap
    )

    if ($Bytes.Length -lt 68) { throw [IO.InvalidDataException]::new('HWP 글자 모양 레코드가 68바이트보다 짧습니다.') }
    $fontIds = New-HwpLanguageValues -Bytes $Bytes -Offset 0 -Kind UInt16
    $ratios = New-HwpLanguageValues -Bytes $Bytes -Offset 14 -Kind Byte
    $spacings = New-HwpLanguageValues -Bytes $Bytes -Offset 21 -Kind SByte
    $relativeSizes = New-HwpLanguageValues -Bytes $Bytes -Offset 28 -Kind Byte
    $offsets = New-HwpLanguageValues -Bytes $Bytes -Offset 35 -Kind SByte
    $fontSizeRaw = [BitConverter]::ToInt32($Bytes, 42)
    $attributes = [BitConverter]::ToUInt32($Bytes, 46)
    $resolvedFontNames = [ordered]@{}
    for ($index = 0; $index -lt 7; $index++) {
        $property = $script:HwpLanguagePropertyNames[$index]
        $key = '{0}:{1}' -f $index, [int]$fontIds.$property
        $resolvedFontNames[$property] = if ($null -ne $FontNameMap -and $FontNameMap.ContainsKey($key)) { $FontNameMap[$key] } else { '' }
    }
    $textColorRaw = [BitConverter]::ToUInt32($Bytes, 52)
    $underlineColorRaw = [BitConverter]::ToUInt32($Bytes, 56)
    $shadeColorRaw = [BitConverter]::ToUInt32($Bytes, 60)
    $shadowColorRaw = [BitConverter]::ToUInt32($Bytes, 64)
    $borderFillId = if ($Bytes.Length -ge 70) { [int][BitConverter]::ToUInt16($Bytes, 68) } else { $null }
    $strikeColorRaw = if ($Bytes.Length -ge 74) { [BitConverter]::ToUInt32($Bytes, 70) } else { $null }
    [pscustomobject][ordered]@{
        index = $RecordIndex
        id = $RecordIndex
        fontIds = $fontIds
        resolvedFontNames = [pscustomobject]$resolvedFontNames
        ratios = $ratios
        spacings = $spacings
        relativeSizes = $relativeSizes
        offsets = $offsets
        fontSizeRaw = $fontSizeRaw
        fontSizePt = [Math]::Round($fontSizeRaw / 100.0, 4)
        attributesRaw = [uint32]$attributes
        attributes = [pscustomobject][ordered]@{
            italic = ($attributes -band 0x1) -ne 0
            bold = ($attributes -band 0x2) -ne 0
            underlineTypeCode = ($attributes -shr 2) -band 0x3
            underlineShapeCode = ($attributes -shr 4) -band 0xF
            outlineCode = ($attributes -shr 8) -band 0x7
            shadowCode = ($attributes -shr 11) -band 0x3
            emboss = ($attributes -band 0x2000) -ne 0
            engrave = ($attributes -band 0x4000) -ne 0
            superscript = ($attributes -band 0x8000) -ne 0
            subscript = ($attributes -band 0x10000) -ne 0
            useFontSpace = ($attributes -band 0x2000000) -ne 0
            kerning = ($attributes -band 0x40000000) -ne 0
        }
        shadowOffset = [pscustomobject]@{
            x = ConvertFrom-HwpSignedByte -Value $Bytes[50]
            y = ConvertFrom-HwpSignedByte -Value $Bytes[51]
        }
        textColorRaw = [uint32]$textColorRaw
        textColor = ConvertFrom-HwpColorRef -Value $textColorRaw
        underlineColorRaw = [uint32]$underlineColorRaw
        underlineColor = ConvertFrom-HwpColorRef -Value $underlineColorRaw
        shadeColorRaw = [uint32]$shadeColorRaw
        shadeColor = ConvertFrom-HwpColorRef -Value $shadeColorRaw
        shadowColorRaw = [uint32]$shadowColorRaw
        shadowColor = ConvertFrom-HwpColorRef -Value $shadowColorRaw
        borderFillId = $borderFillId
        strikeColor = if ($null -eq $strikeColorRaw) { $null } else { ConvertFrom-HwpColorRef -Value $strikeColorRaw }
    }
}

function ConvertFrom-HwpPortableParaShapePayload {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$RecordIndex
    )

    if ($Bytes.Length -lt 42) { throw [IO.InvalidDataException]::new('HWP 문단 모양 레코드가 42바이트보다 짧습니다.') }
    $attributes1 = [BitConverter]::ToUInt32($Bytes, 0)
    $attributes2 = if ($Bytes.Length -ge 46) { [BitConverter]::ToUInt32($Bytes, 42) } else { [uint32]0 }
    $attributes3 = if ($Bytes.Length -ge 50) { [BitConverter]::ToUInt32($Bytes, 46) } else { [uint32]0 }
    $lineSpacingRaw = if ($Bytes.Length -ge 54) { [long][BitConverter]::ToUInt32($Bytes, 50) } else { [long][BitConverter]::ToInt32($Bytes, 24) }
    $lineSpacingKindCode = if ($Bytes.Length -ge 54) { [int]($attributes3 -band 0x1F) } else { [int]($attributes1 -band 0x3) }
    $alignmentCode = [int](($attributes1 -shr 2) -band 0x7)
    [pscustomobject][ordered]@{
        index = $RecordIndex
        id = $RecordIndex
        attributes1Raw = [uint32]$attributes1
        attributes2Raw = [uint32]$attributes2
        attributes3Raw = [uint32]$attributes3
        alignmentCode = $alignmentCode
        alignment = switch ($alignmentCode) {
            0 { 'JUSTIFY' } 1 { 'LEFT' } 2 { 'RIGHT' } 3 { 'CENTER' }
            4 { 'DISTRIBUTE' } 5 { 'DISTRIBUTE_SPACE' } default { "UNKNOWN_$alignmentCode" }
        }
        breakLatinWordCode = [int](($attributes1 -shr 5) -band 0x3)
        breakNonLatinWordCode = [int](($attributes1 -shr 7) -band 0x1)
        snapToGrid = ($attributes1 -band 0x100) -ne 0
        widowOrphan = ($attributes1 -band 0x10000) -ne 0
        keepWithNext = ($attributes1 -band 0x20000) -ne 0
        keepLines = ($attributes1 -band 0x40000) -ne 0
        pageBreakBefore = ($attributes1 -band 0x80000) -ne 0
        verticalAlignmentCode = [int](($attributes1 -shr 20) -band 0x3)
        margins = [pscustomobject][ordered]@{
            left = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 4))
            right = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 8))
            before = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 16))
            after = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 20))
        }
        indent = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 12))
        tabDefinitionId = [int][BitConverter]::ToUInt16($Bytes, 28)
        numberingOrBulletId = [int][BitConverter]::ToUInt16($Bytes, 30)
        borderFillId = [int][BitConverter]::ToUInt16($Bytes, 32)
        borderOffsets = [pscustomobject][ordered]@{
            left = New-HwpMeasurement -Raw ([BitConverter]::ToInt16($Bytes, 34))
            right = New-HwpMeasurement -Raw ([BitConverter]::ToInt16($Bytes, 36))
            top = New-HwpMeasurement -Raw ([BitConverter]::ToInt16($Bytes, 38))
            bottom = New-HwpMeasurement -Raw ([BitConverter]::ToInt16($Bytes, 40))
        }
        autoSpacing = [pscustomobject]@{
            eAsianEnglish = ($attributes2 -band 0x10) -ne 0
            eAsianNumber = ($attributes2 -band 0x20) -ne 0
        }
        lineSpacing = [pscustomobject][ordered]@{
            typeCode = $lineSpacingKindCode
            type = switch ($lineSpacingKindCode) { 0 { 'PERCENT' } 1 { 'FIXED' } 2 { 'BETWEEN_LINES' } 3 { 'MINIMUM' } default { "UNKNOWN_$lineSpacingKindCode" } }
            value = $lineSpacingRaw
        }
    }
}

function Get-HwpPortableDocInfoData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [ValidateRange(1, 1000000)][int]$MaximumRecords = 500000,
        [ValidateRange(1, 1000000)][int]$MaximumResources = 500000
    )

    $records = @(Get-HwpPortableRecords -Bytes $Bytes -MaximumRecords $MaximumRecords -StreamName 'HWP DocInfo')
    $mappingCounts = [int[]]::new(18)
    $fonts = [Collections.Generic.List[object]]::new()
    $borderFills = [Collections.Generic.List[object]]::new()
    $charShapePayloads = [Collections.Generic.List[byte[]]]::new()
    $paraShapes = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        switch ([int]$record.tagId) {
            0x11 {
                $count = [Math]::Min(18, [Math]::Floor($record.payload.Length / 4))
                for ($index = 0; $index -lt $count; $index++) {
                    $value = [BitConverter]::ToInt32($record.payload, 4 * $index)
                    if ($value -lt 0) { throw [IO.InvalidDataException]::new('HWP 아이디 매핑 개수에 음수가 있습니다.') }
                    $mappingCounts[$index] = $value
                }
                break
            }
            0x13 {
                if ($fonts.Count -ge $MaximumResources) { throw [IO.InvalidDataException]::new('HWP 글꼴 수가 안전 한도를 초과했습니다.') }
                $fonts.Add((ConvertFrom-HwpPortableFaceNamePayload -Bytes $record.payload -RecordIndex $fonts.Count))
                break
            }
            0x14 {
                if ($borderFills.Count -ge $MaximumResources) { throw [IO.InvalidDataException]::new('HWP 테두리/배경 수가 안전 한도를 초과했습니다.') }
                $borderFills.Add((ConvertFrom-HwpPortableBorderFillPayload -Bytes $record.payload -RecordIndex $borderFills.Count))
                break
            }
            0x15 {
                if ($charShapePayloads.Count -ge $MaximumResources) { throw [IO.InvalidDataException]::new('HWP 글자 모양 수가 안전 한도를 초과했습니다.') }
                $charShapePayloads.Add([byte[]]$record.payload)
                break
            }
            0x19 {
                if ($paraShapes.Count -ge $MaximumResources) { throw [IO.InvalidDataException]::new('HWP 문단 모양 수가 안전 한도를 초과했습니다.') }
                $paraShapes.Add((ConvertFrom-HwpPortableParaShapePayload -Bytes $record.payload -RecordIndex $paraShapes.Count))
                break
            }
        }
    }

    $fontNameMap = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $globalFontIndex = 0
    for ($languageIndex = 0; $languageIndex -lt 7; $languageIndex++) {
        $languageCount = $mappingCounts[$languageIndex + 1]
        for ($fontId = 0; $fontId -lt $languageCount -and $globalFontIndex -lt $fonts.Count; $fontId++) {
            $font = $fonts[$globalFontIndex]
            $font.id = $fontId
            $font.languageIndex = $languageIndex
            $font.language = $script:HwpLanguageNames[$languageIndex]
            $fontNameMap.Add(('{0}:{1}' -f $languageIndex, $fontId), [string]$font.name)
            $globalFontIndex++
        }
    }
    while ($globalFontIndex -lt $fonts.Count) {
        $fonts[$globalFontIndex].id = $globalFontIndex
        $globalFontIndex++
    }

    $charShapes = [Collections.Generic.List[object]]::new()
    foreach ($payload in $charShapePayloads) {
        $charShapes.Add((ConvertFrom-HwpPortableCharShapePayload -Bytes $payload -RecordIndex $charShapes.Count -FontNameMap $fontNameMap))
    }
    [pscustomobject][ordered]@{
        resources = [pscustomobject][ordered]@{
            fonts = @($fonts)
            borderFills = @($borderFills)
            charShapes = @($charShapes)
            paraShapes = @($paraShapes)
        }
        mappingCounts = @($mappingCounts)
        recordCount = $records.Count
    }
}

function ConvertFrom-HwpPortableParagraphHeaderPayload {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if ($Bytes.Length -lt 22) { throw [IO.InvalidDataException]::new('HWP 문단 헤더가 22바이트보다 짧습니다.') }
    $characterCountRaw = [BitConverter]::ToUInt32($Bytes, 0)
    [pscustomobject][ordered]@{
        characterCountRaw = [uint32]$characterCountRaw
        characterCount = [long]($characterCountRaw -band 0x7FFFFFFF)
        controlMask = [uint32][BitConverter]::ToUInt32($Bytes, 4)
        paraShapeId = [int][BitConverter]::ToUInt16($Bytes, 8)
        styleId = [int]$Bytes[10]
        breakTypeRaw = [int]$Bytes[11]
        charShapeCount = [int][BitConverter]::ToUInt16($Bytes, 12)
        rangeTagCount = [int][BitConverter]::ToUInt16($Bytes, 14)
        lineSegmentCount = [int][BitConverter]::ToUInt16($Bytes, 16)
        instanceId = [uint32][BitConverter]::ToUInt32($Bytes, 18)
        mergedByTrackChange = if ($Bytes.Length -ge 24) { [BitConverter]::ToUInt16($Bytes, 22) -ne 0 } else { $null }
    }
}

function ConvertFrom-HwpPortableParagraphTextDetail {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (($Bytes.Length % 2) -ne 0) { throw [IO.InvalidDataException]::new('HWP 문단 텍스트의 UTF-16LE 바이트 길이가 올바르지 않습니다.') }
    $rawUnits = [int]($Bytes.Length / 2)
    $positionMap = [int[]]::new($rawUnits + 1)
    $builder = [Text.StringBuilder]::new()
    $extendedOrInline = [Collections.Generic.HashSet[uint16]]::new()
    foreach ($code in @(1,2,3,4,5,6,7,8,9,11,12,14,15,16,17,18,19,20,21,22,23)) { $null = $extendedOrInline.Add([uint16]$code) }
    $unit = 0
    while ($unit -lt $rawUnits) {
        $outputBefore = $builder.Length
        $positionMap[$unit] = $outputBefore
        $code = [BitConverter]::ToUInt16($Bytes, $unit * 2)
        if ($code -ge 32) {
            $null = $builder.Append([char]$code)
            $unit++
            $positionMap[$unit] = $builder.Length
            continue
        }
        switch ($code) {
            9 { $null = $builder.Append("`t") }
            10 { $null = $builder.Append("`n") }
            24 { $null = $builder.Append('-') }
            30 { $null = $builder.Append(' ') }
            31 { $null = $builder.Append(' ') }
        }
        $skip = if ($extendedOrInline.Contains([uint16]$code)) { 8 } else { 1 }
        if (($unit + $skip) -gt $rawUnits) { throw [IO.InvalidDataException]::new("HWP 제어 문자 $code 데이터가 중간에서 끝났습니다.") }
        for ($inner = 1; $inner -lt $skip; $inner++) { $positionMap[$unit + $inner] = $outputBefore }
        $unit += $skip
        $positionMap[$unit] = $builder.Length
    }
    [pscustomobject][ordered]@{
        text = $builder.ToString()
        rawCharacterCount = $rawUnits
        positionMap = $positionMap
    }
}

function ConvertFrom-HwpPortableCharShapeRuns {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (($Bytes.Length % 8) -ne 0) { throw [IO.InvalidDataException]::new('HWP 문단 글자 모양 레코드 길이가 8바이트 배수가 아닙니다.') }
    $runs = [Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Bytes.Length; $offset += 8) {
        $runs.Add([pscustomobject][ordered]@{
            start = [long][BitConverter]::ToUInt32($Bytes, $offset)
            charShapeId = [long][BitConverter]::ToUInt32($Bytes, $offset + 4)
        })
    }
    @($runs)
}

function ConvertFrom-HwpPortableLineSegments {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if (($Bytes.Length % 36) -ne 0) { throw [IO.InvalidDataException]::new('HWP 문단 레이아웃 레코드 길이가 36바이트 배수가 아닙니다.') }
    $segments = [Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Bytes.Length; $offset += 36) {
        $flags = [BitConverter]::ToUInt32($Bytes, $offset + 32)
        $segments.Add([pscustomobject][ordered]@{
            index = $segments.Count
            textStart = [long][BitConverter]::ToUInt32($Bytes, $offset)
            verticalPosition = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 4))
            lineHeight = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 8))
            textHeight = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 12))
            baseline = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 16))
            lineSpacing = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 20))
            columnStart = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 24))
            segmentWidth = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, $offset + 28))
            flagsRaw = [uint32]$flags
            isPageFirst = ($flags -band 0x1) -ne 0
            isColumnFirst = ($flags -band 0x2) -ne 0
            isEmpty = ($flags -band 0x10000) -ne 0
            isLineFirst = ($flags -band 0x20000) -ne 0
            isLineLast = ($flags -band 0x40000) -ne 0
            autoHyphenated = ($flags -band 0x80000) -ne 0
            indentationApplied = ($flags -band 0x100000) -ne 0
            paragraphHeadApplied = ($flags -band 0x200000) -ne 0
            text = ''
        })
    }
    @($segments)
}

function ConvertFrom-HwpPortablePageDefinitionPayload {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Index
    )
    if ($Bytes.Length -lt 40) { throw [IO.InvalidDataException]::new('HWP 용지 설정 레코드가 40바이트보다 짧습니다.') }
    $attributes = [BitConverter]::ToUInt32($Bytes, 36)
    [pscustomobject][ordered]@{
        index = $Index
        orientation = if (($attributes -band 0x1) -ne 0) { 'LANDSCAPE' } else { 'PORTRAIT' }
        width = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 0))
        height = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 4))
        margins = [pscustomobject][ordered]@{
            left = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 8))
            right = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 12))
            top = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 16))
            bottom = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 20))
            header = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 24))
            footer = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 28))
            gutter = New-HwpMeasurement -Raw ([BitConverter]::ToInt32($Bytes, 32))
        }
        bindingMethodCode = [int](($attributes -shr 1) -band 0x3)
        attributesRaw = [uint32]$attributes
    }
}

function Complete-HwpPortableParagraphModel {
    param([Parameter(Mandatory)][object]$Context)

    $textDetail = $Context.TextDetail
    if ($null -eq $textDetail) {
        $textDetail = [pscustomobject]@{ text = ''; rawCharacterCount = 0; positionMap = [int[]](0) }
    }
    $segments = @($Context.LineSegments)
    $lineStarts = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $segments.Count; $index++) {
        if ($index -eq 0 -or $segments[$index].isLineFirst) { $lineStarts.Add($segments[$index]) }
    }
    $storedLines = [Collections.Generic.List[object]]::new()
    for ($lineIndex = 0; $lineIndex -lt $lineStarts.Count; $lineIndex++) {
        $startRaw = [int][Math]::Min([long]$textDetail.rawCharacterCount, [long]$lineStarts[$lineIndex].textStart)
        $endRaw = if ($lineIndex -lt ($lineStarts.Count - 1)) {
            [int][Math]::Min([long]$textDetail.rawCharacterCount, [long]$lineStarts[$lineIndex + 1].textStart)
        }
        else { [int]$textDetail.rawCharacterCount }
        $startOutput = $textDetail.positionMap[$startRaw]
        $endOutput = $textDetail.positionMap[$endRaw]
        if ($endOutput -lt $startOutput) { $endOutput = $startOutput }
        $lineText = ([string]$textDetail.text).Substring($startOutput, $endOutput - $startOutput)
        $storedLines.Add([pscustomobject][ordered]@{
            index = $lineIndex
            textStart = $startRaw
            textEnd = $endRaw
            text = $lineText
        })
    }
    for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
        $startRaw = [int][Math]::Min([long]$textDetail.rawCharacterCount, [long]$segments[$segmentIndex].textStart)
        $nextRaw = if ($segmentIndex -lt ($segments.Count - 1)) {
            [int][Math]::Min([long]$textDetail.rawCharacterCount, [long]$segments[$segmentIndex + 1].textStart)
        }
        else { [int]$textDetail.rawCharacterCount }
        $startOutput = $textDetail.positionMap[$startRaw]
        $endOutput = $textDetail.positionMap[$nextRaw]
        if ($endOutput -lt $startOutput) { $endOutput = $startOutput }
        $segments[$segmentIndex].text = ([string]$textDetail.text).Substring($startOutput, $endOutput - $startOutput)
    }
    [pscustomobject][ordered]@{
        index = [int]$Context.Index
        section = [string]$Context.Section
        recordLevel = [int]$Context.RecordLevel
        text = [string]$textDetail.text
        rawCharacterCount = [int]$textDetail.rawCharacterCount
        declaredCharacterCount = [long]$Context.Header.characterCount
        paraShapeId = [int]$Context.Header.paraShapeId
        styleId = [int]$Context.Header.styleId
        breakTypeRaw = [int]$Context.Header.breakTypeRaw
        controlMask = [uint32]$Context.Header.controlMask
        instanceId = [uint32]$Context.Header.instanceId
        charShapeRuns = @($Context.CharShapeRuns)
        lineSegments = @($segments)
        storedLines = @($storedLines)
    }
}

Export-ModuleMember -Function @(
    'Get-HwpPortableRecords',
    'Get-HwpPortableDocInfoData',
    'ConvertFrom-HwpPortableParagraphHeaderPayload',
    'ConvertFrom-HwpPortableParagraphTextDetail',
    'ConvertFrom-HwpPortableCharShapeRuns',
    'ConvertFrom-HwpPortableLineSegments',
    'ConvertFrom-HwpPortablePageDefinitionPayload',
    'Complete-HwpPortableParagraphModel'
)
