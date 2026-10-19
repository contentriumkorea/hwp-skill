# Prepared sibling reorder only. Never transfer section, field or list state.
function New-ScopedParagraphMove {
    param([Xml.XmlElement]$Paragraph,[Xml.XmlElement]$Destination,$Operation,$Package,$Allocation)
    Assert-ScopedSectionSettingsKeys $Operation @('type','address','targetAddress','placement','expectedText') 'move-paragraph'
    if(-not [string]::Equals($Operation['type'],'move-paragraph',[StringComparison]::Ordinal)){throw 'Invalid paragraph move type.'}
    $placement=ConvertTo-ScopedSectionSettingValue $Operation['placement'] @('before','after') 'move-paragraph.placement'
    if($Operation['expectedText'] -isnot [string] -or $Operation['expectedText'].Length -gt 1MB){throw 'Move expectedText must be a string up to 1 MiB.'}
    if([object]::ReferenceEquals($Paragraph,$Destination)){throw 'Cannot move a paragraph relative to itself.'}
    $parent=$Paragraph.ParentNode
    if(-not [object]::ReferenceEquals($parent,$Destination.ParentNode)){throw 'Paragraph move requires siblings in the same section or text list.'}
    if(-not (($parent.NamespaceURI -ceq $script:ScopedHs -and $parent.LocalName -ceq 'sec') -or ($parent.NamespaceURI -ceq $script:ScopedHp -and $parent.LocalName -ceq 'subList'))){throw 'Unsupported paragraph move container.'}
    if($parent.LocalName -ceq 'subList'){
        foreach($key in @('linkListIDRef','linkListNextIDRef','hasTextRef','hasNumRef')){
            if($parent.HasAttribute($key) -and $parent.GetAttribute($key) -cnotmatch '^(0)?$'){throw 'Linked or special text lists cannot be reordered.'}
        }
    }
    $used=0L
    if($Allocation.ContainsKey('MovePreparedCharacters')){
        if(-not (Test-ScopedInteger $Allocation.MovePreparedCharacters) -or $Allocation.MovePreparedCharacters -lt 0 -or $Allocation.MovePreparedCharacters -gt 16MB){throw 'Invalid paragraph move preparation budget.'}
        $used=[long]$Allocation.MovePreparedCharacters
    }
    # Bound traversal before cloning, reference queries or visible-text materialization.
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Node=$parent;Depth=0});$count=0;[long]$characters=0
    while($stack.Count -gt 0){
        $entry=$stack.Pop();$node=$entry.Node;$count++
        if($count -gt 65536 -or $entry.Depth -gt 64){throw 'Paragraph move container exceeds its preparation limit.'}
        if($null -ne $node.Value){$characters+=$node.Value.Length}
        if($null -ne $node.Attributes){foreach($a in $node.Attributes){$characters+=$a.Name.Length+$a.Value.Length}}
        if($characters+$used -gt 16MB){throw 'Cumulative paragraph move preparation exceeds 16 MiB.'}
        foreach($child in $node.ChildNodes){
            if($count+$stack.Count -ge 65536){throw 'Paragraph move container exceeds its preparation limit.'}
            $stack.Push(@{Node=$child;Depth=$entry.Depth+1})
        }
    }
    $length=$parent.OuterXml.Length
    if($length+$used -gt 16MB){throw 'Cumulative paragraph move preparation exceeds 16 MiB.'}
    $ns=New-ScopedNamespaces $Paragraph.OwnerDocument
    if($parent.SelectNodes('.//hp:fieldBegin | .//hp:fieldEnd | .//hp:bookmark | .//hp:footNote | .//hp:endNote',$ns).Count){throw 'Reference-bearing containers cannot be reordered without rebasing.'}
    if($placement -ceq 'before' -and $Destination.SelectNodes('.//hp:secPr',$ns).Count){throw 'Cannot insert before the section-property paragraph.'}
    # The existing text-only reader validates all run branches and preserves exact visible text.
    $cell=$Paragraph.OwnerDocument.CreateElement('hp','tc',$script:ScopedHp)
    foreach($name in @('subList','cellAddr','cellSpan','cellSz','cellMargin')){$null=$cell.AppendChild($Paragraph.OwnerDocument.CreateElement('hp',$name,$script:ScopedHp))}
    $null=(Get-ScopedOneChild $cell 'hp:subList').AppendChild($Paragraph.CloneNode($true))
    $header=$Package.Xml['Contents/header.xml']
    $content=Get-ScopedCellContent $cell (Get-ScopedStyleIds $header 'charPr') (Get-ScopedStyleIds $header 'paraPr')
    $expected=$Operation['expectedText']
    if(-not [string]::Equals($content.Text,$expected,[StringComparison]::Ordinal)){throw 'Move expectedText does not match the original paragraph.'}
    $children=@($parent.SelectNodes('*'));$sourceIndex=-1;$destinationIndex=-1
    for($i=0;$i -lt $children.Count;$i++){
        if([object]::ReferenceEquals($children[$i],$Paragraph)){$sourceIndex=$i}
        if([object]::ReferenceEquals($children[$i],$Destination)){$destinationIndex=$i}
    }
    if($sourceIndex -lt 0 -or $destinationIndex -lt 0){throw 'Paragraph move anchors are absent.'}
    $copy=$parent.CloneNode($true);$nodes=$copy.SelectNodes('*');$moving=$nodes[$sourceIndex];$anchor=$nodes[$destinationIndex]
    $null=$copy.RemoveChild($moving)
    if($placement -ceq 'before'){$null=$copy.InsertBefore($moving,$anchor)}else{$null=$copy.InsertAfter($moving,$anchor)}
    $Allocation.MovePreparedCharacters=$used+$length
    return ,$copy
}
