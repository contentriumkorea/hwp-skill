# Private prepared-only attribute editor; parent dispatch invalidates section caches.
# Source: pinned Hancom 1453388472c703a4b299a0834f425cdac16644b9,
# AutoNumFormatType/NoteShapeType/FootNoteShapeType/EndNoteShapeType.cpp,
# noteSpacing.cpp, numbering.cpp, placement.cpp, noteLine.cpp and enumdef.h.
# Reuses scoped module key, value, numeric and namespace helpers.
# Limits: 256 UTF16 units per prefix/suffix, newNum 1..uint32.MaxValue,
# spacing/length 0..2000 mm; 65536 nodes, depth 64, 16 MiB serialized
# characters of cumulative secPr clones per Allocation. No resources allocated.
# shortcut: fullWidth sentinel semantics are not established by the frozen model;
# expose only fixed lengthMm until independent format evidence establishes them.

function Assert-ScopedNoteSettingsProtection {
    param([Xml.XmlElement]$Node)
    foreach ($flag in @('protect','lock','editable')) {
        if ($Node.HasAttribute($flag) -and
            -not [string]::Equals($Node.GetAttribute($flag),'0',[StringComparison]::Ordinal) -and
            -not [string]::Equals($Node.GetAttribute($flag),'false',[StringComparison]::Ordinal)) { throw "Protected or unknown note settings flag: $($Node.LocalName).$flag." }
    }
}

function New-ScopedNoteSettings {
    param([Xml.XmlElement]$Target, $Operation, $Package, $Allocation)
    $op=ConvertTo-ScopedMap $Operation 'set-note-settings'
    Assert-ScopedSectionSettingsKeys $op @('type','sectionIndex','kind','settings') 'set-note-settings'
    if ($op['type'] -isnot [string] -or -not [string]::Equals($op['type'],'set-note-settings',[StringComparison]::Ordinal)) { throw 'Invalid set-note-settings.type.' }
    $kind=ConvertTo-ScopedSectionSettingValue $op['kind'] @('footnote','endnote') 'set-note-settings.kind'
    $index=Get-ScopedIndex $op['sectionIndex'] 'sectionIndex'
    if ($index -ge $Package.Sections.Count) { throw 'sectionIndex is outside the package sections.' }
    $xml=$Package.Xml[$Package.Sections[$index]];$ns=New-ScopedNamespaces $xml
    $section=$xml.SelectSingleNode('/hs:sec',$ns)
    if ($null -eq $Target -or $null -eq $Target.ParentNode -or $null -eq $section -or
        -not [object]::ReferenceEquals($Target.OwnerDocument,$xml)) { throw 'Note settings require the canonical section secPr target.' }
    $direct=$xml.SelectNodes('/hs:sec/hp:p/hp:run/hp:secPr',$ns)
    if ($direct.Count -ne 1 -or $section.SelectNodes('.//hp:secPr',$ns).Count -ne 1 -or
        -not [object]::ReferenceEquals($direct[0],$Target)) { throw 'Note settings require the sole canonical body hp:secPr target.' }
    $noteName=if ($kind -ceq 'footnote') { 'footNotePr' } else { 'endNotePr' }
    $note=Get-ScopedOneChild $Target ('hp:'+$noteName)
    if ($Target.SelectNodes(('.//hp:'+$noteName),$ns).Count -ne 1) { throw 'Ambiguous nested note definition.' }
    foreach ($node in @($section,$Target.ParentNode.ParentNode,$Target.ParentNode,$Target,$note)) { Assert-ScopedNoteSettingsProtection $node }
    $settings=ConvertTo-ScopedMap $op['settings'] 'settings'
    Assert-ScopedSectionSettingsKeys $settings @() 'settings' @('autoNumFormat','noteSpacing','numbering','placement','noteLine')
    if ($settings.Count -eq 0) { throw 'Note settings must not be empty.' }
    $numberTypes=@('DIGIT','CIRCLED_DIGIT','ROMAN_CAPITAL','ROMAN_SMALL','LATIN_CAPITAL','LATIN_SMALL','CIRCLED_LATIN_CAPITAL','CIRCLED_LATIN_SMALL','HANGUL_SYLLABLE','CIRCLED_HANGUL_SYLLABLE','HANGUL_JAMO','CIRCLED_HANGUL_JAMO','HANGUL_PHONETIC','IDEOGRAPH','CIRCLED_IDEOGRAPH','DECAGON_CIRCLE','DECAGON_CIRCLE_HANJA','2DIGIT')
    $lineTypes=@('NONE','SOLID','DOT','DASH','DASH_DOT','DASH_DOT_DOT','LONG_DASH','CIRCLE','DOUBLE_SLIM','SLIM_THICK','THICK_SLIM','SLIM_THICK_SLIM','WAVE','DOUBLEWAVE','THICK3D','THICKREV3D','3D','REV3D')
    $restartTypes=if ($kind -ceq 'footnote') { @('CONTINUOUS','ON_SECTION','ON_PAGE') } else { @('CONTINUOUS','ON_SECTION') }
    $places=if ($kind -ceq 'footnote') { @('EACH_COLUMN','MERGED_COLUMN','RIGHT_MOST_COLUMN') } else { @('END_OF_DOCUMENT','END_OF_SECTION') }
    $placementKeys=if ($kind -ceq 'footnote') { @('place','beneathText') } else { @('place') }
    $allowed=@{
        autoNumFormat=@('type','prefixChar','suffixChar','supscript')
        noteSpacing=@('betweenNotesMm','belowLineMm','aboveLineMm')
        numbering=@('type','newNum');placement=$placementKeys
        noteLine=@('type','widthMm','color','lengthMm')
    }
    $prepared=@{}
    foreach ($group in $settings.Keys) {
        $fields=ConvertTo-ScopedMap $settings[$group] "settings.$group"
        Assert-ScopedSectionSettingsKeys $fields @() "settings.$group" $allowed[$group]
        if ($fields.Count -eq 0) { throw "settings.$group must not be empty." }
        $leaf=Get-ScopedOneChild $note ('hp:'+$group)
        if ($note.SelectNodes(('.//hp:'+$group),$ns).Count -ne 1) { throw "Ambiguous nested $group note settings." }
        Assert-ScopedNoteSettingsProtection $leaf
        $flag=if ($group -ceq 'autoNumFormat') { 'supscript' } elseif ($group -ceq 'placement') { 'beneathText' } else { $null }
        if ($null -ne $flag -and $leaf.HasAttribute($flag)) { $null=ConvertTo-ScopedSectionSettingValue $leaf.GetAttribute($flag) 'Boolean' "$group.$flag" -Stored }
        $prepared[$group]=@{}
        foreach ($name in $fields.Keys) {
            $value=$fields[$name];$location="settings.$group.$name";$attribute=$name
            switch -CaseSensitive ($group) {
                'autoNumFormat' {
                    if ($name -ceq 'type') { $value=ConvertTo-ScopedSectionSettingValue $value $numberTypes $location }
                    elseif ($name -ceq 'supscript') { $value=ConvertTo-ScopedSectionSettingValue $value 'Boolean' $location }
                    else {
                        if ($value -isnot [string] -or $value.Length -gt 256) { throw "$location must be a string of at most 256 UTF16 units." }
                        $null=[Xml.XmlConvert]::VerifyXmlChars($value)
                    }
                }
                'noteSpacing' { $attribute=$name.Substring(0,$name.Length-2);$value=[string](ConvertTo-ScopedMm $value $location) }
                'numbering' {
                    if ($name -ceq 'type') { $value=ConvertTo-ScopedSectionSettingValue $value $restartTypes $location }
                    else {
                        $value=ConvertTo-ScopedSectionSettingValue $value 'uint32' $location
                        if ($value -ceq '0') { throw "$location must be a positive uint32 newNum." }
                    }
                }
                'placement' {
                    if ($name -ceq 'place') { $value=ConvertTo-ScopedSectionSettingValue $value $places $location }
                    else { $value=ConvertTo-ScopedSectionSettingValue $value 'Boolean' $location }
                }
                'noteLine' {
                    switch -CaseSensitive ($name) {
                        'type' { $value=ConvertTo-ScopedSectionSettingValue $value $lineTypes $location }
                        'widthMm' {
                            $number=Get-ScopedNumber $value 0.1 5 $location
                            if (@(0.1,0.12,0.15,0.2,0.25,0.3,0.4,0.5,0.6,0.7,1,1.5,2,3,4,5) -notcontains $number) { throw "$location must use an official note-line width." }
                            $attribute='width';$value=$number.ToString('0.0#',[Globalization.CultureInfo]::InvariantCulture)+' mm'
                        }
                        'color' {
                            if ($value -isnot [string] -or $value -cnotmatch '\A#[0-9a-fA-F]{6}\z') { throw "$location must be #RRGGBB." }
                        }
                        'lengthMm' { $attribute='length';$value=[string](ConvertTo-ScopedMm $value $location) }
                    }
                }
            }
            $prepared[$group][$attribute]=$value
        }
    }
    $before=[long]0
    if ($Allocation.ContainsKey('NoteSettingsPreparedCharacters')) {
        $value=$Allocation.NoteSettingsPreparedCharacters
        if (-not (Test-ScopedInteger $value) -or $value -lt 0 -or $value -gt 16MB) { throw 'Invalid 16 MiB note settings allocation budget.' }
        $before=[long]$value
    }
    $stack=[Collections.Generic.Stack[object]]::new();$stack.Push(@{Node=$Target;Depth=0});$count=0;[long]$characters=0
    while ($stack.Count -gt 0) {
        $entry=$stack.Pop();$node=$entry.Node;$count++
        if ($count -gt 65536 -or $entry.Depth -gt 64) { throw 'Note settings exceed 65536 nodes or depth 64.' }
        if ($null -ne $node.Value) { $characters+=$node.Value.Length }
        if ($null -ne $node.Attributes) { foreach ($attribute in $node.Attributes) { $characters+=$attribute.Name.Length+$attribute.Value.Length } }
        if ($characters -gt 16MB) { throw 'Note settings exceed 16 MiB characters.' }
        foreach ($child in $node.ChildNodes) {
            if ($count+$stack.Count -ge 65536) { throw 'Note settings exceed 65536 nodes.' }
            $stack.Push(@{Node=$child;Depth=$entry.Depth+1})
        }
    }
    if ($before+$Target.OuterXml.Length -gt 16MB) { throw 'Prepared note settings exceed 16 MiB characters.' }
    $copy=$Target.CloneNode($true);$newNote=Get-ScopedOneChild $copy ('hp:'+$noteName)
    foreach ($group in $prepared.Keys) {
        $leaf=Get-ScopedOneChild $newNote ('hp:'+$group)
        # Attribute-only edits retain unknown children, attributes, IDs and payloads.
        foreach ($name in $prepared[$group].Keys) { $leaf.SetAttribute($name,$prepared[$group][$name]) }
    }
    [long]$total=$before+$copy.OuterXml.Length
    if ($total -gt 16MB) { throw 'Prepared note settings exceed 16 MiB characters.' }
    $Allocation.NoteSettingsPreparedCharacters=$total
    return ,$copy
}
