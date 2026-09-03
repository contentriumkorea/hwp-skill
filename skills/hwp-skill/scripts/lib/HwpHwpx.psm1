Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpHwpxStyles.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpAuthoringPlan.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpHwpxObjects.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpHwpxReferences.psm1') -ErrorAction Stop

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

    $escaped = ConvertTo-HwpxXmlText -Value $Text
    $escaped = [Regex]::Replace($escaped, "\r\n|\r|\n", '<hp:lineBreak/>')
    $escaped = $escaped.Replace("`t", '<hp:tab width="0" leader="0" type="0"/>')
    $null = $Builder.Append('<hp:t>').Append($escaped).Append('</hp:t>')
}

function New-HwpxLineSegmentXml {
    param([int]$HorizontalSize = 51024)

    '<hp:linesegarray><hp:lineseg textpos="0" vertpos="0" vertsize="1000" textheight="1000" baseline="850" spacing="600" horzpos="0" horzsize="{0}" flags="393216"/></hp:linesegarray>' -f $HorizontalSize
}

function New-HwpxSectionPropertiesXml {
    param([AllowNull()][object]$PageSettings = $null)
    $value = @'
<hp:secPr id="" textDirection="HORIZONTAL" spaceColumns="1134" tabStop="8000" tabStopVal="4000" tabStopUnit="HWPUNIT" outlineShapeIDRef="1" memoShapeIDRef="1" textVerticalWidthHead="0" masterPageCnt="0"><hp:grid lineGrid="0" charGrid="0" wonggojiFormat="0"/><hp:startNum pageStartsOn="BOTH" page="0" pic="0" tbl="0" equation="0"/><hp:visibility hideFirstHeader="0" hideFirstFooter="0" hideFirstMasterPage="0" border="SHOW_ALL" fill="SHOW_ALL" hideFirstPageNum="0" hideFirstEmptyLine="0" showLineNumber="0"/><hp:lineNumberShape restartType="0" countBy="0" distance="0" startNumber="0"/><hp:pagePr landscape="WIDELY" width="59528" height="84186" gutterType="LEFT_ONLY"><hp:margin header="4252" footer="4252" gutter="0" left="4251" right="4251" top="2834" bottom="2834"/></hp:pagePr><hp:footNotePr><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/><hp:noteLine length="-1" type="SOLID" width="0.12 mm" color="#000000"/><hp:noteSpacing betweenNotes="283" belowLine="567" aboveLine="850"/><hp:numbering type="CONTINUOUS" newNum="1"/><hp:placement place="EACH_COLUMN" beneathText="0"/></hp:footNotePr><hp:endNotePr><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/><hp:noteLine length="14692344" type="SOLID" width="0.12 mm" color="#000000"/><hp:noteSpacing betweenNotes="0" belowLine="567" aboveLine="850"/><hp:numbering type="CONTINUOUS" newNum="1"/><hp:placement place="END_OF_DOCUMENT" beneathText="0"/></hp:endNotePr><hp:pageBorderFill type="BOTH" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER"><hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill><hp:pageBorderFill type="EVEN" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER"><hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill><hp:pageBorderFill type="ODD" borderFillIDRef="1" textBorder="PAPER" headerInside="0" footerInside="0" fillArea="PAPER"><hp:offset left="1417" right="1417" top="1417" bottom="1417"/></hp:pageBorderFill>
'@
    $value = $value.Replace('height="84186"', 'height="84189"')
    if ($null -ne $PageSettings) {
        # Hancom's saved enum is counterintuitive: WIDELY=portrait, NARROWLY=landscape.
        $landscape = if ([string]$PageSettings.orientation -eq 'LANDSCAPE') { 'NARROWLY' } else { 'WIDELY' }
        $pageXml = '<hp:pagePr landscape="{0}" width="{1}" height="{2}" gutterType="LEFT_ONLY"><hp:margin header="{3}" footer="{4}" gutter="{5}" left="{6}" right="{7}" top="{8}" bottom="{9}"/></hp:pagePr>' -f `
            $landscape, $PageSettings.width, $PageSettings.height, $PageSettings.margins.header,
            $PageSettings.margins.footer, $PageSettings.margins.gutter, $PageSettings.margins.left,
            $PageSettings.margins.right, $PageSettings.margins.top, $PageSettings.margins.bottom
        $value = [regex]::Replace($value, '<hp:pagePr\b.*?</hp:pagePr>', $pageXml)
        $value = $value.Replace('gutterType="LEFT_ONLY"', ('gutterType="{0}"' -f $PageSettings.gutterType))
        $value = [regex]::Replace($value, '(<hp:pageBorderFill\b[^>]*borderFillIDRef=")\d+', ('${1}' + $PageSettings.borderFillId))
        $doc=$PageSettings.document
        $page=Get-HwpPlanValue $doc 'page'
        $apply=Get-HwpPlanValue $page 'borderApplyTo' 'BOTH'
        if ($apply -ne 'BOTH') {
            foreach ($kind in @('BOTH','EVEN','ODD')) {if ($kind -ne $apply) {$value=[regex]::Replace($value, ('(<hp:pageBorderFill type="'+$kind+'" borderFillIDRef=")\d+'), '${1}1')}}
        }
        foreach ($property in @('border','fill')) {
            $visibility=Get-HwpPlanValue $page ($property+'Visibility') 'SHOW_ALL'
            $value=$value.Replace(($property+'="SHOW_ALL"'),($property+'="'+$visibility+'"'))
        }
        $start=Get-HwpPlanValue (Get-HwpPlanValue $doc 'pageNumber') 'start' 0
        $value=$value.Replace('page="0" pic=',('page="{0}" pic=' -f $start))
        foreach ($pair in @(@('hideFirstHeader','hideFirstHeader'),@('hideFirstFooter','hideFirstFooter'),@('hideFirstPageNum','hideFirstPageNumber'))) {
            $value=$value.Replace(($pair[0]+'="0"'),($pair[0]+'="'+[int][bool](Get-HwpPlanValue $doc $pair[1] $false)+'"'))
        }
    }
    $value + '</hp:secPr>'
}

function New-HwpxParagraphXml {
    param(
        [Parameter(Mandatory)][int]$Id,
        [AllowEmptyString()][string]$Text = '',
        [switch]$IncludeSectionProperties,
        [AllowNull()][object]$PageSettings = $null,
        [int]$CharPrId = 0,
        [int]$ParaPrId = 0,
        [int]$StyleId = 0,
        [int]$PageBreak = 0,
        [int]$ColumnBreak = 0,
        [object[]]$Runs = @(),
        [int]$HorizontalSize = 51024,
        [AllowEmptyString()][string]$InlineXml = ''
    )

    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('<hp:p id="').Append($Id).Append('" paraPrIDRef="').Append($ParaPrId).Append('" styleIDRef="').Append($StyleId).Append('" pageBreak="').Append($PageBreak).Append('" columnBreak="').Append($ColumnBreak).Append('" merged="0">')
    if ($IncludeSectionProperties) {
        $cols=$PageSettings.columns
        $null = $builder.Append('<hp:run charPrIDRef="0">').Append((New-HwpxSectionPropertiesXml -PageSettings $PageSettings)).Append('<hp:ctrl><hp:colPr id="" type="NEWSPAPER" layout="LEFT" colCount="').Append($cols.count).Append('" sameSz="').Append([int]($cols.widths.Count -eq 0)).Append('" sameGap="').Append($cols.gap).Append('">')
        for ($i=0; $i -lt $cols.widths.Count; $i++) { $null=$builder.Append(('<hp:colSz width="{0}" gap="{1}"/>' -f $cols.widths[$i], $(if ($i -lt $cols.widths.Count-1) {$cols.gap} else {0}))) }
        $separator=Get-HwpPlanValue (Get-HwpPlanValue $PageSettings.document 'columns') 'separator'
        if ($null -ne $separator) {
            $lineWidth=([double](Get-HwpPlanValue $separator 'widthMm' 0.12)).ToString('0.0#',[Globalization.CultureInfo]::InvariantCulture)+' mm'
            $null=$builder.Append(('<hp:colLine type="{0}" width="{1}" color="{2}"/>' -f (Get-HwpPlanValue $separator 'type' 'SOLID'),$lineWidth,(Get-HwpPlanValue $separator 'color' '#000000')))
        }
        $null=$builder.Append('</hp:colPr></hp:ctrl></hp:run>')
        $references=New-HwpxSectionReferenceXml -Document $PageSettings.document -Id $PageSettings.referenceId -Width $PageSettings.contentWidth
        if ($references.Length) {$null=$builder.Append('<hp:run charPrIDRef="0">').Append($references).Append('</hp:run>')}
    }
    if ($Runs.Count -gt 0) {
        foreach ($run in $Runs) {
            $null = $builder.Append('<hp:run charPrIDRef="').Append($run.__charPrId).Append('">')
            Add-HwpxInlineText $builder ([string]$run.text)
            $null = $builder.Append('</hp:run>')
        }
    }
    elseif ($InlineXml.Length -gt 0) {
        $null = $builder.Append('<hp:run charPrIDRef="').Append($CharPrId).Append('">').Append($InlineXml).Append('</hp:run>')
    }
    else {
        $null = $builder.Append('<hp:run charPrIDRef="').Append($CharPrId).Append('">')
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

function Get-HwpxTableCell {
    param(
        [Parameter(Mandatory)][object]$Block,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column
    )
    foreach ($cell in @(if ($Block.PSObject.Properties.Name -contains 'cells') { $Block.cells } else { @() })) {
        if ([int]$cell.row -eq $Row -and [int]$cell.column -eq $Column) { return $cell }
    }
    $null
}

function New-HwpxTableXml {
    param(
        [Parameter(Mandatory)][object]$Block,
        [Parameter(Mandatory)][int]$Id,
        [int]$AvailableWidth = 51024
    )

    $rows = [int]$Block.rows
    $columns = [int]$Block.columns
    $tableWidth = if ($null -ne $Block.PSObject.Properties['widthMm']) {ConvertTo-HwpxUnit $Block.widthMm} else {$AvailableWidth}
    $widths = @(if ($null -ne $Block.PSObject.Properties['columnWidthsMm']) {$Block.columnWidthsMm|ForEach-Object {ConvertTo-HwpxUnit $_}} else {1..$columns|ForEach-Object {[int][Math]::Floor($tableWidth/$columns)}})
    $widths[$columns-1] += $tableWidth - ($widths|Measure-Object -Sum).Sum
    $cellHeight = 1800
    $heights = @(if ($null -ne $Block.PSObject.Properties['rowHeightsMm']) {$Block.rowHeightsMm|ForEach-Object {ConvertTo-HwpxUnit $_}} else {1..$rows|ForEach-Object {$cellHeight}})
    if ($null -eq $Block.PSObject.Properties['rowHeightsMm']) {
        # Unspecified rows are minima, not fixed heights; reserve positive inner space.
        $defaultMargins=Get-HwpPlanValue $Block '__margins'
        $minimum=[int](Get-HwpPlanValue $defaultMargins 'top' 510)+[int](Get-HwpPlanValue $defaultMargins 'bottom' 510)+1000
        for($r=0;$r -lt $rows;$r++){$heights[$r]=[Math]::Max($heights[$r],$minimum)}
        foreach($cell in $Block.cells){
            $margins=Get-HwpPlanValue $cell '__margins' $defaultMargins;$rs=Get-HwpPlanValue $cell 'rowSpan' 1
            $minimum=[int][Math]::Ceiling(((Get-HwpPlanValue $margins 'top' 510)+(Get-HwpPlanValue $margins 'bottom' 510)+1000)/$rs)
            for($r=$cell.row-1;$r -lt $cell.row+$rs-1;$r++){$heights[$r]=[Math]::Max($heights[$r],$minimum)}
        }
    }
    $tableHeight = [int]($heights|Measure-Object -Sum).Sum
    $covered = [Collections.Generic.HashSet[string]]::new()
    foreach ($cell in $Block.cells) {
        $cs = Get-HwpPlanValue $cell 'colSpan' 1; $rs = Get-HwpPlanValue $cell 'rowSpan' 1
        for ($r=$cell.row; $r -lt $cell.row+$rs; $r++) {for ($c=$cell.column; $c -lt $cell.column+$cs; $c++) {if ($r -ne $cell.row -or $c -ne $cell.column) {$null=$covered.Add("${r}:${c}")}}}
    }
    $tableBorderFillId = if ($Block.PSObject.Properties.Name -contains '__borderFillId') { [int]$Block.__borderFillId } else { 3 }
    $cellPadding = if ($Block.PSObject.Properties.Name -contains '__cellPadding') { [int]$Block.__cellPadding } else { 510 }
    $builder = [Text.StringBuilder]::new()
    $repeat = [int][bool](Get-HwpPlanValue $Block 'repeatHeader' $false)
    $null = $builder.Append('<hp:tbl id="').Append($Id).Append('" zOrder="0" numberingType="TABLE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" pageBreak="').Append((Get-HwpPlanValue $Block 'pageBreak' 'CELL')).Append('" repeatHeader="').Append($repeat).Append('" rowCnt="').Append($rows).Append('" colCnt="').Append($columns).Append('" cellSpacing="0" borderFillIDRef="').Append($tableBorderFillId).Append('" noAdjust="0">')
    $null = $builder.Append('<hp:sz width="').Append($tableWidth).Append('" widthRelTo="ABSOLUTE" height="').Append($tableHeight).Append('" heightRelTo="ABSOLUTE" protect="0"/>')
    $null = $builder.Append('<hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/>')
    $null = $builder.Append('<hp:outMargin left="283" right="283" top="283" bottom="283"/><hp:inMargin left="').Append($cellPadding).Append('" right="').Append($cellPadding).Append('" top="').Append($cellPadding).Append('" bottom="').Append($cellPadding).Append('"/>')
    for ($row = 1; $row -le $rows; $row++) {
        $null = $builder.Append('<hp:tr>')
        for ($column = 1; $column -le $columns; $column++) {
            if ($covered.Contains("${row}:${column}")) {continue}
            $cell = Get-HwpxTableCell -Block $Block -Row $row -Column $column
            $cs = Get-HwpPlanValue $cell 'colSpan' 1; $rs = Get-HwpPlanValue $cell 'rowSpan' 1
            $cellWidth = [int]($widths[($column-1)..($column+$cs-2)]|Measure-Object -Sum).Sum
            $cellHeight = [int]($heights[($row-1)..($row+$rs-2)]|Measure-Object -Sum).Sum
            $cellText = if ($null -eq $cell) { '' } else { [string]$cell.text }
            $cellCharPrId = if ($null -ne $cell -and $cell.PSObject.Properties.Name -contains '__charPrId') { [int]$cell.__charPrId } elseif ($Block.PSObject.Properties.Name -contains '__charPrId') { [int]$Block.__charPrId } else { 0 }
            $cellParaPrId = if ($null -ne $cell -and $cell.PSObject.Properties.Name -contains '__paraPrId') { [int]$cell.__paraPrId } elseif ($Block.PSObject.Properties.Name -contains '__paraPrId') { [int]$Block.__paraPrId } else { 0 }
            $cellBorderFillId = if ($null -ne $cell -and $cell.PSObject.Properties.Name -contains '__borderFillId') { [int]$cell.__borderFillId } else { $tableBorderFillId }
            $cellPaddingValue = if ($null -ne $cell -and $cell.PSObject.Properties.Name -contains '__cellPadding') { [int]$cell.__cellPadding } else { $cellPadding }
            $cellParagraph = [Text.StringBuilder]::new()
            $null = $cellParagraph.Append('<hp:p id="0" paraPrIDRef="').Append($cellParaPrId).Append('" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="').Append($cellCharPrId).Append('">')
            Add-HwpxInlineText -Builder $cellParagraph -Text $cellText
            $null = $cellParagraph.Append('</hp:run>').Append((New-HwpxLineSegmentXml -HorizontalSize ([Math]::Max(1000, $cellWidth - (2 * $cellPaddingValue))))).Append('</hp:p>')
            if ($null -ne $cell -and $null -ne $cell.PSObject.Properties['paragraphs']) {
                $null=$cellParagraph.Clear()
                $pi=0
                foreach ($p in $cell.paragraphs) {
                    $runs=Get-HwpPlanValue $p 'runs' @()
                    $null=$cellParagraph.Append((New-HwpxParagraphXml -Id $pi -Text $p.text -Runs @($runs) -CharPrId $p.__charPrId -ParaPrId $p.__paraPrId -StyleId $p.__styleId -HorizontalSize ([Math]::Max(1,$cellWidth-2*$cellPaddingValue))))
                    $pi++
                }
            }
            $null = $builder.Append('<hp:tc name="" header="').Append([int]($row -eq 1 -and $repeat)).Append('" hasMargin="1" protect="0" editable="0" dirty="0" borderFillIDRef="').Append($cellBorderFillId).Append('"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="').Append((Get-HwpPlanValue $cell 'verticalAlignment' 'CENTER')).Append('" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">').Append($cellParagraph.ToString()).Append('</hp:subList><hp:cellAddr colAddr="').Append($column - 1).Append('" rowAddr="').Append($row - 1).Append('"/><hp:cellSpan colSpan="').Append($cs).Append('" rowSpan="').Append($rs).Append('"/><hp:cellSz width="').Append($cellWidth).Append('" height="').Append($cellHeight).Append('"/><hp:cellMargin left="').Append($cellPaddingValue).Append('" right="').Append($cellPaddingValue).Append('" top="').Append($cellPaddingValue).Append('" bottom="').Append($cellPaddingValue).Append('"/></hp:tc>')
        }
        $null = $builder.Append('</hp:tr>')
    }
    $null = $builder.Append((New-HwpxCaptionXml -Block $Block -Width $tableWidth -NumberType 'TABLE' -Number (Get-HwpPlanValue $Block '__captionNumber' 1))).Append('</hp:tbl>')
    [xml]$wrapper='<root xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">'+$builder.ToString()+'</root>'
    $table=$wrapper.DocumentElement.FirstChild
    $table.SelectSingleNode("*[local-name()='pos']").SetAttribute('horzAlign',[string](Get-HwpPlanValue $Block 'alignment' 'LEFT'))
    foreach ($node in $table.SelectNodes("*[local-name()='tr']/*[local-name()='tc']")) {
        $addr=$node.SelectSingleNode("*[local-name()='cellAddr']")
        $cell=Get-HwpxTableCell $Block ([int]$addr.GetAttribute('rowAddr')+1) ([int]$addr.GetAttribute('colAddr')+1)
        $margins=Get-HwpPlanValue $cell '__margins' (Get-HwpPlanValue $Block '__margins')
        if ($null -eq $margins) {continue}
        $margin=$node.SelectSingleNode("*[local-name()='cellMargin']")
        foreach ($side in @('left','right','top','bottom')) {$margin.SetAttribute($side,[string]$margins.$side)}
    }
    $table.OuterXml
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
        [double]$HeightMm = 30,
        [object]$Block = [pscustomobject]@{}
    )

    $width = ConvertTo-HwpxUnit -Millimeter $WidthMm -Default 11339
    $height = ConvertTo-HwpxUnit -Millimeter $HeightMm -Default 8504
    $centerX = [int][Math]::Floor($width / 2)
    $centerY = [int][Math]::Floor($height / 2)
    $comment = ConvertTo-HwpxXmlText -Value ('그림입니다. 원본 그림의 이름: {0}' -f [IO.Path]::GetFileName($OriginalPath))
    $xml = @"
<hp:pic id="$Id" zOrder="0" numberingType="PICTURE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" href="" groupLevel="0" instid="$Id" reverse="0"><hp:offset x="0" y="0"/><hp:orgSz width="$width" height="$height"/><hp:curSz width="$width" height="$height"/><hp:flip horizontal="0" vertical="0"/><hp:rotationInfo angle="0" centerX="$centerX" centerY="$centerY" rotateimage="1"/><hp:renderingInfo><hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/></hp:renderingInfo><hc:img binaryItemIDRef="$ImageId" bright="0" contrast="0" effect="REAL_PIC" alpha="0"/><hp:imgRect><hc:pt0 x="0" y="0"/><hc:pt1 x="$width" y="0"/><hc:pt2 x="$width" y="$height"/><hc:pt3 x="0" y="$height"/></hp:imgRect><hp:imgClip left="0" right="$width" top="0" bottom="$height"/><hp:inMargin left="0" right="0" top="0" bottom="0"/><hp:imgDim dimwidth="$width" dimheight="$height"/><hp:effects/><hp:sz width="$width" widthRelTo="ABSOLUTE" height="$height" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/><hp:outMargin left="0" right="0" top="0" bottom="0"/><hp:shapeComment>$comment</hp:shapeComment></hp:pic><hp:t/>
"@
    Set-HwpxObjectOptions -Xml $xml -Block $Block -Width $width -Height $height
}

function New-HwpxCaptionXml {
    param([object]$Block,[int]$Width,[string]$NumberType='PICTURE',[int]$Number=1)
    if ($null -eq $Block.PSObject.Properties['caption']) {return ''}
    $text=[Text.StringBuilder]::new();Add-HwpxInlineText $text (' '+$Block.caption)
    '<hp:caption side="BOTTOM" fullSz="1" width="{0}" gap="850" lastWidth="{0}"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="TOP" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0"><hp:p id="0" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="0"><hp:ctrl><hp:autoNum num="{1}" numType="{2}"><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar="." supscript="0"/></hp:autoNum></hp:ctrl>{3}</hp:run></hp:p></hp:subList></hp:caption>' -f $Width,$Number,$NumberType,$text.ToString()
}

function New-HwpxSectionXml {
    param(
        [Parameter(Mandatory)][object[]]$Blocks,
        [AllowNull()][object]$PageSettings = $null,
        [int]$SectionIndex = 0,
        [object]$Document = [pscustomobject]@{},
        [string]$SourceVersion = '1.0'
    )

    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><hs:sec ').Append($script:HwpxNamespaceBlock).Append('>')
    $paragraphId = 1
    $controlId = 1000 + $SectionIndex * 10000
    $contentWidth = [int]$PageSettings.columnWidth
    $PageSettings|Add-Member NoteProperty document $Document -Force
    $PageSettings|Add-Member NoteProperty referenceId (1900000+$SectionIndex*1000000) -Force
    $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -IncludeSectionProperties -PageSettings $PageSettings -HorizontalSize $contentWidth))
    $paragraphId++
    $blockIndex=0
    $columnIndex=0
    foreach ($block in $Blocks) {
        if ($block.type -eq 'column-break') {$columnIndex=($columnIndex+1)%$PageSettings.columns.count}
        if ($block.type -eq 'page-break') {$columnIndex=0}
        $contentWidth=if ($PageSettings.columns.widths.Count) {[int]$PageSettings.columns.widths[$columnIndex]} else {[int]$PageSettings.columnWidth}
        $controlId=1000000+$SectionIndex*1000000+$blockIndex*1000
        $blockIndex++
        switch ([string]$block.type) {
            'paragraph' {
                $blockRuns = Get-HwpPlanValue $block 'runs' @()
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -Text ([string]$block.text) -Runs @($blockRuns) -StyleId $block.__styleId `
                    -CharPrId ([int]$block.__charPrId) -ParaPrId ([int]$block.__paraPrId) -HorizontalSize $contentWidth))
            }
            'field' {
                if ($SourceVersion -eq '2.0') {$null=$builder.Append((New-HwpxReferenceBlockXml -Block $block -Id $controlId -Width $contentWidth));break}
                $label = if ($block.PSObject.Properties.Name -contains 'label') { [string]$block.label } else { '' }
                $fieldText = $label + [string]$block.value
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -Text $fieldText `
                    -CharPrId ([int]$block.__charPrId) -ParaPrId ([int]$block.__paraPrId) -HorizontalSize $contentWidth))
            }
            'table' {
                $tableXml = New-HwpxTableXml -Block $block -Id $controlId -AvailableWidth $contentWidth
                $controlId++
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -InlineXml $tableXml `
                    -CharPrId ([int]$block.__charPrId) -ParaPrId ([int]$block.__paraPrId) -HorizontalSize $contentWidth))
            }
            'image' {
                $imageNumber = [int]$block.__hwpxImageNumber
                $imageId = 'image{0}' -f $imageNumber
                $widthMm = if ($block.PSObject.Properties.Name -contains 'widthMm') { [double]$block.widthMm } else { 40 }
                $heightMm = if ($block.PSObject.Properties.Name -contains 'heightMm') { [double]$block.heightMm } else { 30 }
                $pictureXml = New-HwpxPictureXml -Id $controlId -ImageId $imageId -OriginalPath ([string]$block.path) -WidthMm $widthMm -HeightMm $heightMm -Block $block
                $pictureXml=$pictureXml.Replace('</hp:pic>', ((New-HwpxCaptionXml $block (ConvertTo-HwpxUnit $widthMm) 'PICTURE' (Get-HwpPlanValue $block '__captionNumber' $imageNumber))+'</hp:pic>'))
                $controlId++
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -InlineXml $pictureXml `
                    -CharPrId ([int]$block.__charPrId) -ParaPrId ([int]$block.__paraPrId) -HorizontalSize $contentWidth))
            }
            'page-break' {
                $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -PageBreak 1 -HorizontalSize $contentWidth))
            }
            'column-break' { $null=$builder.Append((New-HwpxParagraphXml -Id $paragraphId -ColumnBreak 1 -HorizontalSize $contentWidth)) }
            'shape' {
                $shapeXml=New-HwpxBasicShapeXml -Block $block -Id $controlId
                $shapeTag=switch ($block.shape) {'line' {'line'};'ellipse' {'ellipse'};default {'rect'}}
                $shapeXml=$shapeXml.Replace("</hp:$shapeTag>",((New-HwpxCaptionXml $block (ConvertTo-HwpxUnit $block.widthMm) 'PICTURE' (Get-HwpPlanValue $block '__captionNumber' 1))+"</hp:$shapeTag>"))
                $controlId++
                $null=$builder.Append((New-HwpxParagraphXml -Id $paragraphId -InlineXml $shapeXml -HorizontalSize $contentWidth))
            }
            {$_ -in @('bookmark','hyperlink','footnote','endnote','toc')} {
                $null=$builder.Append((New-HwpxReferenceBlockXml -Block $block -Id $controlId -Width $contentWidth))
            }
        }
        $paragraphId++
    }
    $null = $builder.Append((New-HwpxParagraphXml -Id $paragraphId -HorizontalSize $contentWidth))
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
        [Parameter(Mandatory)][int]$ImageCount,
        [int]$SectionCount = 1
    )

    $items = [Text.StringBuilder]::new()
    $null = $items.Append('<opf:item id="header" href="Contents/header.xml" media-type="application/xml"/>')
    for ($index = 1; $index -le $ImageCount; $index++) {
        $null = $items.Append('<opf:item id="image').Append($index).Append('" href="BinData/image').Append($index).Append('.').Append('{0}' -f $script:HwpxImageExtensions[$index - 1]).Append('" media-type="').Append((Get-HwpxImageMediaType -Extension $script:HwpxImageExtensions[$index - 1])).Append('" isEmbeded="1"/>')
    }
    $spine = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $SectionCount; $index++) {
        $null = $items.Append(('<opf:item id="section{0}" href="Contents/section{0}.xml" media-type="application/xml"/>' -f $index))
        $null = $spine.Append(('<opf:itemref idref="section{0}" linear="yes"/>' -f $index))
    }
    $null = $items.Append('<opf:item id="settings" href="settings.xml" media-type="application/xml"/>')
    $safeTitle = ConvertTo-HwpxXmlText -Value $Title
    @"
<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><opf:package $script:HwpxNamespaceBlock version="" unique-identifier="" id=""><opf:metadata><opf:title>$safeTitle</opf:title><opf:language>ko</opf:language><opf:meta name="creator" content="text">hwp-skill</opf:meta><opf:meta name="subject" content="text"/><opf:meta name="description" content="text"/><opf:meta name="lastsaveby" content="text">hwp-skill</opf:meta><opf:meta name="keyword" content="text"/></opf:metadata><opf:manifest>$($items.ToString())</opf:manifest><opf:spine><opf:itemref idref="header" linear="yes"/>$($spine.ToString())</opf:spine></opf:package>
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
    if ($Plan.PSObject.Properties.Name -notcontains 'sourceVersion') {
        $validation=Test-HwpAuthoringPlan -Plan $Plan
        if($validation.Status -ne 'PASS'){return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @($validation.Errors)}
        $Plan = ConvertTo-HwpAuthoringPlan -Plan $Plan
    }
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
            Test-HwpxRasterIntegrity -Path $imagePath | Out-Null
            $copy = [pscustomobject]@{}
            foreach ($property in $block.PSObject.Properties) { $copy | Add-Member NoteProperty $property.Name $property.Value }
            $copy | Add-Member NoteProperty path $imagePath -Force
            $copy | Add-Member NoteProperty __hwpxImageNumber ($imageBlocks.Count + 1) -Force
            if ($Plan.sourceVersion -eq '2.0') {
                $size=Get-HwpxRasterSize -Path $imagePath
                $w=Get-HwpPlanValue $copy 'widthMm';$h=Get-HwpPlanValue $copy 'heightMm'
                if (($null -eq $w -or $null -eq $h) -and $null -eq $size) {throw '이 이미지 형식은 너비와 높이를 모두 지정해야 합니다.'}
                if ($null -eq $w -and $null -eq $h) {$w=40}
                if ($null -eq $w) {$w=$h*$size.width/$size.height}
                if ($null -eq $h) {$h=$w*$size.height/$size.width}
                $copy | Add-Member NoteProperty widthMm $w -Force
                $copy | Add-Member NoteProperty heightMm $h -Force
            }
            $imageBlocks.Add($copy)
            $imageExtensions.Add($extension)
        }
        catch {
            return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @($_.Exception.Message)
        }
    }

    $script:HwpxImageExtensions = @($imageExtensions)
    # Resolve omitted image dimensions before accepting parent-area constraints.
    $imageIndex=0
    foreach ($section in $Plan.sections) {
        $page=Get-HwpPlanValue $section.document 'page'
        $landscape=(Get-HwpPlanValue $page 'orientation' 'PORTRAIT') -eq 'LANDSCAPE'
        $m=Get-HwpPlanValue $page 'margins';$g=Get-HwpPlanValue $m 'gutterMm' 0
        $topGutter=(Get-HwpPlanValue $page 'gutterType' 'LEFT_ONLY') -eq 'TOP_ONLY'
        $bodyWidth=(Get-HwpPlanValue $page 'widthMm' $(if($landscape){297}else{210}))-(Get-HwpPlanValue $m 'leftMm' 15)-(Get-HwpPlanValue $m 'rightMm' 15)-$(if($topGutter){0}else{$g})
        $bodyHeight=(Get-HwpPlanValue $page 'heightMm' $(if($landscape){210}else{297}))-(Get-HwpPlanValue $m 'topMm' 10)-(Get-HwpPlanValue $m 'bottomMm' 10)-(Get-HwpPlanValue $m 'headerMm' 15)-(Get-HwpPlanValue $m 'footerMm' 15)-$(if($topGutter){$g}else{0})
        $columns=Get-HwpPlanValue $section.document 'columns';$count=Get-HwpPlanValue $columns 'count' 1
        $widths=Get-HwpPlanValue $columns 'widthsMm'
        $columnIndex=0
        foreach ($block in $section.content) {
            if ($block.type -eq 'column-break') {$columnIndex=($columnIndex+1)%$count}
            if ($block.type -eq 'page-break') {$columnIndex=0}
            $available=if ($null -ne $widths) {$widths[$columnIndex]} else {($bodyWidth-($count-1)*(Get-HwpPlanValue $columns 'gapMm' 0))/$count}
            if ($block.type -ne 'image') {continue}
            $image=$imageBlocks[$imageIndex];$imageIndex++
            if ((Get-HwpPlanValue (Get-HwpPlanValue $image 'placement') 'treatAsChar' $true) -and
                ((Get-HwpPlanValue $image 'widthMm' 40) -gt $available+0.02 -or (Get-HwpPlanValue $image 'heightMm' 30) -gt $bodyHeight+0.02)) {
                return New-HwpResult -Status BLOCKED -Command generate-hwpx -Errors @('그림의 계산된 치수가 부모 영역을 초과합니다. 너비/높이 또는 배치를 명시하십시오.')
            }
        }
    }
    $stagingPath = [IO.Path]::Combine($directory, ('{0}.{1}.partial.hwpx' -f [IO.Path]::GetFileNameWithoutExtension($resolvedOutput), [guid]::NewGuid().ToString('n')))
    $sourceStream = $null
    $sourceArchive = $null
    $targetStream = $null
    $targetArchive = $null
    $generationFailed = $false
    try {
        $imageCursor = 0
        $selectedBlocks = foreach ($block in @($Plan.content)) {
            if ([string]$block.type -eq 'image') {
                $imageCursor++
                $imageBlocks[$imageCursor - 1]
            }
            else { $block }
        }
        $normalizedBlocks = @(Copy-HwpxStyledBlocks -Blocks @($selectedBlocks))
        $numbers=@{table=0;picture=0;footnote=0;endnote=0}
        foreach ($block in $normalizedBlocks) {
            $kind=if($block.type -in @('image','shape')) {'picture'} else {$block.type}
            if (-not $numbers.ContainsKey($kind)) {continue}
            $numbers[$kind]++
            if ($kind -in @('footnote','endnote')) {
                if ($null -ne $block.PSObject.Properties['number']) {$numbers[$kind]=[int]$block.number}
                else {$block|Add-Member NoteProperty number $numbers[$kind]}
            } else {$block|Add-Member NoteProperty __captionNumber $numbers[$kind]}
        }
        $title = [IO.Path]::GetFileNameWithoutExtension($resolvedOutput)
        if ($Plan.PSObject.Properties.Name -contains 'title' -and -not [string]::IsNullOrWhiteSpace([string]$Plan.title)) { $title = [string]$Plan.title }
        $contentXml = New-HwpxContentPackageXml -Title $title -ImageCount $imageExtensions.Count -SectionCount @($Plan.sections).Count

        $sourceStream = [IO.File]::Open($resolvedTemplate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $sourceArchive = [IO.Compression.ZipArchive]::new($sourceStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        $targetStream = [IO.File]::Create($stagingPath)
        Initialize-HwpxZipStream -Stream $targetStream
        $targetArchive = [IO.Compression.ZipArchive]::new($targetStream, [IO.Compression.ZipArchiveMode]::Update, $false)
        $sourceMap = @{}
        foreach ($entry in $sourceArchive.Entries) { $sourceMap[$entry.FullName] = $entry }
        foreach ($name in @('version.xml')) {
            if ($sourceMap.ContainsKey($name)) {
                Copy-HwpxZipEntry -Source $sourceMap[$name] -TargetArchive $targetArchive -Name $name -CompressionLevel ([IO.Compression.CompressionLevel]::NoCompression)
            }
        }
        $headerEntry = $sourceMap['Contents/header.xml']
        $headerReader = [IO.StreamReader]::new($headerEntry.Open(), [Text.Encoding]::UTF8, $true)
        try { $headerXml = $headerReader.ReadToEnd() } finally { $headerReader.Dispose() }
        $headerXml = Add-HwpxGridBorderFill -HeaderXml $headerXml
        $sharedRegistry = $null
        $cursor = 0
        for ($s = 0; $s -lt @($Plan.sections).Count; $s++) {
            $section = $Plan.sections[$s]
            $count = @($section.content).Count
            $sectionBlocks = @($normalizedBlocks[$cursor..($cursor + $count - 1)])
            $cursor += $count
            $styleContext = Initialize-HwpxStyleContext -Plan $section -Blocks $sectionBlocks -HeaderXml $headerXml -Registry $sharedRegistry
            $sharedRegistry = $styleContext.registry
            $headerXml = $styleContext.HeaderXml
            $sectionXml = New-HwpxSectionXml -Blocks @($styleContext.Blocks) -PageSettings $styleContext.Page -SectionIndex $s -Document $section.document -SourceVersion $Plan.sourceVersion
            # These are renderer caches, not layout instructions. A fixed 10pt/160%
            # cache is false for arbitrary text, fonts and paragraph spacing in V1 too.
            $sectionXml=[regex]::Replace($sectionXml,'<hp:linesegarray>.*?</hp:linesegarray>','')
            Write-HwpxZipTextEntry -Archive $targetArchive -Name ('Contents/section{0}.xml' -f $s) -Text $sectionXml
        }
        $headerXml = [regex]::Replace($headerXml, '(\bsecCnt=")\d+(" )', ('${1}' + @($Plan.sections).Count + '$2'))
        $headerXml = [regex]::Replace($headerXml, '(\bsecCnt=")\d+("\s*>)', ('${1}' + @($Plan.sections).Count + '$2'))
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'Contents/header.xml' -Text $headerXml
        Write-HwpxZipTextEntry -Archive $targetArchive -Name 'Contents/content.hpf' -Text $contentXml
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
            if ($entry.FullName -in @('mimetype','version.xml','Contents/header.xml','Contents/content.hpf','Preview/PrvText.txt','settings.xml') -or $entry.FullName -match '^BinData/|^Preview/PrvImage\.|^Contents/section\d+\.xml$') { continue }
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
