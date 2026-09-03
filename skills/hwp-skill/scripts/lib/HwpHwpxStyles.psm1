Set-StrictMode -Version Latest

function Test-HwpxStyleProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
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
    }
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
    $key = '{0}|{1}|{2}|{3}|{4}' -f $Style.fontFamily, $Style.fontSizePt, $Style.bold, $Style.italic, $Style.textColor
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
    $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $Style.alignment, $Style.lineSpacingPercent,
        $Style.marginBeforeMm, $Style.marginAfterMm, $Style.leftMarginMm, $Style.rightMarginMm, $Style.indentMm
    if ($Registry.ParagraphStyleIds.ContainsKey($key)) { return $Registry.ParagraphStyleIds[$key] }
    $id = [int]$Registry.NextParaShapeId
    $Registry.NextParaShapeId++
    $Registry.ParagraphStyleIds.Add($key, $id)
    $Registry.ParagraphStyles.Add([pscustomobject]@{ id = $id; style = $Style })
    $id
}

function Register-HwpxTableStyle {
    param([Parameter(Mandatory)][object]$Registry, [AllowNull()][object]$Style)
    if ($null -eq $Style) { return 3 }
    $fillColor = if ([string]::IsNullOrWhiteSpace([string]$Style.fillColor)) { 'none' } else { ([string]$Style.fillColor).ToUpperInvariant() }
    $key = '{0}|{1}|{2}|{3}' -f $Style.borderType, $Style.borderWidthMm, $Style.borderColor, $fillColor
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
        $null = $builder.Append('<hh:ratio hangul="100" latin="100" hanja="100" japanese="100" other="100" symbol="100" user="100"/><hh:spacing hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/><hh:relSz hangul="100" latin="100" hanja="100" japanese="100" other="100" symbol="100" user="100"/><hh:offset hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>')
        if ($style.italic) { $null = $builder.Append('<hh:italic/>') }
        if ($style.bold) { $null = $builder.Append('<hh:bold/>') }
        $null = $builder.Append('<hh:underline type="NONE" shape="SOLID" color="#000000"/><hh:strikeout shape="NONE" color="#000000"/><hh:outline type="NONE"/><hh:shadow type="NONE" color="#C0C0C0" offsetX="10" offsetY="10"/></hh:charPr>')
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
        $null = $builder.Append('<hh:paraPr id="').Append($entry.id).Append('" tabPrIDRef="0" condense="0" fontLineHeight="0" snapToGrid="1" suppressLineNumbers="0" checked="0" textDir="LTR"><hh:align horizontal="').Append($style.alignment).Append('" vertical="BASELINE"/><hh:heading type="NONE" idRef="0" level="0"/><hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="KEEP_WORD" widowOrphan="0" keepWithNext="0" keepLines="0" pageBreakBefore="0" lineWrap="BREAK"/><hh:autoSpacing eAsianEng="0" eAsianNum="0"/><hh:margin>')
        $null = $builder.Append('<hc:intent value="').Append($intent).Append('" unit="HWPUNIT"/><hc:left value="').Append($left).Append('" unit="HWPUNIT"/><hc:right value="').Append($right).Append('" unit="HWPUNIT"/><hc:prev value="').Append($before).Append('" unit="HWPUNIT"/><hc:next value="').Append($after).Append('" unit="HWPUNIT"/></hh:margin>')
        $null = $builder.Append('<hh:lineSpacing type="PERCENT" value="').Append($style.lineSpacingPercent).Append('" unit="HWPUNIT"/><hh:border borderFillIDRef="2" offsetLeft="0" offsetRight="0" offsetTop="0" offsetBottom="0" connect="0" ignoreMargin="0"/></hh:paraPr>')
    }
    $builder.ToString()
}

function Get-HwpxTableStylesXml {
    param([Parameter(Mandatory)][object]$Registry)
    $builder = [Text.StringBuilder]::new()
    foreach ($entry in $Registry.TableStyles) {
        $style = $entry.style
        $width = ([double]$style.borderWidthMm).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' mm'
        $null = $builder.Append('<hh:borderFill id="').Append($entry.id).Append('" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0"><hh:slash type="NONE" Crooked="0" isCounter="0"/><hh:backSlash type="NONE" Crooked="0" isCounter="0"/>')
        foreach ($side in @('leftBorder','rightBorder','topBorder','bottomBorder')) {
            $null = $builder.Append('<hh:').Append($side).Append(' type="').Append($style.borderType).Append('" width="').Append($width).Append('" color="').Append($style.borderColor).Append('"/>')
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
    $header
}

function Get-HwpxPageSettings {
    param([AllowNull()][object]$Page)
    if ($null -eq $Page) { return $null }
    $orientation = ([string](Get-HwpxStyleValue -Primary $Page -Fallback $null -Name 'orientation' -Default 'PORTRAIT')).ToUpperInvariant()
    $defaultWidth = if ($orientation -eq 'LANDSCAPE') { 297 } else { 210 }
    $defaultHeight = if ($orientation -eq 'LANDSCAPE') { 210 } else { 297 }
    $margins = if (Test-HwpxStyleProperty -InputObject $Page -Name 'margins') { $Page.margins } else { $null }
    [pscustomobject][ordered]@{
        orientation = $orientation
        width = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $Page -Fallback $null -Name 'widthMm' -Default $defaultWidth))
        height = ConvertTo-HwpxStyleUnit -Millimeter ([double](Get-HwpxStyleValue -Primary $Page -Fallback $null -Name 'heightMm' -Default $defaultHeight))
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
}

function Initialize-HwpxStyleContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][object[]]$Blocks,
        [Parameter(Mandatory)][string]$HeaderXml
    )

    $registry = New-HwpxStyleRegistry -HeaderXml $HeaderXml
    $documentStyle = if (Test-HwpxStyleProperty -InputObject $Plan -Name 'document') { $Plan.document } else { $null }
    $defaultText = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'textStyle') { $documentStyle.textStyle } else { $null }
    $defaultParagraph = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'paragraphStyle') { $documentStyle.paragraphStyle } else { $null }
    $defaultTable = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'tableStyle') { $documentStyle.tableStyle } else { $null }
    foreach ($block in $Blocks) {
        $blockTextRaw = if (Test-HwpxStyleProperty -InputObject $block -Name 'textStyle') { $block.textStyle } else { $null }
        $blockParagraphRaw = if (Test-HwpxStyleProperty -InputObject $block -Name 'paragraphStyle') { $block.paragraphStyle } else { $null }
        $blockText = Get-HwpxNormalizedTextStyle -Fallback $defaultText -Primary $blockTextRaw
        $blockParagraph = Get-HwpxNormalizedParagraphStyle -Fallback $defaultParagraph -Primary $blockParagraphRaw
        Add-HwpxInternalProperty -Target $block -Name '__charPrId' -Value (Register-HwpxTextStyle -Registry $registry -Style $blockText)
        Add-HwpxInternalProperty -Target $block -Name '__paraPrId' -Value (Register-HwpxParagraphStyle -Registry $registry -Style $blockParagraph)
        if ([string]$block.type -ne 'table') { continue }
        $blockTableRaw = if (Test-HwpxStyleProperty -InputObject $block -Name 'style') { $block.style } else { $null }
        $blockTable = Get-HwpxNormalizedTableStyle -Fallback $defaultTable -Primary $blockTableRaw
        Add-HwpxInternalProperty -Target $block -Name '__borderFillId' -Value (Register-HwpxTableStyle -Registry $registry -Style $blockTable)
        $paddingMm = if ($null -eq $blockTable) { 1.8 } else { [double]$blockTable.cellPaddingMm }
        Add-HwpxInternalProperty -Target $block -Name '__cellPadding' -Value (ConvertTo-HwpxStyleUnit -Millimeter $paddingMm)
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
        }
    }
    $page = if (Test-HwpxStyleProperty -InputObject $documentStyle -Name 'page') { Get-HwpxPageSettings -Page $documentStyle.page } else { $null }
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
