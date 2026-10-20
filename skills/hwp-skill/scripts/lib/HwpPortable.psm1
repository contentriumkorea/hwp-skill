Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpTables.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpDocumentModel.psm1') -ErrorAction Stop

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

    return ,([Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($Bytes, $MaximumBytes))
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

function ConvertFrom-HwpPortableTablePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][int]$TableIndex,
        [Parameter(Mandatory)][int]$RecordLevel,
        [ValidateRange(1, 100000000)][long]$MaximumGridSlots = 5000000
    )

    if ($Bytes.Length -lt 20) {
        throw [IO.InvalidDataException]::new("$SectionName 표 레코드가 최소 길이보다 짧습니다.")
    }
    $properties = [BitConverter]::ToUInt32($Bytes, 0)
    $rowCount = [int][BitConverter]::ToUInt16($Bytes, 4)
    $columnCount = [int][BitConverter]::ToUInt16($Bytes, 6)
    if ($rowCount -lt 1 -or $columnCount -lt 1) {
        throw [IO.InvalidDataException]::new("$SectionName 표의 행 또는 열 수가 0입니다.")
    }
    [long]$gridSlots = [long]$rowCount * [long]$columnCount
    if ($gridSlots -gt $MaximumGridSlots) {
        throw [IO.InvalidDataException]::new(
            "$SectionName 표 $TableIndex 그리드가 안전 한도 $MaximumGridSlots 칸을 초과했습니다."
        )
    }

    $minimumLength = 20 + (2 * $rowCount)
    if ($Bytes.Length -lt $minimumLength) {
        throw [IO.InvalidDataException]::new("$SectionName 표 행 크기 데이터가 중간에서 끝났습니다.")
    }
    $rowSizes = [Collections.Generic.List[int]]::new()
    $cursor = 18
    for ($row = 0; $row -lt $rowCount; $row++) {
        $rowSizes.Add([int][BitConverter]::ToUInt16($Bytes, $cursor))
        $cursor += 2
    }
    $borderFillId = [int][BitConverter]::ToUInt16($Bytes, $cursor)
    $cursor += 2

    $validZones = [Collections.Generic.List[object]]::new()
    if ($cursor -lt $Bytes.Length) {
        if (($Bytes.Length - $cursor) -lt 2) {
            throw [IO.InvalidDataException]::new("$SectionName 표 유효 영역 개수가 중간에서 끝났습니다.")
        }
        $zoneCount = [int][BitConverter]::ToUInt16($Bytes, $cursor)
        $cursor += 2
        [long]$zoneBytes = [long]$zoneCount * 10
        if (($cursor + $zoneBytes) -gt $Bytes.Length) {
            throw [IO.InvalidDataException]::new("$SectionName 표 유효 영역 데이터가 중간에서 끝났습니다.")
        }
        for ($zoneIndex = 0; $zoneIndex -lt $zoneCount; $zoneIndex++) {
            $validZones.Add([pscustomobject][ordered]@{
                index = $zoneIndex
                startColumnAddress = [int][BitConverter]::ToUInt16($Bytes, $cursor)
                startRowAddress = [int][BitConverter]::ToUInt16($Bytes, $cursor + 2)
                endColumnAddress = [int][BitConverter]::ToUInt16($Bytes, $cursor + 4)
                endRowAddress = [int][BitConverter]::ToUInt16($Bytes, $cursor + 6)
                borderFillId = [int][BitConverter]::ToUInt16($Bytes, $cursor + 8)
            })
            $cursor += 10
        }
    }

    $pageBreakCode = [int]($properties -band 0x3)
    $pageBreak = switch ($pageBreakCode) {
        0 { 'NONE' }
        1 { 'TABLE' }
        2 { 'CELL' }
        default { 'RESERVED' }
    }

    [pscustomobject]@{
        Index = $TableIndex
        Section = $SectionName
        Source = 'hwp-portable'
        RecordLevel = $RecordLevel
        RowCount = $rowCount
        ColumnCount = $columnCount
        CellSpacing = [int][BitConverter]::ToUInt16($Bytes, 8)
        InnerMargins = [pscustomobject][ordered]@{
            left = [int][BitConverter]::ToUInt16($Bytes, 10)
            right = [int][BitConverter]::ToUInt16($Bytes, 12)
            top = [int][BitConverter]::ToUInt16($Bytes, 14)
            bottom = [int][BitConverter]::ToUInt16($Bytes, 16)
        }
        RowSizes = @($rowSizes)
        BorderFillId = $borderFillId
        Properties = [pscustomobject][ordered]@{
            raw = [uint32]$properties
            pageBreakCode = $pageBreakCode
            pageBreak = $pageBreak
            repeatHeader = ($properties -band 0x4) -ne 0
            noAdjust = $null
        }
        ValidZones = @($validZones)
        Cells = [Collections.Generic.List[object]]::new()
        ActiveCell = $null
        ActiveParagraph = $null
        FinalTable = $null
    }
}

function ConvertFrom-HwpPortableCellPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$CellIndex
    )

    if ($Bytes.Length -lt 32) {
        throw [IO.InvalidDataException]::new('HWP 표 셀 레코드가 최소 길이보다 짧습니다.')
    }
    $cellAttributeOffset = if ($Bytes.Length -ge 34) { 8 } else { 6 }
    # Modern table ListHeader has UINT32 paragraph count + UINT32 properties.
    # Keep the short legacy UINT16-count representation separate.
    $listProperties = [BitConverter]::ToUInt32($Bytes, $cellAttributeOffset - 4)
    $paragraphCount = if($cellAttributeOffset -eq 8){[long][BitConverter]::ToUInt32($Bytes,0)}else{[long][BitConverter]::ToUInt16($Bytes,0)}
    $cellFlags = if ($cellAttributeOffset -eq 8) {
        [BitConverter]::ToUInt16($Bytes, 6)
    }
    else {
        [uint16]0
    }
    [pscustomobject]@{
        Index = $CellIndex
        ParagraphCountDeclared = $paragraphCount
        ListPropertiesRaw = [uint32]$listProperties
        CellFlagsRaw = [int]$cellFlags
        HasMargin = ($cellFlags -band 0x1) -ne 0
        Protect = ($cellFlags -band 0x2) -ne 0
        Header = ($cellFlags -band 0x4) -ne 0
        Editable = ($cellFlags -band 0x8) -ne 0
        Dirty = ($cellFlags -band 0x10) -ne 0
        ColumnAddress = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset)
        RowAddress = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 2)
        ColumnSpan = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 4)
        RowSpan = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 6)
        Width = [long][BitConverter]::ToUInt32($Bytes, $cellAttributeOffset + 8)
        Height = [long][BitConverter]::ToUInt32($Bytes, $cellAttributeOffset + 12)
        Margins = [pscustomobject][ordered]@{
            left = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 16)
            right = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 18)
            top = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 20)
            bottom = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 22)
        }
        BorderFillId = [int][BitConverter]::ToUInt16($Bytes, $cellAttributeOffset + 24)
        TextDirectionCode = [int]($listProperties -band 0x7)
        LineWrapCode = [int](($listProperties -shr 3) -band 0x3)
        VerticalAlignmentCode = [int](($listProperties -shr 5) -band 0x3)
        Paragraphs = [Collections.Generic.List[string]]::new()
        CurrentParagraph = $null
    }
}

function Complete-HwpPortableCellParagraph {
    param([Parameter(Mandatory)][object]$TableContext)

    if ($null -eq $TableContext.ActiveCell -or $null -eq $TableContext.ActiveParagraph) {
        return
    }
    $TableContext.ActiveCell.Paragraphs.Add($TableContext.ActiveParagraph.ToString())
    $TableContext.ActiveCell.CurrentParagraph = $null
    $TableContext.ActiveParagraph = $null
}

function Complete-HwpPortableTableContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$TableContext,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$StructureWarnings,
        [ValidateRange(1, 100000000)][long]$MaximumGridSlots = 5000000
    )

    if ($null -ne $TableContext.FinalTable) { return $TableContext.FinalTable }
    Complete-HwpPortableCellParagraph -TableContext $TableContext

    $cells = [Collections.Generic.List[object]]::new()
    foreach ($cellContext in $TableContext.Cells) {
        $paragraphs = @($cellContext.Paragraphs)
        if ($paragraphs.Count -ne [int]$cellContext.ParagraphCountDeclared) {
            $StructureWarnings.Add(
                "$($TableContext.Section) 표 $($TableContext.Index) 셀 $($cellContext.Index)의 선언 문단 수와 실제 문단 수가 다릅니다."
            )
        }
        $textDirection = switch ([int]$cellContext.TextDirectionCode) {
            0 { 'HORIZONTAL' }
            1 { 'VERTICAL' }
            default { 'UNKNOWN_{0}' -f [int]$cellContext.TextDirectionCode }
        }
        $lineWrap = switch ([int]$cellContext.LineWrapCode) {
            0 { 'NORMAL' }
            1 { 'KEEP_LINE' }
            2 { 'EXPAND_WIDTH' }
            default { 'RESERVED' }
        }
        $verticalAlignment = switch ([int]$cellContext.VerticalAlignmentCode) {
            0 { 'TOP' }
            1 { 'CENTER' }
            2 { 'BOTTOM' }
            default { 'RESERVED' }
        }
        $cells.Add([pscustomobject][ordered]@{
            index = [int]$cellContext.Index
            id = ('table-{0}-cell-{1}' -f $TableContext.Index, $cellContext.Index)
            name = ''
            rowAddress = [int]$cellContext.RowAddress
            columnAddress = [int]$cellContext.ColumnAddress
            rowSpan = [int]$cellContext.RowSpan
            columnSpan = [int]$cellContext.ColumnSpan
            width = [long]$cellContext.Width
            height = [long]$cellContext.Height
            margins = $cellContext.Margins
            borderFillId = [int]$cellContext.BorderFillId
            cellFlagsRaw = [int]$cellContext.CellFlagsRaw
            hasMargin = [bool]$cellContext.HasMargin
            protect = [bool]$cellContext.Protect
            header = [bool]$cellContext.Header
            editable = [bool]$cellContext.Editable
            dirty = [bool]$cellContext.Dirty
            paragraphCountDeclared = [int]$cellContext.ParagraphCountDeclared
            paragraphs = $paragraphs
            text = $paragraphs -join "`r`n"
            listPropertiesRaw = [uint32]$cellContext.ListPropertiesRaw
            textDirectionCode = [int]$cellContext.TextDirectionCode
            textDirection = $textDirection
            lineWrapCode = [int]$cellContext.LineWrapCode
            lineWrap = $lineWrap
            verticalAlignmentCode = [int]$cellContext.VerticalAlignmentCode
            verticalAlignment = $verticalAlignment
        })
    }

    $label = "$($TableContext.Section) 표 $($TableContext.Index)"
    $grid = @(New-HwpTableGrid -RowCount $TableContext.RowCount -ColumnCount $TableContext.ColumnCount `
        -Cells @($cells) -Warnings $StructureWarnings -TableLabel $label -MaximumGridSlots $MaximumGridSlots)
    $TableContext.FinalTable = [pscustomobject][ordered]@{
        index = [int]$TableContext.Index
        section = [string]$TableContext.Section
        source = [string]$TableContext.Source
        recordLevel = [int]$TableContext.RecordLevel
        rowCount = [int]$TableContext.RowCount
        columnCount = [int]$TableContext.ColumnCount
        cellSpacing = [int]$TableContext.CellSpacing
        innerMargins = $TableContext.InnerMargins
        rowSizes = @($TableContext.RowSizes)
        borderFillId = [int]$TableContext.BorderFillId
        properties = $TableContext.Properties
        validZones = @($TableContext.ValidZones)
        cells = @($cells)
        grid = $grid
    }
    $TableContext.FinalTable
}

function Get-HwpPortableSectionData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Controls,
        [AllowEmptyCollection()][Collections.Generic.List[object]]$Tables = ([Collections.Generic.List[object]]::new()),
        [AllowEmptyCollection()][Collections.Generic.List[string]]$StructureWarnings = ([Collections.Generic.List[string]]::new()),
        [ValidateRange(1, 2000000)][int]$MaximumRecords = 1000000,
        [ValidateRange(1, 1000000)][int]$MaximumControls = 100000,
        [ValidateRange(1, 268435456)][long]$MaximumTextCharacters = 67108864,
        [ValidateRange(1, 1000000)][int]$MaximumTables = 100000,
        [ValidateRange(1, 2000000)][int]$MaximumTableCells = 1000000,
        [ValidateRange(1, 100000000)][long]$MaximumTableGridSlots = 5000000
    )

    $paragraphs = [Collections.Generic.List[string]]::new()
    $layoutParagraphs = [Collections.Generic.List[object]]::new()
    $pageDefinitions = [Collections.Generic.List[object]]::new()
    $sectionTables = [Collections.Generic.List[object]]::new()
    $tableStack = [Collections.Generic.List[object]]::new()
    $activeLayoutParagraph = $null
    $storedPageFirstLineCount = 0
    $tableCellCount = 0
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
        $level = [int](($header -shr 10) -band 0x3FF)
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

        $payload = [byte[]]::new([int]$size)
        if ($size -gt 0) {
            [Array]::Copy($Bytes, $offset, $payload, 0, [int]$size)
        }

        while ($tableStack.Count -gt 0 -and $level -lt $tableStack[$tableStack.Count - 1].RecordLevel) {
            $completedContext = $tableStack[$tableStack.Count - 1]
            $null = Complete-HwpPortableTableContext -TableContext $completedContext `
                -StructureWarnings $StructureWarnings -MaximumGridSlots $MaximumTableGridSlots
            $tableStack.RemoveAt($tableStack.Count - 1)
        }
        if ($tagId -eq 0x4D) {
            while ($tableStack.Count -gt 0 -and $level -le $tableStack[$tableStack.Count - 1].RecordLevel) {
                $completedContext = $tableStack[$tableStack.Count - 1]
                $null = Complete-HwpPortableTableContext -TableContext $completedContext `
                    -StructureWarnings $StructureWarnings -MaximumGridSlots $MaximumTableGridSlots
                $tableStack.RemoveAt($tableStack.Count - 1)
            }
            if (($Tables.Count + $sectionTables.Count) -ge $MaximumTables) {
                throw [IO.InvalidDataException]::new("$SectionName 표 수가 문서 전체 안전 한도를 초과했습니다.")
            }
            $tableContext = ConvertFrom-HwpPortableTablePayload -Bytes $payload -SectionName $SectionName `
                -TableIndex ($Tables.Count + $sectionTables.Count) -RecordLevel $level `
                -MaximumGridSlots $MaximumTableGridSlots
            $sectionTables.Add($tableContext)
            $tableStack.Add($tableContext)
        }

        if ($tagId -eq 0x42) {
            if ($null -ne $activeLayoutParagraph) {
                $completedParagraph = Complete-HwpPortableParagraphModel -Context $activeLayoutParagraph
                $layoutParagraphs.Add($completedParagraph)
                $storedPageFirstLineCount += @($completedParagraph.LineSegments | Where-Object IsPageFirst).Count
            }
            $activeLayoutParagraph = [pscustomobject]@{
                Index = $layoutParagraphs.Count
                Section = $SectionName
                RecordLevel = $level
                Header = ConvertFrom-HwpPortableParagraphHeaderPayload -Bytes $payload
                TextDetail = $null
                CharShapeRuns = [Collections.Generic.List[object]]::new()
                LineSegments = [Collections.Generic.List[object]]::new()
            }
        }

        if ($tagId -eq 0x49) {
            $pageDefinitions.Add((ConvertFrom-HwpPortablePageDefinitionPayload -Bytes $payload -Index $pageDefinitions.Count))
        }

        if ($tagId -eq 0x43) {
            $paragraph = ConvertFrom-HwpPortableParagraphText -Bytes $payload
            if (($textCharacterCount + $paragraph.Length) -gt $MaximumTextCharacters) {
                throw [IO.InvalidDataException]::new("$SectionName 추출 텍스트가 문서 전체 안전 한도를 초과했습니다.")
            }
            $paragraphs.Add($paragraph)
            $textCharacterCount += $paragraph.Length
            if ($null -ne $activeLayoutParagraph -and $level -gt $activeLayoutParagraph.RecordLevel) {
                $activeLayoutParagraph.TextDetail = ConvertFrom-HwpPortableParagraphTextDetail -Bytes $payload
            }
            if ($tableStack.Count -gt 0) {
                $activeTable = $tableStack[$tableStack.Count - 1]
                if ($null -ne $activeTable.ActiveCell -and $level -gt $activeTable.RecordLevel) {
                    if ($null -eq $activeTable.ActiveParagraph) {
                        $activeTable.ActiveParagraph = [Text.StringBuilder]::new()
                        $activeTable.ActiveCell.CurrentParagraph = $activeTable.ActiveParagraph
                    }
                    $null = $activeTable.ActiveParagraph.Append($paragraph)
                }
            }
        }
        elseif ($tagId -eq 0x44 -and $null -ne $activeLayoutParagraph -and
                $level -gt $activeLayoutParagraph.RecordLevel) {
            foreach ($run in @(ConvertFrom-HwpPortableCharShapeRuns -Bytes $payload)) {
                $activeLayoutParagraph.CharShapeRuns.Add($run)
            }
        }
        elseif ($tagId -eq 0x45 -and $null -ne $activeLayoutParagraph -and
                $level -gt $activeLayoutParagraph.RecordLevel) {
            foreach ($segment in @(ConvertFrom-HwpPortableLineSegments -Bytes $payload)) {
                $activeLayoutParagraph.LineSegments.Add($segment)
            }
        }
        elseif ($tagId -eq 0x48 -and $tableStack.Count -gt 0 -and
                $level -eq $tableStack[$tableStack.Count - 1].RecordLevel -and $payload.Length -ge 32) {
            if ($tableCellCount -ge $MaximumTableCells) {
                throw [IO.InvalidDataException]::new("$SectionName 표 셀 수가 문서 전체 안전 한도를 초과했습니다.")
            }
            $activeTable = $tableStack[$tableStack.Count - 1]
            Complete-HwpPortableCellParagraph -TableContext $activeTable
            $cell = ConvertFrom-HwpPortableCellPayload -Bytes $payload -CellIndex $activeTable.Cells.Count
            $activeTable.Cells.Add($cell)
            $activeTable.ActiveCell = $cell
            $activeTable.ActiveParagraph = $null
            $tableCellCount++
        }
        elseif ($tagId -eq 0x42 -and $tableStack.Count -gt 0 -and
                $level -eq $tableStack[$tableStack.Count - 1].RecordLevel -and
                $null -ne $tableStack[$tableStack.Count - 1].ActiveCell) {
            $activeTable = $tableStack[$tableStack.Count - 1]
            Complete-HwpPortableCellParagraph -TableContext $activeTable
            $activeTable.ActiveParagraph = [Text.StringBuilder]::new()
            $activeTable.ActiveCell.CurrentParagraph = $activeTable.ActiveParagraph
        }

        if ($tagId -in @(0x4D, 0x55, 0x58)) {
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

    if ($null -ne $activeLayoutParagraph) {
        $completedParagraph = Complete-HwpPortableParagraphModel -Context $activeLayoutParagraph
        $layoutParagraphs.Add($completedParagraph)
        $storedPageFirstLineCount += @($completedParagraph.LineSegments | Where-Object IsPageFirst).Count
    }

    while ($tableStack.Count -gt 0) {
        $completedContext = $tableStack[$tableStack.Count - 1]
        $null = Complete-HwpPortableTableContext -TableContext $completedContext `
            -StructureWarnings $StructureWarnings -MaximumGridSlots $MaximumTableGridSlots
        $tableStack.RemoveAt($tableStack.Count - 1)
    }
    foreach ($tableContext in $sectionTables) {
        $Tables.Add($tableContext.FinalTable)
    }

    [pscustomobject]@{
        Paragraphs = @($paragraphs)
        LayoutParagraphs = @($layoutParagraphs)
        PageDefinitions = @($pageDefinitions)
        StoredPageFirstLineCount = $storedPageFirstLineCount
        RecordCount = $recordCount
        TextCharacterCount = $textCharacterCount
        TableCount = $sectionTables.Count
        TableCellCount = $tableCellCount
    }
}

function Get-HwpPortableByteHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function New-HwpPortableBinaryAsset {
    param([string]$StreamName = '')
    [pscustomobject][ordered]@{
        Id = $null
        StreamName = $StreamName
        Extension = ''
        StorageType = 'UNKNOWN'
        Flags = $null
        CompressionMode = $null
        Compressed = $null
        StoredBytes = $null
        StoredSha256 = $null
        DecodedBytes = $null
        Sha256 = $null
        VerificationStatus = 'UNVERIFIED'
        VerificationLimitation = ''
    }
}

function Get-HwpPortableBinaryAssets {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][byte[]]$DocInfoBytes,
        [bool]$DocumentCompressed,
        [int]$MaximumStreamBytes,
        [long]$RemainingExpandedBytes
    )
    $assets = [Collections.Generic.List[object]]::new()
    $byName = @{}
    # Scan just BIN_DATA records; do not duplicate all DocInfo payloads.
    $offset = 0
    while ($offset -lt $DocInfoBytes.Length) {
        if ($DocInfoBytes.Length - $offset -lt 4) { throw [IO.InvalidDataException]::new('BinData 레코드 헤더가 잘렸습니다.') }
        $record = [BitConverter]::ToUInt32($DocInfoBytes, $offset)
        $offset += 4
        [long]$size = ($record -shr 20) -band 0xFFF
        if ($size -eq 0xFFF) {
            if ($DocInfoBytes.Length - $offset -lt 4) { throw [IO.InvalidDataException]::new('BinData 확장 헤더가 잘렸습니다.') }
            $size = [BitConverter]::ToUInt32($DocInfoBytes, $offset)
            $offset += 4
        }
        if ($size -gt ($DocInfoBytes.Length - $offset)) { throw [IO.InvalidDataException]::new('BinData 레코드가 범위를 벗어났습니다.') }
        if (($record -band 0x3FF) -eq 0x12) {
            if ($assets.Count -ge 65536) { throw [IO.InvalidDataException]::new('BinData 개수 안전 한도를 초과했습니다.') }
            if ($size -lt 2) { throw [IO.InvalidDataException]::new('BinData 속성이 잘렸습니다.') }
            $asset = New-HwpPortableBinaryAsset
            $flags = [int][BitConverter]::ToUInt16($DocInfoBytes, $offset)
            $asset.Flags = $flags
            $kind = $flags -band 0xF
            $mode = ($flags -shr 4) -band 3
            $asset.CompressionMode = $mode
            $asset.Compressed = if ($mode -eq 0) { $DocumentCompressed } elseif ($mode -eq 1) { $true } elseif ($mode -eq 2) { $false } else { $null }
            if ($kind -eq 0) {
                $asset.StorageType = 'LINK'
                $asset.VerificationLimitation = '외부 연결 자산은 읽지 않아 원본 바이트 해시를 검증할 수 없습니다.'
            }
            elseif ($kind -in @(1,2)) {
                if ($size -lt 4) { throw [IO.InvalidDataException]::new('BinData ID가 잘렸습니다.') }
                $asset.Id = [int][BitConverter]::ToUInt16($DocInfoBytes, $offset + 2)
                $asset.StorageType = if ($kind -eq 1) { 'EMBEDDING' } else { 'STORAGE' }
                $asset.StreamName = 'BIN{0:X4}' -f $asset.Id
                if ($kind -eq 1) {
                    if ($size -lt 6) { throw [IO.InvalidDataException]::new('BinData 확장자 길이가 잘렸습니다.') }
                    $length = [int][BitConverter]::ToUInt16($DocInfoBytes, $offset + 4)
                    if (6 + 2 * $length -gt $size) { throw [IO.InvalidDataException]::new('BinData 확장자가 범위를 벗어났습니다.') }
                    $asset.Extension = [Text.Encoding]::Unicode.GetString($DocInfoBytes, $offset + 6, 2 * $length).ToLowerInvariant()
                    $asset.StreamName += '.' + $asset.Extension
                    if ($asset.Extension -notmatch '^[a-z0-9]{1,31}$') {
                        $asset.VerificationLimitation = 'BinData 확장자를 안전하게 식별할 수 없습니다.'
                    }
                }
                if ($mode -eq 3) { $asset.VerificationLimitation = '예약된 BinData 압축 모드는 해석하지 않습니다.' }
                if ($byName.ContainsKey($asset.StreamName)) { throw [IO.InvalidDataException]::new('BinData 스트림 메타데이터가 중복되었습니다.') }
                $byName[$asset.StreamName] = $asset
            }
            else { $asset.VerificationLimitation = '알 수 없는 BinData 저장 유형입니다.' }
            $assets.Add($asset)
        }
        $offset += [int]$size
    }
    $binaryStorage = @($Session.ListElements('') | Where-Object { $_.Name -eq 'BinData' -and $_.Type -eq 1 })
    $found = @{}
    [long]$expanded = 0
    [long]$budgetUsed = 0
    if ($binaryStorage.Count -gt 0) {
        foreach ($element in $Session.ListElements('BinData')) {
            $name = [string]$element.Name
            $asset = if ($byName.ContainsKey($name)) { $byName[$name] } else {
                $unknown = New-HwpPortableBinaryAsset -StreamName $name
                $unknown.VerificationLimitation = 'DocInfo BinData 메타데이터가 없어 압축 여부를 검증할 수 없습니다.'
                $assets.Add($unknown)
                $unknown
            }
            $found[$name] = $true
            $asset.StoredBytes = [long]$element.Size
            if ($element.Type -ne 2) {
                $asset.VerificationLimitation = '중첩 BinData 저장소의 바이트 검증은 지원하지 않습니다.'
                continue
            }
            if ($element.Size -gt $MaximumStreamBytes) {
                $asset.VerificationLimitation = 'BinData 스트림이 읽기 안전 한도를 초과했습니다.'
                continue
            }
            [byte[]]$stored = $Session.ReadStream('BinData', $name, $MaximumStreamBytes)
            $asset.StoredSha256 = Get-HwpPortableByteHash -Bytes $stored
            if ($asset.VerificationLimitation) { continue }
            $remaining = $RemainingExpandedBytes - $budgetUsed
            if ($remaining -lt 1) {
                $asset.VerificationLimitation = 'BinData 문서 전체 압축 해제 안전 한도가 소진되었습니다.'
                continue
            }
            try {
                [byte[]]$decoded = $stored
                if ($asset.Compressed) {
                    $decoded = Expand-HwpPortableDeflate -Bytes $stored -MaximumBytes ([Math]::Min($remaining, $MaximumStreamBytes))
                }
                elseif ($stored.Length -gt $remaining) {
                    throw [IO.InvalidDataException]::new('BinData 문서 전체 안전 한도를 초과했습니다.')
                }
                if ($decoded.Length -eq 0) { throw [IO.InvalidDataException]::new('BinData 원본 바이트가 비어 있어 검증할 수 없습니다.') }
                $asset.DecodedBytes = $decoded.Length
                $asset.Sha256 = Get-HwpPortableByteHash -Bytes $decoded
                $asset.VerificationStatus = 'HASHED'
                $expanded += $decoded.Length
                $budgetUsed += $decoded.Length
            }
            catch [IO.InvalidDataException] {
                $asset.VerificationLimitation = 'BinData 원본 바이트를 해석할 수 없습니다: ' + $_.Exception.Message
                # Failed inflation may consume the remaining budget. Prevent
                # repeated failures from multiplying bounded inflation work.
                $budgetUsed = $RemainingExpandedBytes
            }
        }
    }
    foreach ($asset in $assets) {
        if ($asset.StreamName -and -not $found.ContainsKey($asset.StreamName)) {
            $asset.VerificationLimitation = 'DocInfo에 선언된 BinData 스트림을 찾을 수 없습니다.'
        }
    }
    $limitations = @($assets | Where-Object { $_.VerificationStatus -ne 'HASHED' } | ForEach-Object {
        'BinData {0}: {1}' -f $_.StreamName, $_.VerificationLimitation
    })
    [pscustomobject]@{
        Assets = @($assets)
        Verified = ($limitations.Count -eq 0)
        Warnings = $limitations
        ExpandedBytes = $expanded
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
        [ValidateRange(1, 1000000)][int]$MaximumTables = 100000,
        [ValidateRange(1, 2000000)][int]$MaximumTableCells = 1000000,
        [ValidateRange(1, 100000000)][long]$MaximumTableGridSlots = 5000000,
        [ValidatePattern('^$|^[0-9a-fA-F]{64}$')][string]$ExpectedSha256 = ''
    )

    $resolvedPath = Resolve-HwpLiteralPath -LiteralPath $LiteralPath
    if ((Get-Item -LiteralPath $resolvedPath).Length -gt $MaximumFileBytes) {
        return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
            'HWP 파일이 휴대형 읽기 안전 한도를 초과했습니다.'
        )
    }

    $compoundSession = $null
    try {
        $compoundSession = [Contentrium.HwpSkill.CompoundFileReader]::Open($resolvedPath, $MaximumFileBytes)
        $lockedHash = $compoundSession.ComputeSha256()
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

        [long]$expandedByteCount = 0
        [byte[]]$docInfoBytes = $compoundSession.ReadStream('', 'DocInfo', $MaximumStreamBytes)
        if ($compressed) {
            try {
                [byte[]]$docInfoBytes = Expand-HwpPortableDeflate -Bytes $docInfoBytes -MaximumBytes $MaximumExpandedBytes
            }
            catch [IO.InvalidDataException] {
                throw [IO.InvalidDataException]::new(
                    'HWP 문서 전체 압축 해제 데이터가 잘못되었거나 안전 한도를 초과했습니다.',
                    $_.Exception
                )
            }
        }
        $expandedByteCount += $docInfoBytes.Length
        if ($expandedByteCount -gt $MaximumExpandedBytes) {
            throw [IO.InvalidDataException]::new('HWP 문서 정보 압축 해제 크기가 안전 한도를 초과했습니다.')
        }
        $docInfo = Get-HwpPortableDocInfoData -Bytes $docInfoBytes

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
        $layoutParagraphs = [Collections.Generic.List[object]]::new()
        $sections = [Collections.Generic.List[object]]::new()
        $controls = [Collections.Generic.List[object]]::new()
        $tables = [Collections.Generic.List[object]]::new()
        $structureWarnings = [Collections.Generic.List[string]]::new()
        $recordCount = 0
        [long]$textCharacterCount = 0
        $storedPageCount = 0
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
                -Controls $controls -Tables $tables -StructureWarnings $structureWarnings `
                -MaximumRecords $remainingRecords -MaximumControls $MaximumControls `
                -MaximumTextCharacters $remainingTextCharacters -MaximumTables $MaximumTables `
                -MaximumTableCells $MaximumTableCells -MaximumTableGridSlots $MaximumTableGridSlots
            foreach ($paragraph in @($section.Paragraphs)) {
                $paragraphs.Add([string]$paragraph)
            }
            $paragraphStartIndex = $layoutParagraphs.Count
            foreach ($layoutParagraph in @($section.LayoutParagraphs)) {
                $layoutParagraph.index = $layoutParagraphs.Count
                $layoutParagraphs.Add($layoutParagraph)
            }
            $sections.Add([pscustomobject][ordered]@{
                index = $sections.Count
                name = [string]$element.Name
                paragraphStartIndex = $paragraphStartIndex
                paragraphCount = @($section.LayoutParagraphs).Count
                pageDefinitions = @($section.PageDefinitions)
                storedPageFirstLineCount = [int]$section.StoredPageFirstLineCount
            })
            $storedPageCount += [int]$section.StoredPageFirstLineCount
            $recordCount += [int]$section.RecordCount
            $textCharacterCount += [long]$section.TextCharacterCount
        }

        $binaryAssets = Get-HwpPortableBinaryAssets -Session $compoundSession -DocInfoBytes $docInfoBytes `
            -DocumentCompressed $compressed -MaximumStreamBytes $MaximumStreamBytes `
            -RemainingExpandedBytes ($MaximumExpandedBytes - $expandedByteCount)

        $finalHash = Get-HwpSha256 -LiteralPath $resolvedPath
        if ($finalHash -ne $lockedHash -or $compoundSession.ComputeSha256() -ne $lockedHash) {
            return New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
                'HWP 파일이 읽는 동안 변경되어 일관된 결과를 만들 수 없습니다.'
            )
        }

        $warnings = @(
            'HWP 5.x를 관리형 .NET 복합파일 읽기 엔진으로 읽었으며 한컴오피스는 실행하지 않았습니다.',
            '글꼴·글자 모양·문단 모양·테두리/배경·저장된 줄 좌표·용지 설정과 표 구조를 읽었습니다.',
            '줄 배치와 페이지 수는 HWP에 저장된 레이아웃 캐시 기준이며, 설치 글꼴 대체까지 반영한 최종 픽셀 렌더링은 별도 렌더러로 확인해야 합니다.'
        )
        $warnings += @($structureWarnings)
        $warnings += @($binaryAssets.Warnings)
        New-HwpResult -Status PASS_WITH_WARNINGS -Command inspect-hwp-portable -Data ([pscustomobject]@{
            Path = $resolvedPath
            Version = $version
            Compressed = $compressed
            Text = $paragraphs -join "`r`n"
            Fields = [pscustomobject]@{}
            Controls = @($controls)
            Tables = @($tables)
            Resources = $docInfo.Resources
            # HASHED means decoded binary identity, not visual/image rendering.
            BinaryAssets = @($binaryAssets.Assets)
            BinaryAssetsVerified = [bool]$binaryAssets.Verified
            BinaryAssetExpandedBytes = [long]$binaryAssets.ExpandedBytes
            Paragraphs = @($layoutParagraphs)
            Sections = @($sections)
            Layout = [pscustomobject][ordered]@{
                source = 'HWP_STORED_LAYOUT_CACHE'
                storedLineLayoutAvailable = @($layoutParagraphs | Where-Object { $_.LineSegments.Count -gt 0 }).Count -gt 0
                lineSegmentCount = @($layoutParagraphs | ForEach-Object { $_.LineSegments }).Count
                pageCountSource = if ($storedPageCount -gt 0) { 'PAGE_FIRST_LINE_FLAGS' } else { 'UNAVAILABLE' }
                exactRenderingVerified = $false
            }
            PageCount = $storedPageCount
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
    catch [IO.IOException] {
        New-HwpResult -Status BLOCKED -Command inspect-hwp-portable -Errors @(
            "HWP 복합파일 스트림을 읽을 수 없습니다: $($_.Exception.Message)"
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
