# Prepared clones only; parent owns dispatch, overlap checks, cache invalidation and commit.
# Pinned Hancom 1453388472c703a4b299a0834f425cdac16644b9: Head/SlashType.cpp,
# BorderFillType.cpp, BorderType.cpp and g_SlashTypeList/g_LineTypeList2/g_LineWithList.
# CENTER is the single straight diagonal; Crooked=0, isCounter=false are constructor defaults.
# ReadAttribute accepts legacy isCrooked only when Crooked is absent. Preserve that spelling.
function Assert-ScopedCellDiagonalCloneBounds {
    param([Xml.XmlElement]$Node)
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Node=$Node;Depth=0});$count=0;[long]$characters=0
    while($stack.Count -gt 0){
        $entry=$stack.Pop();$current=$entry.Node;$count++
        if($count -gt 65536 -or $entry.Depth -gt 64){throw 'Cell diagonal subtree exceeds 65536 nodes or depth 64.'}
        if($null -ne $current.Value){$characters+=$current.Value.Length}
        if($null -ne $current.Attributes){foreach($a in $current.Attributes){$characters+=$a.Name.Length+$a.Value.Length}}
        if($characters -gt 16MB){throw 'Cell diagonal subtree exceeds 16 MiB characters.'}
        foreach($child in $current.ChildNodes){
            if($count+$stack.Count -ge 65536){throw 'Cell diagonal subtree exceeds 65536 nodes.'}
            $stack.Push(@{Node=$child;Depth=$entry.Depth+1})
        }
    }
    if($Node.OuterXml.Length -gt 16MB){throw 'Cell diagonal subtree exceeds 16 MiB serialized characters.'}
}

function New-ScopedCellDiagonal {
    param([Xml.XmlElement]$Target,$Operation,$Package,$Allocation)
    $op=ConvertTo-ScopedMap $Operation 'set-cell-diagonal'
    Assert-ScopedSectionSettingsKeys $op @('type','address','direction') 'set-cell-diagonal' @('line')
    $null=ConvertTo-ScopedSectionSettingValue $op['type'] @('set-cell-diagonal') 'type'
    $direction=ConvertTo-ScopedSectionSettingValue $op['direction'] @('SLASH','BACK_SLASH','CROSS','NONE') 'direction'
    if($direction -ceq 'NONE'){
        if($op.ContainsKey('line')){throw 'NONE must omit line; the stored diagonal line is preserved.'}
    }elseif(-not $op.ContainsKey('line')){throw 'A visible diagonal requires line.type, line.widthMm and line.color.'}
    $types=@('NONE','SOLID','DOT','DASH','DASH_DOT','DASH_DOT_DOT','LONG_DASH','CIRCLE','DOUBLE_SLIM','SLIM_THICK','THICK_SLIM','SLIM_THICK_SLIM','WAVE','DOUBLEWAVE','THICK3D','THICKREV3D','3D','REV3D')
    $widths=@('0.1 mm','0.12 mm','0.15 mm','0.2 mm','0.25 mm','0.3 mm','0.4 mm','0.5 mm','0.6 mm','0.7 mm','1.0 mm','1.5 mm','2.0 mm','3.0 mm','4.0 mm','5.0 mm')
    $line=$null;$width=$null
    if($direction -cne 'NONE'){
        $line=ConvertTo-ScopedMap $op['line'] 'line'
        Assert-ScopedSectionSettingsKeys $line @('type','widthMm','color') 'line'
        $null=ConvertTo-ScopedSectionSettingValue $line['type'] @($types|Where-Object {$_ -cne 'NONE'}) 'line.type'
        $number=Get-ScopedNumber $line['widthMm'] 0.1 5 'line.widthMm'
        foreach($candidate in $widths){
            $decimal=[decimal]::Parse($candidate.Substring(0,$candidate.Length-3),[Globalization.CultureInfo]::InvariantCulture)
            # Do not round high precision decimals into a supported thickness.
            $equal=if($line['widthMm'] -is [decimal]){$line['widthMm'] -eq $decimal}else{$number -eq [double]$decimal}
            if($equal){$width=$candidate;break}
        }
        if($null -eq $width){throw 'line.widthMm must be an exact supported HWPX thickness.'}
        if($line['color'] -isnot [string] -or $line['color'] -cnotmatch '\A#[0-9A-Fa-f]{6}\z'){throw 'line.color must be #RRGGBB.'}
    }
    if($null -eq $Target -or -not [string]::Equals($Target.LocalName,'tc',[StringComparison]::Ordinal) -or
        -not [string]::Equals($Target.NamespaceURI,$script:ScopedHp,[StringComparison]::Ordinal)){throw 'Cell diagonal requires an inspected hp:tc.'}
    $address=ConvertTo-ScopedMap $op['address'] 'address'
    Assert-ScopedSectionSettingsKeys $address @('version','sourceSha256','part','path','kind') 'address'
    $null=ConvertTo-ScopedSectionSettingValue $address['version'] @('1.0') 'address.version'
    $null=ConvertTo-ScopedSectionSettingValue $address['kind'] @('tc') 'address.kind'
    if($address['sourceSha256'] -isnot [string] -or $address['sourceSha256'] -cnotmatch '\A[0-9A-Fa-f]{64}\z'){throw 'address.sourceSha256 must be a SHA-256 string.'}
    $resolved=Resolve-ScopedAddress $address $Package 'tc'
    if(-not [object]::ReferenceEquals($resolved.Node,$Target)){throw 'Cell diagonal target differs from its inspected address.'}
    Assert-ScopedEditContext $Target
    # Shared context validation uses linguistic comparisons. Enforce stored flags ordinally too.
    $ancestor=$Target
    while($ancestor -is [Xml.XmlElement]){
        if($ancestor.LocalName -ceq 'tc' -or $ancestor.LocalName -ceq 'tbl'){
            foreach($flag in @('protect','lock','editable')){
                if($ancestor.HasAttribute($flag)){$null=ConvertTo-ScopedSectionSettingValue $ancestor.GetAttribute($flag) @('0','false') ('stored '+$flag)}
            }
        }
        $ancestor=$ancestor.ParentNode
    }
    $originalId=$Target.GetAttribute('borderFillIDRef')
    if($originalId -cnotmatch '\A(?:0|[1-9][0-9]{0,9})\z'){throw 'Invalid cell borderFillIDRef.'}
    $null=Get-ScopedStyleId $originalId 'cell.borderFillIDRef'
    $header=$Package.Xml['Contents/header.xml'];$ns=New-ScopedNamespaces $header
    $collection=Get-ScopedOneChild (Get-ScopedOneChild $header.DocumentElement 'hh:refList') 'hh:borderFills'
    $nodes=$collection.SelectNodes('hh:borderFill',$ns)
    if($collection.GetAttribute('itemCnt') -cnotmatch '\A(?:0|[1-9][0-9]{0,9})\z' -or
        (Get-ScopedXmlInteger $collection 'itemCnt') -ne $nodes.Count){throw 'borderFills.itemCnt does not match resources.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$source=$null
    foreach($node in $nodes){
        $id=$node.GetAttribute('id')
        if($id -cnotmatch '\A(?:0|[1-9][0-9]{0,9})\z'){throw 'Invalid borderFill resource ID.'}
        $null=Get-ScopedStyleId $id 'borderFill.id'
        if(-not $ids.Add($id)){throw 'Duplicate borderFill resource ID.'}
        if([string]::Equals($id,$originalId,[StringComparison]::Ordinal)){$source=$node}
    }
    if($Allocation.ContainsKey('Resources')){
        foreach($pending in $Allocation.Resources){
            if(-not [string]::Equals($pending.Kind,'borderFill',[StringComparison]::Ordinal)){continue}
            $id=$pending.Id
            if($id -isnot [string] -or $id -cnotmatch '\A(?:0|[1-9][0-9]{0,9})\z'){throw 'Invalid pending borderFill ID.'}
            $null=Get-ScopedStyleId $id 'pending.borderFill.id'
            if(-not $ids.Add($id) -or $pending.Node.GetAttribute('id') -cne $id -or
                -not [object]::ReferenceEquals($pending.Collection,$collection)){throw 'Conflicting pending borderFill resource.'}
            if([string]::Equals($id,$originalId,[StringComparison]::Ordinal)){$source=$pending.Node}
        }
    }
    if($null -eq $source){throw 'Referenced cell borderFill is absent.'}
    foreach($name in @('slash','backSlash')){
        $flag=Get-ScopedOneChild $source ('hh:'+$name)
        foreach($a in $flag.Attributes){
            if($a.NamespaceURI -ceq '' -and -not [string]::Equals($a.Name,'type',[StringComparison]::Ordinal) -and
                -not [string]::Equals($a.Name,'Crooked',[StringComparison]::Ordinal) -and
                -not [string]::Equals($a.Name,'isCrooked',[StringComparison]::Ordinal) -and
                -not [string]::Equals($a.Name,'isCounter',[StringComparison]::Ordinal)){throw 'Unknown diagonal flag metadata.'}
        }
        $null=ConvertTo-ScopedSectionSettingValue $flag.GetAttribute('type') @('NONE','CENTER') ('stored '+$name+'.type')
        if($flag.HasAttribute('Crooked') -eq $flag.HasAttribute('isCrooked')){throw 'Expected exactly one Crooked or legacy isCrooked flag.'}
        $crooked=if($flag.HasAttribute('Crooked')){'Crooked'}else{'isCrooked'}
        $null=ConvertTo-ScopedSectionSettingValue $flag.GetAttribute($crooked) @('0') ('stored '+$crooked)
        $null=ConvertTo-ScopedSectionSettingValue $flag.GetAttribute('isCounter') @('0','false') 'stored isCounter'
        foreach($child in $flag.ChildNodes){
            if($child.NodeType -in @('Whitespace','SignificantWhitespace','Comment')){continue}
            if($child.NodeType -ne 'Element' -or $child.NamespaceURI -ceq '' -or $child.NamespaceURI -ceq $script:ScopedHh){throw 'Unsupported native diagonal flag child.'}
        }
    }
    $diagonal=Get-ScopedOneChild $source 'hh:diagonal'
    foreach($a in $diagonal.Attributes){
        if($a.NamespaceURI -ceq '' -and -not [string]::Equals($a.Name,'type',[StringComparison]::Ordinal) -and
            -not [string]::Equals($a.Name,'width',[StringComparison]::Ordinal) -and
            -not [string]::Equals($a.Name,'color',[StringComparison]::Ordinal)){throw 'Unknown native diagonal line metadata.'}
    }
    $null=ConvertTo-ScopedSectionSettingValue $diagonal.GetAttribute('type') $types 'stored diagonal.type'
    $null=ConvertTo-ScopedSectionSettingValue $diagonal.GetAttribute('width') $widths 'stored diagonal.width'
    if($diagonal.GetAttribute('color') -cnotmatch '\A#[0-9A-Fa-f]{6}\z'){throw 'Unsupported stored diagonal color.'}
    Assert-ScopedCellDiagonalCloneBounds $Target;Assert-ScopedCellDiagonalCloneBounds $source
    $id=Get-ScopedReadableResourceId $ids
    # Border fills use positive IDs, including the sparse Int32 fallback.
    if($id -ceq '0'){[long]$free=1;while($ids.Contains([string]$free)){$free++};if($free -gt [int]::MaxValue){throw 'No readable borderFill IDs remain.'};$id=[string]$free}
    $copy=$source.CloneNode($true);$copy.SetAttribute('id',$id)
    $slashType=if($direction -ceq 'SLASH' -or $direction -ceq 'CROSS'){'CENTER'}else{'NONE'}
    $backType=if($direction -ceq 'BACK_SLASH' -or $direction -ceq 'CROSS'){'CENTER'}else{'NONE'}
    $copy.SelectSingleNode('hh:slash',$ns).SetAttribute('type',$slashType)
    $copy.SelectSingleNode('hh:backSlash',$ns).SetAttribute('type',$backType)
    if($null -ne $line){$newLine=$copy.SelectSingleNode('hh:diagonal',$ns);$newLine.SetAttribute('type',$line['type']);$newLine.SetAttribute('width',$width);$newLine.SetAttribute('color',$line['color'])}
    $replacement=$Target.CloneNode($true);$replacement.SetAttribute('borderFillIDRef',$id)
    [long]$before=0;[long]$cloneBefore=0
    foreach($key in @('PreparedResourceCharacters','CellDiagonalPreparedCharacters')){
        if($Allocation.ContainsKey($key)){
            if(-not (Test-ScopedInteger $Allocation[$key]) -or $Allocation[$key] -lt 0 -or $Allocation[$key] -gt 16MB){throw 'Invalid cell diagonal preparation budget.'}
            if($key -ceq 'PreparedResourceCharacters'){$before=[long]$Allocation[$key]}else{$cloneBefore=[long]$Allocation[$key]}
        }
    }
    $resourceLength=$copy.OuterXml.Length;$cloneLength=$resourceLength+$replacement.OuterXml.Length
    if($before+$resourceLength -gt 16MB -or $cloneBefore+$cloneLength -gt 16MB){throw 'Cell diagonal preparation exceeds 16 MiB characters.'}
    $resource=@{Node=$copy;Collection=$collection;Kind='borderFill';Id=$id;CountAttribute='itemCnt'}
    Add-ScopedPreparedResource $Allocation $resource
    # Existing ordinary border allocator reserves the IDs registered in Borders.
    if(-not $Allocation.ContainsKey('Borders')){$Allocation.Borders=@{}}
    $Allocation.Borders['cell-diagonal|'+$id]=$resource
    $Allocation.CellDiagonalPreparedCharacters=$cloneBefore+$cloneLength
    return ,$replacement
}
