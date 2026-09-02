Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop

$script:HwpxNamespaceBlock = 'xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:hp10="http://www.hancom.co.kr/hwpml/2016/paragraph" xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hhs="http://www.hancom.co.kr/hwpml/2011/history" xmlns:hm="http://www.hancom.co.kr/hwpml/2011/master-page" xmlns:hpf="http://www.hancom.co.kr/schema/2011/hpf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf/" xmlns:ooxmlchart="http://www.hancom.co.kr/hwpml/2016/ooxmlchart" xmlns:hwpunitchar="http://www.hancom.co.kr/hwpml/2016/HwpUnitChar" xmlns:epub="http://www.idpf.org/2007/ops" xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0"'

function ConvertTo-HwpxXmlText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    [Security.SecurityElement]::Escape([string]$Value)
}

function ConvertTo-HwpxUnit {
    param(
        [Parameter(Mandatory)][double]$Millimeter,
        [int]$Default = 1
    )

    if ($Millimeter -le 0) { return $Default }
    [int][Math]::Max(1, [Math]::Round($Millimeter * 283.4645669))
}

function Add-HwpxInlineText {
    param(
        [Parameter(Mandatory)][Text.StringBuilder]$Builder,
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        $null = $Builder.Append('<hp:t/>')
        return
    }

    $parts = [Regex]::Split($Text, "\r\n|\r|\n")
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $escaped = ConvertTo-HwpxXmlText -Value $parts[$index]
        if ($escaped.Length -eq 0) {
            $null = $Builder.Append('<hp:t/>')
        }
        else {
            $null = $Builder.Append('<hp:t>').Append($escaped).Append('</hp:t>')
        }
        if ($index -lt ($parts.Count - 1)) {
            $null = $Builder.Append('<hp:lineBreak/>')
        }
    }
}

function New-HwpxLineSegmentXml {
    param([int]$HorizontalSize = 51024)

    '<hp:linesegarray><hp:lineseg textpos="0" vertpos="0" vertsize="1000" textheight="1000" baseline="850" spacing="600" horzpos="0" horzsize="{0}" flags="393216"/></hp:linesegarray>' -f $HorizontalSize
}

function New-HwpxSectionPropertiesXml {
    $value = @'
<hp:secPr id="" textDirection="HORIZONTAL" spaceColumns="1134" tabStop="8000" tabStopVal="4000" tabStopUnit="HWPUNIT" outlineShapeIDRef="1" memoShapeIDRef="1" textVerticalWidthHead="0" masterPageCnt="0"><hp:grid lineGrid="0" charGrid="0" wonggojiFormat="0"/><hp:startNum pageStartsOn="BOTH" page="0" pic="0" tbl="0" equation="0"/><hp:visibility hideFirstHeader="0" hideFirstFooter="0" hideFirstMasterPage="0" border="SHOW_ALL" fill="SHOW_ALL" hideFirstPageNum="0" hideFirstEmptyLine="0" showLineNumber="0"/><hp:lineNumberShape restartType="0" countBy="0" distance="0" startNumber="0"/><hp:pagePr landscape="WIDELY" width="59528" height="84186" gutterType="LEFT_ONLY"><hp:margin header="4252" footer="4252" gutter="0" left="4251" right="4251" top="2834" bottom="2834"/></hp:pagePr><hp:footNotePr><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/><hp:noteLine length="-1" type="SOLID" width="0.12 mm" color="#000000"/><hp:noteSpacing betweenNotes="283" belowLine="567" aboveLine="850"/><hp:numbering type="CONTINUOUS" newNum="1"/><hp:placement place="EACH_COLUMN" beneathText="0"/></hp:footNotePr><hp:endNotePr><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/><hp:noteLine length="14692344" type="SOLID" width="0.12 mm" color="#000000"/><hp:noteSpacing betweenNotes="0" belowLine="567" aboveLine="850"/><hp:numbering type="CONTINUOUS" newNum="1"/><hp:placement place="END_OF_DOCUMENT" beneathText="0"/></hp:endNotePr><hp:pageBorderFill type="BOTH" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER"><hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill><hp:pageBorderFill type="EVEN" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER"><hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill><hp:pageBorderFill type="ODD" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER"><hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill>
'@
    $value + '</hp:secPr>'
}

function New-HwpxParagraphXml {
    param(
        [Parameter(Mandatory)][int]$Id,
        [AllowEmptyString()][string]$Text = '',
        [switch]$IncludeSectionProperties,
        [int]$PageBreak = 0,
        [int]$HorizontalSize = 51024,
        [AllowEmptyString()][string]$InlineXml = ''
    )

    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('<hp:p id="').Append($Id).Append('" paraPrIDRef="0" styleIDRef="0" pageBreak="').Append($PageBreak).Append('" columnBreak="0" merged="0">')
    if ($IncludeSectionProperties) {
        $null = $builder.Append('<hp:run charPrIDRef="0">').Append((New-HwpxSectionPropertiesXml)).Append('<hp:ctrl><hp:colPr id="" type="NEWSPAPER" layout="LEFT" colCount="1" sameSz="1" sameGap="0"/></hp:ctrl></hp:run>')
    }
    if ($InlineXml.Length -gt 0) {
        $null = $builder.Append('<hp:run charPrIDRef="0">').Append($InlineXml).Append('</hp:run>')
    }
    else {
        $null = $builder.Append('<hp:run charPrIDRef="0">')
        Add-HwpxInlineText -Builder $builder -Text $Text
        $null = $builder.Append('</hp:run>')
    }
    $null = $builder.Append((New-HwpxLineSegmentXml -HorizontalSize $HorizontalSize)).Append('</hp:p>')
    $builder.ToString()
}

function Get-HwpxTableCellText {
    param(
        [Parameter(Mandatory)][object]$Block,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column
    )

    foreach ($cell in @(if ($Block.PSObject.Properties.Name -contains 'cells') { $Block.cells } else { @() })) {
        if ([int]$cell.row -eq $Row -and [int]$cell.column -eq $Column) {
            return [string]$cell.text
        }
    }
    ''
}

function New-HwpxTableXml {
    param(
        [Parameter(Mandatory)][object]$Block,
        [Parameter(Mandatory)][int]$Id
    )

    $rows = [int]$Block.rows
    $columns = [int]$Block.columns
    $tableWidth = 51024
    $cellWidth = [int][Math]::Floor($tableWidth / $columns)
    $cellHeight = 1800
    $tableHeight = [int][Math]::Max($cellHeight, $cellHeight * $rows)
    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('<hp:tbl id="').Append($Id).Append('" zOrder="0" numberingType="TABLE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" pageBreak="CELL" repeatHeader="0" rowCnt="').Append($rows).Append('" colCnt="').Append($columns).Append('" cellSpacing="0" borderFillIDRef="3" noAdjust="0">')
    $null = $builder.Append('<hp:sz width="').Append($tableWidth).Append('" widthRelTo="ABSOLUTE" height="').Append($tableHeight).Append('" heightRelTo="ABSOLUTE" protect="0"/>')
    $null = $builder.Append('<hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/>')
    $null = $builder.Append('<hp:outMargin left="283" right="283" top="283" bottom="283"/><hp:inMargin left="510" right="510" top="141" bottom="141"/>')
    for ($row = 1; $row -le $rows; $row++) {
        $null = $builder.Append('<hp:tr>')
        for ($column = 1; $column -le $columns; $column++) {
            $cellText = Get-HwpxTableCellText -Block $Block -Row $row -Column $column
            $cellParagraph = [Text.StringBuilder]::new()
            $null = $cellParagraph.Append('<hp:p id="0" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="0">')
            Add-HwpxInlineText -Builder $cellParagraph -Text $cellText
            $null = $cellParagraph.Append('</hp:run>').Append((New-HwpxLineSegmentXml -HorizontalSize ([Math]::Max(1000, $cellWidth - 1020)))).Append('</hp:p>')
            $null = $builder.Append('<hp:tc name="" header="0" hasMargin="0" protect="0" editable="0" dirty="0" borderFillIDRef="3"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">').Append($cellParagraph.ToString()).Append('</hp:subList><hp:cellAddr colAddr="').Append($column - 1).Append('" rowAddr="').Append($row - 1).Append('"/><hp:cellSpan colSpan="1" rowSpan="1"/><hp:cellSz width="').Append($cellWidth).Append('" height="').Append($cellHeight).Append('"/><hp:cellMargin left="510" right="510" top="141" bottom="141"/></hp:tc>')
        }
        $null = $builder.Append('</hp:tr>')
    }
    $null = $builder.Append('</hp:tbl>')
    $builder.ToString()
}

function Get-HwpxImageExtension {
    param([Parameter(Mandatory)][string]$Path)

    $extension = [IO.Path]::GetExtension($Path).TrimStart('.').ToUpperInvariant()
    switch ($extension) {
        'JPEG' { return 'JPG' }
        'JPG' { return 'JPG' }
        'PNG' { return 'PNG' }
        'BMP' { return 'BMP' }
        'GIF' { return 'GIF' }
        'TIFF' { return 'TIF' }
        'TIF' { return 'TIF' }
        default { throw "HWPX에 직접 삽입할 수 없는 이미지 형식입니다: .$extension" }
    }
}

function Get-HwpxImageMediaType {
    param([Parameter(Mandatory)][string]$Extension)

    switch ($Extension.ToUpperInvariant()) {
        'JPG' { 'image/jpeg'; break }
        'PNG' { 'image/png'; break }
        'BMP' { 'image/bmp'; break }
        'GIF' { 'image/gif'; break }
        'TIF' { 'image/tiff'; break }
        default { 'application/octet-stream' }
    }
}

function Test-HwpxImageSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Extension
    )

    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 16
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally {
        $stream.Dispose()
    }
    $matches = switch ($Extension.ToUpperInvariant()) {
        'JPG' { $read -ge 3 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xD8 -and $buffer[2] -eq 0xFF; break }
        'PNG' { $read -ge 8 -and $buffer[0] -eq 0x89 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x4E -and $buffer[3] -eq 0x47 -and $buffer[4] -eq 0x0D -and $buffer[5] -eq 0x0A -and $buffer[6] -eq 0x1A -and $buffer[7] -eq 0x0A; break }
        'BMP' { $read -ge 2 -and $buffer[0] -eq 0x42 -and $buffer[1] -eq 0x4D; break }
        'GIF' { $read -ge 6 -and (($buffer[0] -eq 0x47) -and ($buffer[1] -eq 0x49) -and ($buffer[2] -eq 0x46) -and ($buffer[3] -eq 0x38) -and (($buffer[4] -eq 0x37) -or ($buffer[4] -eq 0x39)) -and $buffer[5] -eq 0x61); break }
        'TIF' { $read -ge 4 -and ((($buffer[0] -eq 0x49) -and ($buffer[1] -eq 0x49) -and ($buffer[2] -eq 0x2A) -and ($buffer[3] -eq 0x00)) -or (($buffer[0] -eq 0x4D) -and ($buffer[1] -eq 0x4D) -and ($buffer[2] -eq 0x00) -and ($buffer[3] -eq 0x2A))); break }
        default { $false }
    }
    if (-not $matches) {
        throw "이미지 확장자와 실제 파일 시그니처가 일치하지 않습니다: $Path"
    }
    $true
}

function New-HwpxPictureXml {
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$ImageId,
        [Parameter(Mandatory)][string]$OriginalPath,
        [double]$WidthMm = 40,
        [double]$HeightMm = 30
    )

    $width = ConvertTo-HwpxUnit -Millimeter $WidthMm -Default 11339
    $height = ConvertTo-HwpxUnit -Millimeter $HeightMm -Default 8504
    $centerX = [int][Math]::Floor($width / 2)
    $centerY = [int][Math]::Floor($height / 2)
    $comment = ConvertTo-HwpxXmlText -Value ('그림입니다. 원본 그림의 이름: {0}' -f [IO.Path]::GetFileName($OriginalPath))
    @"
<hp:pic id="$Id" zOrder="0" numberingType="PICTURE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" href="" groupLevel="0" instid="$Id" reverse="0"><hp:offset x="0" y="0"/><hp:orgSz width="$width" height="$height"/><hp:curSz width="$width" height="$height"/><hp:flip horizontal="0" vertical="0"/><hp:rotationInfo angle="0" centerX="$centerX" centerY="$centerY" rotateimage="1"/><hp:renderingInfo><hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/></hp:renderingInfo><hc:img binaryItemIDRef="$ImageId" bright="0" contrast="0" effect="REAL_PIC" alpha="0"/><hp:imgRect><hc:pt0 x="0" y="0"/><hc:pt1 x="$width" y="0"/><hc:pt2 x="$width" y="$height"/><hc:pt3 x="0" y="$height"/></hp:imgRect><hp:imgClip left="0" right="$width" top="0" bottom="$height"/><hp:inMargin left="0" right="0" top="0" bottom="0"/><hp:imgDim dimwidth="$width" dimheight="$height"/><hp:effects/><hp:sz width="$width" widthRelTo="ABSOLUTE" height="$height" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/><hp:outMargin left="0" right="0" top="0" bottom="0"/><hp:shapeComment>$comment</hp:shapeComment></hp:pic><hp:t/>
"@
}

function New-HwpxSectionXml {
    param([Parameter(Mandatory)][object[]]$Blocks)

    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hs:sec ').Append($script:HwpxNamespaceBlock).Append('>')
    $paragraphId = 1
    $controlId = 1000
    $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -IncludeSectionProperties))
    $paragraphId++
    foreach ($block in $Blocks) {
        switch ([string]$block.type) {
            'paragraph' {
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -Text ([string]$block.text)))
            }
            'field' {
                $label = if ($block.PSObject.Properties.Name -contains 'label') { [string]$block.label } else { '' }
                $fieldText = $label + [string]$block.value
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -Text $fieldText))
            }
            'table' {
                $tableXml = New-HwpxTableXml -Block $block -Id $controlId
                $controlId++
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -InlineXml $tableXml))
            }
            'image' {
                $imageNumber = [int]$block.__hwpxImageNumber
                $imageId = 'image{0}' -f $imageNumber
                $widthMm = if ($block.PSObject.Properties.Name -contains 'widthMm') { [double]$block.widthMm } else { 40 }
                $heightMm = if ($block.PSObject.Properties.Name -contains 'heightMm') { [double]$block.heightMm } else { 30 }
                $pictureXml = New-HwpxPictureXml -Id $controlId -ImageId $imageId -OriginalPath ([string]$block.path) -WidthMm $widthMm -HeightMm $heightMm
                $controlId++
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -InlineXml $pictureXml))
            }
            'page-break' {
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -PageBreak 1))
            }
        }
        $paragraphId++
    }
    $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId))
    $null = $builder.Append('</hs:sec>')
    $builder.ToString()
}

function Add-HwpxGridBorderFill {
    param([Parameter(Mandatory)][string]$HeaderXml)

    if ($HeaderXml -match 'borderFill id="3"') { return $HeaderXml }
    $header = $HeaderXml -replace '(<hh:borderFills\s+itemCnt=")2(")', '${1}3$2'
    $grid = '<hh:borderFill id="3" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0"><hh:slash type="NONE" Crooked="0" isCounter="0"/><hh:backSlash type="NONE" Crooked="0" isCounter="0"/><hh:leftBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:rightBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:topBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:bottomBorder type="SOLID" width="0.12 mm" color="#000000"/><hh:diagonal type="SOLID" width="0.1 mm" color="#000000"/></hh:borderFill>'
    $header -replace '</hh:borderFills>', ($grid + '</hh:borderFills>')
}

function New-HwpxContentPackageXml {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][int]$ImageCount
    )

    $items = [Text.StringBuilder]::new()
    $null = $items.Append('<opf:item id="header" href="Contents/header.xml" media-type="application/xml"/>')
    for ($index = 1; $index -le $ImageCount; $index++) {
        $null = $items.Append('<opf:item id="image').Append($index).Append('" href="BinData/image').Append($index).Append('.').Append('{0}' -f $script:HwpxImageExtensions[$index - 1]).Append('" media-type="').Append((Get-HwpxImageMediaType -Extension $script:HwpxImageExtensions[$index - 1])).Append('" isEmbeded="1"/>')
    }
    $null = $items.Append('<opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/><opf:item id="settings" href="settings.xml" media-type="application/xml"/>')
    $safeTitle = ConvertTo-HwpxXmlText -Value $Title
    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><opf:package $script:HwpxNamespaceBlock version="" unique-identifier="" id=""><opf:metadata><opf:title>$safeTitle</opf:title><opf:language>ko</opf:language><opf:meta name="creator" content="text">hwp-skill</opf:meta><opf:meta name="subject" content="text"/><opf:meta name="description" content="text"/><opf:meta name="lastsaveby" content="text">hwp-skill</opf:meta><opf:meta name="keyword" content="text"/></opf:metadata><opf:manifest>$($items.ToString())</opf:manifest><opf:spine><opf:itemref idref="header" linear="yes"/><opf:itemref idref="section0" linear="yes"/></opf:spine></opf:package>
"@.Trim()
}

function Write-HwpxZipTextEntry {
    param(
        [Parameter(Mandatory)][IO.Compression.ZipArchive]$Archive,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [IO.Compression.CompressionLevel]$CompressionLevel = [IO.Compression.CompressionLevel]::Optimal
    )

    $entry = $Archive.CreateEntry($Name, $CompressionLevel)
    $stream = $entry.Open()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function Copy-HwpxZipEntry {
    param(
        [Parameter(Mandatory)][IO.Compression.ZipArchiveEntry]$Source,
        [Parameter(Mandatory)][IO.Compression.ZipArchive]$TargetArchive,
        [Parameter(Mandatory)][string]$Name,
        [IO.Compression.CompressionLevel]$CompressionLevel = [IO.Compression.CompressionLevel]::Optimal
    )

    $target = $TargetArchive.CreateEntry($Name, $CompressionLevel)
    $input = $Source.Open()
    $output = $target.Open()
    try { $input.CopyTo($output) }
    finally { $output.Dispose(); $input.Dispose() }
}

function Invoke-HwpxGenerateDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Plan,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
        [string]$TemplatePath = (Join-Path $PSScriptRoot '../../templates/default.hwpx')
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput).ToLowerInvariant() -ne '.hwpx') {
        return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @('직접 생성 단계의 출력은 .hwpx여야 합니다.')
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @("기존 결과를 덮어쓰지 않습니다: $resolvedOutput")
    }
    $directory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @("결과 폴더가 없습니다: $directory")
    }
    $resolvedTemplate = Resolve-HwpLiteralPath -LiteralPath $TemplatePath
    if (-not (Test-Path -LiteralPath $resolvedTemplate -PathType Leaf)) {
        return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @("HWPX 기본 템플릿이 없습니다: $resolvedTemplate")
    }

    $imageBlocks = [Collections.Generic.List[object]]::new()
    $imageExtensions = [Collections.Generic.List[string]]::new()
    foreach ($block in @($Plan.content)) {
        if ([string]$block.type -ne 'image') { continue }
        try {
            $imagePath = (Resolve-Path -LiteralPath ([string]$block.path) -ErrorAction Stop).Path
            if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
                throw "이미지 파일이 없습니다: $imagePath"
            }
            $extension = Get-HwpxImageExtension -Path $imagePath
            Test-HwpxImageSignature -Path $imagePath -Extension $extension | Out-Null
            $copy = [pscustomobject]@{}
            foreach ($property in $block.PSObject.Properties) { $copy | Add-Member NoteProperty $property.Name $property.Value }
            $copy | Add-Member NoteProperty path $imagePath -Force
            $copy | Add-Member NoteProperty __hwpxImageNumber ($imageBlocks.Count + 1) -Force
            $imageBlocks.Add($copy)
            $imageExtensions.Add($extension)
        }
        catch {
            return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @($_.Exception.Message)
        }
    }

    $script:HwpxImageExtensions = @($imageExtensions)
    $stagingPath = [IO.Path]::Combine($directory, ('{0}.{1}.partial.hwpx' -f [IO.Path]::GetFileNameWithoutExtension($resolvedOutput), [guid]::NewGuid().ToString('n')))
    $sourceStream = $null
    $sourceArchive = $null
    $targetStream = $null
    $targetArchive = $null
    $generationFailed = $false
    try {
        $imageCursor = 0
        $normalizedBlocks = foreach ($block in @($Plan.content)) {
            if ([string]$block.type -eq 'image') {
                $imageCursor++
                $imageBlocks[$imageCursor - 1]
            }
            else { $block }
        }
        $sectionXml = New-HwpxSectionXml -Blocks @($normalizedBlocks)
        $title = [IO.Path]::GetFileNameWithoutExtension($resolvedOutput)
        if ($Plan.PSObject.Properties.Name -contains 'title' -and -not [string]::IsNullOrWhiteSpace([string]$Plan.title)) { $title = [string]$Plan.title }
        $contentXml = New-HwpxContentPackageXml -Title $title -ImageCount $imageExtensions.Count

        $sourceStream = [IO.File]::Open($resolvedTemplate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sourceArchive = [IO.Compression.ZipArchive]::new($sourceStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        $targetStream = [IO.File]::Create($stagingPath)
        $targetArchive = [IO.Compression.ZipArchive]::new($targetStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        $sourceMap = @{}
        foreach ($entry in $sourceArchive.Entries) { $sourceMap[$entry.FullName] = $entry }
        foreach ($name in 'mimetype','version.xml') {
            if ($sourceMap.ContainsKey($name)) {
                Copy-HwpxZipEntry -Source $sourceMap[$name] -TargetArchive $targetArchive -Name $name -CompressionLevel ([IO.Compression.CompressionLevel]::NoCompression)
            }
        }
        $headerEntry = $sourceMap['Contents/header.xml']
        $headerReader = [IO.StreamReader]::new($headerEntry.Open(), [Text.Encoding]::UTF8, $true)
        try { $headerXml = $headerReader.ReadToEnd() } finally { $headerReader.Dispose() }
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'Contents/header.xml' -Text (Add-HwpxGridBorderFill -HeaderXml $headerXml)
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'Contents/content.hpf' -Text $contentXml
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'Contents/section0.xml' -Text $sectionXml
        $previewText = (($normalizedBlocks | ForEach-Object {
            $previewBlock = $_
            switch ([string]$previewBlock.type) {
                'paragraph' { if ($previewBlock.PSObject.Properties.Name -contains 'text') { [string]$previewBlock.text } else { '' } }
                'field' { if ($previewBlock.PSObject.Properties.Name -contains 'value') { [string]$previewBlock.value } else { '' } }
                'table' { @($previewBlock.cells | ForEach-Object { $previewCell = $_; if ($previewCell.PSObject.Properties.Name -contains 'text') { [string]$previewCell.text } }) -join ' ' }
                'image' { '[이미지]' }
                default { '' }
            }
        }) -join "`r`n")
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'Preview/PrvText.txt' -Text $previewText
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'settings.xml' -Text ('<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><ha:HWPApplicationSetting xmlns:ha="http://www.hancom.co.kr/hwpml/2011/app" xmlns:config="urn:oasis:names:tc:opendocument:xmlns:config:1.0"><ha:CaretPosition listIDRef="0" paraIDRef="0" pos="0"/></ha:HWPApplicationSetting>')
        foreach ($entry in $sourceArchive.Entries) {
            if ($entry.FullName -in @('mimetype','version.xml','Contents/header.xml','Contents/content.hpf','Contents/section0.xml','Preview/PrvText.txt','settings.xml') -or $entry.FullName -match '^BinData/') { continue }
            Copy-HwpxZipEntry -Source $entry -TargetArchive $targetArchive -Name $entry.FullName
        }
        for ($index = 0; $index -lt $imageBlocks.Count; $index++) {
            $image = $imageBlocks[$index]
            $name = 'BinData/image{0}.{1}' -f ($index + 1), $imageExtensions[$index]
            $entry = $targetArchive.CreateEntry($name, [IO.Compression.CompressionLevel]::NoCompression)
            $input = [IO.File]::OpenRead([string]$image.path)
            $output = $entry.Open()
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        }
    }
    catch {
        $generationFailed = $true
        return New-HwpResult -Status FAILED -Command generate-hwpx -Errors @("HWPX 직접 생성에 실패했습니다: $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $targetArchive) { $targetArchive.Dispose() }
        if ($null -ne $targetStream) { $targetStream.Dispose() }
        if ($null -ne $sourceArchive) { $sourceArchive.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        if ($generationFailed -and (Test-Path -LiteralPath $stagingPath)) {
            Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        [IO.File]::Move($stagingPath, $resolvedOutput)
    }
    catch {
        if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue }
        return New-HwpResult -Status FAILED -Command generate-hwpx -Errors @("검증 전 HWPX를 최종 경로로 승격하지 못했습니다: $($_.Exception.Message)")
    }
    $kind = Get-HwpFileKind -LiteralPath $resolvedOutput
    if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWPX-ZIP') {
        return New-HwpResult -Status FAILED -Command generate-hwpx -Errors @('생성 결과가 HWPX ZIP 형식으로 확인되지 않았습니다.')
    }
    New-HwpResult -Status PASS -Command generate-hwpx -Data ([pscustomobject]@{
        OutputPath = $resolvedOutput
        OutputSha256 = Get-HwpSha256 -LiteralPath $resolvedOutput
        ByteLength = (Get-Item -LiteralPath $resolvedOutput).Length
        ImageCount = $imageBlocks.Count
        EntryCount = $null
        NativeLayoutVerified = $false
        HancomDiskAccess = $false
        DirectHwpxWrite = $true
    })
}

Export-ModuleMember -Function @(
    'Invoke-HwpxGenerateDocument'
)
