# Prepared replacements only; the shared scoped editor owns serialization and promotion.
function New-ScopedParagraphStructure {
    param([Xml.XmlElement]$Paragraph,$Operation,$Package,$Allocation)
    $parent=$Paragraph.ParentNode;$xml=$Paragraph.OwnerDocument;$ns=New-ScopedNamespaces $xml
    if(-not (($parent.NamespaceURI -ceq $script:ScopedHs -and $parent.LocalName -ceq 'sec') -or ($parent.NamespaceURI -ceq $script:ScopedHp -and $parent.LocalName -ceq 'subList'))){throw 'Paragraph structure editing requires a direct section or supported subList.'}
    if($parent.LocalName -ceq 'subList') {
        foreach($key in @('linkListIDRef','linkListNextIDRef','hasTextRef','hasNumRef')){if($parent.HasAttribute($key) -and $parent.GetAttribute($key) -cnotin @('','0')){throw 'Linked or special paragraph lists cannot be structurally edited.'}}
    }
    $siblings=@($parent.SelectNodes('hp:p',$ns));$index=-1
    for($i=0;$i -lt $siblings.Count;$i++){if([object]::ReferenceEquals($siblings[$i],$Paragraph)){$index=$i;break}}
    if($index -lt 0){throw 'Paragraph anchor is absent.'}
    $copy=$parent.CloneNode($true);$anchor=$copy.SelectNodes('hp:p',$ns)[$index]
    if($Operation['type'] -ceq 'delete-paragraph') {
        if($siblings.Count -le 1){throw 'Cannot delete the last paragraph in a section or text list.'}
        # Validate through the text-only replacement guard; controls and unknown metadata cannot disappear.
        $null=New-ScopedParagraphContent $Paragraph @{expectedText=$Operation['expectedText'];paragraph=@{text=''}} $Package $Allocation
        $null=$copy.RemoveChild($anchor)
    } else {
        if($Operation['placement'] -isnot [string] -or $Operation['placement'] -cnotin @('before','after')){throw 'Paragraph placement must be before or after.'}
        $template=$xml.CreateElement('hp','p',$script:ScopedHp);$template.SetAttribute('id','0');$template.SetAttribute('paraPrIDRef',$Paragraph.GetAttribute('paraPrIDRef'))
        if($Paragraph.HasAttribute('styleIDRef')){$template.SetAttribute('styleIDRef',$Paragraph.GetAttribute('styleIDRef'))}
        $run=$xml.CreateElement('hp','run',$script:ScopedHp);$base=$Paragraph.SelectSingleNode('hp:run[hp:t]',$ns)
        $run.SetAttribute('charPrIDRef',$(if($base){$base.GetAttribute('charPrIDRef')}else{'0'}));$null=$run.AppendChild($xml.CreateElement('hp','t',$script:ScopedHp));$null=$template.AppendChild($run)
        $cell=$xml.CreateElement('hp','tc',$script:ScopedHp)
        foreach($name in @('subList','cellAddr','cellSpan','cellSz','cellMargin')){$null=$cell.AppendChild($xml.CreateElement('hp',$name,$script:ScopedHp))}
        $null=(Get-ScopedOneChild $cell 'hp:subList').AppendChild($template)
        $prepared=New-ScopedCellContentReplacement $cell @{expectedText='';paragraphs=$Operation['paragraphs']} $Package $Allocation
        foreach($paragraphNode in @($prepared.SelectNodes('hp:subList/hp:p',$ns))){
            if($Operation['placement'] -ceq 'before'){$null=$copy.InsertBefore($paragraphNode,$anchor)}else{$null=$copy.InsertAfter($paragraphNode,$anchor);$anchor=$paragraphNode}
        }
    }
    return ,$copy
}

function New-ScopedParagraphContent {
    param([Xml.XmlElement]$Paragraph,$Operation,$Package,$Allocation)
    $xml=$Paragraph.OwnerDocument;$ns=New-ScopedNamespaces $xml
    # Reuse the strict text-only cell writer without allowing document controls to be removed.
    $cell=$xml.CreateElement('hp','tc',$script:ScopedHp);$cell.SetAttribute('protect','0');$cell.SetAttribute('editable','0')
    foreach($name in @('subList','cellAddr','cellSpan','cellSz','cellMargin')){$null=$cell.AppendChild($xml.CreateElement('hp',$name,$script:ScopedHp))}
    $sub=Get-ScopedOneChild $cell 'hp:subList';$null=$sub.AppendChild($Paragraph.CloneNode($true))
    $result=New-ScopedCellContentReplacement $cell @{expectedText=$Operation['expectedText'];paragraphs=@($Operation['paragraph'])} $Package $Allocation
    $new=$result.SelectSingleNode('hp:subList/hp:p',$ns)
    foreach($attribute in $Paragraph.Attributes){if($attribute.Name -cnotin @('paraPrIDRef','styleIDRef')){$new.SetAttribute($attribute.Name,$attribute.Value)}}
    return ,$new
}

function New-ScopedParagraphBreaks {
    param([Xml.XmlElement]$Paragraph,$Operation)
    $copy=$Paragraph.CloneNode($true);$found=$false
    foreach($key in @('pageBreak','columnBreak')) {
        if($Operation.ContainsKey($key)) {
            if($Operation[$key] -isnot [bool]){throw "$key must be Boolean."}
            $copy.SetAttribute($key,[string][int]$Operation[$key]);$found=$true
        }
    }
    if(-not $found){throw 'Specify at least one paragraph break.'}
    return ,$copy
}

function Get-ScopedSectionContentWidth {
    param([xml]$Xml)
    $ns=New-ScopedNamespaces $Xml;$nodes=$Xml.SelectNodes('/hs:sec/hp:p/hp:run/hp:secPr/hp:pagePr',$ns)
    if($nodes.Count -ne 1){throw 'Columns require one direct section page definition.'}
    $page=$nodes[0];$margin=Get-ScopedOneChild $page 'hp:margin'
    if((Get-ScopedXmlInteger $margin 'gutter') -gt 0 -and $page.GetAttribute('gutterType') -cne 'LEFT_ONLY'){throw 'Nonzero non-left gutter needs an explicit binding-aware column layout.'}
    $dimension=if($page.GetAttribute('landscape') -ceq 'NARROWLY'){'height'}elseif($page.GetAttribute('landscape') -ceq 'WIDELY'){'width'}else{throw 'Unknown page orientation.'}
    $width=(Get-ScopedXmlInteger $page $dimension 1)-(Get-ScopedXmlInteger $margin 'left')-(Get-ScopedXmlInteger $margin 'right')-(Get-ScopedXmlInteger $margin 'gutter')
    if($width -lt 1){throw 'Section has no positive content width.'};return $width
}

function New-ScopedColumns {
    param([Xml.XmlElement]$Target,$Operation)
    $count=Get-ScopedIndex $Operation['count'] 'columns.count'
    if($count -lt 1 -or $count -gt 16){throw 'Column count must be 1 to 16.'}
    $gap=ConvertTo-ScopedMm $Operation['gapMm'] 'columns.gapMm'
    $contentWidth=Get-ScopedSectionContentWidth $Target.OwnerDocument
    if([long]$gap*($count-1) -ge $contentWidth){throw 'Column gaps consume the content area.'}
    $xml=$Target.OwnerDocument;$ns=New-ScopedNamespaces $xml;$copy=$Target.CloneNode($true)
    if($Target.LocalName -ceq 'colPr'){$column=$copy}
    else {
        $column=$xml.CreateElement('hp','colPr',$script:ScopedHp);$ctrl=$xml.CreateElement('hp','ctrl',$script:ScopedHp);$null=$ctrl.AppendChild($column);$null=$copy.AppendChild($ctrl)
        foreach($pair in @(@('id',''),@('type','NEWSPAPER'),@('layout','LEFT'))){$column.SetAttribute($pair[0],$pair[1])}
    }
    Assert-ScopedCellAttributes $column @('id','type','layout','colCount','sameSz','sameGap')
    if($column.GetAttribute('type') -cne 'NEWSPAPER' -or $column.GetAttribute('layout') -cnotin @('LEFT','RIGHT','MIRROR')){throw 'Only canonical newspaper columns are editable.'}
    foreach($child in @($column.ChildNodes)) {
        if($child.NodeType -in @('Whitespace','SignificantWhitespace')){continue}
        if($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or $child.LocalName -cnotin @('colSz','colLine')){throw 'Unknown column metadata cannot be replaced.'}
        if($child.LocalName -ceq 'colSz'){Assert-ScopedCellAttributes $child @('width','gap');if($child.HasChildNodes){throw 'Unknown column-size metadata.'};$null=$column.RemoveChild($child)}
    }
    $column.SetAttribute('colCount',[string]$count);$column.SetAttribute('sameGap',[string]$gap)
    $widths=@()
    if($Operation.ContainsKey('widthsMm')) {
        if($Operation['widthsMm'] -isnot [Collections.IList] -or $Operation['widthsMm'].Count -ne $count){throw 'widthsMm must list every column width.'}
        $widths=@(foreach($value in $Operation['widthsMm']){$n=ConvertTo-ScopedMm $value 'columns.widthsMm';if($n -lt 1){throw 'Column widths must be positive.'};$n})
        $sum=($widths|Measure-Object -Sum).Sum+[long]$gap*($count-1)
        if([Math]::Abs($sum-$contentWidth) -gt $count+1){throw 'Explicit column widths and gaps must fill the section content width.'}
    }
    $column.SetAttribute('sameSz',[string][int]($widths.Count -eq 0))
    for($i=0;$i -lt $widths.Count;$i++) {
        $size=$xml.CreateElement('hp','colSz',$script:ScopedHp);$size.SetAttribute('width',[string]$widths[$i]);$size.SetAttribute('gap',[string]$(if($i -lt $count-1){$gap}else{0}))
        $line=$column.SelectSingleNode('hp:colLine',$ns);if($line){$null=$column.InsertBefore($size,$line)}else{$null=$column.AppendChild($size)}
    }
    return ,$copy
}

function New-ScopedPageBorder {
    param([Xml.XmlElement]$Section,$Operation,$Package,$Allocation)
    $kind=$Operation['applyTo'];if($kind -isnot [string] -or $kind -cnotin @('BOTH','EVEN','ODD')){throw 'Page-border applyTo must be BOTH, EVEN or ODD.'}
    $style=ConvertTo-ScopedMap $Operation['style'] 'page-border.style'
    Assert-ScopedKeys $style @() 'page-border.style' @('borderType','borderWidthMm','borderColor','fillColor','borders')
    if($style.Count -eq 0){throw 'Page-border style must not be empty.'}
    $copy=$Section.CloneNode($true);$ns=New-ScopedNamespaces $Section.OwnerDocument
    $nodes=$copy.SelectNodes(('hp:pageBorderFill[@type="'+$kind+'"]'),$ns)
    if($nodes.Count -ne 1){throw 'Selected page-border definition is absent or ambiguous.'}
    $node=$nodes[0];$adapter=$Section.OwnerDocument.CreateElement('hp','tc',$script:ScopedHp);$adapter.SetAttribute('borderFillIDRef',$node.GetAttribute('borderFillIDRef'))
    $resource=New-ScopedBorderResource $Package.Xml['Contents/header.xml'] $adapter $Operation['style'] $Allocation
    if($null -eq $resource){throw 'No page-border resource was prepared.'};$node.SetAttribute('borderFillIDRef',$resource.Id)
    if($Operation.ContainsKey('offsetMm')) {
        $offset=ConvertTo-ScopedMap $Operation['offsetMm'] 'page-border.offsetMm';Assert-ScopedKeys $offset @() 'page-border.offsetMm' @('left','right','top','bottom')
        if($offset.Count -eq 0){throw 'Page-border offsets must not be empty.'}
        $target=Get-ScopedOneChild $node 'hp:offset'
        foreach($side in $offset.Keys){$target.SetAttribute($side,[string](ConvertTo-ScopedMm $offset[$side] "page-border.offsetMm.$side"))}
        $page=Get-ScopedOneChild $copy 'hp:pagePr';$w=Get-ScopedXmlInteger $page 'width' 1;$h=Get-ScopedXmlInteger $page 'height' 1
        if($page.GetAttribute('landscape') -ceq 'NARROWLY'){$swap=$w;$w=$h;$h=$swap}
        if((Get-ScopedXmlInteger $target 'left')+(Get-ScopedXmlInteger $target 'right') -ge $w -or (Get-ScopedXmlInteger $target 'top')+(Get-ScopedXmlInteger $target 'bottom') -ge $h){throw 'Page-border offsets consume the paper area.'}
    }
    return ,$copy
}

function New-ScopedSortedTable {
    param([Xml.XmlElement]$Table,$Operation,$Package)
    $copy=$Table.CloneNode($true);$grid=Get-ScopedTableGrid $copy;$ns=New-ScopedNamespaces $copy.OwnerDocument
    $start=Get-ScopedIndex $Operation['startRow'] 'sort.startRow';$end=Get-ScopedIndex $Operation['endRow'] 'sort.endRow';$column=Get-ScopedIndex $Operation['column'] 'sort.column'
    if($start -gt $end -or $end -ge $grid.RowCount -or $column -ge $grid.ColumnCount){throw 'Sort range or key column is outside the table.'}
    $dataType=$Operation['dataType'];$direction=$Operation['direction']
    if($dataType -isnot [string] -or $dataType -cnotin @('TEXT','NUMBER')){throw 'Sort dataType must be TEXT or NUMBER.'}
    if($direction -isnot [string] -or $direction -cnotin @('ASC','DESC')){throw 'Sort direction must be ASC or DESC.'}
    if(@($grid.Cells|Where-Object RowSpan -gt 1).Count -gt 0){throw 'Row sorting cannot move vertical merges.'}
    # Moving references can alter their targets; preserve them rather than guessing rebasing semantics.
    if($copy.SelectNodes('.//hp:fieldBegin | .//hp:fieldEnd | .//hp:bookmark | .//hp:footNote | .//hp:endNote',$ns).Count -gt 0){throw 'Reference-bearing tables need an explicit reference-aware sort.'}
    $ordered=[Collections.Generic.List[object]]::new()
    for($row=$start;$row -le $end;$row++) {
        foreach($cell in @($grid.Cells|Where-Object Row -eq $row)){Assert-ScopedEditContext $cell.Node;if($cell.Node.GetAttribute('header') -cin @('1','true')){throw 'Sort range must exclude repeating header rows.'}}
        $keyCell=$grid.Occupancy["$row,$column"]
        if($keyCell.Column -ne $column){throw 'Sort key must select a cell anchor.'}
        $sub=Get-ScopedOneChild $keyCell.Node 'hp:subList'
        if($sub.SelectNodes('.//hp:pic | .//hp:tbl | .//hp:ctrl | .//hp:rect | .//hp:ellipse | .//hp:line',$ns).Count -gt 0){throw 'Sort key must contain plain visible text only.'}
        $content=Get-ScopedCellContent $keyCell.Node (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'charPr') (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'paraPr') -PreserveCellMetadata
        $key=$content.Text
        if($dataType -ceq 'NUMBER'){
            $key=$key.Trim();if($key -cnotmatch '^[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?$'){throw 'Numeric sort requires plain decimal numbers; units and empty values are not guessed.'}
            $key=[decimal]::Parse($key.Replace(',',''),[Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture)
        }
        $entry=@{Row=$grid.Rows[$row];Key=$key};$position=$ordered.Count
        while($position -gt 0){$previous=$ordered[$position-1];$comparison=if($dataType -ceq 'NUMBER'){$key.CompareTo([decimal]$previous.Key)}else{[StringComparer]::Ordinal.Compare([string]$key,[string]$previous.Key)};if($direction -ceq 'DESC'){$comparison=-$comparison};if($comparison -ge 0){break};$position--}
        $ordered.Insert($position,$entry)
    }
    # Keep non-row children and whitespace at their original positions.
    $marker=$copy.OwnerDocument.CreateComment('sort-anchor');$null=$copy.InsertBefore($marker,$grid.Rows[$start])
    for($row=$start;$row -le $end;$row++){$null=$copy.RemoveChild($grid.Rows[$row])}
    for($i=0;$i -lt $ordered.Count;$i++){
        $node=$ordered[$i].Row;foreach($cell in $node.SelectNodes('hp:tc',$ns)){(Get-ScopedOneChild $cell 'hp:cellAddr').SetAttribute('rowAddr',[string]($start+$i))};$null=$copy.InsertBefore($node,$marker)
    }
    $null=$copy.RemoveChild($marker)
    foreach($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',$ns))){$null=$cache.ParentNode.RemoveChild($cache)}
    $null=Get-ScopedTableGrid $copy;return ,$copy
}
