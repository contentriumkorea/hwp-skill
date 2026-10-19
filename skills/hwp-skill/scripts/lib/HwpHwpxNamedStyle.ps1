# Prepared-only; parent resolves conflicts, commits Resources and invalidates section caches.
# apply-named-style: address, styleId; optional expectedText, textStyle,
# paragraphStyle, name, englishName. Any override clones the PARA named style.
# Applying deliberately replaces ALL direct run charPrIDRef values (local differences
# are discarded); controls, nested paragraphs and unknown target/resource XML survive.
# expectedText accepts only text/inline-tab/lineBreak runs, never inferred control text.
# StyleType attributes: pinned model 1453388472c703a4b299a0834f425cdac16644b9.
# Limits: readable Int32 IDs, 256-unit names, 4096 runs, 65536 nodes, depth 64,
# 16 MiB paragraph/prepared resources and cumulative prepared paragraph characters.

function Get-ScopedNamedStyleId {
    param($Value,[string]$Location)
    if(($Value -isnot [string] -and -not (Test-ScopedInteger $Value)) -or
        [string]$Value -cnotmatch '\A(?:0|[1-9][0-9]{0,9})\z' -or [decimal]$Value -gt [int]::MaxValue){throw "$Location requires a readable nonnegative Int32 resource ID."}
    return [string]$Value
}

function Assert-ScopedNamedStyleAttributes {
    param([Xml.XmlElement]$Node,[string[]]$Allowed)
    $keys=[Collections.Generic.HashSet[string]]::new($Allowed,[StringComparer]::Ordinal)
    foreach($attribute in $Node.Attributes){
        if($attribute.NamespaceURI -ceq 'http://www.w3.org/2000/xmlns/'){continue}
        if($attribute.NamespaceURI -cne '' -or -not $keys.Contains($attribute.LocalName)){throw 'Unsupported named style metadata.'}
    }
}

function Assert-ScopedNamedStyleTreeBound {
    param([Xml.XmlElement]$Root)
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Node=$Root;Depth=0})
    $count=0;[long]$characters=0
    while($stack.Count -gt 0){
        $entry=$stack.Pop();$node=$entry.Node;$count++
        if($count -gt 65536 -or $entry.Depth -gt 64){throw 'Named style subtree exceeds 65536 nodes or depth 64.'}
        if($null -ne $node.Value){$characters+=$node.Value.Length}
        if($null -ne $node.Attributes){foreach($a in $node.Attributes){$characters+=$a.Name.Length+$a.Value.Length}}
        if($characters -gt 16MB){throw 'Named style subtree exceeds 16 MiB characters.'}
        foreach($child in $node.ChildNodes){
            if($stack.Count+$count -ge 65536){throw 'Named style subtree exceeds 65536 nodes.'}
            $stack.Push(@{Node=$child;Depth=$entry.Depth+1})
        }
    }
}

function New-ScopedNamedStyle {
    param([Xml.XmlElement]$Target,$Operation,$Package,$Allocation)
    $op=ConvertTo-ScopedMap $Operation 'apply-named-style'
    Assert-ScopedSectionSettingsKeys $op @('type','address','styleId') 'apply-named-style' @('expectedText','textStyle','paragraphStyle','name','englishName')
    if($op['type'] -isnot [string] -or -not [string]::Equals($op['type'],'apply-named-style',[StringComparison]::Ordinal)){throw 'Invalid apply-named-style.type.'}
    $id=Get-ScopedNamedStyleId $op['styleId'] 'styleId'
    $address=ConvertTo-ScopedMap $op['address'] 'address'
    Assert-ScopedSectionSettingsKeys $address @('version','sourceSha256','part','path','kind') 'address'
    if(-not [string]::Equals($address['version'],'1.0',[StringComparison]::Ordinal) -or -not [string]::Equals($address['kind'],'p',[StringComparison]::Ordinal)){throw 'Named style requires an inspected paragraph address.'}
    $resolved=Resolve-ScopedAddress $op['address'] $Package 'p'
    if(-not [object]::ReferenceEquals($resolved.Node,$Target)){throw 'address does not identify the supplied paragraph.'}

    $cloneStyle=$false
    foreach($key in @('name','englishName')){
        if(-not $op.ContainsKey($key)){continue};$cloneStyle=$true;$value=$op[$key]
        if($value -isnot [string] -or $value.Length -gt 256 -or ($key -ceq 'name' -and [string]::IsNullOrWhiteSpace($value))){throw "$key must be a string of at most 256 UTF16 units; name must be nonblank."}
        $null=[Xml.XmlConvert]::VerifyXmlChars($value)
    }
    foreach($key in @('textStyle','paragraphStyle')){
        if(-not $op.ContainsKey($key)){continue};$cloneStyle=$true
        $fields=ConvertTo-ScopedMap $op[$key] $key
        $allowed=if($key -ceq 'textStyle'){@('fontFamily','fontSizePt','bold','italic','textColor','underline','strikeout','superscript','subscript','letterSpacingPercent','widthPercent')}else{@('alignment','lineSpacingPercent','lineSpacing','leftMarginMm','rightMarginMm','indentMm','marginBeforeMm','marginAfterMm','keepWithNext','keepLines','widowOrphan','pageBreakBefore')}
        Assert-ScopedSectionSettingsKeys $fields @() $key $allowed
        if($fields.Count -eq 0){throw 'A named style override must contain at least one formatting property.'}
        if($fields.ContainsKey('textColor') -and ($fields['textColor'] -isnot [string] -or $fields['textColor'] -cnotmatch '\A#[0-9A-Fa-f]{6}\z')){throw 'textStyle.textColor must be exactly #RRGGBB.'}
        # The shared format helper uses linguistic comparisons; validate enums ordinally here.
        foreach($field in @('underline','alignment')){
            if($fields.ContainsKey($field)){
                $choices=if($field -ceq 'underline'){@('NONE','BOTTOM','CENTER','TOP')}else{@('LEFT','CENTER','RIGHT','JUSTIFY','DISTRIBUTE','DISTRIBUTE_SPACE')}
                $null=ConvertTo-ScopedSectionSettingValue $fields[$field] $choices "$key.$field"
            }
        }
        if($fields.ContainsKey('lineSpacing')){
            $spacing=ConvertTo-ScopedMap $fields['lineSpacing'] 'lineSpacing'
            Assert-ScopedSectionSettingsKeys $spacing @('type','valuePt') 'lineSpacing'
            $null=ConvertTo-ScopedSectionSettingValue $spacing['type'] @('FIXED','AT_LEAST') 'lineSpacing.type'
        }
    }

    # Bound traversal before CloneNode/OuterXml; unknown target content is preserved verbatim.
    Assert-ScopedNamedStyleTreeBound $Target
    $ns=New-ScopedNamespaces $Target.OwnerDocument;$runs=$Target.SelectNodes('hp:run',$ns)
    if($runs.Count -lt 1 -or $runs.Count -gt 4096){throw 'Named style requires 1 to 4096 direct runs.'}
    if($op.ContainsKey('expectedText')){
        $expected=$op['expectedText']
        if($expected -isnot [string] -or $expected.Length -gt 1MB){throw 'expectedText must be a string of at most 1 MiB.'}
        $null=[Xml.XmlConvert]::VerifyXmlChars($expected)
        $visible=[Text.StringBuilder]::new()
        foreach($run in $runs){$text=Get-ScopedInlineText $run;if($visible.Length+$text.Length -gt 1MB){throw 'Visible paragraph text exceeds 1 MiB.'};$null=$visible.Append($text)}
        $actual=$visible.ToString().Replace("`r`n","`n").Replace("`r","`n")
        if(-not [string]::Equals($expected.Replace("`r`n","`n").Replace("`r","`n"),$actual,[StringComparison]::Ordinal)){throw 'expectedText does not match the original paragraph.'}
        foreach($child in $Target.ChildNodes){
            if($child.NodeType -in @('Whitespace','SignificantWhitespace','Comment')){continue}
            if($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or ($child.LocalName -cne 'run' -and $child.LocalName -cne 'linesegarray')){throw 'Cannot infer expectedText across paragraph controls.'}
        }
    }
    $paragraphXml=$Target.OuterXml
    if($paragraphXml.Length -gt 16MB){throw 'Named style paragraph exceeds 16 MiB serialized characters.'}
    foreach($budget in @('NamedStylePreparedCharacters','PreparedResourceCharacters','ClonedResourceCharacters')){
        if($Allocation.ContainsKey($budget) -and (-not (Test-ScopedInteger $Allocation[$budget]) -or $Allocation[$budget] -lt 0 -or $Allocation[$budget] -gt 16MB)){throw 'Invalid named style 16 MiB allocation budget.'}
    }
    [long]$before=0;if($Allocation.ContainsKey('NamedStylePreparedCharacters')){$before=$Allocation.NamedStylePreparedCharacters}
    if($before+$paragraphXml.Length -gt 16MB){throw 'Named style prepared paragraphs exceed 16 MiB.'}

    $header=$Package.Xml['Contents/header.xml'];$hns=New-ScopedNamespaces $header
    $collection=Get-ScopedOneChild (Get-ScopedOneChild $header.DocumentElement 'hh:refList') 'hh:styles'
    Assert-ScopedNamedStyleAttributes $collection @('itemCnt')
    $styles=$collection.SelectNodes('hh:style',$hns)
    if($styles.Count -gt 65536 -or (Get-ScopedXmlInteger $collection 'itemCnt') -ne $styles.Count){throw 'Named style collection count does not match its resources or exceeds 65536.'}
    foreach($child in $collection.ChildNodes){
        if($child.NodeType -in @('Whitespace','SignificantWhitespace','Comment')){continue}
        if($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHh -or $child.LocalName -cne 'style'){throw 'Unknown named style collection metadata.'}
    }
    $styleIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $definitions=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($item in $styles){$key=Get-ScopedNamedStyleId $item.GetAttribute('id') 'style.id';if(-not $styleIds.Add($key)){throw 'Duplicate named style ID.'};$definitions.Add($key,$item)}
    if($Allocation.ContainsKey('Resources')){
        foreach($resource in $Allocation.Resources){
            if($resource.Kind -ceq 'style'){
                $key=Get-ScopedNamedStyleId $resource.Id 'prepared style.id'
                if(-not $styleIds.Add($key)){throw 'Duplicate prepared named style ID.'};$definitions.Add($key,$resource.Node)
            }
        }
    }
    if(-not $definitions.ContainsKey($id)){throw 'Named paragraph style is absent.'};$source=$definitions[$id]
    Assert-ScopedNamedStyleAttributes $source @('id','type','name','engName','paraPrIDRef','charPrIDRef','nextStyleIDRef','langID','lockForm')
    foreach($child in $source.ChildNodes){if($child.NodeType -notin @('Whitespace','SignificantWhitespace','Comment')){throw 'Unsupported named style child metadata.'}}
    if(-not [string]::Equals($source.GetAttribute('type'),'PARA',[StringComparison]::Ordinal)){throw 'Named style source must have exact type PARA.'}
    if($source.HasAttribute('lockForm')){$null=ConvertTo-ScopedSectionSettingValue $source.GetAttribute('lockForm') @('0','false') 'style.lockForm'}
    if($source.HasAttribute('langID')){$lang=Get-ScopedNamedStyleId $source.GetAttribute('langID') 'style.langID';if([long]$lang -gt 65535){throw 'Unsupported named style language ID.'}}
    $next=Get-ScopedNamedStyleId $source.GetAttribute('nextStyleIDRef') 'style.nextStyleIDRef'
    if(-not $definitions.ContainsKey($next) -or -not [string]::Equals($definitions[$next].GetAttribute('type'),'PARA',[StringComparison]::Ordinal)){throw 'Named next paragraph style is absent or unsupported.'}
    $charId=Get-ScopedNamedStyleId $source.GetAttribute('charPrIDRef') 'style.charPrIDRef'
    $paraId=Get-ScopedNamedStyleId $source.GetAttribute('paraPrIDRef') 'style.paraPrIDRef'
    foreach($kind in @('charPr','paraPr')){
        $ids=Get-ScopedAvailableStyleIds $header $kind $Allocation
        $reference=$source.GetAttribute($kind+'IDRef')
        if(-not $ids.Contains($reference)){throw "Named style $kind resource is absent."}
        $container=if($kind -ceq 'charPr'){'charProperties'}else{'paraProperties'}
        $formatCollection=Get-ScopedOneChild (Get-ScopedOneChild $header.DocumentElement 'hh:refList') ('hh:'+$container)
        $definitionsForRef=@($formatCollection.SelectNodes(('hh:'+$kind+'[@id="'+$reference+'"]'),$hns))
        if($Allocation.ContainsKey('Resources')){$definitionsForRef+=@($Allocation.Resources|Where-Object {$_.Kind -ceq $kind -and [string]::Equals($_.Id,$reference,[StringComparison]::Ordinal)}|ForEach-Object {$_.Node})}
        if($definitionsForRef.Count -ne 1){throw "Named style $kind definition is absent or ambiguous."}
        $override=if($kind -ceq 'charPr'){'textStyle'}else{'paragraphStyle'}
        if($op.ContainsKey($override)){Assert-ScopedNamedStyleTreeBound $definitionsForRef[0]}
    }

    # Isolate mutable allocation containers: a late format/font/budget failure must
    # not leak prepared resources, reserved IDs or cache entries to the caller.
    # Cache values retain their identity; only newly created resources may be rebased.
    if($Allocation.ContainsKey('FormatCache')){
        foreach($cached in $Allocation.FormatCache.Values){$null=Get-ScopedNamedStyleId $cached.Id 'cached format resource.id'}
    }
    $staged=@{}
    foreach($key in $Allocation.Keys){
        $value=$Allocation[$key]
        if($value -is [Collections.Generic.HashSet[string]]){$value=[Collections.Generic.HashSet[string]]::new($value,[StringComparer]::Ordinal)}
        elseif($value -is [Collections.IDictionary]){$value=ConvertTo-ScopedMap $value 'allocation'}
        elseif($key -ceq 'Resources'){$list=[Collections.Generic.List[object]]::new();foreach($resource in $value){$list.Add($resource)};$value=$list}
        $staged[$key]=$value
    }
    if($cloneStyle){
        $newId=Get-ScopedReadableResourceId $styleIds
        foreach($spec in @(@{Key='textStyle';Kind='charPr'},@{Key='paragraphStyle';Kind='paraPr'})){
            if(-not $op.ContainsKey($spec.Key)){continue}
            $kind=$spec.Kind;$ids=Get-ScopedAvailableStyleIds $header $kind $staged
            $readableId=Get-ScopedReadableResourceId $ids
            $resource=New-ScopedFormatResource $header $source $kind $op[$spec.Key] $staged
            if([long]$resource.Id -gt [int]::MaxValue){
                $oldId=$resource.Id;$resource.Id=$readableId;$resource.Node.SetAttribute('id',$readableId)
                $null=$staged[$kind].Remove($oldId);$null=$staged[$kind].Add($readableId)
            }
            if($kind -ceq 'charPr'){$charId=$resource.Id}else{$paraId=$resource.Id}
        }
        $copyStyle=$source.CloneNode($true);$copyStyle.SetAttribute('id',$newId)
        $copyStyle.SetAttribute('charPrIDRef',$charId);$copyStyle.SetAttribute('paraPrIDRef',$paraId)
        if([string]::Equals($next,$id,[StringComparison]::Ordinal)){$copyStyle.SetAttribute('nextStyleIDRef',$newId)}
        if($op.ContainsKey('name')){$copyStyle.SetAttribute('name',$op['name'])}
        if($op.ContainsKey('englishName')){$copyStyle.SetAttribute('engName',$op['englishName'])}
        Add-ScopedPreparedResource $staged @{Node=$copyStyle;Collection=$collection;Kind='style';Id=$newId;CountAttribute='itemCnt'}
        $id=$newId
    }
    if($staged.ContainsKey('Resources')){foreach($resource in $staged.Resources){$null=Get-ScopedNamedStyleId $resource.Id 'prepared resource.id'}}
    $copy=$Target.CloneNode($true);$copy.SetAttribute('styleIDRef',$id);$copy.SetAttribute('paraPrIDRef',$paraId)
    foreach($run in $copy.SelectNodes('hp:run',$ns)){$run.SetAttribute('charPrIDRef',$charId)}
    $length=$copy.OuterXml.Length
    if($before+$length -gt 16MB){throw 'Named style prepared paragraphs exceed 16 MiB.'}
    $staged.NamedStylePreparedCharacters=$before+$length
    foreach($key in $staged.Keys){$Allocation[$key]=$staged[$key]}
    return ,$copy
}
