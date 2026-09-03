$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilitiesModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$portableModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPortable.psm1'
$tablesModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpTables.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1'

Import-Module $commonModule -Force
Import-Module $executionModule -Force
Import-Module $capabilitiesModule -Force
Import-Module $tablesModule -Force
$script:portableModuleInfo = Import-Module $portableModule -Force -PassThru
Import-Module $inspectModule -Force
$hasTestJson = $null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)

function Add-TestUInt16 {
    param([Collections.Generic.List[byte]]$Buffer, [uint16]$Value)
    $Buffer.AddRange([byte[]][BitConverter]::GetBytes($Value))
}

function Add-TestUInt32 {
    param([Collections.Generic.List[byte]]$Buffer, [uint32]$Value)
    $Buffer.AddRange([byte[]][BitConverter]::GetBytes($Value))
}

function Add-TestInt16 {
    param([Collections.Generic.List[byte]]$Buffer, [int16]$Value)
    $Buffer.AddRange([byte[]][BitConverter]::GetBytes($Value))
}

function Add-TestInt32 {
    param([Collections.Generic.List[byte]]$Buffer, [int32]$Value)
    $Buffer.AddRange([byte[]][BitConverter]::GetBytes($Value))
}

function New-TestHwpRecord {
    param(
        [int]$TagId,
        [int]$Level,
        [byte[]]$Payload
    )

    if ($Payload.Length -ge 0xFFF) {
        throw '시험 레코드는 확장 길이를 사용하지 않는다.'
    }
    $bytes = [Collections.Generic.List[byte]]::new()
    $header = [uint32]($TagId -bor ($Level -shl 10) -bor ($Payload.Length -shl 20))
    Add-TestUInt32 -Buffer $bytes -Value $header
    $bytes.AddRange($Payload)
    ,$bytes.ToArray()
}

function New-TestHwpTablePayload {
    $bytes = [Collections.Generic.List[byte]]::new()
    Add-TestUInt32 -Buffer $bytes -Value 6 # pageBreakCode=2, repeatHeader=true
    Add-TestUInt16 -Buffer $bytes -Value 2
    Add-TestUInt16 -Buffer $bytes -Value 3
    Add-TestUInt16 -Buffer $bytes -Value 20
    foreach ($margin in @(510, 511, 141, 142)) {
        Add-TestUInt16 -Buffer $bytes -Value $margin
    }
    foreach ($rowSize in @(1000, 2000)) {
        Add-TestUInt16 -Buffer $bytes -Value $rowSize
    }
    Add-TestUInt16 -Buffer $bytes -Value 3
    Add-TestUInt16 -Buffer $bytes -Value 1
    foreach ($zoneValue in @(0, 0, 2, 0, 9)) {
        Add-TestUInt16 -Buffer $bytes -Value $zoneValue
    }
    ,$bytes.ToArray()
}

function New-TestHwpCellPayload {
    param(
        [uint16]$ColumnAddress,
        [uint16]$RowAddress,
        [uint16]$ColumnSpan = 1,
        [uint16]$RowSpan = 1,
        [uint16]$ParagraphCount = 1,
        [uint32]$ListProperties = 74,
        [uint16]$CellFlags = 11,
        [uint32]$Width = 3000,
        [uint32]$Height = 1000,
        [uint16]$BorderFillId = 7
    )

    $bytes = [Collections.Generic.List[byte]]::new()
    Add-TestUInt16 -Buffer $bytes -Value $ParagraphCount
    Add-TestUInt32 -Buffer $bytes -Value $ListProperties
    Add-TestUInt16 -Buffer $bytes -Value $CellFlags
    Add-TestUInt16 -Buffer $bytes -Value $ColumnAddress
    Add-TestUInt16 -Buffer $bytes -Value $RowAddress
    Add-TestUInt16 -Buffer $bytes -Value $ColumnSpan
    Add-TestUInt16 -Buffer $bytes -Value $RowSpan
    Add-TestUInt32 -Buffer $bytes -Value $Width
    Add-TestUInt32 -Buffer $bytes -Value $Height
    foreach ($margin in @(510, 511, 141, 142)) {
        Add-TestUInt16 -Buffer $bytes -Value $margin
    }
    Add-TestUInt16 -Buffer $bytes -Value $BorderFillId
    $bytes.AddRange([byte[]]::new(13))
    ,$bytes.ToArray()
}

function New-TestHwpParagraphHeaderPayload {
    ,([byte[]]::new(24))
}

function New-TestHwpParagraphTextPayload {
    param([string]$Text)
    ,[Text.Encoding]::Unicode.GetBytes($Text + [char]13)
}

function New-TestHwpFaceNamePayload {
    param([Parameter(Mandatory)][string]$Name)

    $bytes = [Collections.Generic.List[byte]]::new()
    $bytes.Add(0)
    Add-TestUInt16 -Buffer $bytes -Value ([uint16]$Name.Length)
    $bytes.AddRange([Text.Encoding]::Unicode.GetBytes($Name))
    ,$bytes.ToArray()
}

function New-TestHwpBorderFillPayload {
    $bytes = [Collections.Generic.List[byte]]::new()
    Add-TestUInt16 -Buffer $bytes -Value 0
    $bytes.AddRange([byte[]](0, 1, 2, 3))
    $bytes.AddRange([byte[]](1, 2, 3, 4))
    foreach ($color in @([uint32]0x000000FF, [uint32]0x0000FF00, [uint32]0x00FF0000, [uint32]0x00112233)) {
        Add-TestUInt32 -Buffer $bytes -Value $color
    }
    $bytes.Add(0)
    $bytes.Add(1)
    Add-TestUInt32 -Buffer $bytes -Value ([uint32]0x00665544)
    Add-TestUInt32 -Buffer $bytes -Value 1
    Add-TestUInt32 -Buffer $bytes -Value ([uint32]0x00CCBBAA)
    Add-TestUInt32 -Buffer $bytes -Value ([uint32]0x00030201)
    Add-TestInt32 -Buffer $bytes -Value 5
    ,$bytes.ToArray()
}

function New-TestHwpCharShapePayload {
    $bytes = [Collections.Generic.List[byte]]::new()
    foreach ($unused in 1..7) { Add-TestUInt16 -Buffer $bytes -Value 0 }
    $bytes.AddRange([byte[]](100, 100, 100, 100, 100, 100, 100))
    $bytes.AddRange([byte[]](0, 0, 0, 0, 0, 0, 0))
    $bytes.AddRange([byte[]](100, 100, 100, 100, 100, 100, 100))
    $bytes.AddRange([byte[]](0, 0, 0, 0, 0, 0, 0))
    Add-TestInt32 -Buffer $bytes -Value 1200
    Add-TestUInt32 -Buffer $bytes -Value ([uint32]0x40000003)
    $bytes.AddRange([byte[]](10, 20))
    foreach ($color in @([uint32]0x00332211, [uint32]0x00665544, [uint32]0x00998877, [uint32]0x00CCBBAA)) {
        Add-TestUInt32 -Buffer $bytes -Value $color
    }
    Add-TestUInt16 -Buffer $bytes -Value 0
    Add-TestUInt32 -Buffer $bytes -Value ([uint32]0x00FFEEDD)
    ,$bytes.ToArray()
}

function New-TestHwpParaShapePayload {
    $bytes = [Collections.Generic.List[byte]]::new()
    Add-TestUInt32 -Buffer $bytes -Value 12
    foreach ($value in @(1000, 200, -300, 100, 200, 160)) {
        Add-TestInt32 -Buffer $bytes -Value $value
    }
    foreach ($value in @(0, 0, 0)) { Add-TestUInt16 -Buffer $bytes -Value $value }
    foreach ($value in @(10, 20, 30, 40)) { Add-TestInt16 -Buffer $bytes -Value $value }
    Add-TestUInt32 -Buffer $bytes -Value 48
    Add-TestUInt32 -Buffer $bytes -Value 0
    Add-TestUInt32 -Buffer $bytes -Value 150
    ,$bytes.ToArray()
}

function New-TestHwpDocInfoStream {
    $stream = [Collections.Generic.List[byte]]::new()
    $mapping = [Collections.Generic.List[byte]]::new()
    foreach ($count in @(0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0)) {
        Add-TestInt32 -Buffer $mapping -Value $count
    }
    $stream.AddRange((New-TestHwpRecord -TagId 0x11 -Level 0 -Payload $mapping.ToArray()))
    foreach ($font in @('한글시험체', 'Latin Test', '漢字試験', '日本語試験', 'Other Test', 'Symbol Test', 'User Test')) {
        $stream.AddRange((New-TestHwpRecord -TagId 0x13 -Level 0 -Payload (New-TestHwpFaceNamePayload -Name $font)))
    }
    $stream.AddRange((New-TestHwpRecord -TagId 0x14 -Level 0 -Payload (New-TestHwpBorderFillPayload)))
    $stream.AddRange((New-TestHwpRecord -TagId 0x15 -Level 0 -Payload (New-TestHwpCharShapePayload)))
    $stream.AddRange((New-TestHwpRecord -TagId 0x19 -Level 0 -Payload (New-TestHwpParaShapePayload)))
    ,$stream.ToArray()
}

function New-TestHwpDetailedParagraphHeaderPayload {
    $bytes = [Collections.Generic.List[byte]]::new()
    Add-TestUInt32 -Buffer $bytes -Value 7
    Add-TestUInt32 -Buffer $bytes -Value 0
    Add-TestUInt16 -Buffer $bytes -Value 0
    $bytes.Add(2)
    $bytes.Add(5)
    Add-TestUInt16 -Buffer $bytes -Value 1
    Add-TestUInt16 -Buffer $bytes -Value 0
    Add-TestUInt16 -Buffer $bytes -Value 2
    Add-TestUInt32 -Buffer $bytes -Value 77
    Add-TestUInt16 -Buffer $bytes -Value 0
    ,$bytes.ToArray()
}

function New-TestHwpLineSegmentPayload {
    param(
        [uint32]$TextStart,
        [int32]$VerticalPosition,
        [uint32]$Flags
    )

    $bytes = [Collections.Generic.List[byte]]::new()
    Add-TestUInt32 -Buffer $bytes -Value $TextStart
    foreach ($value in @($VerticalPosition, 1200, 1000, 850, 600, 100, 5000)) {
        Add-TestInt32 -Buffer $bytes -Value $value
    }
    Add-TestUInt32 -Buffer $bytes -Value $Flags
    ,$bytes.ToArray()
}

function New-TestHwpPageDefinitionPayload {
    $bytes = [Collections.Generic.List[byte]]::new()
    foreach ($value in @(59528, 84186, 4252, 4252, 2835, 2835, 1417, 1417, 0)) {
        Add-TestInt32 -Buffer $bytes -Value $value
    }
    Add-TestUInt32 -Buffer $bytes -Value 0
    ,$bytes.ToArray()
}

function New-TestHwpLayoutSection {
    $section = [Collections.Generic.List[byte]]::new()
    $section.AddRange((New-TestHwpRecord -TagId 0x42 -Level 0 -Payload (New-TestHwpDetailedParagraphHeaderPayload)))
    $section.AddRange((New-TestHwpRecord -TagId 0x43 -Level 1 -Payload (New-TestHwpParagraphTextPayload -Text '첫줄둘째줄')))
    $charRuns = [Collections.Generic.List[byte]]::new()
    Add-TestUInt32 -Buffer $charRuns -Value 0
    Add-TestUInt32 -Buffer $charRuns -Value 0
    $section.AddRange((New-TestHwpRecord -TagId 0x44 -Level 1 -Payload $charRuns.ToArray()))
    $lineSegments = [Collections.Generic.List[byte]]::new()
    $lineSegments.AddRange((New-TestHwpLineSegmentPayload -TextStart 0 -VerticalPosition 1000 -Flags 393219))
    $lineSegments.AddRange((New-TestHwpLineSegmentPayload -TextStart 2 -VerticalPosition 2200 -Flags 393216))
    $section.AddRange((New-TestHwpRecord -TagId 0x45 -Level 1 -Payload $lineSegments.ToArray()))
    $section.AddRange((New-TestHwpRecord -TagId 0x49 -Level 1 -Payload (New-TestHwpPageDefinitionPayload)))
    ,$section.ToArray()
}

function New-TestHwpTableSection {
    param([switch]$IncludeOverlappingCell)

    $section = [Collections.Generic.List[byte]]::new()
    $section.AddRange((New-TestHwpRecord -TagId 0x4D -Level 2 -Payload (New-TestHwpTablePayload)))
    $cells = @(
        @{ Column=0; Row=0; ColumnSpan=2; RowSpan=1; Text='병합 셀'; Width=6000; Height=1000 },
        @{ Column=2; Row=0; ColumnSpan=1; RowSpan=1; Text='오른쪽'; Width=3000; Height=1000 },
        @{ Column=0; Row=1; ColumnSpan=1; RowSpan=1; Text='아래 1'; Width=3000; Height=2000 },
        @{ Column=1; Row=1; ColumnSpan=1; RowSpan=1; Text='아래 2'; Width=3000; Height=2000 },
        @{ Column=2; Row=1; ColumnSpan=1; RowSpan=1; Text='아래 3'; Width=3000; Height=2000 }
    )
    if ($IncludeOverlappingCell) {
        $cells += @{ Column=1; Row=0; ColumnSpan=1; RowSpan=1; Text='충돌'; Width=3000; Height=1000 }
    }
    foreach ($cell in $cells) {
        $cellPayload = New-TestHwpCellPayload -ColumnAddress $cell.Column -RowAddress $cell.Row `
            -ColumnSpan $cell.ColumnSpan -RowSpan $cell.RowSpan -Width $cell.Width -Height $cell.Height
        $section.AddRange((New-TestHwpRecord -TagId 0x48 -Level 2 -Payload $cellPayload))
        $section.AddRange((New-TestHwpRecord -TagId 0x42 -Level 2 -Payload (New-TestHwpParagraphHeaderPayload)))
        $section.AddRange((New-TestHwpRecord -TagId 0x43 -Level 3 -Payload (New-TestHwpParagraphTextPayload -Text $cell.Text)))
    }
    $section.AddRange((New-TestHwpRecord -TagId 0x42 -Level 0 -Payload (New-TestHwpParagraphHeaderPayload)))
    ,$section.ToArray()
}

function New-TestTableHwpx {
    param([Parameter(Mandatory)][string]$LiteralPath)

    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $entries = [ordered]@{
                mimetype = 'application/hwp+zip'
                'Contents/section0.xml' = @'
<?xml version="1.0" encoding="UTF-8"?>
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
        xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
  <hp:tbl id="20" pageBreak="CELL" repeatHeader="1" noAdjust="1" rowCnt="2" colCnt="3"
          cellSpacing="20" borderFillIDRef="3">
    <hp:inMargin left="510" right="511" top="141" bottom="142"/>
    <hp:cellzoneList><hp:cellzone startRowAddr="0" startColAddr="0" endRowAddr="1"
      endColAddr="2" borderFillIDRef="9"/></hp:cellzoneList>
    <hp:tr>
      <hp:tc name="title" header="1" hasMargin="1" protect="1" editable="1" dirty="1"
             borderFillIDRef="7"><hp:subList textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER">
        <hp:p id="1"><hp:run><hp:t>병합 셀</hp:t></hp:run></hp:p>
      </hp:subList><hp:cellAddr colAddr="0" rowAddr="0"/><hp:cellSpan colSpan="2" rowSpan="1"/>
      <hp:cellSz width="6000" height="1000"/><hp:cellMargin left="510" right="511" top="141" bottom="142"/></hp:tc>
      <hp:tc borderFillIDRef="7"><hp:subList textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER">
        <hp:p id="2"><hp:run><hp:t>오른쪽</hp:t></hp:run></hp:p>
      </hp:subList><hp:cellAddr colAddr="2" rowAddr="0"/><hp:cellSpan colSpan="1" rowSpan="1"/>
      <hp:cellSz width="3000" height="1000"/><hp:cellMargin left="510" right="511" top="141" bottom="142"/></hp:tc>
    </hp:tr>
    <hp:tr>
      <hp:tc borderFillIDRef="8"><hp:subList textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="BOTTOM">
        <hp:p id="3"><hp:run><hp:t>아래 전체</hp:t></hp:run></hp:p>
      </hp:subList><hp:cellAddr colAddr="0" rowAddr="1"/><hp:cellSpan colSpan="3" rowSpan="1"/>
      <hp:cellSz width="9000" height="2000"/><hp:cellMargin left="510" right="511" top="141" bottom="142"/></hp:tc>
    </hp:tr>
  </hp:tbl>
</hs:sec>
'@
            }
            foreach ($name in $entries.Keys) {
                $compression = if ($name -eq 'mimetype') {
                    [IO.Compression.CompressionLevel]::NoCompression
                }
                else {
                    [IO.Compression.CompressionLevel]::Optimal
                }
                $entry = $archive.CreateEntry($name, $compression)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write([string]$entries[$name]) }
                finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    $LiteralPath
}

Describe 'HWP 서식 리소스와 저장 레이아웃 복원' {
    It 'DocInfo의 언어별 글꼴·테두리·글자 모양·문단 모양을 원시 참조와 함께 읽는다' {
        $docInfo = New-TestHwpDocInfoStream

        $result = & $script:portableModuleInfo {
            param($Bytes)
            Get-HwpPortableDocInfoData -Bytes $Bytes
        } $docInfo

        $result.Resources.Fonts.Count | Should Be 7
        $result.Resources.Fonts[0].Language | Should Be 'HANGUL'
        $result.Resources.Fonts[0].Name | Should Be '한글시험체'
        $result.Resources.Fonts[1].Language | Should Be 'LATIN'
        $result.Resources.BorderFills.Count | Should Be 1
        $result.Resources.BorderFills[0].Id | Should Be 1
        $result.Resources.BorderFills[0].Borders.Left.Type | Should Be 'SOLID'
        $result.Resources.BorderFills[0].Borders.Left.WidthMm | Should Be 0.12
        $result.Resources.BorderFills[0].Borders.Left.Color | Should Be '#FF0000'
        $result.Resources.BorderFills[0].Fill.Solid.BackgroundColor | Should Be '#AABBCC'
        $result.Resources.CharShapes.Count | Should Be 1
        $result.Resources.CharShapes[0].FontSizePt | Should Be 12
        $result.Resources.CharShapes[0].Attributes.Bold | Should Be $true
        $result.Resources.CharShapes[0].Attributes.Italic | Should Be $true
        $result.Resources.CharShapes[0].ResolvedFontNames.Hangul | Should Be '한글시험체'
        $result.Resources.ParaShapes.Count | Should Be 1
        $result.Resources.ParaShapes[0].Alignment | Should Be 'CENTER'
        $result.Resources.ParaShapes[0].Margins.Left.Raw | Should Be 1000
        $result.Resources.ParaShapes[0].Indent.Raw | Should Be -300
        $result.Resources.ParaShapes[0].LineSpacing.Value | Should Be 150
    }

    It '문단 헤더·글자 모양 구간·저장된 줄 구간과 용지 배치를 복원한다' {
        [byte[]]$sectionBytes = New-TestHwpLayoutSection
        $controls = [Collections.Generic.List[object]]::new()
        $tables = [Collections.Generic.List[object]]::new()
        $warnings = [Collections.Generic.List[string]]::new()

        $result = & $script:portableModuleInfo {
            param($Bytes, $Controls, $Tables, $Warnings)
            Get-HwpPortableSectionData -Bytes $Bytes -SectionName 'Section0' -Controls $Controls `
                -Tables $Tables -StructureWarnings $Warnings
        } $sectionBytes $controls $tables $warnings

        $result.LayoutParagraphs.Count | Should Be 1
        $paragraph = $result.LayoutParagraphs[0]
        $paragraph.Text | Should Be '첫줄둘째줄'
        $paragraph.ParaShapeId | Should Be 0
        $paragraph.StyleId | Should Be 2
        $paragraph.BreakTypeRaw | Should Be 5
        $paragraph.CharShapeRuns.Count | Should Be 1
        $paragraph.CharShapeRuns[0].CharShapeId | Should Be 0
        $paragraph.LineSegments.Count | Should Be 2
        $paragraph.LineSegments[0].IsPageFirst | Should Be $true
        $paragraph.StoredLines.Count | Should Be 2
        $paragraph.StoredLines[0].Text | Should Be '첫줄'
        $paragraph.StoredLines[1].Text | Should Be '둘째줄'
        $result.PageDefinitions.Count | Should Be 1
        $result.PageDefinitions[0].Orientation | Should Be 'PORTRAIT'
        $result.PageDefinitions[0].Width.Raw | Should Be 59528
        $result.StoredPageFirstLineCount | Should Be 1
    }
}

Describe 'HWP 표 구조 복원' {
    It '행열 병합 셀 속성 문단과 전체 그리드를 레코드 계층에서 복원한다' {
        [byte[]]$sectionBytes = New-TestHwpTableSection
        $controls = [Collections.Generic.List[object]]::new()
        $tables = [Collections.Generic.List[object]]::new()
        $warnings = [Collections.Generic.List[string]]::new()

        $result = & $script:portableModuleInfo {
            param($Bytes, $Controls, $Tables, $Warnings)
            Get-HwpPortableSectionData -Bytes $Bytes -SectionName 'Section0' -Controls $Controls `
                -Tables $Tables -StructureWarnings $Warnings
        } $sectionBytes $controls $tables $warnings

        $tables.Count | Should Be 1
        $table = $tables[0]
        $table.RowCount | Should Be 2
        $table.ColumnCount | Should Be 3
        $table.CellSpacing | Should Be 20
        $table.InnerMargins.Left | Should Be 510
        $table.InnerMargins.Right | Should Be 511
        $table.RowSizes[0] | Should Be 1000
        $table.RowSizes[1] | Should Be 2000
        $table.Properties.PageBreakCode | Should Be 2
        $table.Properties.PageBreak | Should Be 'NONE'
        $table.Properties.RepeatHeader | Should Be $true
        $table.ValidZones.Count | Should Be 1
        $table.ValidZones[0].EndColumnAddress | Should Be 2
        $table.Cells.Count | Should Be 5

        $merged = $table.Cells[0]
        $merged.RowAddress | Should Be 0
        $merged.ColumnAddress | Should Be 0
        $merged.RowSpan | Should Be 1
        $merged.ColumnSpan | Should Be 2
        $merged.Text | Should Be '병합 셀'
        $merged.Paragraphs.Count | Should Be 1
        $merged.Width | Should Be 6000
        $merged.Margins.Bottom | Should Be 142
        $merged.TextDirectionCode | Should Be 2
        $merged.TextDirection | Should Be 'UNKNOWN_2'
        $merged.LineWrapCode | Should Be 1
        $merged.LineWrap | Should Be 'KEEP_LINE'
        $merged.VerticalAlignmentCode | Should Be 2
        $merged.VerticalAlignment | Should Be 'BOTTOM'
        $merged.CellFlagsRaw | Should Be 11
        $merged.Name | Should Be ''
        $merged.HasMargin | Should Be $true
        $merged.Protect | Should Be $true
        $merged.Editable | Should Be $true
        $merged.Dirty | Should Be $false
        $table.Properties.NoAdjust | Should Be $null

        $table.Grid.Count | Should Be 2
        $table.Grid[0].Count | Should Be 3
        $table.Grid[0][0].IsAnchor | Should Be $true
        $table.Grid[0][1].IsAnchor | Should Be $false
        $table.Grid[0][1].MergedInto.RowAddress | Should Be 0
        $table.Grid[0][1].MergedInto.ColumnAddress | Should Be 0
        $table.Grid[1][2].CellIndex | Should Be 4
        $warnings.Count | Should Be 0
        $result.RecordCount | Should BeGreaterThan 0
    }

    It '겹치는 셀을 추측하지 않고 구조 경고로 반환한다' {
        [byte[]]$sectionBytes = New-TestHwpTableSection -IncludeOverlappingCell
        $controls = [Collections.Generic.List[object]]::new()
        $tables = [Collections.Generic.List[object]]::new()
        $warnings = [Collections.Generic.List[string]]::new()

        $null = & $script:portableModuleInfo {
            param($Bytes, $Controls, $Tables, $Warnings)
            Get-HwpPortableSectionData -Bytes $Bytes -SectionName 'Section0' -Controls $Controls `
                -Tables $Tables -StructureWarnings $Warnings
        } $sectionBytes $controls $tables $warnings

        ($warnings -join ' ') | Should Match '겹치는 셀'
        $tables[0].Grid[0][1].CellIndex | Should Be 0
    }

    It '셀 없는 그리드 칸 수를 구조 경고로 정확히 반환한다' {
        $warnings = [Collections.Generic.List[string]]::new()
        $cells = @([pscustomobject]@{
            Index = 0
            RowAddress = 0
            ColumnAddress = 0
            RowSpan = 1
            ColumnSpan = 1
        })

        $grid = @(New-HwpTableGrid -RowCount 1 -ColumnCount 2 -Cells $cells `
            -Warnings $warnings -TableLabel '시험 표')

        $grid.Count | Should Be 1
        $grid[0][1] | Should Be $null
        ($warnings -join ' ') | Should Match '1개'
    }
}

Describe '표 구조 검사 JSON 스키마' {
    It 'tables 필드가 없으면 검사 결과 계약을 거부한다' -Skip:(-not $hasTestJson) {
        $schemaPath = Join-Path $PSScriptRoot '../skills/hwp-skill/schemas/inspection.schema.json'
        $withoutTables = [ordered]@{
            status = 'PASS_WITH_WARNINGS'
            path = 'C:\fixture.hwpx'
            sha256 = ('a' * 64)
            detectedKind = 'HWPX-ZIP'
            text = ''
            fields = [pscustomobject]@{}
            controls = @()
            pageCount = 0
            warnings = @()
        }

        (($withoutTables | ConvertTo-Json -Depth 30) |
            Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    It '행 수가 음수인 잘못된 표 구조를 거부한다' -Skip:(-not $hasTestJson) {
        $schemaPath = Join-Path $PSScriptRoot '../skills/hwp-skill/schemas/inspection.schema.json'
        $malformed = [ordered]@{
            status = 'PASS_WITH_WARNINGS'
            path = 'C:\fixture.hwpx'
            sha256 = ('a' * 64)
            detectedKind = 'HWPX-ZIP'
            text = ''
            fields = [pscustomobject]@{}
            controls = @()
            tables = @([ordered]@{ rowCount = -1 })
            pageCount = 0
            warnings = @()
        }

        (($malformed | ConvertTo-Json -Depth 30) |
            Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }
}

Describe 'HWPX 표 구조 복원' {
    It 'HWP와 같은 tables 계약으로 병합 구조와 셀 내용을 반환한다' {
        $path = New-TestTableHwpx -LiteralPath (Join-Path $TestDrive 'table.hwpx')

        $result = Get-HwpInspection -LiteralPath $path

        $result.Status | Should Match '^PASS'
        $result.Tables.Count | Should Be 1
        $table = $result.Tables[0]
        $table.RowCount | Should Be 2
        $table.ColumnCount | Should Be 3
        $table.CellSpacing | Should Be 20
        $table.Properties.PageBreak | Should Be 'CELL'
        $table.Properties.RepeatHeader | Should Be $true
        $table.Properties.NoAdjust | Should Be $true
        $table.RowSizes[0] | Should Be 1000
        $table.RowSizes[1] | Should Be 2000
        $table.ValidZones.Count | Should Be 1
        $table.ValidZones[0].StartRowAddress | Should Be 0
        $table.ValidZones[0].EndColumnAddress | Should Be 2
        $table.ValidZones[0].BorderFillId | Should Be 9
        $table.Cells.Count | Should Be 3
        $table.Cells[0].Text | Should Be '병합 셀'
        $table.Cells[0].Name | Should Be 'title'
        $table.Cells[0].CellFlagsRaw | Should Be $null
        $table.Cells[0].HasMargin | Should Be $true
        $table.Cells[0].Protect | Should Be $true
        $table.Cells[0].Header | Should Be $true
        $table.Cells[0].Editable | Should Be $true
        $table.Cells[0].Dirty | Should Be $true
        $table.Cells[2].ColumnSpan | Should Be 3
        $table.Cells[2].VerticalAlignment | Should Be 'BOTTOM'
        $table.Grid[0][1].MergedInto.ColumnAddress | Should Be 0
        $table.Grid[1][2].MergedInto.RowAddress | Should Be 1
    }
}
