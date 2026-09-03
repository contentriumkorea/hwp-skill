Set-StrictMode -Version Latest

function Test-HwpxStyleProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    $null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-HwpxStyleValue {
    param(
        [AllowNull()][object]$Primary,
        [AllowNull()][object]$Fallback,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Default
    )
    if (Test-HwpxStyleProperty -InputObject $Primary -Name $Name) { return $Primary.$Name }
    if (Test-HwpxStyleProperty -InputObject $Fallback -Name $Name) { return $Fallback.$Name }
    $Default
}

function ConvertTo-HwpxStyleUnit {
    param([Parameter(Mandatory)][double]$Millimeter)
    [int][Math]::Round($Millimeter * 283.4645669)
}

function ConvertTo-HwpxStyleXmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    [Security.SecurityElement]::Escape([string]$Value)
}

function Copy-HwpxStyledBlocks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Blocks)

    $copies = [Collections.Generic.List[object]]::new()
    foreach ($block in $Blocks) {
        $copy = [pscustomobject]@{}
        foreach ($property in $block.PSObject.Properties) {
            if ($property.Name -eq 'cells' -and $null -ne $property.Value) {
                $cells = [Collections.Generic.List[object]]::new()
                foreach ($cell in @($property.Value)) {
                    $cellCopy = [pscustomobject]@{}
                    foreach ($cellProperty in $cell.PSObject.Properties) {
                        $cellCopy | Add-Member NoteProperty $cellProperty.Name $cellProperty.Value
                    }
                    $cells.Add($cellCopy)
                }
                $copy | Add-Member NoteProperty cells @($cells)
            }
            else {
                $copy | Add-Member NoteProperty $property.Name $property.Value
            }
        }
        $copies.Add($copy)
    }
    @($copies)
}

function Get-HwpxNormalizedTextStyle {
    param([AllowNull()][object]$Fallback, [AllowNull()][object]$Primary)
    if ($null -eq $Fallback -and $null -eq $Primary) { return $null }
    [pscustomobject][ordered]@{
        fontFamily = [string](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'fontFamily' -Default '함초롬바탕')
        fontSizePt = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'fontSizePt' -Default 10)
        bold = [bool](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'bold' -Default $false)
        italic = [bool](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'italic' -Default $false)
        underline = [string](Get-HwpxStyleValue $Primary $Fallback 'underline' 'NONE')
        strikeout = [bool](Get-HwpxStyleValue $Primary $Fallback 'strikeout' $false)
        superscript = [bool](Get-HwpxStyleValue $Primary $Fallback 'superscript' $false)
        subscript = [bool](Get-HwpxStyleValue $Primary $Fallback 'subscript' $false)
        letterSpacingPercent = [int](Get-HwpxStyleValue $Primary $Fallback 'letterSpacingPercent' 0)
        widthPercent = [int](Get-HwpxStyleValue $Primary $Fallback 'widthPercent' 100)
        textColor = ([string](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'textColor' -Default '#000000')).ToUpperInvariant()
    }
}

function Get-HwpxNormalizedParagraphStyle {
    param([AllowNull()][object]$Fallback, [AllowNull()][object]$Primary)
    if ($null -eq $Fallback -and $null -eq $Primary) { return $null }
    [pscustomobject][ordered]@{
        alignment = ([string](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'alignment' -Default 'JUSTIFY')).ToUpperInvariant()
        lineSpacingPercent = [int](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'lineSpacingPercent' -Default 160)
        marginBeforeMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'marginBeforeMm' -Default 0)
        marginAfterMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'marginAfterMm' -Default 0)
        leftMarginMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'leftMarginMm' -Default 0)
        rightMarginMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'rightMarginMm' -Default 0)
        indentMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'indentMm' -Default 0)
        keepWithNext = [bool](Get-HwpxStyleValue $Primary $Fallback 'keepWithNext' $false)
        keepLines = [bool](Get-HwpxStyleValue $Primary $Fallback 'keepLines' $false)
        widowOrphan = [bool](Get-HwpxStyleValue $Primary $Fallback 'widowOrphan' $false)
        pageBreakBefore = [bool](Get-HwpxStyleValue $Primary $Fallback 'pageBreakBefore' $false)
        lineSpacing = if (Test-HwpxStyleProperty $Primary 'lineSpacingPercent') {Get-HwpxStyleValue $Primary $null 'lineSpacing' $null} else {Get-HwpxStyleValue $Primary $Fallback 'lineSpacing' $null}
        tabs = Get-HwpxStyleValue $Primary $Fallback 'tabs' $null
        list = Get-HwpxStyleValue $Primary $Fallback 'list' $null
    }
}

function Get-HwpxNormalizedTableStyle {
    param([AllowNull()][object]$Fallback, [AllowNull()][object]$Primary)
    if ($null -eq $Fallback -and $null -eq $Primary) { return $null }
    [pscustomobject][ordered]@{
        borderType = ([string](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'borderType' -Default 'SOLID')).ToUpperInvariant()
        borderWidthMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'borderWidthMm' -Default 0.12)
        borderColor = ([string](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'borderColor' -Default '#000000')).ToUpperInvariant()
        fillColor = ([string](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'fillColor' -Default 'none'))
        cellPaddingMm = [double](Get-HwpxStyleValue -Primary $Primary -Fallback $Fallback -Name 'cellPaddingMm' -Default 1.8)
        borders = Merge-HwpxStyleObject (Get-HwpxStyleValue $Fallback $null 'borders' $null) (Get-HwpxStyleValue $Primary $null 'borders' $null)
        cellMargins = Merge-HwpxStyleObject (Get-HwpxStyleValue $Fallback $null 'cellMargins' $null) (Get-HwpxStyleValue $Primary $null 'cellMargins' $null)
    }
}

function Merge-HwpxStyleObject {
    param([AllowNull()][object]$Fallback,[AllowNull()][object]$Primary)
    if ($null -eq $Fallback -and $null -eq $Primary) {return $null}
    $merged=[pscustomobject]@{}
    foreach ($source in @($Fallback,$Primary)) {
        if ($null -eq $source) {continue}
        foreach ($property in $source.PSObject.Properties) {
            $value=$property.Value
            if ($value -is [pscustomobject]) {$value=Merge-HwpxStyleObject (Get-HwpxStyleValue $merged $null $property.Name $null) $value}
            $merged | Add-Member NoteProperty $property.Name $value -Force
        }
    }
    return $merged
}

function Get-HwpxMaximumResourceId {
    param([Parameter(Mandatory)][Xml.XmlDocument]$Document, [Parameter(Mandatory)][string]$LocalName)
    $maximum = -1
    foreach ($node in @($Document.SelectNodes("//*[local-name()='$LocalName']"))) {
        $raw = [string]$node.GetAttribute('id')
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -gt $maximum) { $maximum = $value }
    }
    $maximum
}

function New-HwpxStyleRegistry {
    param([Parameter(Mandatory)][string]$HeaderXml)
    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $false
    $document.XmlResolver = $null
    $document.LoadXml($HeaderXml)
    $fontMap = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($fontFace in @($document.SelectNodes("//*[local-name()='fontface']"))) {
        if ([string]$fontFace.GetAttribute('lang') -ne 'HANGUL') { continue }
        foreach ($font in @($fontFace.SelectNodes("./*[local-name()='font']"))) {
            $id = 0
            if ([int]::TryParse([string]$font.GetAttribute('id'), [ref]$id)) {
                $name = [string]$font.GetAttribute('face')
                if (-not $fontMap.ContainsKey($name)) { $fontMap.Add($name, $id) }
            }
        }
    }
    [pscustomobject]@{
        HeaderXml = $HeaderXml
        FontMap = $fontMap
        NewFonts = [Collections.Generic.List[object]]::new()
        NextFontId = (Get-HwpxMaximumResourceId -Document $document -LocalName 'font') + 1
        TextStyleIds = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        TextStyles = [Collections.Generic.List[object]]::new()
        NextCharShapeId = (Get-HwpxMaximumResourceId -Document $document -LocalName 'charPr') + 1
        ParagraphStyleIds = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        ParagraphStyles = [Collections.Generic.List[object]]::new()
        NextParaShapeId = (Get-HwpxMaximumResourceId -Document $document -LocalName 'paraPr') + 1
        TableStyleIds = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        TableStyles = [Collections.Generic.List[object]]::new()
        NextBorderFillId = (Get-HwpxMaximumResourceId -Document $document -LocalName 'borderFill') + 1
        NextTabId = (Get-HwpxMaximumResourceId -Document $document -LocalName 'tabPr') + 1
        NextNumberId = [Math]::Max(1,(Get-HwpxMaximumResourceId -Document $document -LocalName 'numbering') + 1)
        NextBulletId = [Math]::Max(1,(Get-HwpxMaximumResourceId -Document $document -LocalName 'bullet') + 1)
        Tabs = [Collections.Generic.List[object]]::new()
        Lists = [Collections.Generic.List[object]]::new()
        NextStyleId = (Get-HwpxMaximumResourceId -Document $document -LocalName 'style') + 1
        NamedStyles = [Collections.Generic.List[object]]::new()
        NamedStyleIds = @{}
    }
}

function Register-HwpxFont {
    param([Parameter(Mandatory)][object]$Registry, [Parameter(Mandatory)][string]$FontFamily)
    if ($Registry.FontMap.ContainsKey($FontFamily)) { return $Registry.FontMap[$FontFamily] }
    $id = [int]$Registry.NextFontId
    $Registry.NextFontId++
    $Registry.FontMap.Add($FontFamily, $id)
    $Registry.NewFonts.Add([pscustomobject]@{ id = $id; name = $FontFamily })
    $id
}

function Register-HwpxTextStyle {
    param([Parameter(Mandatory)][object]$Registry, [AllowNull()][object]$Style)
    if ($null -eq $Style) { return 0 }
    $key = $Style | ConvertTo-Json -Depth 10 -Compress
    if ($Registry.TextStyleIds.ContainsKey($key)) { return $Registry.TextStyleIds[$key] }
    $id = [int]$Registry.NextCharShapeId
    $Registry.NextCharShapeId++
    $fontId = Register-HwpxFont -Registry $Registry -FontFamily ([string]$Style.fontFamily)
    $Registry.TextStyleIds.Add($key, $id)
    $Registry.TextStyles.Add([pscustomobject]@{ id = $id; fontId = $fontId; style = $Style })
    $id
}

function Register-HwpxParagraphStyle {
    param([Parameter(Mandatory)][object]$Registry, [AllowNull()][object]$Style)
    if ($null -eq $Style) { return 0 }
    $key = $Style | ConvertTo-Json -Depth 10 -Compress
    if ($Registry.ParagraphStyleIds.ContainsKey($key)) { return $Registry.ParagraphStyleIds[$key] }
    $id = [int]$Registry.NextParaShapeId
    $Registry.NextParaShapeId++
    $Registry.ParagraphStyleIds.Add($key, $id)
    $tabId=0;$listId=0
    if ($null -ne $Style.tabs) {$tabId=$Registry.NextTabId++;$Registry.Tabs.Add([pscustomobject]@{id=$tabId;items=$Style.tabs})}
    if ($null -ne $Style.list) {
        if ($Style.list.type -eq 'BULLET') {$listId=$Registry.NextBulletId; $Registry.NextBulletId++}
        else {$listId=$Registry.NextNumberId; $Registry.NextNumberId++}
        $Registry.Lists.Add([pscustomobject]@{id=$listId;style=$Style.list})
    }
    $Registry.ParagraphStyles.Add([pscustomobject]@{ id = $id; style = $Style;tabId=$tabId;listId=$listId })
    $id
}

function Register-HwpxTableStyle {
    param([Parameter(Mandatory)][object]$Registry, [AllowNull()][object]$Style)
    if ($null -eq $Style) { return 3 }
    $fillColor = if ([string]::IsNullOrWhiteSpace([string]$Style.fillColor)) { 'none' } else { ([string]$Style.fillColor).ToUpperInvariant() }
    $key = $Style | ConvertTo-Json -Depth 10 -Compress
    if ($Registry.TableStyleIds.ContainsKey($key)) { return $Registry.TableStyleIds[$key] }
    $id = [int]$Registry.NextBorderFillId
    $Registry.NextBorderFillId++
    $Registry.TableStyleIds.Add($key, $id)
    $Registry.TableStyles.Add([pscustomobject]@{ id = $id; style = $Style; fillColor = $fillColor })
    $id
}

function Add-HwpxInternalProperty {
    param([Parameter(Mandatory)][object]$Target, [Parameter(Mandatory)][string]$Name, [AllowNull()][object]$Value)
    $Target | Add-Member NoteProperty $Name $Value -Force
}

function Add-HwpxHeaderCollection {
    param(
        [Parameter(Mandatory)][string]$HeaderXml,
        [Parameter(Mandatory)][string]$CollectionName,
        [Parameter(Mandatory)][string]$ClosingTag,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ItemsXml,
        [Parameter(Mandatory)][int]$AddCount
    )
    if ($AddCount -eq 0) { return $HeaderXml }
    $pattern = '(<hh:{0}\b[^>]*itemCnt=")(\d+)(")' -f [regex]::Escape($CollectionName)
    $updated = [regex]::Replace($HeaderXml, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $match.Groups[1].Value + ([int]$match.Groups[2].Value + $AddCount) + $match.Groups[3].Value
    }, 1)
    if ($updated -eq $HeaderXml) { throw "HWPX header.xml에서 $CollectionName 컬렉션을 찾지 못했습니다." }
    $updated.Replace($ClosingTag, $ItemsXml + $ClosingTag)
}

function Add-HwpxFontsToHeader {
    param([Parameter(Mandatory)][string]$HeaderXml, [Parameter(Mandatory)][object]$Registry)
    if ($Registry.NewFonts.Count -eq 0) { return $HeaderXml }
    $pattern = '(?s)(<hh:fontface\b[^>]*fontCnt=")(\d+)("[^>]*>)(.*?)(</hh:fontface>)'
    [regex]::Replace($HeaderXml, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $items = [Text.StringBuilder]::new()
        foreach ($font in $Registry.NewFonts) {
            $safeName = ConvertTo-HwpxStyleXmlText -Value $font.name
            $null = $items.Append('<hh:font id="').Append($font.id).Append('" face="').Append($safeName).Append('" type="TTF" isEmbedded="0"><hh:typeInfo familyType="FCAT_GOTHIC" weight="6" proportion="4" contrast="0" strokeVariation="1" armStyle="1" letterform="1" midline="1" xHeight="1"/></hh:font>')
        }
        $match.Groups[1].Value + ([int]$match.Groups[2].Value + $Registry.NewFonts.Count) +
            $match.Groups[3].Value + $match.Groups[4].Value + $items.ToString() + $match.Groups[5].Value
    })
}

function Get-HwpxTextStylesXml {
    param([Parameter(Mandatory)][object]$Registry)
    $builder = [Text.StringBuilder]::new()
    foreach ($entry in $Registry.TextStyles) {
        $style = $entry.style
        $height = [int][Math]::Round([double]$style.fontSizePt * 100)
        $null = $builder.Append('<hh:charPr id="').Append($entry.id).Append('" height="').Append($height).Append('" textColor="').Append($style.textColor).Append('" shadeColor="none" useFontSpace="0" useKerning="0" symMark="NONE" borderFillIDRef="2">')
        $null = $builder.Append('<hh:fontRef hangul="').Append($entry.fontId).Append('" latin="').Append($entry.fontId).Append('" hanja="').Append($entry.fontId).Append('" japanese="').Append($entry.fontId).Append('" other="').Append($entry.fontId).Append('" symbol="').Append($entry.fontId).Append('" user="').Append($entry.fontId).Append('"/>')
        foreach ($property in @('ratio','spacing','relSz','offset')) {
            $value = switch ($property) {'ratio' {$style.widthPercent};'spacing' {$style.letterSpacingPercent};'relSz' {100};'offset' {0}}
            $null = $builder.Append('<hh:').Append($property)
            foreach ($lang in @('hangul','latin','hanja','japanese','other','symbol','user')) { $null = $builder.Append(' ').Append($lang).Append('="').Append($value).Append('"') }
            $null = $builder.Append('/>')
        }
        if ($style.italic) { $null = $builder.Append('<hh:italic/>') }
        if ($style.bold) { $null = $builder.Append('<hh:bold/>') }
        $null = $builder.Append('<hh:underline type="').Append($style.underline).Append('" shape="SOLID" color="').Append($style.textColor).Append('"/><hh:strikeout shape="').Append($(if ($style.strikeout) {'SOLID'} else {'NONE'})).Append('" color="').Append($style.textColor).Append('"/><hh:outline type="NONE"/><hh:shadow type="NONE" color="#C0C0C0" offsetX="10" offsetY="10"/>')
        if ($style.superscript) { $null = $builder.Append('<hh:supscript/>') }
        if ($style.subscript) { $null = $builder.Append('<hh:subscript/>') }
        $null = $builder.Append('</hh:charPr>')
    }
    $builder.ToString()
}

function Get-HwpxParagraphStylesXml {
    param([Parameter(Mandatory)][object]$Registry)
    $builder = [Text.StringBuilder]::new()
    foreach ($entry in $Registry.ParagraphStyles) {
        $style = $entry.style
        $intent = ConvertTo-HwpxStyleUnit -Millimeter $style.indentMm
        $left = ConvertTo-HwpxStyleUnit -Millimeter $style.leftMarginMm
        $right = ConvertTo-HwpxStyleUnit -Millimeter $style.rightMarginMm
        $before = ConvertTo-HwpxStyleUnit -Millimeter $style.marginBeforeMm
        $after = ConvertTo-HwpxStyleUnit -Millimeter $style.marginAfterMm
        $null = $builder.Append('<hh:paraPr id="').Append($entry.id).Append('" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0" textDir="LTR"><hh:align horizontal="').Append($style.alignment).Append('" vertical="BASELINE"/><hh:heading type="NONE" idRef="0" level="0"/><hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="KEEP_WORD" widowOrphan="').Append([int]$style.widowOrphan).Append('" keepWithNext="').Append([int]$style.keepWithNext).Append('" keepLines="').Append([int]$style.keepLines).Append('" pageBreakBefore="').Append([int]$style.pageBreakBefore).Append('" lineWrap="BREAK"/><hh:autoSpacing eAsianEng="0" eAsianNum="0"/><hh:margin>')
        $null = $builder.Append('<hc:intent value="').Append($intent).Append('" unit="HWPUNIT"/><hc:left value="').Append($left).Append('" unit="HWPUNIT"/><hc:right value="').Append($right).Append('" unit="HWPUNIT"/><hc:prev value="').Append($before).Append('" unit="HWPUNIT"/><hc:next value="').Append($after).Append('" unit="HWPUNIT"/></hh:margin>')
        $spacingType=if ($null -eq $style.lineSpacing) {'PERCENT'} else {$style.lineSpacing.type}
        $spacingValue=if ($null -eq $style.lineSpacing) {$style.lineSpacingPercent} else {[int][Math]::Round($style.lineSpacing.valuePt*100)}
        $null = $builder.Append('<hh:lineSpacing type="').Append($spacingType).Append('" value="').Append($spacingValue).Append('" unit="HWPUNIT"/><hh:border borderFillIDRef="2" offsetLeft="0" offsetRight="0" offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/></hh:paraPr>')
    }
    [xml]$root='<root xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core">'+$builder.ToString()+'</root>'
    foreach ($entry in $Registry.ParagraphStyles) {
        $node=$root.DocumentElement.SelectSingleNode("*[local-name()='paraPr' and @id='$($entry.id)']")
        $node.SetAttribute('tabPrIDRef',[string]$entry.tabId)
        if ($null -ne $entry.style.list) {
            $heading=$node.SelectSingleNode("*[local-name()='heading']");$heading.SetAttribute('type',[string]$entry.style.list.type)
            $heading.SetAttribute('idRef',[string]$entry.listId);$heading.SetAttribute('level',[string]([int](Get-HwpxStyleValue $entry.style.list $null 'level' 1)-1))
        }
    }
    $root.DocumentElement.InnerXml
}

function Get-HwpxTableStylesXml {
    param([Parameter(Mandatory)][object]$Registry)
    $builder = [Text.StringBuilder]::new()
    foreach ($entry in $Registry.TableStyles) {
        $style = $entry.style
        $width = ([double]$style.borderWidthMm).ToString('0.0#', [Globalization.CultureInfo]::InvariantCulture) + ' mm'
        $null = $builder.Append('<hh:borderFill id="').Append($entry.id).Append('" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0"><hh:slash type="NONE" Crooked="0" isCounter="0"/><hh:backSlash type="NONE" Crooked="0" isCounter="0"/>')
        foreach ($side in @('leftBorder','rightBorder','topBorder','bottomBorder')) {
            $sideStyle=Get-HwpxStyleValue $style.borders $null ($side.Replace('Border','')) $null
            $sideWidth=([double](Get-HwpxStyleValue $sideStyle $null 'widthMm' $style.borderWidthMm)).ToString('0.0#',[Globalization.CultureInfo]::InvariantCulture)+' mm'
            $null = $builder.Append('<hh:').Append($side).Append(' type="').Append((Get-HwpxStyleValue $sideStyle $null 'type' $style.borderType)).Append('" width="').Append($sideWidth).Append('" color="').Append((Get-HwpxStyleValue $sideStyle $null 'color' $style.borderColor)).Append('"/>')
        }
        $null = $builder.Append('<hh:diagonal type="NONE" width="0.1 mm" color="#000000"/>')
        if ($entry.fillColor -ne 'NONE' -and $entry.fillColor -ne 'none') {
            $null = $builder.Append('<hc:fillBrush><hc:winBrush faceColor="').Append($entry.fillColor).Append('" hatchColor="#000000" alpha="0"/></hc:fillBrush>')
        }
        $null = $builder.Append('</hh:borderFill>')
    }
    $builder.ToString()
}

function Apply-HwpxStyleRegistryToHeader {
    param([Parameter(Mandatory)][object]$Registry)
    $header = Add-HwpxFontsToHeader -HeaderXml $Registry.HeaderXml -Registry $Registry
    $header = Add-HwpxHeaderCollection -HeaderXml $header -CollectionName 'charProperties' -ClosingTag '</hh:charProperties>' `
        -ItemsXml (Get-HwpxTextStylesXml -Registry $Registry) -AddCount $Registry.TextStyles.Count
    $header = Add-HwpxHeaderCollection -HeaderXml $header -CollectionName 'paraProperties' -ClosingTag '</hh:paraProperties>' `
        -ItemsXml (Get-HwpxParagraphStylesXml -Registry $Registry) -AddCount $Registry.ParagraphStyles.Count
    $header = Add-HwpxHeaderCollection -HeaderXml $header -CollectionName 'borderFills' -ClosingTag '</hh:borderFills>' `
        -ItemsXml (Get-HwpxTableStylesXml -Registry $Registry) -AddCount $Registry.TableStyles.Count
    if ($Registry.Tabs.Count) {
        $items=foreach ($entry in $Registry.Tabs) {
            $tabItems=foreach ($tab in $entry.items) {
                '<hh:tabItem pos="{0}" type="{1}" leader="{2}" unit="HWPUNIT"/>' -f (ConvertTo-HwpxStyleUnit $tab.positionMm), (Get-HwpxStyleValue $tab $null 'alignment' 'LEFT'), (Get-HwpxStyleValue $tab $null 'leader' 'NONE')
            }
            '<hh:tabPr id="{0}" autoTabLeft="0" autoTabRight="0">{1}</hh:tabPr>' -f $entry.id, ($tabItems -join '')
        }
        $header=Add-HwpxHeaderCollection $header 'tabProperties' '</hh:tabProperties>' ($items-join '') $Registry.Tabs.Count
    }
    foreach ($kind in @('NUMBER','BULLET')) {
        $entries=@($Registry.Lists | Where-Object {if ($kind -eq 'BULLET') {$_.style.type -eq 'BULLET'} else {$_.style.type -ne 'BULLET'}})
        if (-not $entries.Count) {continue}
        $items=foreach ($entry in $entries) {
            $start=Get-HwpxStyleValue $entry.style $null 'start' 1
            if ($kind -eq 'BULLET') {
                $char=ConvertTo-HwpxStyleXmlText (Get-HwpxStyleValue $entry.style $null 'character' '•')
                '<hh:bullet id="{0}" char="{1}" useImage="0"><hh:paraHead level="1" align="LEFT" useInstWidth="1" autoIndent="1" widthAdjust="0" textOffsetType="PERCENT" textOffset="50" numFormat="DIGIT" charPrIDRef="4294967295" checkable="0"/></hh:bullet>' -f $entry.id,$char
            } else {
                $heads=1..7|ForEach-Object {'<hh:paraHead start="{0}" level="{1}" align="LEFT" useInstWidth="1" autoIndent="1" widthAdjust="0" textOffsetType="PERCENT" textOffset="50" numFormat="DIGIT" charPrIDRef="4294967295" checkable="0">^{1}.</hh:paraHead>' -f $start,$_}
                '<hh:numbering id="{0}" start="{1}">{2}</hh:numbering>' -f $entry.id,$start,($heads-join '')
            }
        }
        $collection=if ($kind -eq 'BULLET') {'bullets'} else {'numberings'}
        if ($header -notmatch "<hh:$collection\b") {
            $header=$header.Replace('<hh:paraProperties', ('<hh:{0} itemCnt="{1}">{2}</hh:{0}><hh:paraProperties' -f $collection,$entries.Count,($items-join '')))
        } else {$header=Add-HwpxHeaderCollection $header $collection ('</hh:{0}>' -f $collection) ($items-join '') $entries.Count}
    }
    if ($Registry.NamedStyles.Count) {
        $items=foreach ($entry in $Registry.NamedStyles) {'<hh:style id="{0}" type="PARA" name="{1}" engName="" paraPrIDRef="{2}" charPrIDRef="{3}" nextStyleIDRef="{0}" langID="1042" lockForm="0"/>' -f $entry.id,(ConvertTo-HwpxStyleXmlText $entry.name),$entry.para,$entry.char}
        $header=Add-HwpxHeaderCollection $header 'styles' '</hh:styles>' ($items-join '') $Registry.NamedStyles.Count
    }
    $header
}

function Get-HwpxPageSettings {
    param([AllowNull()][object]$Page)
    $orientation = ([string](Get-HwpxStyleValue -Primary $Page -Fallback $null -Name 'orientation' -Default 'PORTRAIT')).ToUpperInvariant()
    $defaultWidth = if ($orientation -eq 'LANDSCAPE') { 297 } else { 210 }
    $defaultHeight = if ($orientation -eq 'LANDSCAPE') { 210 } else { 297 }
    $margins = if (Test-HwpxStyleProperty -InputObject $Page -Name 'margins') { $Page.margins } else { $null }
    $effectiveWidth = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $Page -Fallback $null -Name 'widthMm' -Default $defaultWidth))
    $effectiveHeight = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $Page -Fallback $null -Name 'heightMm' -Default $defaultHeight))
    $result = [pscustomobject][ordered]@{
        orientation = $orientation
        # HWPX keeps the paper dimensions unrotated; landscape supplies the rotation.
        width = if ($orientation -eq 'LANDSCAPE') { $effectiveHeight } else { $effectiveWidth }
        height = if ($orientation -eq 'LANDSCAPE') { $effectiveWidth } else { $effectiveHeight }
        effectiveWidth = $effectiveWidth
        effectiveHeight = $effectiveHeight
        gutterType = [string](Get-HwpxStyleValue $Page $null 'gutterType' 'LEFT_ONLY')
        margins = [pscustomobject][ordered]@{
            left = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'leftMm' -Default 15))
            right = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'rightMm' -Default 15))
            top = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'topMm' -Default 10))
            bottom = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'bottomMm' -Default 10))
            header = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'headerMm' -Default 15))
            footer = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'footerMm' -Default 15))
            gutter = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $margins -Fallback $null -Name 'gutterMm' -Default 0))
        }
    }
    $horizontalGutter = if ($result.gutterType -eq 'TOP_ONLY') {0} else {$result.margins.gutter}
    $result | Add-Member NoteProperty contentWidth ($effectiveWidth - $result.margins.left - $result.margins.right - $horizontalGutter)
    $result
}

function Initialize-HwpxStyleContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object[]]$Blocks,
        [Parameter(Mandatory)][string]$HeaderXml,
        [AllowNull()][object]$Registry
    )

    if ($null -eq $Registry) {$Registry = New-HwpxStyleRegistry -HeaderXml $HeaderXml}
    $documentStyle = if (Test-HwpxStyleProperty -InputObject $Plan -Name 'document') { $Plan.document } else { $null }
    $defaultText = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'textStyle') { $documentStyle.textStyle } else { $null }
    $defaultParagraph = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'paragraphStyle') { $documentStyle.paragraphStyle } else { $null }
    $defaultTable = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'tableStyle') { $documentStyle.tableStyle } else { $null }
    $namedIds=@{}
    foreach ($style in (Get-HwpxStyleValue $documentStyle $null 'styles' @())) {
        $char=Register-HwpxTextStyle $registry (Get-HwpxNormalizedTextStyle $defaultText (Get-HwpxStyleValue $style $null 'textStyle' $null))
        $para=Register-HwpxParagraphStyle $registry (Get-HwpxNormalizedParagraphStyle $defaultParagraph (Get-HwpxStyleValue $style $null 'paragraphStyle' $null))
        $key=$style.name+'|'+$char+'|'+$para
        if ($registry.NamedStyleIds.ContainsKey($key)) {$id=$registry.NamedStyleIds[$key]}
        else {
            $id=$registry.NextStyleId++
            $name=$style.name
            if (@($registry.NamedStyles|Where-Object {$_.name -eq $name}).Count) {$name+=' ['+$id+']'}
            $registry.NamedStyles.Add([pscustomobject]@{id=$id;name=$name;char=$char;para=$para})
            $registry.NamedStyleIds[$key]=$id
        }
        $namedIds[$style.name]=$id
    }
    foreach ($block in $Blocks) {
        $blockTextRaw = if (Test-HwpxStyleProperty -InputObject $block -Name 'textStyle') { $block.textStyle } else { $null }
        $blockParagraphRaw = if (Test-HwpxStyleProperty -InputObject $block -Name 'paragraphStyle') { $block.paragraphStyle } else { $null }
        $blockText = Get-HwpxNormalizedTextStyle -Fallback $defaultText -Primary $blockTextRaw
        $blockParagraph = Get-HwpxNormalizedParagraphStyle -Fallback $defaultParagraph -Primary $blockParagraphRaw
        Add-HwpxInternalProperty -Target $block -Name '__charPrId' -Value (Register-HwpxTextStyle -Registry $registry -Style $blockText)
        Add-HwpxInternalProperty -Target $block -Name '__paraPrId' -Value (Register-HwpxParagraphStyle -Registry $registry -Style $blockParagraph)
        Add-HwpxInternalProperty $block '__styleId' $(if (Test-HwpxStyleProperty $block 'styleName') {$namedIds[$block.styleName]} else {0})
        if (Test-HwpxStyleProperty $block 'runs') {
            foreach ($run in $block.runs) {
                $runStyle = Get-HwpxNormalizedTextStyle -Fallback $blockText -Primary $(if (Test-HwpxStyleProperty $run 'textStyle') {$run.textStyle} else {$null})
                Add-HwpxInternalProperty $run '__charPrId' (Register-HwpxTextStyle $registry $runStyle)
            }
        }
        if ([string]$block.type -ne 'table') { continue }
        $blockTableRaw = if (Test-HwpxStyleProperty -InputObject $block -Name 'style') { $block.style } else { $null }
        $blockTable = Get-HwpxNormalizedTableStyle -Fallback $defaultTable -Primary $blockTableRaw
        Add-HwpxInternalProperty -Target $block -Name '__borderFillId' -Value (Register-HwpxTableStyle -Registry $registry -Style $blockTable)
        $paddingMm = if ($null -eq $blockTable) { 1.8 } else { [double]$blockTable.cellPaddingMm }
        Add-HwpxInternalProperty -Target $block -Name '__cellPadding' -Value (ConvertTo-HwpxStyleUnit -Millimeter $paddingMm)
        $blockMargins=[ordered]@{}
        foreach ($side in @('left','right','top','bottom')) {$blockMargins[$side]=ConvertTo-HwpxStyleUnit (Get-HwpxStyleValue $(if ($null -ne $blockTable) {$blockTable.cellMargins} else {$null}) $null ($side+'Mm') $paddingMm)}
        Add-HwpxInternalProperty $block '__margins' ([pscustomobject]$blockMargins)
        foreach ($cell in @($block.cells)) {
            $cellTextRaw = if (Test-HwpxStyleProperty -InputObject $cell -Name 'textStyle') { $cell.textStyle } else { $null }
            $cellParagraphRaw = if (Test-HwpxStyleProperty -InputObject $cell -Name 'paragraphStyle') { $cell.paragraphStyle } else { $null }
            $cellTableRaw = if (Test-HwpxStyleProperty -InputObject $cell -Name 'style') { $cell.style } else { $null }
            $cellText = Get-HwpxNormalizedTextStyle -Fallback $blockText -Primary $cellTextRaw
            $cellParagraph = Get-HwpxNormalizedParagraphStyle -Fallback $blockParagraph -Primary $cellParagraphRaw
            $cellTable = Get-HwpxNormalizedTableStyle -Fallback $blockTable -Primary $cellTableRaw
            Add-HwpxInternalProperty -Target $cell -Name '__charPrId' -Value (Register-HwpxTextStyle -Registry $registry -Style $cellText)
            Add-HwpxInternalProperty -Target $cell -Name '__paraPrId' -Value (Register-HwpxParagraphStyle -Registry $registry -Style $cellParagraph)
            Add-HwpxInternalProperty -Target $cell -Name '__borderFillId' -Value (Register-HwpxTableStyle -Registry $registry -Style $cellTable)
            $cellPaddingMm = if ($null -eq $cellTable) { $paddingMm } else { [double]$cellTable.cellPaddingMm }
            Add-HwpxInternalProperty -Target $cell -Name '__cellPadding' -Value (ConvertTo-HwpxStyleUnit -Millimeter $cellPaddingMm)
            $cellMargins=[ordered]@{}
            foreach ($side in @('left','right','top','bottom')) {$cellMargins[$side]=ConvertTo-HwpxStyleUnit (Get-HwpxStyleValue $(if ($null -ne $cellTable) {$cellTable.cellMargins} else {$null}) $null ($side+'Mm') $cellPaddingMm)}
            Add-HwpxInternalProperty $cell '__margins' ([pscustomobject]$cellMargins)
            if (Test-HwpxStyleProperty $cell 'paragraphs') {
                foreach ($p in $cell.paragraphs) {
                    $pText=Get-HwpxNormalizedTextStyle $cellText (Get-HwpxStyleValue $p $null 'textStyle' $null)
                    $pStyle=Get-HwpxNormalizedParagraphStyle $cellParagraph (Get-HwpxStyleValue $p $null 'paragraphStyle' $null)
                    Add-HwpxInternalProperty $p '__charPrId' (Register-HwpxTextStyle $registry $pText)
                    Add-HwpxInternalProperty $p '__paraPrId' (Register-HwpxParagraphStyle $registry $pStyle)
                    Add-HwpxInternalProperty $p '__styleId' $(if (Test-HwpxStyleProperty $p 'styleName') {$namedIds[$p.styleName]} else {0})
                    if (Test-HwpxStyleProperty $p 'runs') {foreach ($run in $p.runs) {
                        Add-HwpxInternalProperty $run '__charPrId' (Register-HwpxTextStyle $registry (Get-HwpxNormalizedTextStyle $pText (Get-HwpxStyleValue $run $null 'textStyle' $null)))
                    }}
                }
            }
        }
    }
    $page = Get-HwpxPageSettings -Page $(if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'page') { $documentStyle.page } else { $null })
    $columns = Get-HwpxStyleValue $documentStyle $null 'columns' $null
    $count = [int](Get-HwpxStyleValue $columns $null 'count' 1)
    $gap = ConvertTo-HwpxStyleUnit (Get-HwpxStyleValue $columns $null 'gapMm' 0)
    $widths = @(if (Test-HwpxStyleProperty $columns 'widthsMm') {$columns.widthsMm|ForEach-Object {ConvertTo-HwpxStyleUnit $_}})
    $columnWidth = if ($widths.Count) {$widths[0]} else {[int][Math]::Floor(($page.contentWidth-($count-1)*$gap)/$count)}
    $page | Add-Member NoteProperty columnWidth $columnWidth
    $page | Add-Member NoteProperty columns ([pscustomobject]@{count=$count;gap=$gap;widths=$widths})
    $border = if (Test-HwpxStyleProperty $documentStyle 'page') {Get-HwpxStyleValue $documentStyle.page $null 'border' $null} else {$null}
    $page | Add-Member NoteProperty borderFillId $(if ($null -eq $border) {1} else {Register-HwpxTableStyle $registry (Get-HwpxNormalizedTableStyle $null $border)})
    [pscustomobject][ordered]@{
        blocks = @($Blocks)
        headerXml = Apply-HwpxStyleRegistryToHeader -Registry $registry
        page = $page
        registry = $registry
    }
}

Export-ModuleMember -Function @(
    'Copy-HwpxStyledBlocks',
    'Initialize-HwpxStyleContext'
)
