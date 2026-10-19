# Private, prepared-only helper; dot-source inside HwpHwpxScopedEdit.
# Public operation: type, inspected p address, expectedText, find, replacement,
# optional Boolean replaceAll=false. Literal ordinal, left-to-right, non-overlapping.
# Visible text uses LF for hp:lineBreak. Guards/replacements accept CRLF or CR;
# find is exact (not newline-normalized). No formatting resources are allocated.
# Limits: 1 MiB UTF16 units/string and resulting paragraph, 4096 runs,
# 10000 matches, 65536 input/conservative output nodes, 16 MiB serialized
# paragraph and cumulative prepared XML/replacement characters per Allocation.

function Add-ScopedTextRangeSlice {
    param($Tokens, [Xml.XmlElement]$Destination, [int]$Start, [int]$Length)
    if ($Length -eq 0) { return }
    $end=$Start+$Length; $low=0; $high=$Tokens.Count-1
    # Binary search avoids rescanning a many-node run for every literal match.
    while ($low -le $high) {
        $mid=$low+(($high-$low) -shr 1)
        if ($Tokens[$mid].End -le $Start) { $low=$mid+1 } else { $high=$mid-1 }
    }
    for ($i=$low; $i -lt $Tokens.Count -and $Tokens[$i].Start -lt $end; $i++) {
        $token=$Tokens[$i]; $node=$token.Node
        $left=[Math]::Max($Start,$token.Start); $right=[Math]::Min($end,$token.End)
        if ($right -le $left) { continue }
        if ($left -eq $token.Start -and $right -eq $token.End) { $piece=$node.CloneNode($true) }
        else { $piece=$Destination.OwnerDocument.CreateTextNode($node.Value.Substring($left-$token.Start,$right-$left)) }
        $null=$Destination.AppendChild($piece)
    }
}

function New-ScopedTextRangeReplacement {
    param([Xml.XmlElement]$Paragraph, $Operation, $Package, $Allocation)
    $op=ConvertTo-ScopedMap $Operation 'replace-paragraph-text'
    Assert-ScopedKeys $op @('type','address','expectedText','find','replacement') 'replace-paragraph-text' @('replaceAll')
    if ($op['type'] -isnot [string] -or $op['type'] -cne 'replace-paragraph-text') { throw 'Invalid replace-paragraph-text.type.' }
    $all=$false
    if ($op.ContainsKey('replaceAll')) {
        if ($op['replaceAll'] -isnot [bool]) { throw 'replaceAll must be Boolean.' }
        $all=$op['replaceAll']
    }
    foreach ($key in @('expectedText','find','replacement')) {
        if ($op[$key] -isnot [string]) { throw "$key must be a string." }
        if ($op[$key].Length -gt 1MB) { throw "$key exceeds 1 MiB characters." }
        $null=[Xml.XmlConvert]::VerifyXmlChars($op[$key])
    }
    if ($op['find'].Length -eq 0) { throw 'find must not be empty.' }
    $resolved=Resolve-ScopedAddress $op['address'] $Package 'p'
    if (-not [object]::ReferenceEquals($resolved.Node,$Paragraph)) { throw 'address does not identify the supplied paragraph target.' }

    $preparedBefore=[long]0; $replacementBefore=[long]0
    foreach ($key in @('TextRangePreparedCharacters','TextRangeReplacementCharacters')) {
        if ($Allocation.ContainsKey($key)) {
            if (-not (Test-ScopedInteger $Allocation[$key]) -or $Allocation[$key] -lt 0 -or $Allocation[$key] -gt 16MB) { throw 'Invalid 16 MiB text range allocation budget.' }
            if ($key -ceq 'TextRangePreparedCharacters') { $preparedBefore=[long]$Allocation[$key] }
            else { $replacementBefore=[long]$Allocation[$key] }
        }
    }
    # Bound traversal before materializing strings or cloning any subtree.
    $stack=[Collections.Generic.Stack[Xml.XmlNode]]::new(); $stack.Push($Paragraph)
    $nodeCount=0; [long]$characters=0
    while ($stack.Count -gt 0) {
        $node=$stack.Pop(); $nodeCount++
        if ($nodeCount -gt 65536) { throw 'Paragraph exceeds 65536 nodes.' }
        if ($null -ne $node.Value) { $characters+=$node.Value.Length }
        if ($null -ne $node.Attributes) {
            foreach ($attribute in $node.Attributes) { $characters+=$attribute.Name.Length+$attribute.Value.Length }
        }
        if ($characters -gt 16MB) { throw 'Paragraph exceeds 16 MiB characters.' }
        foreach ($child in $node.ChildNodes) {
            if ($stack.Count+$nodeCount -ge 65536) { throw 'Paragraph exceeds 65536 nodes.' }
            $stack.Push($child)
        }
    }
    Assert-ScopedCellAttributes $Paragraph @('id','paraPrIDRef','styleIDRef','pageBreak','columnBreak','merged')
    $null=Get-ScopedStyleId $Paragraph.GetAttribute('id') 'paragraph.id'
    foreach ($flag in @('pageBreak','columnBreak','merged')) {
        if ($Paragraph.HasAttribute($flag) -and $Paragraph.GetAttribute($flag) -cnotin @('0','1','false','true')) { throw "Invalid paragraph metadata: $flag." }
    }
    $header=$Package.Xml['Contents/header.xml']
    $charIds=Get-ScopedStyleIds $header 'charPr'; $paraIds=Get-ScopedStyleIds $header 'paraPr'
    if (-not $paraIds.Contains((Get-ScopedStyleId $Paragraph.GetAttribute('paraPrIDRef') 'paragraph.paraPrIDRef'))) { throw 'Paragraph style resource is absent.' }
    $ns=New-ScopedNamespaces $Paragraph.OwnerDocument
    $runs=$Paragraph.SelectNodes('hp:run',$ns)
    if ($runs.Count -lt 1 -or $runs.Count -gt 4096) { throw 'Paragraph requires 1 to 4096 text runs.' }
    foreach ($child in $Paragraph.ChildNodes) {
        if ($child.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
        if ($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or $child.LocalName -cnotin @('run','linesegarray')) { throw 'Unknown paragraph metadata or controls.' }
        if ($child.LocalName -ceq 'linesegarray') {
            Assert-ScopedCellAttributes $child @()
            foreach ($line in $child.ChildNodes) {
                if ($line.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
                if ($line.NodeType -ne 'Element' -or $line.NamespaceURI -cne $script:ScopedHp -or $line.LocalName -cne 'lineseg' -or $line.HasChildNodes) { throw 'Unknown line cache metadata.' }
                Assert-ScopedCellAttributes $line @('textpos','vertpos','vertsize','textheight','baseline','spacing','horzpos','horzsize','flags')
            }
        }
    }
    $records=[Collections.Generic.List[object]]::new(); $visible=[Text.StringBuilder]::new()
    foreach ($run in $runs) {
        Assert-ScopedCellAttributes $run @('charPrIDRef')
        if (-not $charIds.Contains((Get-ScopedStyleId $run.GetAttribute('charPrIDRef') 'run.charPrIDRef'))) { throw 'Character style resource is absent.' }
        $text=Get-ScopedInlineText $run
        if ($visible.Length+$text.Length -gt 1MB) { throw 'Paragraph exceeds 1 MiB characters.' }
        $null=[Xml.XmlConvert]::VerifyXmlChars($text)
        $t=Get-ScopedOneChild $run 'hp:t'; Assert-ScopedCellAttributes $t @()
        $tokens=[Collections.Generic.List[object]]::new(); $offset=0
        foreach ($child in $t.ChildNodes) {
            if ($child.NodeType -eq 'Element') {
                Assert-ScopedCellAttributes $child $(if ($child.LocalName -ceq 'tab') { @('width','leader','type') } else { @() })
                $length=1
            } else { $null=[Xml.XmlConvert]::VerifyXmlChars($child.Value); $length=$child.Value.Length }
            $tokens.Add(@{Node=$child;Start=$offset;End=$offset+$length}); $offset+=$length
        }
        $records.Add(@{Start=$visible.Length;End=$visible.Length+$text.Length;Tokens=$tokens})
        $null=$visible.Append($text)
    }
    $original=$visible.ToString()
    $expected=$op['expectedText'].Replace("`r`n","`n").Replace("`r","`n")
    $actual=$original.Replace("`r`n","`n").Replace("`r","`n")
    # The shared guard's linguistic comparison can ignore soft hyphens/zero-width characters.
    if (-not (Test-ScopedExpectedCellText $op['expectedText'] $original) -or
        -not [string]::Equals($expected,$actual,[StringComparison]::Ordinal)) { throw 'expectedText does not match the entire original paragraph.' }
    $find=$op['find']; $replacement=$op['replacement'].Replace("`r`n","`n").Replace("`r","`n")
    $matches=[Collections.Generic.List[int]]::new(); $position=0
    while ($position -le $original.Length-$find.Length) {
        $index=$original.IndexOf($find,$position,[StringComparison]::Ordinal)
        if ($index -lt 0) { break }
        if ($matches.Count -ge 10000) { throw 'Paragraph exceeds 10000 literal matches.' }
        $matches.Add($index); $position=$index+$find.Length
        if (-not $all) { break }
    }
    if ($matches.Count -eq 0) { throw 'find has no literal match in the original paragraph.' }
    [long]$outputLength=$original.Length+[long]$matches.Count*($replacement.Length-$find.Length)
    if ($outputLength -gt 1MB) { throw 'Replacement paragraph exceeds 1 MiB characters.' }
    [long]$replacementTotal=$replacementBefore+[long]$matches.Count*$replacement.Length
    if ($replacementTotal -gt 16MB) { throw 'Cumulative replacement text exceeds 16 MiB characters.' }
    $separators=0
    foreach ($character in $replacement.ToCharArray()) { if ($character -eq "`t" -or $character -eq "`n") { $separators++ } }
    if ($nodeCount+[long]$matches.Count*(2*$separators+2) -gt 65536) { throw 'Prepared paragraph exceeds conservative 65536 node budget.' }
    if ($Paragraph.OuterXml.Length -gt 16MB) { throw 'Serialized paragraph exceeds 16 MiB characters.' }

    $copy=$Paragraph.CloneNode($true); $clonedRuns=$copy.SelectNodes('hp:run',$ns); $matchIndex=0
    for ($r=0; $r -lt $records.Count; $r++) {
        $record=$records[$r]; $start=$record.Start; $end=$record.End
        if ($start -eq $end -or $matchIndex -ge $matches.Count -or $matches[$matchIndex] -ge $end) { continue }
        $old=Get-ScopedOneChild $clonedRuns[$r] 'hp:t'; $new=$old.CloneNode($false)
        $cursor=$start
        while ($matchIndex -lt $matches.Count -and $matches[$matchIndex] -lt $end) {
            $hit=$matches[$matchIndex]; $hitEnd=$hit+$find.Length
            if ($hitEnd -le $start) { $matchIndex++; continue }
            if ($hit -gt $cursor) { Add-ScopedTextRangeSlice $record.Tokens $new ($cursor-$start) ($hit-$cursor) }
            if ($hit -ge $start) {
                # Set-ScopedInlineText APPENDS hp:t; use an empty temporary run.
                $temporary=$copy.OwnerDocument.CreateElement('hp','run',$script:ScopedHp)
                Set-ScopedInlineText $temporary $replacement
                foreach ($piece in @($temporary.FirstChild.ChildNodes)) { $null=$new.AppendChild($piece) }
            }
            $cursor=[Math]::Min($end,$hitEnd)
            if ($hitEnd -le $end) { $matchIndex++ } else { break }
        }
        if ($cursor -lt $end) { Add-ScopedTextRangeSlice $record.Tokens $new ($cursor-$start) ($end-$cursor) }
        # Replace only the validated text element; never clear run/paragraph metadata.
        $null=$clonedRuns[$r].ReplaceChild($new,$old)
    }
    foreach ($cache in @($copy.SelectNodes('hp:linesegarray',$ns))) { $null=$copy.RemoveChild($cache) }
    [long]$preparedTotal=$preparedBefore+$copy.OuterXml.Length
    if ($preparedTotal -gt 16MB) { throw 'Cumulative prepared paragraphs exceed 16 MiB characters.' }
    # Allocation changes are committed only after every guard and clone succeeds.
    $Allocation.TextRangePreparedCharacters=$preparedTotal
    $Allocation.TextRangeReplacementCharacters=$replacementTotal
    return ,$copy
}
