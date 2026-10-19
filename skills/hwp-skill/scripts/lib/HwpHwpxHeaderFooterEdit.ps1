# Private prepared run replacement; the parent owns dispatch, source hashes,
# overlapping-run conflicts, section-wide cache invalidation, output and reopen.
# Stored shape/policies corroborated from the local official source snapshot:
# 1453388472c703a4b299a0834f425cdac16644b9,
# OWPML/Class/Para/HeaderFooterType.cpp, ParaListType.cpp and enums.content.
# No native host, package writes or protection changes. 16 MiB prepared XML
# characters per allocation; shared paragraph/run/text/resource limits also apply.

function Copy-ScopedHeaderFooterAllocation {
    param($Allocation)
    $stage=@{}
    foreach($key in $Allocation.Keys){$stage[$key]=$Allocation[$key]}
    # These are the mutable collections touched by the shared text/resource writer.
    # Existing resource records and XML collection pointers are read, never edited.
    foreach($key in @('charPr','paraPr')){
        if($stage.ContainsKey($key)){
            $ids=$stage[$key]
            if($ids -isnot [Collections.Generic.HashSet[string]]){throw "Invalid allocation $key ID set."}
            $stage[$key]=[Collections.Generic.HashSet[string]]::new($ids,$ids.Comparer)
        }
    }
    foreach($key in @('Fonts','FormatCache')){
        if($stage.ContainsKey($key)){
            if($stage[$key] -isnot [hashtable]){throw "Invalid allocation $key cache."}
            $stage[$key]=$stage[$key].Clone()
        }
    }
    if($stage.ContainsKey('Resources')){
        if($stage.Resources -isnot [Collections.Generic.List[object]]){throw 'Invalid allocation Resources list.'}
        $stage.Resources=[Collections.Generic.List[object]]::new($stage.Resources)
    }
    foreach($rule in @(@('ObjectId',4294967296L),@('NextParagraphId',4294967296L),@('CellContentNodes',16384),@('CellTextCharacters',16MB),@('ClonedResourceCharacters',16MB),@('PreparedResourceCharacters',16MB),@('HeaderFooterPreparedCharacters',16MB))){
        if($stage.ContainsKey($rule[0])){
            $value=$stage[$rule[0]]
            if(-not (Test-ScopedInteger $value) -or $value -lt 0 -or $value -gt $rule[1]){throw "Invalid allocation $($rule[0]) budget."}
        }
    }
    return ,$stage
}

function Assert-ScopedHeaderFooterTree {
    param([Xml.XmlElement]$Node)
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Node=$Node;Depth=0});$count=0
    while($stack.Count -gt 0){
        $entry=$stack.Pop();$count++
        if($count -gt 65536 -or $entry.Depth -gt 64){throw 'Header/footer run exceeds 65536 nodes or depth 64.'}
        foreach($child in $entry.Node.ChildNodes){
            if($count+$stack.Count -ge 65536){throw 'Header/footer run exceeds 65536 nodes.'}
            $stack.Push(@{Node=$child;Depth=$entry.Depth+1})
        }
    }
    if($Node.OuterXml.Length -gt 16MB){throw 'Header/footer run exceeds 16 MiB XML characters.'}
}

function New-ScopedHeaderFooter {
    param([Xml.XmlElement]$Target,$Operation,$Package,$Allocation)
    try {
        $op=ConvertTo-ScopedMap $Operation 'set-header-footer'
        Assert-ScopedSectionSettingsKeys $op @('type','sectionIndex','kind','applyTo','expectedText','paragraphs') 'set-header-footer'
        if($op['type'] -isnot [string] -or -not [string]::Equals($op['type'],'set-header-footer',[StringComparison]::Ordinal)){throw 'Expected set-header-footer type.'}
        $kind=ConvertTo-ScopedSectionSettingValue $op['kind'] @('header','footer') 'kind'
        $apply=ConvertTo-ScopedSectionSettingValue $op['applyTo'] @('BOTH','EVEN','ODD') 'applyTo'
        if($op['expectedText'] -isnot [string] -or $op['expectedText'].Length -gt 1MB){throw 'expectedText must be a string of at most 1 MiB characters.'}
        $null=[Xml.XmlConvert]::VerifyXmlChars($op['expectedText'])
        $index=Get-ScopedIndex $op['sectionIndex'] 'sectionIndex'
        if($index -ge $Package.Sections.Count){throw 'sectionIndex is outside the package sections.'}
        $xml=$Package.Xml[$Package.Sections[$index]];$ns=New-ScopedNamespaces $xml
        $section=$xml.SelectSingleNode('/hs:sec',$ns)
        if($null -eq $section -or $null -eq $Target -or $Target.NamespaceURI -cne $script:ScopedHp -or $Target.LocalName -cne 'run' -or
            -not [object]::ReferenceEquals($Target.OwnerDocument,$xml) -or $Target.ParentNode -isnot [Xml.XmlElement] -or
            $Target.ParentNode.LocalName -cne 'p' -or $Target.ParentNode.NamespaceURI -cne $script:ScopedHp -or
            -not [object]::ReferenceEquals($Target.ParentNode.ParentNode,$section)){throw 'Target must be the original canonical section paragraph run.'}
        $definitions=$section.SelectNodes('.//*[local-name()="secPr"]')
        if($definitions.Count -ne 1 -or $definitions[0].NamespaceURI -cne $script:ScopedHp -or
            -not [object]::ReferenceEquals($definitions[0].ParentNode,$Target) -or
            -not [object]::ReferenceEquals($Target.SelectSingleNode('*'),$definitions[0])){throw 'Target must contain the sole section secPr as its first element.'}
        Assert-ScopedEditContext $Target
        foreach($ancestor in @($section,$Target.ParentNode,$Target)){
            foreach($flag in @('protect','lock','editable')){if($ancestor.HasAttribute($flag) -and $ancestor.GetAttribute($flag) -cnotin @('0','false')){throw 'Protected or special section context is not editable.'}}
        }
        $policies=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$existing=$null
        # Search all definitions of the requested kind, including other policies,
        # nested containers and foreign-namespace lookalikes, before creating any.
        foreach($node in $section.SelectNodes(('.//*[local-name()="'+$kind+'"]'))){
            $ctrl=$node.ParentNode;$policy=$node.GetAttribute('applyPageType')
            if($node.NamespaceURI -cne $script:ScopedHp -or $ctrl.LocalName -cne 'ctrl' -or $ctrl.NamespaceURI -cne $script:ScopedHp -or
                -not [object]::ReferenceEquals($ctrl.ParentNode,$Target)){throw 'Every matching header/footer definition must be in a direct ctrl of the canonical run.'}
            $null=ConvertTo-ScopedSectionSettingValue $policy @('BOTH','EVEN','ODD') 'stored header/footer policy'
            if(-not $policies.Add($policy)){throw 'Unknown or duplicate header/footer policy.'}
            if($policy -ceq $apply){$existing=$node}
        }
        if(($policies.Contains('BOTH') -and ($policies.Count -gt 1 -or $apply -cne 'BOTH')) -or ($apply -ceq 'BOTH' -and $policies.Count -gt 0 -and -not $policies.Contains('BOTH'))){throw 'BOTH cannot be mixed with EVEN or ODD for the same kind.'}
        Assert-ScopedHeaderFooterTree $Target
        if($Allocation -isnot [Collections.IDictionary] -or ([Collections.IDictionary]$Allocation).IsReadOnly){throw 'Allocation must be a writable dictionary.'}
        $sub=$null
        if($null -ne $existing){
            $null=Get-ScopedStyleId $existing.GetAttribute('id') 'header/footer.id'
            $sub=Get-ScopedOneChild $existing 'hp:subList'
            foreach($node in @($existing.ParentNode,$existing,$sub)){
                foreach($flag in @('protect','lock','editable')){if($node.HasAttribute($flag) -and $node.GetAttribute($flag) -cnotin @('0','false')){throw 'Protected or special header/footer is not editable.'}}
            }
            foreach($key in @('linkListIDRef','linkListNextIDRef','hasTextRef','hasNumRef')){if($sub.HasAttribute($key) -and $sub.GetAttribute($key) -cnotin @('','0','false')){throw 'Linked or special header/footer lists cannot be replaced.'}}
            $null=Get-ScopedXmlInteger $sub 'textWidth';$null=Get-ScopedXmlInteger $sub 'textHeight'
            if($sub.GetAttribute('textDirection') -cnotin @('HORIZONTAL','VERTICAL','VERTICALALL') -or $sub.GetAttribute('lineWrap') -cnotin @('BREAK','SQUEEZE','KEEP') -or $sub.GetAttribute('vertAlign') -cnotin @('TOP','CENTER','BOTTOM')){throw 'Invalid header/footer list layout enum.'}
            foreach($child in $sub.ChildNodes){if($child.NodeType -notin @('Whitespace','SignificantWhitespace') -and ($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or $child.LocalName -cne 'p')){throw 'Header/footer list must contain only direct text paragraphs.'}}
        } elseif($op['expectedText'].Length -ne 0){throw 'A missing header/footer requires empty expectedText.'}
        # The cell adapter carries paragraph content only. The actual list keeps
        # its original ID, width and metadata; cell-only list restrictions do not
        # misclassify a normal nonzero-width header/footer as a linked cell.
        $cell=$xml.CreateElement('hp','tc',$script:ScopedHp);$cell.SetAttribute('protect','0');$cell.SetAttribute('editable','0')
        foreach($name in @('subList','cellAddr','cellSpan','cellSz','cellMargin')){$null=$cell.AppendChild($xml.CreateElement('hp',$name,$script:ScopedHp))}
        $adapter=Get-ScopedOneChild $cell 'hp:subList'
        if($null -ne $sub){foreach($p in $sub.SelectNodes('hp:p',$ns)){$null=$adapter.AppendChild($p.CloneNode($true))}}
        else {
            $p=$xml.CreateElement('hp','p',$script:ScopedHp);$p.SetAttribute('id','0');$p.SetAttribute('paraPrIDRef',$Target.ParentNode.GetAttribute('paraPrIDRef'))
            if($Target.ParentNode.HasAttribute('styleIDRef')){$p.SetAttribute('styleIDRef',$Target.ParentNode.GetAttribute('styleIDRef'))}
            $run=$xml.CreateElement('hp','run',$script:ScopedHp);$run.SetAttribute('charPrIDRef',$Target.GetAttribute('charPrIDRef'))
            $null=$run.AppendChild($xml.CreateElement('hp','t',$script:ScopedHp));$null=$p.AppendChild($run);$null=$adapter.AppendChild($p)
        }
        $header=$Package.Xml['Contents/header.xml']
        $content=Get-ScopedCellContent $cell (Get-ScopedAvailableStyleIds $header 'charPr' $Allocation) (Get-ScopedAvailableStyleIds $header 'paraPr' $Allocation) -PreserveCellMetadata
        $expected=$op['expectedText'].Replace("`r`n","`n").Replace("`r","`n")
        $actual=$content.Text.Replace("`r`n","`n").Replace("`r","`n")
        # The shared cell guard is linguistic; this contract must retain every
        # character, including soft hyphens and zero-width characters.
        if(-not [string]::Equals($expected,$actual,[StringComparison]::Ordinal)){throw 'expectedText does not match the entire original header/footer text.'}
        $stage=Copy-ScopedHeaderFooterAllocation $Allocation
        [long]$before=0;if($stage.ContainsKey('HeaderFooterPreparedCharacters')){$before=$stage.HeaderFooterPreparedCharacters}
        # Prime the established allocators and synchronize the two pending ID
        # cursors, so new lists/controls and paragraphs cannot reuse each other.
        $sourceFloor=[long](Get-ScopedNextObjectId $Package @{})
        if(-not $stage.ContainsKey('ObjectId')){$stage.ObjectId=$sourceFloor}
        if(-not $stage.ContainsKey('NextParagraphId')){$id=Get-ScopedNextParagraphId $Package $stage;$stage.NextParagraphId=[long]$id}
        $next=[Math]::Max($sourceFloor,[Math]::Max([long]$stage.ObjectId,[long]$stage.NextParagraphId));$stage.ObjectId=$next;$stage.NextParagraphId=$next
        $controlId=$null;$listId=$null
        if($null -eq $existing){$controlId=Get-ScopedNextObjectId $Package $stage;$listId=Get-ScopedNextObjectId $Package $stage;$stage.NextParagraphId=$stage.ObjectId}
        $prepared=New-ScopedCellContentReplacement $cell @{expectedText=$op['expectedText'];paragraphs=$op['paragraphs']} $Package $stage
        $stage.ObjectId=[Math]::Max([long]$stage.ObjectId,[long]$stage.NextParagraphId)
        $copy=$Target.CloneNode($true)
        if($null -ne $existing){
            $new=$copy.SelectSingleNode(('hp:ctrl/hp:'+$kind+'[@applyPageType="'+$apply+'"]'),$ns)
            $newSub=Get-ScopedOneChild $new 'hp:subList'
            foreach($p in @($newSub.SelectNodes('hp:p',$ns))){$null=$newSub.RemoveChild($p)}
        } else {
            $ctrl=$xml.CreateElement('hp','ctrl',$script:ScopedHp);$new=$xml.CreateElement('hp',$kind,$script:ScopedHp)
            $new.SetAttribute('id',$controlId);$new.SetAttribute('applyPageType',$apply)
            $newSub=$xml.CreateElement('hp','subList',$script:ScopedHp)
            foreach($pair in @(@('id',$listId),@('textDirection','HORIZONTAL'),@('lineWrap','BREAK'),@('vertAlign','TOP'),@('linkListIDRef','0'),@('linkListNextIDRef','0'),@('textWidth',[string](Get-ScopedSectionContentWidth $xml)),@('textHeight','0'),@('hasTextRef','0'),@('hasNumRef','0'))){$newSub.SetAttribute($pair[0],$pair[1])}
            $null=$new.AppendChild($newSub);$null=$ctrl.AppendChild($new);$text=$copy.SelectSingleNode('hp:t',$ns)
            if($null -ne $text){$null=$copy.InsertBefore($ctrl,$text)}else{$null=$copy.AppendChild($ctrl)}
        }
        foreach($p in @($prepared.SelectNodes('hp:subList/hp:p',$ns))){$null=$newSub.AppendChild($p)}
        Assert-ScopedHeaderFooterTree $copy
        [long]$total=$before+$copy.OuterXml.Length
        if($total -gt 16MB){throw 'Cumulative prepared header/footer XML exceeds 16 MiB characters.'}
        $stage.HeaderFooterPreparedCharacters=$total
        foreach($key in $stage.Keys){$Allocation[$key]=$stage[$key]}
        return ,$copy
    } catch {throw "Header/footer: $($_.Exception.Message)"}
}
