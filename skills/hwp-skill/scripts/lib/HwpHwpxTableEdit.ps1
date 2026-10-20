# Private helpers for HWPX table/cell editing. Loaded by HwpHwpxScopedEdit.psm1.
# All work is prepared in memory before the scoped editor writes a separate copy.

function Add-ScopedPreparedResource {
    param($Allocation, $Resource)
    if (-not $Allocation.ContainsKey('Resources')) { $Allocation.Resources = [Collections.Generic.List[object]]::new() }
    if (-not $Allocation.ContainsKey('PreparedResourceCharacters')) { $Allocation.PreparedResourceCharacters=[long]0 }
    $Allocation.PreparedResourceCharacters += $Resource.Node.OuterXml.Length
    if ($Allocation.PreparedResourceCharacters -gt 16MB) {throw 'Prepared resources exceed 16 MiB characters.'}
    $Allocation.Resources.Add($Resource)
}

function Test-ScopedExpectedCellText {
    param([object]$Expected, [string]$Actual)
    # Inspection exposes Windows paragraph separators; plans may use LF on any OS.
    if ($Expected -isnot [string] -or $Expected.Length -gt 1MB) {return $false}
    return $Expected.Replace("`r`n","`n").Replace("`r","`n") -ceq $Actual.Replace("`r`n","`n").Replace("`r","`n")
}

function Get-ScopedAvailableStyleIds {
    param([xml]$Header,[string]$Kind,$Allocation)
    $ids=Get-ScopedStyleIds $Header $Kind
    if($Allocation.ContainsKey($Kind)){foreach($id in $Allocation[$Kind]){$null=$ids.Add([string]$id)}}
    return ,$ids
}

function Get-ScopedInlineText {
    param([Xml.XmlElement]$Run)
    $ns = New-ScopedNamespaces $Run.OwnerDocument
    $nodes = @($Run.ChildNodes | Where-Object {$_.NodeType -notin @('Whitespace','SignificantWhitespace')})
    if ($nodes.Count -ne 1 -or $nodes[0].LocalName -cne 't' -or $nodes[0].NamespaceURI -cne $script:ScopedHp) { throw 'Cell run must contain one text element, without controls.' }
    $text = [Text.StringBuilder]::new()
    foreach ($child in $nodes[0].ChildNodes) {
        if ($child.NodeType -in @('Text','CDATA','Whitespace','SignificantWhitespace')) { $null = $text.Append($child.Value) }
        elseif ($child.NodeType -eq 'Element' -and $child.NamespaceURI -ceq $script:ScopedHp -and -not $child.HasChildNodes) {
            if ($child.LocalName -ceq 'lineBreak') { $null = $text.Append("`n") }
            elseif ($child.LocalName -ceq 'tab') { $null = $text.Append("`t") }
            else { throw 'Unknown inline cell content.' }
        } else { throw 'Unknown inline cell content.' }
    }
    return $text.ToString()
}

function Set-ScopedInlineText {
    param([Xml.XmlElement]$Run, [string]$Text)
    if ($Text.Length -gt 1MB) { throw 'Cell run exceeds 1 MiB characters.' }
    $null = [Xml.XmlConvert]::VerifyXmlChars($Text)
    $xml = $Run.OwnerDocument
    $t = $xml.CreateElement('hp','t',$script:ScopedHp)
    foreach ($piece in [regex]::Split($Text, '(\r\n|\r|\n|\t)')) {
        if ($piece -cin @("`r`n","`r","`n","`t")) {
            $name = if ($piece -ceq "`t") { 'tab' } else { 'lineBreak' }
            $node = $xml.CreateElement('hp',$name,$script:ScopedHp)
            if ($name -ceq 'tab') { foreach ($key in @('width','leader','type')) { $node.SetAttribute($key,'0') } }
            $null = $t.AppendChild($node)
        } elseif ($piece.Length -gt 0) { $null = $t.AppendChild($xml.CreateTextNode($piece)) }
    }
    $null = $Run.AppendChild($t)
}

function Set-ScopedFontFamily {
    param([xml]$Header, [Xml.XmlElement]$Character, [object]$Value, $Allocation)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 256) { throw 'fontFamily must be a nonblank string of at most 256 characters.' }
    $null = [Xml.XmlConvert]::VerifyXmlChars($Value)
    $ns = New-ScopedNamespaces $Header
    $reference = Get-ScopedOneChild $Character 'hh:fontRef'
    if (-not $Allocation.ContainsKey('Fonts')) { $Allocation.Fonts = @{} }
    foreach ($lang in @('HANGUL','LATIN','HANJA','JAPANESE','OTHER','SYMBOL','USER')) {
        $faces = $Header.SelectNodes(('/hh:head/hh:refList/hh:fontfaces/hh:fontface[@lang="{0}"]' -f $lang),$ns)
        if ($faces.Count -ne 1) { throw "Missing or ambiguous fontface language: $lang" }
        $face = $faces[0]
        $fonts = $face.SelectNodes('hh:font',$ns)
        if ((Get-ScopedXmlInteger $face 'fontCnt') -ne $fonts.Count) { throw 'fontCnt does not match font resources.' }
        $cacheKey = $lang + '|' + $Value
        if ($Allocation.Fonts.ContainsKey($cacheKey)) { $id = $Allocation.Fonts[$cacheKey] }
        else {
            $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            [long]$next = 0; $id = $null
            foreach ($font in $fonts) {
                $fontId = Get-ScopedStyleId $font.GetAttribute('id') 'font.id'
                if (-not $ids.Add($fontId)) { throw 'Duplicate font resource ID.' }
                $next = [Math]::Max($next,([long]$fontId+1))
                if ($font.GetAttribute('face') -ceq $Value) { $id = $fontId }
            }
            if ($null -eq $id) {
                foreach ($entry in $Allocation.Fonts.GetEnumerator()) { if ($entry.Key.StartsWith($lang+'|',[StringComparison]::Ordinal)) { $next = [Math]::Max($next,([long]$entry.Value+1)) } }
                if ($next -gt [uint32]::MaxValue) { throw 'No font IDs remain.' }
                $id = [string]$next
                $font = $Header.CreateElement('hh','font',$script:ScopedHh)
                $font.SetAttribute('id',$id); $font.SetAttribute('face',$Value)
                $font.SetAttribute('type','TTF'); $font.SetAttribute('isEmbedded','0')
                $info=$Header.CreateElement('hh','typeInfo',$script:ScopedHh)
                foreach ($key in @('familyType','weight','proportion','contrast','strokeVariation','armStyle','letterform','midline','xHeight')) {
                    $attribute=if ($key -ceq 'familyType') {'FCAT_GOTHIC'} elseif ($key -ceq 'weight') {'6'} elseif ($key -ceq 'proportion') {'4'} elseif ($key -ceq 'contrast') {'0'} else {'1'}
                    $info.SetAttribute($key,$attribute)
                }
                $null=$font.AppendChild($info)
                Add-ScopedPreparedResource $Allocation @{Node=$font;Collection=$face;Kind='font';Id=$id;CountAttribute='fontCnt'}
            }
            $Allocation.Fonts[$cacheKey] = $id
        }
        $reference.SetAttribute($lang.ToLowerInvariant(),$id)
    }
}

function New-ScopedBorderResource {
    param([xml]$Header, [Xml.XmlElement]$Cell, $Style, $Allocation)
    $fields = ConvertTo-ScopedMap $Style 'cell.style'
    $borderKeys = @('borderType','borderWidthMm','borderColor','fillColor','borders')
    Assert-ScopedKeys $fields @() 'cell.style' ($borderKeys + @('cellPaddingMm','cellMargins'))
    if (@($fields.Keys | Where-Object { $_ -cin $borderKeys }).Count -eq 0) { return $null }
    $originalId = Get-ScopedStyleId $Cell.GetAttribute('borderFillIDRef') 'cell.borderFillIDRef'
    $cacheKey = $originalId + '|' + (ConvertTo-Json -InputObject $Style -Depth 15 -Compress)
    if (-not $Allocation.ContainsKey('Borders')) { $Allocation.Borders = @{} }
    if ($Allocation.Borders.ContainsKey($cacheKey)) { return $Allocation.Borders[$cacheKey] }
    $ns = New-ScopedNamespaces $Header
    $collection = Get-ScopedOneChild (Get-ScopedOneChild $Header.DocumentElement 'hh:refList') 'hh:borderFills'
    $nodes = $collection.SelectNodes('hh:borderFill',$ns)
    if ((Get-ScopedXmlInteger $collection 'itemCnt') -ne $nodes.Count) { throw 'borderFills.itemCnt does not match resources.' }
    $source = $null
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($node in $nodes) {
        $id = Get-ScopedStyleId $node.GetAttribute('id') 'borderFill.id'
        if (-not $ids.Add($id)) { throw 'Duplicate borderFill resource ID.' }
        if ($id -ceq $originalId) { $source = $node }
    }
    foreach ($entry in $Allocation.Borders.Values) { $null=$ids.Add([string]$entry.Id) }
    if($Allocation.ContainsKey('Resources')){
        foreach($pending in $Allocation.Resources){
            if($pending.Kind -ceq 'borderFill'){
                $null=$ids.Add([string]$pending.Id)
                if($null -eq $source -and $pending.Id -ceq $originalId){$source=$pending.Node}
            }
        }
    }
    if ($null -eq $source) { throw 'Missing borderFill resource.' }
    $next=Get-ScopedReadableResourceId $ids
    if($next -ceq '0'){
        [long]$positive=1;while($ids.Contains([string]$positive)){$positive++}
        if($positive -gt [int]::MaxValue){throw 'No readable positive borderFill IDs remain.'}
        $next=[string]$positive
    }
    $copy = $source.CloneNode($true); $copy.SetAttribute('id',[string]$next)
    $sides = if ($fields.ContainsKey('borders')) { ConvertTo-ScopedMap $fields['borders'] 'style.borders' } else { @{} }
    Assert-ScopedKeys $sides @() 'style.borders' @('left','right','top','bottom')
    if ($fields.ContainsKey('borders') -and $sides.Count -eq 0) {throw 'borders cannot be empty.'}
    foreach ($side in @('left','right','top','bottom')) {
        $changes = @{}
        foreach ($pair in @(@('borderType','type'),@('borderWidthMm','widthMm'),@('borderColor','color'))) { if ($fields.ContainsKey($pair[0])) { $changes[$pair[1]]=$fields[$pair[0]] } }
        if ($sides.ContainsKey($side)) {
            $override = ConvertTo-ScopedMap $sides[$side] "borders.$side"
            Assert-ScopedKeys $override @() "borders.$side" @('type','widthMm','color')
            if ($override.Count -eq 0) { throw 'A border side must specify a property.' }
            foreach ($key in $override.Keys) { $changes[$key]=$override[$key] }
        }
        if ($changes.Count -eq 0) { continue }
        $border = Get-ScopedOneChild $copy ('hh:'+$side+'Border')
        foreach ($key in $changes.Keys) {
            $value = $changes[$key]
            switch -CaseSensitive ($key) {
                'type' {
                    if ($value -isnot [string] -or $value -cnotin @('NONE','SOLID','DASH','DOT','DASH_DOT','DASH_DOT_DOT','LONG_DASH','CIRCLE','DOUBLE','THIN_THICK','THICK_THIN','THIN_THICK_THIN','WAVE','DOUBLE_WAVE')) { throw 'Unsupported border type.' }
                    $border.SetAttribute('type',$value)
                }
                'widthMm' {
                    $number = Get-ScopedNumber $value 0.1 5 'border.widthMm'
                    if (@(0.1,0.12,0.15,0.2,0.25,0.3,0.4,0.5,0.6,0.7,1,1.5,2,3,4,5) -notcontains $number) { throw 'Border width must use a supported HWPX thickness.' }
                    $border.SetAttribute('width',($number.ToString('0.0#',[Globalization.CultureInfo]::InvariantCulture)+' mm'))
                }
                'color' {
                    if ($value -isnot [string] -or $value -cnotmatch '^#[0-9A-Fa-f]{6}$') { throw 'Border color must be #RRGGBB.' }
                    $border.SetAttribute('color',$value)
                }
            }
        }
    }
    if ($fields.ContainsKey('fillColor')) {
        $color = $fields['fillColor']
        if ($color -isnot [string] -or ($color -cne 'NONE' -and $color -cnotmatch '^#[0-9A-Fa-f]{6}$')) { throw 'fillColor must be NONE or #RRGGBB.' }
        $brushes = $copy.SelectNodes('hc:fillBrush',$ns)
        if ($brushes.Count -gt 1) { throw 'Ambiguous fillBrush.' }
        if ($brushes.Count -eq 1) {
            $brush = $brushes[0]
            $children = $brush.SelectNodes('*')
            if ($children.Count -ne 1 -or $children[0].LocalName -cne 'winBrush' -or $children[0].NamespaceURI -cne 'http://www.hancom.co.kr/hwpml/2011/core') { throw 'Gradient/picture/unknown fills need a dedicated editor.' }
            if ($color -ceq 'NONE') {
                Assert-ScopedCellAttributes $brush @()
                Assert-ScopedCellAttributes $children[0] @('faceColor','hatchColor','alpha','hatchStyle')
                $null=$copy.RemoveChild($brush)
            }
            else { $children[0].SetAttribute('faceColor',$color) }
        } elseif ($color -cne 'NONE') {
            $brush = $Header.CreateElement('hc','fillBrush','http://www.hancom.co.kr/hwpml/2011/core')
            $win = $Header.CreateElement('hc','winBrush','http://www.hancom.co.kr/hwpml/2011/core')
            $win.SetAttribute('faceColor',$color); $win.SetAttribute('hatchColor','#000000'); $win.SetAttribute('alpha','0')
            $null=$brush.AppendChild($win); $null=$copy.AppendChild($brush)
        }
    }
    $resource = @{Node=$copy;Collection=$collection;Kind='borderFill';Id=[string]$next;CountAttribute='itemCnt'}
    Add-ScopedPreparedResource $Allocation $resource
    $Allocation.Borders[$cacheKey]=$resource
    return $resource
}

function Set-ScopedCellFormat {
    param([Xml.XmlElement]$Cell, $Fields, $Package, $Allocation)
    Assert-ScopedEditContext $Cell
    $ns = New-ScopedNamespaces $Cell.OwnerDocument
    foreach($key in @('textDirection','lineWrap')) {
        if($Fields.ContainsKey($key)) {
            $allowed=if($key -ceq 'textDirection'){@('HORIZONTAL','VERTICAL','VERTICALALL')}else{@('BREAK','SQUEEZE','KEEP')}
            if($Fields[$key] -isnot [string] -or $Fields[$key] -cnotin $allowed){throw "Invalid cell $key."}
            (Get-ScopedOneChild $Cell 'hp:subList').SetAttribute($key,$Fields[$key])
        }
    }
    if ($Fields.ContainsKey('verticalAlignment')) {
        $value = $Fields['verticalAlignment']
        if ($value -isnot [string] -or $value -cnotin @('TOP','CENTER','BOTTOM')) { throw 'verticalAlignment must be TOP, CENTER or BOTTOM.' }
        (Get-ScopedOneChild $Cell 'hp:subList').SetAttribute('vertAlign',$value)
    }
    if ($Fields.ContainsKey('style')) {
        $style = ConvertTo-ScopedMap $Fields['style'] 'cell.style'
        if ($style.Count -eq 0) { throw 'Cell style cannot be empty.' }
        $resource = New-ScopedBorderResource $Package.Xml['Contents/header.xml'] $Cell $style $Allocation
        if ($null -ne $resource) { $Cell.SetAttribute('borderFillIDRef',$resource.Id) }
        if ($style.ContainsKey('cellPaddingMm') -or $style.ContainsKey('cellMargins')) {
            $margin = Get-ScopedOneChild $Cell 'hp:cellMargin'
            if ($style.ContainsKey('cellPaddingMm')) {
                $units = ConvertTo-ScopedMm $style['cellPaddingMm'] 'style.cellPaddingMm'
                foreach ($side in @('left','right','top','bottom')) { $margin.SetAttribute($side,[string]$units) }
            }
            if ($style.ContainsKey('cellMargins')) {
                $margins = ConvertTo-ScopedMap $style['cellMargins'] 'style.cellMargins'
                Assert-ScopedKeys $margins @() 'style.cellMargins' @('leftMm','rightMm','topMm','bottomMm')
                if ($margins.Count -eq 0) { throw 'cellMargins cannot be empty.' }
                foreach ($key in $margins.Keys) { $margin.SetAttribute($key.Replace('Mm',''),[string](ConvertTo-ScopedMm $margins[$key] "cellMargins.$key")) }
            }
            $Cell.SetAttribute('hasMargin','1')
            $size = Get-ScopedOneChild $Cell 'hp:cellSz'
            if ((Get-ScopedXmlInteger $margin 'left')+(Get-ScopedXmlInteger $margin 'right') -ge (Get-ScopedXmlInteger $size 'width') -or
                (Get-ScopedXmlInteger $margin 'top')+(Get-ScopedXmlInteger $margin 'bottom') -ge (Get-ScopedXmlInteger $size 'height')) { throw 'Cell margins consume its stored width or height.' }
        }
    }
    if ($Fields.ContainsKey('textStyle') -or $Fields.ContainsKey('paragraphStyle')) {
        $content = Get-ScopedCellContent $Cell (Get-ScopedAvailableStyleIds $Package.Xml['Contents/header.xml'] 'charPr' $Allocation) (Get-ScopedAvailableStyleIds $Package.Xml['Contents/header.xml'] 'paraPr' $Allocation) -PreserveCellMetadata
        foreach ($p in $content.Paragraphs) {
            if ($Fields.ContainsKey('paragraphStyle')) { $r=New-ScopedFormatResource $Package.Xml['Contents/header.xml'] $p 'paraPr' $Fields['paragraphStyle'] $Allocation; $p.SetAttribute('paraPrIDRef',$r.Id) }
            if ($Fields.ContainsKey('textStyle')) { foreach ($run in $p.SelectNodes('hp:run',$ns)) { $r=New-ScopedFormatResource $Package.Xml['Contents/header.xml'] $run 'charPr' $Fields['textStyle'] $Allocation; $run.SetAttribute('charPrIDRef',$r.Id) } }
        }
    }
    foreach ($cache in @($Cell.SelectNodes('.//hp:p/hp:linesegarray',$ns))) { $null=$cache.ParentNode.RemoveChild($cache) }
}

function New-ScopedCellContentReplacement {
    param([Xml.XmlElement]$Cell, $Operation, $Package, $Allocation)
    $header = $Package.Xml['Contents/header.xml']
    $content = Get-ScopedCellContent $Cell (Get-ScopedAvailableStyleIds $header 'charPr' $Allocation) (Get-ScopedAvailableStyleIds $header 'paraPr' $Allocation) -PreserveCellMetadata
    if (-not (Test-ScopedExpectedCellText $Operation['expectedText'] $content.Text)) { throw 'set-cell-content.expectedText does not match the original cell text.' }
    $paragraphs = $Operation['paragraphs']
    if ($paragraphs -isnot [Collections.IList] -or $paragraphs.Count -lt 1 -or $paragraphs.Count -gt 1024) { throw 'paragraphs must contain 1 to 1024 paragraph blocks.' }
    $ns = New-ScopedNamespaces $Cell.OwnerDocument
    # Whole-content replacement is explicit, but must not silently drop extensions.
    foreach ($p in $content.Paragraphs) {
        Assert-ScopedCellAttributes $p @('id','paraPrIDRef','styleIDRef','pageBreak','columnBreak','merged')
        foreach ($run in $p.SelectNodes('hp:run',$ns)) {
            Assert-ScopedCellAttributes $run @('charPrIDRef')
            $t=Get-ScopedOneChild $run 'hp:t'
            Assert-ScopedCellAttributes $t @()
            foreach ($inline in $t.SelectNodes('*')) {Assert-ScopedCellAttributes $inline $(if ($inline.LocalName -ceq 'tab') {@('width','leader','type')} else {@()})}
        }
    }
    $copy = $Cell.CloneNode($true); $sub = Get-ScopedOneChild $copy 'hp:subList'
    foreach ($p in @($sub.SelectNodes('hp:p',$ns))) { $null=$sub.RemoveChild($p) }
    $template = $content.Paragraphs[0]; $baseRun = $template.SelectSingleNode('hp:run',$ns)
    if (-not $Allocation.ContainsKey('CellContentNodes')) {$Allocation.CellContentNodes=0}
    $Allocation.CellContentNodes += $paragraphs.Count
    foreach ($entry in $paragraphs) {
        $block = ConvertTo-ScopedMap $entry 'paragraph'
        Assert-ScopedKeys $block @() 'paragraph' @('type','text','runs','textStyle','paragraphStyle')
        if ($block.ContainsKey('type') -and $block['type'] -cne 'paragraph') { throw 'Cell content accepts paragraph blocks only.' }
        if ($block.ContainsKey('text') -eq $block.ContainsKey('runs')) { throw 'A paragraph needs exactly one of text or runs.' }
        $p = $Cell.OwnerDocument.CreateElement('hp','p',$script:ScopedHp)
        $p.SetAttribute('id',(Get-ScopedNextParagraphId $Package $Allocation))
        $p.SetAttribute('paraPrIDRef',$template.GetAttribute('paraPrIDRef'))
        if ($template.HasAttribute('styleIDRef')) { $p.SetAttribute('styleIDRef',$template.GetAttribute('styleIDRef')) }
        foreach ($flag in @('pageBreak','columnBreak','merged')) { $p.SetAttribute($flag,'0') }
        if ($block.ContainsKey('paragraphStyle')) { $r=New-ScopedFormatResource $header $p 'paraPr' $block['paragraphStyle'] $Allocation; $p.SetAttribute('paraPrIDRef',$r.Id) }
        if ($block.ContainsKey('text')) { $runs=@(@{text=$block['text']}) } else { $runs=$block['runs'] }
        if ($runs -isnot [Collections.IList] -or $runs.Count -lt 1 -or $runs.Count -gt 1024) { throw 'runs must contain 1 to 1024 runs.' }
        $Allocation.CellContentNodes += $runs.Count
        if ($Allocation.CellContentNodes -gt 16384) {throw 'Cell content exceeds 16384 paragraph/run nodes per plan.'}
        foreach ($entryRun in $runs) {
            $runBlock = ConvertTo-ScopedMap $entryRun 'run'
            Assert-ScopedKeys $runBlock @('text') 'run' @('textStyle')
            if ($runBlock['text'] -isnot [string]) { throw 'Run text must be a string.' }
            if (-not $Allocation.ContainsKey('CellTextCharacters')) { $Allocation.CellTextCharacters=[long]0 }
            $Allocation.CellTextCharacters += $runBlock['text'].Length
            if ($Allocation.CellTextCharacters -gt 16MB) { throw 'Cell replacement text exceeds 16 MiB characters.' }
            $run = $Cell.OwnerDocument.CreateElement('hp','run',$script:ScopedHp)
            $run.SetAttribute('charPrIDRef',$baseRun.GetAttribute('charPrIDRef'))
            $style = @{}
            foreach ($sourceStyle in @($(if ($block.ContainsKey('textStyle')) {$block['textStyle']}),$(if ($runBlock.ContainsKey('textStyle')) {$runBlock['textStyle']}))) {
                if ($null -ne $sourceStyle) { $map=ConvertTo-ScopedMap $sourceStyle 'textStyle'; foreach ($key in $map.Keys) { $style[$key]=$map[$key] } }
            }
            if ($style.Count -gt 0) { $r=New-ScopedFormatResource $header $run 'charPr' $style $Allocation; $run.SetAttribute('charPrIDRef',$r.Id) }
            Set-ScopedInlineText $run $runBlock['text']
            $null=$p.AppendChild($run)
        }
        $null=$sub.AppendChild($p)
    }
    return ,$copy
}

function Get-ScopedCellMinimumHeight {
    param([Xml.XmlElement]$Cell,[int]$Depth=0)
    $ns=New-ScopedNamespaces $Cell.OwnerDocument
    $size=Get-ScopedOneChild $Cell 'hp:cellSz';$margin=Get-ScopedOneChild $Cell 'hp:cellMargin'
    if($Cell.HasAttribute('hasMargin') -and $Cell.GetAttribute('hasMargin') -cin @('0','false')){
        $parent=$Cell.SelectSingleNode('ancestor::hp:tbl[1]',$ns);$margin=Get-ScopedOneChild $parent 'hp:inMargin'
    }
    [long]$content=0
    $sub=Get-ScopedOneChild $Cell 'hp:subList'
    foreach($paragraph in $sub.SelectNodes('hp:p',$ns)){
        [long]$line=0
        foreach($child in $paragraph.SelectNodes('hp:run/hp:tbl',$ns)){
            if($sub.GetAttribute('textDirection') -cne 'HORIZONTAL'){throw 'Nested minimum height requires horizontal cell text flow.'}
            $outside=Get-ScopedOneChild $child 'hp:outMargin'
            $extent=(Get-ScopedTableMinimumHeight $child ($Depth+1))+(Get-ScopedXmlInteger $outside 'top')+(Get-ScopedXmlInteger $outside 'bottom')
            $line=[Math]::Max($line,$extent)
        }
        # A lower bound: text is unmeasured; same-paragraph objects are not summed.
        $content+=$line
    }
    return [long][Math]::Max((Get-ScopedXmlInteger $size 'height' 1),$content+(Get-ScopedXmlInteger $margin 'top')+(Get-ScopedXmlInteger $margin 'bottom'))
}

function Get-ScopedTableMinimumHeight {
    param([Xml.XmlElement]$Table,[int]$Depth=0)
    if($Depth -gt 8){throw 'Nested minimum-height analysis exceeds eight levels.'}
    $size=Get-ScopedOneChild $Table 'hp:sz'
    if($size.GetAttribute('heightRelTo') -cne 'ABSOLUTE'){throw 'Minimum table height requires absolute stored geometry.'}
    $grid=Get-ScopedTableGrid $Table;$prefix=[long[]]::new($grid.RowCount+1)
    for($end=1;$end -le $grid.RowCount;$end++){
        $prefix[$end]=$prefix[$end-1]
        foreach($cell in $grid.Cells){
            if($cell.Row+$cell.RowSpan -ne $end){continue}
            $height=Get-ScopedCellMinimumHeight $cell.Node $Depth
            $prefix[$end]=[Math]::Max($prefix[$end],$prefix[$cell.Row]+$height)
        }
    }
    return [long][Math]::Max((Get-ScopedXmlInteger $size 'height' 1),$prefix[$grid.RowCount])
}

function Assert-ScopedTableBounds {
    param([Xml.XmlElement]$Table,$Package)
    $xml=$Table.OwnerDocument;$ns=New-ScopedNamespaces $xml
    $pageNodes=$xml.SelectNodes('/hs:sec/hp:p/hp:run/hp:secPr/hp:pagePr',$ns)
    if($pageNodes.Count -ne 1){throw 'Table bounds require one direct section page definition.'}
    $page=$pageNodes[0];$m=Get-ScopedOneChild $page 'hp:margin'
    $landscape=$page.GetAttribute('landscape')
    if($landscape -cnotin @('WIDELY','NARROWLY')){throw 'Unknown table page orientation.'}
    $width=Get-ScopedXmlInteger $page $(if($landscape -ceq 'NARROWLY'){'height'}else{'width'}) 1
    $height=Get-ScopedXmlInteger $page $(if($landscape -ceq 'NARROWLY'){'width'}else{'height'}) 1
    $width-=(Get-ScopedXmlInteger $m 'left')+(Get-ScopedXmlInteger $m 'right')
    $height-=(Get-ScopedXmlInteger $m 'top')+(Get-ScopedXmlInteger $m 'bottom')+(Get-ScopedXmlInteger $m 'header')+(Get-ScopedXmlInteger $m 'footer')
    $gutterType=$page.GetAttribute('gutterType')
    if($gutterType -cin @('TOP_ONLY','TOP_BOTTOM')){$height-=Get-ScopedXmlInteger $m 'gutter'}
    elseif($gutterType -cin @('LEFT_ONLY','LEFT_RIGHT')){$width-=Get-ScopedXmlInteger $m 'gutter'}
    else{throw 'Unknown table page gutter type.'}
    if($width -le 0 -or $height -le 0){throw 'Table has no positive page writing area.'}
    $parentCell=$Table.SelectSingleNode('ancestor::hp:tc[1]',$ns)
    if($null -ne $parentCell){$width=Get-ScopedCellInnerWidth $parentCell}
    else {
        $columns=$xml.SelectNodes('//hp:colPr',$ns)
        if($columns.Count -gt 1){throw 'Table bounds cannot resolve multiple column transitions.'}
        if($columns.Count -eq 1){
            $col=$columns[0];$count=Get-ScopedXmlInteger $col 'colCount' 1 16
            if($count -gt 1 -or $col.GetAttribute('sameSz') -cin @('0','false')){
                if($col.GetAttribute('sameSz') -cin @('1','true')){
                    $gap=Get-ScopedXmlInteger $col 'sameGap'
                    $width=[long][Math]::Floor(($width-[long]$gap*($count-1))/$count)
                }elseif($col.GetAttribute('sameSz') -cin @('0','false')){
                    $sizes=$col.SelectNodes('hp:colSz',$ns)
                    if($sizes.Count -ne $count){throw 'Table bounds require every column width.'}
                    [long]$columnExtent=0
                    for($n=0;$n -lt $count;$n++){
                        $columnExtent+=Get-ScopedXmlInteger $sizes[$n] 'width' 1
                        if($n -lt $count-1){$columnExtent+=Get-ScopedXmlInteger $sizes[$n] 'gap'}
                    }
                    if([Math]::Abs($columnExtent-$width) -gt $count+1){throw 'Stored column widths and gaps do not match the final page writing area.'}
                    # Automatic pagination is unknown: only a width safe in every column is certified.
                    $width=[long](($sizes|ForEach-Object {Get-ScopedXmlInteger $_ 'width' 1}|Measure-Object -Minimum).Minimum)
                }else{throw 'Unknown column sizing mode.'}
            }
        }
    }
    $size=Get-ScopedOneChild $Table 'hp:sz';$pos=Get-ScopedOneChild $Table 'hp:pos'
    if($size.GetAttribute('widthRelTo') -cne 'ABSOLUTE'){throw 'Table bounds require an absolute width.'}
    $inline=$pos.GetAttribute('treatAsChar')
    if($inline -cnotin @('0','1','false','true')){throw 'Unknown table inline treatment.'}
    if($pos.GetAttribute('horzAlign') -cnotin @('LEFT','CENTER','RIGHT','INSIDE','OUTSIDE')){throw 'Unknown native table horizontal alignment.'}
    if($inline -cin @('0','false') -and $pos.GetAttribute('horzAlign') -cin @('INSIDE','OUTSIDE')){throw 'Parity-dependent table alignment needs a verified page layout.'}
    if($inline -cin @('0','false') -and $pos.GetAttribute('horzRelTo') -cnotin @('COLUMN','PARA')){throw 'Table bounds require a body-relative horizontal anchor.'}
    if($inline -cin @('1','true') -or $pos.GetAttribute('horzRelTo') -ceq 'PARA'){
        $paragraph=$Table.SelectSingleNode('ancestor::hp:p[1]',$ns)
        if($null -eq $paragraph){throw 'Paragraph-relative table has no anchor paragraph.'}
        $id=Get-ScopedXmlInteger $paragraph 'paraPrIDRef'
        $header=$Package.Xml['Contents/header.xml'];$headerNs=New-ScopedNamespaces $header
        $resources=$header.SelectNodes(('//hh:paraPr[@id="'+$id+'"]'),$headerNs)
        if($resources.Count -ne 1){throw 'Table anchor paragraph style is ambiguous.'}
        [long]$inset=0
        foreach($branch in (Get-ScopedParagraphBranches $resources[0] 'margin')){
            [long]$sum=0
            [long]$left=0
            foreach($side in @('left','right')){
                $node=Get-ScopedOneChild $branch ('hc:'+$side)
                if($node.GetAttribute('unit') -cne 'HWPUNIT'){throw 'Table paragraph inset unit cannot be resolved.'}
                $value=Get-ScopedXmlInteger $node 'value';$sum+=$value
                if($side -ceq 'left'){$left=$value}
            }
            $intent=Get-ScopedOneChild $branch 'hc:intent'
            if($intent.GetAttribute('unit') -cne 'HWPUNIT' -or $intent.GetAttribute('value') -cnotmatch '^-?(0|[1-9][0-9]{0,9})$'){throw 'Table paragraph indentation cannot be resolved.'}
            [long]$indent=$intent.GetAttribute('value')
            if($left+$indent -lt 0){throw 'Table paragraph hanging indent extends outside the writing area.'}
            $sum+=[Math]::Max([long]0,$indent)
            $scale=if($branch.ParentNode.NamespaceURI -ceq $script:ScopedHp -and $branch.ParentNode.LocalName -ceq 'case'){1}else{2}
            $inset=[Math]::Max($inset,[long][Math]::Ceiling($sum/$scale))
        }
        $width-=$inset
    }
    $outside=Get-ScopedOneChild $Table 'hp:outMargin'
    [long]$occupied=(Get-ScopedXmlInteger $size 'width' 1)+(Get-ScopedXmlInteger $outside 'left')+(Get-ScopedXmlInteger $outside 'right')
    [long]$offset=0
    if($inline -cin @('0','false') -and $pos.HasAttribute('horzOffset')){
        if($pos.GetAttribute('horzOffset') -cnotmatch '^-?(0|[1-9][0-9]{0,9})$'){throw 'Invalid table horizontal offset.'}
        $signedOffset=[long]$pos.GetAttribute('horzOffset')
        if(($pos.GetAttribute('horzAlign') -ceq 'LEFT' -and $signedOffset -lt 0) -or ($pos.GetAttribute('horzAlign') -ceq 'RIGHT' -and $signedOffset -gt 0)){throw 'Table horizontal offset points outside its writing area.'}
        $offset=[Math]::Abs($signedOffset)
    }
    if($pos.GetAttribute('horzAlign') -ceq 'CENTER'){$offset*=2}
    if($width -le 0 -or $occupied+$offset -gt $width){throw 'Table width including outside margins and offset exceeds its writing area.'}
    $mode=$Table.GetAttribute('pageBreak')
    $lists=@($Table.SelectNodes('hp:tr/hp:tc/hp:subList',$ns))
    $allVertical=$lists.Count -gt 0 -and @($lists|Where-Object {$_.GetAttribute('textDirection') -cnotin @('VERTICAL','VERTICALALL')}).Count -eq 0
    if($mode -ceq 'NONE' -or $inline -cin @('1','true') -or $allVertical){
        if($size.GetAttribute('heightRelTo') -cne 'ABSOLUTE'){throw 'Indivisible table bounds require an absolute height.'}
        [long]$extent=(Get-ScopedTableMinimumHeight $Table)+(Get-ScopedXmlInteger $outside 'top')+(Get-ScopedXmlInteger $outside 'bottom')
        if($extent -gt $height){throw 'Indivisible table height exceeds the page writing area; enable pageBreak CELL.'}
    }elseif($mode -ceq 'TABLE'){
        foreach($cell in $Table.SelectNodes('hp:tr/hp:tc',$ns)){
            if((Get-ScopedCellMinimumHeight $cell)+(Get-ScopedXmlInteger $outside 'top')+(Get-ScopedXmlInteger $outside 'bottom') -gt $height){throw 'Indivisible cell height exceeds the page writing area; enable pageBreak CELL.'}
        }
    }elseif($mode -cne 'CELL' -and $mode -cne ''){throw 'Unknown table page-break mode.'}
}

function New-ScopedFormattedTable {
    param([Xml.XmlElement]$Table, $Operation, $Package, $Allocation)
    $copy=$Table.CloneNode($true); $grid=Get-ScopedTableGrid $copy
    $ns=New-ScopedNamespaces $copy.OwnerDocument
    foreach ($axis in @('columnWidthsMm','rowHeightsMm')) {
        if (-not $Operation.ContainsKey($axis)) { continue }
        $values=$Operation[$axis]; $count=if ($axis -ceq 'columnWidthsMm') {$grid.ColumnCount} else {$grid.RowCount}
        if ($values -isnot [Collections.IList] -or $values.Count -ne $count) { throw "$axis must specify every track exactly once." }
        $units=@(foreach ($value in $values) { $n=ConvertTo-ScopedMm $value $axis; if ($n -lt 1) {throw 'Track dimensions must round positive.'}; $n })
        $size=Get-ScopedOneChild $copy 'hp:sz'
        if ($size.HasAttribute('protect') -and $size.GetAttribute('protect') -cnotin @('0','false')) {throw 'Protected table dimensions cannot be resized.'}
        if ($size.GetAttribute('widthRelTo') -cne 'ABSOLUTE' -or $size.GetAttribute('heightRelTo') -cne 'ABSOLUTE') { throw 'Resizing requires absolute table dimensions.' }
        $attribute=if ($axis -ceq 'columnWidthsMm') {'width'} else {'height'}
        [long]$total=($units|Measure-Object -Sum).Sum
        if ($total -gt [int]::MaxValue) {throw 'Table size exceeds HWPUNIT limits.'}
        $size.SetAttribute($attribute,[string]$total)
        foreach ($cell in $grid.Cells) {
            $start=if ($axis -ceq 'columnWidthsMm') {$cell.Column} else {$cell.Row}
            $span=if ($axis -ceq 'columnWidthsMm') {$cell.ColumnSpan} else {$cell.RowSpan}
            (Get-ScopedOneChild $cell.Node 'hp:cellSz').SetAttribute($attribute,[string](($units[$start..($start+$span-1)]|Measure-Object -Sum).Sum))
        }
    }
    if ($Operation.ContainsKey('repeatHeader') -and $Operation.ContainsKey('headerRows')) {throw 'Use repeatHeader or headerRows, not both.'}
    if ($Operation.ContainsKey('headerRows') -or $Operation.ContainsKey('repeatHeader')) {
        if($Operation.ContainsKey('headerRows')){$count=Get-ScopedIndex $Operation['headerRows'] 'table.headerRows'}
        else{if($Operation['repeatHeader'] -isnot [bool]){throw 'repeatHeader must be Boolean.'};$count=[int]$Operation['repeatHeader']}
        if($count -gt $grid.RowCount){throw 'headerRows exceeds the table row count.'}
        foreach($cell in $grid.Cells){if($cell.Row -lt $count -and $cell.Row+$cell.RowSpan -gt $count){throw 'Header boundary cannot cut a vertical merge.'}}
        $copy.SetAttribute('repeatHeader',[string][int]($count -gt 0))
        foreach($cell in $grid.Cells){Assert-ScopedEditContext $cell.Node;$cell.Node.SetAttribute('header',[string][int]($cell.Row -lt $count))}
    }
    if ($Operation.ContainsKey('pageBreak')) {
        if ($Operation['pageBreak'] -isnot [string] -or $Operation['pageBreak'] -cnotin @('CELL','TABLE','NONE')) {throw 'pageBreak must be CELL, TABLE or NONE.'}
        $copy.SetAttribute('pageBreak',$Operation['pageBreak'])
        if($Operation['pageBreak'] -cne 'NONE'){
            $pos=Get-ScopedOneChild $copy 'hp:pos'
            $pos.SetAttribute('treatAsChar','0')
            $pos.SetAttribute('flowWithText','1')
            if(-not $pos.HasAttribute('horzRelTo')){$pos.SetAttribute('horzRelTo','COLUMN')}
            if(-not $pos.HasAttribute('vertRelTo')){$pos.SetAttribute('vertRelTo','PARA')}
        }
    }
    if ($Operation.ContainsKey('alignment')) {
        $value=$Operation['alignment']
        if ($value -isnot [string] -or $value -cnotin @('LEFT','CENTER','RIGHT')) {throw 'Table alignment must be LEFT, CENTER or RIGHT.'}
        (Get-ScopedOneChild $copy 'hp:pos').SetAttribute('horzAlign',$value)
    }
    $cellFields=@{}; foreach ($key in @('verticalAlignment','textDirection','lineWrap','style','textStyle','paragraphStyle')) {if ($Operation.ContainsKey($key)) {$cellFields[$key]=$Operation[$key]}}
    foreach ($cell in $grid.Cells) { Assert-ScopedEditContext $cell.Node; if ($cellFields.Count -gt 0) {Set-ScopedCellFormat $cell.Node $cellFields $Package $Allocation} }
    foreach ($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',$ns))) {$null=$cache.ParentNode.RemoveChild($cache)}
    $null=Get-ScopedTableGrid $copy
    return ,$copy
}

function New-ScopedDeletedTable {
    param([Xml.XmlElement]$Table, $Operation, $Package)
    $copy=$Table.CloneNode($true); $grid=Get-ScopedTableGrid $copy
    $isRow=$Operation['type'] -ceq 'delete-table-row'
    $index=Get-ScopedIndex $Operation['index'] 'delete.index'
    $count=if ($isRow) {$grid.RowCount} else {$grid.ColumnCount}
    if ($count -le 1 -or $index -ge $count) {throw 'Cannot delete the last track or an absent track.'}
    if ($isRow) {
        Assert-ScopedCellAttributes $grid.Rows[$index] @()
        foreach ($node in $grid.Rows[$index].ChildNodes) {
            if ($node.NodeType -in @('Whitespace','SignificantWhitespace')) {continue}
            if ($node.NodeType -ne 'Element' -or $node.NamespaceURI -cne $script:ScopedHp -or $node.LocalName -cne 'tc') {throw 'Unknown row metadata cannot be removed.'}
        }
    }
    foreach ($cell in $grid.Cells) {if ($cell.RowSpan -ne 1 -or $cell.ColumnSpan -ne 1) {throw 'Deletion requires an unmerged rectangular table.'}; Assert-ScopedEditContext $cell.Node}
    $selected=@($grid.Cells|Where-Object {$(if($isRow){$_.Row}else{$_.Column}) -eq $index})
    $expected=$Operation['expectedTexts']
    if ($expected -isnot [Collections.IList] -or $expected.Count -ne $selected.Count) {throw 'expectedTexts must list the deleted track in row/column order.'}
    for ($n=0;$n -lt $selected.Count;$n++) {
        $content=Get-ScopedCellContent $selected[$n].Node (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'charPr') (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'paraPr')
        if (-not (Test-ScopedExpectedCellText $expected[$n] $content.Text)) {throw 'Deleted track expectedTexts differs from original.'}
    }
    $size=Get-ScopedOneChild $copy 'hp:sz'
    if ($size.HasAttribute('protect') -and $size.GetAttribute('protect') -cnotin @('0','false')) {throw 'Protected table dimensions cannot be resized.'}
    if ($size.GetAttribute('widthRelTo') -cne 'ABSOLUTE' -or $size.GetAttribute('heightRelTo') -cne 'ABSOLUTE') {throw 'Deletion requires absolute table dimensions.'}
    foreach ($axis in @('width','height')) {
        $tracks=if ($axis -ceq 'width') {$grid.Widths} else {$grid.Heights}
        if ((Get-ScopedXmlInteger $size $axis 1) -ne ($tracks|Measure-Object -Sum).Sum) {throw 'Table extent differs from its cell grid.'}
    }
    if ($isRow) { $null=$copy.RemoveChild($grid.Rows[$index]); $copy.SetAttribute('rowCnt',[string]($count-1)); $size.SetAttribute('height',[string](($grid.Heights|Measure-Object -Sum).Sum-$grid.Heights[$index])) }
    else {foreach ($cell in $selected) {$null=$cell.Node.ParentNode.RemoveChild($cell.Node)}; $copy.SetAttribute('colCnt',[string]($count-1)); $size.SetAttribute('width',[string](($grid.Widths|Measure-Object -Sum).Sum-$grid.Widths[$index]))}
    foreach ($cell in $grid.Cells) {
        $coordinate=if ($isRow) {$cell.Row} else {$cell.Column}
        if ($coordinate -gt $index) {(Get-ScopedOneChild $cell.Node 'hp:cellAddr').SetAttribute($(if($isRow){'rowAddr'}else{'colAddr'}),[string]($coordinate-1))}
    }
    $ns=New-ScopedNamespaces $copy.OwnerDocument
    foreach ($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',$ns))) {$null=$cache.ParentNode.RemoveChild($cache)}
    $null=Get-ScopedTableGrid $copy
    return ,$copy
}
