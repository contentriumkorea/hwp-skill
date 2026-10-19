# Prepared-only private helper. Parent owns dispatch, cache invalidation and commit.
# Stored attributes/defaults: hancom-io/hwpx-owpml-model commit
# 1453388472c703a4b299a0834f425cdac16644b9, OWPML/Class/Para/
# SectionDefinitionType.cpp, startNum.cpp, visibility.cpp, grid.cpp, pageNum.cpp.
# Limits: sideChar 256 UTF16 units; cloned run 65536 nodes, depth 64,
# 16 MiB serialized characters; cumulative prepared XML 16 MiB per Allocation.

function Assert-ScopedSectionSettingsKeys {
    param($Map, [string[]]$Required, [string]$Location, [string[]]$Optional=@())
    Assert-ScopedKeys $Map $Required $Location $Optional
    # Shared -ccontains checks use linguistic equality, which ignores some characters.
    $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in ($Required+$Optional)) { $null=$allowed.Add($key) }
    foreach ($key in $Map.Keys) { if (-not $allowed.Contains($key)) { throw "Unrecognized property: $Location.$key" } }
}

function ConvertTo-ScopedSectionSettingValue {
    param($Value, $Rule, [string]$Location, [switch]$Stored)
    if ($Rule -is [array]) {
        if ($Value -is [string]) {
            foreach ($choice in $Rule) { if ([string]::Equals($Value,$choice,[StringComparison]::Ordinal)) { return $Value } }
        }
        throw "$Location has an unsupported enum value."
    }
    switch -CaseSensitive ($Rule) {
        'uint32' {
            if ($Stored) {
                if ($Value -isnot [string] -or $Value -cnotmatch '^(0|[1-9][0-9]{0,9})$' -or [decimal]$Value -gt [uint32]::MaxValue) { throw "$Location must be uint32." }
            } elseif (-not (Test-ScopedInteger $Value) -or $Value -lt 0 -or $Value -gt [uint32]::MaxValue) { throw "$Location must be uint32 without coercion." }
            return ([uint32]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        'Boolean' {
            if ($Stored) {
                if ($Value -is [string]) {
                    foreach ($choice in @('0','1','false','true')) { if ([string]::Equals($Value,$choice,[StringComparison]::Ordinal)) { return $Value } }
                }
                throw "$Location has invalid stored Boolean metadata."
            }
            if ($Value -isnot [bool]) { throw "$Location must be Boolean." }
            return [string][int]$Value
        }
        'sideChar' {
            if ($Value -isnot [string] -or $Value.Length -gt 256) { throw "$Location must be a string of at most 256 UTF16 units." }
            $null=[Xml.XmlConvert]::VerifyXmlChars($Value)
            return $Value
        }
        default { throw 'Unknown section setting validation rule.' }
    }
}

function Assert-ScopedSectionSettingsLeaf {
    param([Xml.XmlElement]$Node, $Rules)
    Assert-ScopedCellAttributes $Node @($Rules.Keys)
    foreach ($child in $Node.ChildNodes) {
        if ($child.NodeType -notin @('Whitespace','SignificantWhitespace')) { throw "Unknown $($Node.LocalName) child metadata." }
    }
    foreach ($name in $Rules.Keys) {
        if (-not $Node.HasAttribute($name)) { throw "Canonical $($Node.LocalName) is missing $name." }
        $null=ConvertTo-ScopedSectionSettingValue $Node.GetAttribute($name) $Rules[$name] "$($Node.LocalName).$name" -Stored
    }
}

function New-ScopedSectionSettings {
    param([Xml.XmlElement]$Target, $Operation, $Package, $Allocation)
    $op=ConvertTo-ScopedMap $Operation 'set-section-settings'
    Assert-ScopedSectionSettingsKeys $op @('type','sectionIndex','settings') 'set-section-settings'
    if ($op['type'] -isnot [string] -or -not [string]::Equals($op['type'],'set-section-settings',[StringComparison]::Ordinal)) { throw 'Invalid set-section-settings.type.' }
    $index=Get-ScopedIndex $op['sectionIndex'] 'sectionIndex'
    if ($index -ge $Package.Sections.Count) { throw 'sectionIndex is outside the package sections.' }
    $xml=$Package.Xml[$Package.Sections[$index]]; $ns=New-ScopedNamespaces $xml
    $section=$xml.SelectSingleNode('/hs:sec',$ns)
    if ($null -eq $section -or $null -eq $Target -or $null -eq $Target.ParentNode -or
        -not [object]::ReferenceEquals($Target.OwnerDocument,$xml) -or
        -not [object]::ReferenceEquals($Target.ParentNode.ParentNode,$section)) { throw 'Section settings require the canonical section paragraph run target.' }
    $definitions=$section.SelectNodes('.//hp:secPr',$ns)
    if ($definitions.Count -ne 1 -or -not [object]::ReferenceEquals($definitions[0].ParentNode,$Target) -or
        $Target.SelectNodes('hp:secPr',$ns).Count -ne 1 -or $section.SelectNodes('hp:p/hp:run',$ns) -notcontains $Target) { throw 'Target must contain the sole direct section hp:secPr.' }
    foreach ($ancestor in @($section,$Target.ParentNode)) {
        foreach ($flag in @('protect','lock','editable')) {
            if ($ancestor.HasAttribute($flag) -and
                -not [string]::Equals($ancestor.GetAttribute($flag),'0',[StringComparison]::Ordinal) -and
                -not [string]::Equals($ancestor.GetAttribute($flag),'false',[StringComparison]::Ordinal)) { throw "Protected or unknown section ancestor flag: $flag." }
        }
    }
    Assert-ScopedCellAttributes $Target @('charPrIDRef')
    $sec=$definitions[0]
    Assert-ScopedCellAttributes $sec @('id','textDirection','spaceColumns','tabStop','tabStopVal','tabStopUnit','outlineShapeIDRef','memoShapeIDRef','textVerticalWidthHead','masterPageCnt')
    $directions=@('HORIZONTAL','VERTICAL','VERTICALALL')
    $null=ConvertTo-ScopedSectionSettingValue $sec.GetAttribute('textDirection') $directions 'secPr.textDirection' -Stored
    if ($sec.HasAttribute('textVerticalWidthHead')) { $null=ConvertTo-ScopedSectionSettingValue $sec.GetAttribute('textVerticalWidthHead') 'Boolean' 'secPr.textVerticalWidthHead' -Stored }
    $rules=@{
        startNumbers=@{pageStartsOn=@('BOTH','EVEN','ODD');page='uint32';pic='uint32';tbl='uint32';equation='uint32'}
        visibility=@{hideFirstHeader='Boolean';hideFirstFooter='Boolean';hideFirstMasterPage='Boolean';hideFirstPageNum='Boolean';hideFirstEmptyLine='Boolean';showLineNumber='Boolean';border=@('HIDE_FIRST','SHOW_FIRST','SHOW_ALL');fill=@('HIDE_FIRST','SHOW_FIRST','SHOW_ALL')}
        grid=@{lineGrid='uint32';charGrid='uint32';wonggojiFormat='Boolean'}
        pageNumber=@{position=@('NONE','TOP_LEFT','TOP_CENTER','TOP_RIGHT','BOTTOM_LEFT','BOTTOM_CENTER','BOTTOM_RIGHT','OUTSIDE_TOP','OUTSIDE_BOTTOM','INSIDE_TOP','INSIDE_BOTTOM');format=@('DIGIT','CIRCLED_DIGIT','ROMAN_CAPITAL','ROMAN_SMALL','LATIN_CAPITAL','LATIN_SMALL','HANGUL_SYLLABLE','HANGUL_JAMO','IDEOGRAPH','2DIGIT');sideChar='sideChar'}
    }
    $settings=ConvertTo-ScopedMap $op['settings'] 'settings'
    Assert-ScopedSectionSettingsKeys $settings @() 'settings' @('startNumbers','visibility','grid','textDirection','pageNumber')
    if ($settings.Count -eq 0) { throw 'settings must not be empty.' }
    $prepared=@{}
    foreach ($key in $settings.Keys) {
        if ($key -ceq 'textDirection') { $prepared[$key]=ConvertTo-ScopedSectionSettingValue $settings[$key] $directions 'settings.textDirection'; continue }
        $fields=ConvertTo-ScopedMap $settings[$key] "settings.$key"
        Assert-ScopedSectionSettingsKeys $fields @() "settings.$key" @($rules[$key].Keys)
        if ($fields.Count -eq 0) { throw "settings.$key must not be empty." }
        $prepared[$key]=@{}
        foreach ($name in $fields.Keys) { $prepared[$key][$name]=ConvertTo-ScopedSectionSettingValue $fields[$name] $rules[$key][$name] "settings.$key.$name" }
    }
    $childNames=@{startNumbers='startNum';visibility='visibility';grid='grid'}
    foreach ($key in $childNames.Keys) {
        if ($prepared.ContainsKey($key)) { Assert-ScopedSectionSettingsLeaf (Get-ScopedOneChild $sec ('hp:'+$childNames[$key])) $rules[$key] }
    }
    $page=$null
    $pageRules=@{pos=$rules.pageNumber.position;formatType=$rules.pageNumber.format;sideChar='sideChar'}
    if ($prepared.ContainsKey('pageNumber')) {
        # Search the entire section, including nested tables/headers, before creating.
        $pages=$section.SelectNodes('.//*[local-name()="pageNum"]')
        if ($pages.Count -gt 1) { throw 'Ambiguous section pageNum controls.' }
        if ($pages.Count -eq 1) {
            $page=$pages[0]; $ctrl=$page.ParentNode
            if ($page.NamespaceURI -cne $script:ScopedHp -or $ctrl.LocalName -cne 'ctrl' -or $ctrl.NamespaceURI -cne $script:ScopedHp -or
                -not [object]::ReferenceEquals($ctrl.ParentNode,$Target)) { throw 'Existing pageNum must belong to the target run direct hp:ctrl.' }
            Assert-ScopedCellAttributes $ctrl @()
            Assert-ScopedSectionSettingsLeaf $page $pageRules
        }
    }
    $before=[long]0
    if ($Allocation.ContainsKey('SectionSettingsPreparedCharacters')) {
        $value=$Allocation.SectionSettingsPreparedCharacters
        if (-not (Test-ScopedInteger $value) -or $value -lt 0 -or $value -gt 16MB) { throw 'Invalid 16 MiB section settings allocation budget.' }
        $before=[long]$value
    }
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Node=$Target;Depth=0});$count=0;[long]$characters=0
    while ($stack.Count -gt 0) {
        $entry=$stack.Pop();$node=$entry.Node;$count++
        if ($count -gt 65536 -or $entry.Depth -gt 64) { throw 'Section run exceeds 65536 nodes or depth 64.' }
        if ($null -ne $node.Value) { $characters+=$node.Value.Length }
        if ($null -ne $node.Attributes) { foreach ($attribute in $node.Attributes) { $characters+=$attribute.Name.Length+$attribute.Value.Length } }
        if ($characters -gt 16MB) { throw 'Section run exceeds 16 MiB characters.' }
        foreach ($child in $node.ChildNodes) {
            if ($count+$stack.Count -ge 65536) { throw 'Section run exceeds 65536 nodes.' }
            $stack.Push(@{Node=$child;Depth=$entry.Depth+1})
        }
    }
    if ($prepared.ContainsKey('pageNumber') -and $null -eq $page -and $count+2 -gt 65536) { throw 'Prepared section run exceeds 65536 nodes.' }
    if ($before+$Target.OuterXml.Length -gt 16MB) { throw 'Prepared section settings exceed 16 MiB characters.' }
    $copy=$Target.CloneNode($true);$newSec=Get-ScopedOneChild $copy 'hp:secPr'
    if ($prepared.ContainsKey('textDirection')) { $newSec.SetAttribute('textDirection',$prepared.textDirection) }
    foreach ($key in $childNames.Keys) {
        if (-not $prepared.ContainsKey($key)) { continue }
        $node=Get-ScopedOneChild $newSec ('hp:'+$childNames[$key])
        foreach ($name in $prepared[$key].Keys) { $node.SetAttribute($name,$prepared[$key][$name]) }
    }
    if ($prepared.ContainsKey('pageNumber')) {
        if ($null -ne $page) { $newPage=$copy.SelectSingleNode('hp:ctrl/hp:pageNum',$ns) }
        else {
            $ctrl=$xml.CreateElement('hp','ctrl',$script:ScopedHp);$newPage=$xml.CreateElement('hp','pageNum',$script:ScopedHp)
            $newPage.SetAttribute('pos','TOP_LEFT');$newPage.SetAttribute('formatType','DIGIT');$newPage.SetAttribute('sideChar','')
            $null=$ctrl.AppendChild($newPage);$text=$copy.SelectSingleNode('hp:t',$ns)
            if ($null -ne $text) { $null=$copy.InsertBefore($ctrl,$text) } else { $null=$copy.AppendChild($ctrl) }
        }
        $names=@{position='pos';format='formatType';sideChar='sideChar'}
        foreach ($name in $prepared.pageNumber.Keys) { $newPage.SetAttribute($names[$name],$prepared.pageNumber[$name]) }
    }
    [long]$total=$before+$copy.OuterXml.Length
    if ($total -gt 16MB) { throw 'Prepared section settings exceed 16 MiB characters.' }
    $Allocation.SectionSettingsPreparedCharacters=$total
    return ,$copy
}
