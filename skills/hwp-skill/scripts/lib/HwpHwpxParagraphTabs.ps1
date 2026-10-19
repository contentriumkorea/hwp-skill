# Prepared resource clones only. Storage: pinned Hancom TabDefType/tabItem models.
function Get-ScopedReadableResourceId {
    param($Ids)
    [long]$next=0;foreach($id in $Ids){$next=[Math]::Max($next,([long]$id+1))}
    # The inspector reads these references as Int32. Reuse a free lower ID at the boundary.
    if($next -gt [int]::MaxValue){$next=0;while($next -le [int]::MaxValue -and $Ids.Contains([string]$next)){$next++}}
    if($next -gt [int]::MaxValue){throw 'No readable resource IDs remain.'}
    return [string]$next
}
function New-ScopedParagraphTabs {
    param([Xml.XmlElement]$Target,$Operation,$Package,$Allocation)
    $op=ConvertTo-ScopedMap $Operation 'set-paragraph-tabs'
    Assert-ScopedSectionSettingsKeys $op @('type','address','tabs') 'set-paragraph-tabs' @('autoTabLeft','autoTabRight')
    if($op['type'] -isnot [string] -or -not [string]::Equals($op['type'],'set-paragraph-tabs',[StringComparison]::Ordinal) -or $Target.LocalName -cne 'p' -or $Target.NamespaceURI -cne $script:ScopedHp){throw 'Paragraph tabs require an inspected paragraph.'}
    if($op['tabs'] -isnot [Collections.IList] -or $op['tabs'].Count -gt 64){throw 'tabs must be an array of 0 to 64 explicit tab stops.'}
    $types=@('LEFT','RIGHT','CENTER','DECIMAL','VERTBAR')
    $leaders=@('NONE','SOLID','DOT','DASH','DASH_DOT','DASH_DOT_DOT','LONG_DASH','CIRCLE','DOUBLE_SLIM','SLIM_THICK','THICK_SLIM','SLIM_THICK_SLIM','WAVE','DOUBLEWAVE','THICK3D','THICKREV3D','3D','REV3D')
    $prepared=[Collections.Generic.List[object]]::new();$previous=-1
    foreach($item in $op['tabs']){
        $tab=ConvertTo-ScopedMap $item 'tabs.item';Assert-ScopedSectionSettingsKeys $tab @('positionMm') 'tabs.item' @('alignment','leader')
        $position=ConvertTo-ScopedMm $tab['positionMm'] 'tabs.positionMm'
        if($position -le $previous){throw 'Tab positions must be strictly increasing after HWPUNIT rounding.'};$previous=$position
        $alignment=if($tab.ContainsKey('alignment')){$tab['alignment']}else{'LEFT'}
        $leader=if($tab.ContainsKey('leader')){$tab['leader']}else{'NONE'}
        $alignment=ConvertTo-ScopedSectionSettingValue $alignment $types 'tabs.alignment'
        $leader=ConvertTo-ScopedSectionSettingValue $leader $leaders 'tabs.leader'
        $prepared.Add(@{pos=$position;type=$alignment;leader=$leader})
    }
    foreach($flag in @('autoTabLeft','autoTabRight')){if($op.ContainsKey($flag) -and $op[$flag] -isnot [bool]){throw "$flag must be Boolean."}}
    Assert-ScopedEditContext $Target
    $header=$Package.Xml['Contents/header.xml'];$ns=New-ScopedNamespaces $header
    $paraIds=Get-ScopedAvailableStyleIds $header 'paraPr' $Allocation
    $originalId=Get-ScopedStyleId $Target.GetAttribute('paraPrIDRef') 'paragraph.paraPrIDRef'
    if(-not $paraIds.Contains($originalId)){throw 'Original paragraph resource is absent.'}
    $paraCollection=Get-ScopedOneChild (Get-ScopedOneChild $header.DocumentElement 'hh:refList') 'hh:paraProperties'
    $sourcePara=$paraCollection.SelectNodes(('hh:paraPr[@id="'+$originalId+'"]'),$ns)
    if($sourcePara.Count -ne 1){throw 'Original paragraph resource is absent or ambiguous.'}
    $collection=Get-ScopedOneChild (Get-ScopedOneChild $header.DocumentElement 'hh:refList') 'hh:tabProperties'
    Assert-ScopedCellAttributes $collection @('itemCnt')
    $tabIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $nodes=$collection.SelectNodes('hh:tabPr',$ns)
    if((Get-ScopedXmlInteger $collection 'itemCnt') -ne $nodes.Count){throw 'Tab collection count does not match its resources.'}
    foreach($child in $collection.ChildNodes){if($child.NodeType -in @('Whitespace','SignificantWhitespace','Comment')){continue};if($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHh -or $child.LocalName -cne 'tabPr'){throw 'Unknown tab collection metadata.'}}
    foreach($node in $nodes){if(-not $tabIds.Add((Get-ScopedStyleId $node.GetAttribute('id') 'tabPr.id'))){throw 'Duplicate tab resource ID.'}}
    if($Allocation.ContainsKey('Resources')){foreach($resource in $Allocation.Resources){if($resource.Kind -ceq 'tabPr'){$null=$tabIds.Add([string]$resource.Id)}}}
    $sourceTabId=Get-ScopedStyleId $sourcePara[0].GetAttribute('tabPrIDRef') 'paraPr.tabPrIDRef'
    $sourceTab=$collection.SelectNodes(('hh:tabPr[@id="'+$sourceTabId+'"]'),$ns)
    if($sourceTab.Count -ne 1){throw 'Referenced tab resource is absent or ambiguous.'}
    Assert-ScopedCellAttributes $sourceTab[0] @('id','autoTabLeft','autoTabRight')
    foreach($flag in @('autoTabLeft','autoTabRight')){if($sourceTab[0].GetAttribute($flag) -cnotmatch '\A(?:0|1|false|true)\z'){throw 'Unknown automatic-tab metadata.'}}
    foreach($child in $sourceTab[0].ChildNodes){
        if($child.NodeType -in @('Whitespace','SignificantWhitespace')){continue}
        if($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHh -or $child.LocalName -cne 'tabItem'){throw 'Unknown tab resource metadata cannot be replaced.'}
        Assert-ScopedCellAttributes $child @('pos','type','leader','unit')
        if($child.HasChildNodes){throw 'Unknown stored tab item metadata.'}
        $null=ConvertTo-ScopedSectionSettingValue $child.GetAttribute('type') $types 'stored tab type'
        $null=ConvertTo-ScopedSectionSettingValue $child.GetAttribute('leader') $leaders 'stored tab leader'
        if($child.HasAttribute('unit')){$null=ConvertTo-ScopedSectionSettingValue $child.GetAttribute('unit') @('CHAR','HWPUNIT') 'stored tab unit'}
        $null=Get-ScopedXmlInteger $child 'pos'
    }
    $paraId=Get-ScopedReadableResourceId $paraIds;$tabId=Get-ScopedReadableResourceId $tabIds
    if($sourcePara[0].OuterXml.Length+$sourceTab[0].OuterXml.Length -gt 16MB){throw 'Tab resource clones exceed 16 MiB.'}
    $newPara=$sourcePara[0].CloneNode($true);$newPara.SetAttribute('id',[string]$paraId);$newPara.SetAttribute('tabPrIDRef',[string]$tabId)
    $newTab=$sourceTab[0].CloneNode($false);$newTab.SetAttribute('id',[string]$tabId)
    foreach($flag in @('autoTabLeft','autoTabRight')){if($op.ContainsKey($flag)){$newTab.SetAttribute($flag,[string][int]$op[$flag])}}
    foreach($entry in $prepared){$node=$header.CreateElement('hh','tabItem',$script:ScopedHh);foreach($key in @('pos','type','leader')){$node.SetAttribute($key,[string]$entry[$key])};$node.SetAttribute('unit','HWPUNIT');$null=$newTab.AppendChild($node)}
    [long]$before=0
    if($Allocation.ContainsKey('PreparedResourceCharacters')){if(-not (Test-ScopedInteger $Allocation.PreparedResourceCharacters) -or $Allocation.PreparedResourceCharacters -lt 0 -or $Allocation.PreparedResourceCharacters -gt 16MB){throw 'Invalid prepared resource budget.'};$before=[long]$Allocation.PreparedResourceCharacters}
    if($before+$newPara.OuterXml.Length+$newTab.OuterXml.Length -gt 16MB){throw 'Prepared resources exceed 16 MiB characters.'}
    $tabResource=@{Node=$newTab;Collection=$collection;Kind='tabPr';Id=[string]$tabId;CountAttribute='itemCnt'}
    $paraResource=@{Node=$newPara;Collection=$paraCollection;Kind='paraPr';Id=[string]$paraId;CountAttribute='itemCnt'}
    Add-ScopedPreparedResource $Allocation $tabResource;Add-ScopedPreparedResource $Allocation $paraResource
    $null=$paraIds.Add([string]$paraId);$Allocation.paraPr=$paraIds
    return $paraResource
}
