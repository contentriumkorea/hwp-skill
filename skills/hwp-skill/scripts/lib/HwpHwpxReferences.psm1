#requires -Version 5.1
Set-StrictMode -Version 2.0

# XML shape/attributes/enums verified against hancom-io/hwpx-owpml-model
# commit 1453388472c703a4b299a0834f425cdac16644b9, OWPML/Class/Para:
# ctrl, fieldBegin, fieldEnd, ParameterList, bookmark, NoteType,
# HeaderFooterType, ParaListType, AutoNumNewNumType, AutoNumFormatType,
# pageNum, PType; and OWPML/Class/enumdef.h.
# That model permits named parameters; it does not implement field execution.
# Hyperlink Command syntax: https://forum.developer.hancom.com/t/topic/2291
# Internal target grammar: hancom-io/devcenter-archive,
# hwp-automation/ParameterSetTable_2504.pdf pp.174-176, blob
# 50ff092e81c81f8bba54a17d98b6aa4d909e6f87 (read through gh api).
# This module only serializes XML. It never follows links or runs field commands.

function Get-HwpxReferenceValue {
    param([object]$Object, [string]$Name, [object]$Default = $null, [switch]$Required)
    if ($null -ne $Object) {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return ,($Object[$Name]) }
        }
        elseif ($null -ne $Object.PSObject.Properties[$Name]) { return ,($Object.$Name) }
    }
    if ($Required) { throw "HWPX reference: missing '$Name'." }
    return ,$Default
}

function ConvertTo-HwpxReferenceText {
    param([AllowNull()][object]$Value)
    $text = [string]$Value
    $null = [System.Xml.XmlConvert]::VerifyXmlChars($text)
    # Preserve attribute whitespace as well as XML metacharacters on reparse.
    return [System.Security.SecurityElement]::Escape($text).Replace("`r", '&#xD;').Replace("`n", '&#xA;').Replace("`t", '&#x9;')
}

function ConvertTo-HwpxReferenceInlineText {
    param([AllowNull()][object]$Value)
    # OWPML t.cpp registers lineBreak/tab under t, not run. Return t CONTENT
    # only; metadata/attributes retain ConvertTo-HwpxReferenceText semantics.
    # Escape first so literal entity-looking text cannot become a control.
    # tab.cpp's numeric defaults are used without claiming a measured width.
    $escaped = ConvertTo-HwpxReferenceText $Value
    return $escaped.Replace('&#xD;&#xA;', '<hp:lineBreak/>').Replace('&#xD;', '<hp:lineBreak/>').Replace('&#xA;', '<hp:lineBreak/>').Replace('&#x9;', '<hp:tab width="0" leader="0" type="0"/>')
}

function Get-HwpxReferenceInteger {
    param([object]$Value, [string]$Name, [long]$Minimum = 0, [long]$Maximum = 4294967295)
    $number = 0L
    if ($null -eq $Value -or -not [long]::TryParse([string]$Value, [ref]$number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "HWPX reference: '$Name' must be an integer from $Minimum to $Maximum."
    }
    return $number
}

function Get-HwpxReferenceName {
    param([object]$Object)
    $name = [string](Get-HwpxReferenceValue $Object 'name' -Required)
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'HWPX reference: name must not be blank.' }
    return (ConvertTo-HwpxReferenceText $name)
}

function Get-HwpxReferenceNextId {
    param([ref]$Cursor)
    if ($Cursor.Value -gt 4294967295) { throw 'HWPX reference: ID range exceeds UINT32.' }
    $id = [long]$Cursor.Value
    $Cursor.Value = $id + 1L
    return $id
}

function New-HwpxReferenceParagraph {
    param([long]$ParagraphId, [long]$ParaPrId, [AllowEmptyString()][string]$Runs)
    return '<hp:p id="{0}" paraPrIDRef="{1}" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0">{2}</hp:p>' -f $ParagraphId, $ParaPrId, $Runs
}

function New-HwpxReferenceTextRun {
    param([object]$Text, [long]$CharPrId)
    return '<hp:run charPrIDRef="{0}"><hp:t>{1}</hp:t></hp:run>' -f $CharPrId, (ConvertTo-HwpxReferenceInlineText $Text)
}

function New-HwpxReferenceSubList {
    param([long]$ListId, [long]$Width, [string]$Paragraph)
    return '<hp:subList id="{0}" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="TOP" linkListIDRef="0" linkListNextIDRef="0" textWidth="{1}" textHeight="0" hasTextRef="0" hasNumRef="0">{2}</hp:subList>' -f $ListId, $Width, $Paragraph
}

function Get-HwpxReferenceLinkParameters {
    param([object]$Target, [switch]$InternalOnly)
    if ($Target -isnot [string] -or [string]::IsNullOrWhiteSpace($Target) -or $Target -match '[\x00-\x1f\x7f]') {
        throw 'HWPX reference: hyperlink target must be a nonblank HTTP(S) URI or #bookmark.'
    }
    $internal = $Target.StartsWith('#', [StringComparison]::Ordinal)
    if ($internal) {
        if ([string]::IsNullOrWhiteSpace($Target.Substring(1))) { throw 'HWPX reference: internal target must name a bookmark.' }
    }
    else {
        if ($InternalOnly) { throw 'HWPX reference: TOC entries require #bookmark targets.' }
        $uri = $null
        if ($Target -notmatch '^https?://' -or $Target -match '\s|\\|%(?![0-9A-Fa-f]{2})' -or
            -not [Uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrWhiteSpace($uri.Host) -or
            $uri.HostNameType -eq [UriHostNameType]::Unknown) {
            throw 'HWPX reference: invalid or disallowed hyperlink URI.'
        }
    }
    # Escape the Command mini-language separately from XML. A target cannot
    # inject extra semicolon-delimited link-kind/document-window options.
    $commandTarget = if ($internal) { $Target.Substring(1) } else { $Target }
    $commandPath = $commandTarget.Replace('\', '\\').Replace(':', '\:').Replace(';', '\;').Replace('?', '\?')
    # '?' separates the empty (current) document path from a bookmark NAME.
    # The JSON '#' marker is not an HWP object instance-ID prefix.
    if ($internal) { $commandPath = '?' + $commandPath }
    $linkType = if ($internal) { '0' } else { '1' }
    $command = ConvertTo-HwpxReferenceText ($commandPath + ';' + $linkType + ';0;0;')
    $path = ConvertTo-HwpxReferenceText $Target
    return '<hp:parameters cnt="3" name=""><hp:integerParam name="Prop">0</hp:integerParam><hp:stringParam name="Command">{0}</hp:stringParam><hp:stringParam name="Path">{1}</hp:stringParam></hp:parameters>' -f $command, $path
}

function New-HwpxReferenceFieldRuns {
    param([long]$FieldId, [long]$CharPrId, [string]$Type, [string]$SafeName, [int]$Editable, [string]$Parameters, [object]$Text)
    $begin = '<hp:run charPrIDRef="{0}"><hp:ctrl><hp:fieldBegin id="{1}" type="{2}" name="{3}" editable="{4}" dirty="0" zorder="-1" fieldid="{1}">{5}</hp:fieldBegin></hp:ctrl></hp:run>' -f $CharPrId, $FieldId, $Type, $SafeName, $Editable, $Parameters
    $end = '<hp:run charPrIDRef="{0}"><hp:ctrl><hp:fieldEnd beginIDRef="{1}" fieldid="{1}"/></hp:ctrl></hp:run>' -f $CharPrId, $FieldId
    return $begin + (New-HwpxReferenceTextRun -Text $Text -CharPrId $CharPrId) + $end
}

function New-HwpxReferenceBlockXml {
    <#
    .SYNOPSIS
    Returns one XML string containing complete hp:p elements, without xmlns.
    .DESCRIPTION
    Block accepts a dictionary or PSCustomObject with type field, bookmark,
    hyperlink, footnote, endnote, or toc. __charPrId/__paraPrId default to 0.
    A field label is literal text before its editable value (no added separator).
    Notes default number to 1; the caller supplies document-wide note numbering.
    TOC title is emitted only if supplied and nonempty; entries link internally.
    Display text maps CRLF/CR/LF to hp:lineBreak and TAB to hp:tab inside hp:t.
    Width is positive HWPUNIT, used for note subList textWidth. No line caches,
    inferred heights, rendered page numbers, or automatic TOC fields are emitted.
    .PARAMETER Id
    First ID in a caller-reserved UINT32 range. No global allocator is used.
    Consumes: bookmark=1; field/hyperlink=2; footnote/endnote=4;
    toc=max(1, 2*entries.Count plus 1 for a nonempty title). Each id/instId is unique
    within the range. fieldid and beginIDRef intentionally refer to fieldBegin.id.
    Reserve disjoint ranges across both APIs and other writer-generated objects.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Block,
        [Parameter(Mandatory)][ValidateRange(0, 4294967295)][long]$Id,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][long]$Width
    )
    $cursor = $Id
    $charPr = Get-HwpxReferenceInteger (Get-HwpxReferenceValue $Block '__charPrId' 0) '__charPrId'
    $paraPr = Get-HwpxReferenceInteger (Get-HwpxReferenceValue $Block '__paraPrId' 0) '__paraPrId'
    $type = [string](Get-HwpxReferenceValue $Block 'type' -Required)
    if ($type -eq 'toc') {
        $builder = New-Object System.Text.StringBuilder
        $title = [string](Get-HwpxReferenceValue $Block 'title' '')
        if ($title.Length -gt 0) {
            $paragraphId = Get-HwpxReferenceNextId ([ref]$cursor)
            $null = $builder.Append((New-HwpxReferenceParagraph $paragraphId $paraPr (New-HwpxReferenceTextRun $title $charPr)))
        }
        $entries = Get-HwpxReferenceValue $Block 'entries' -Required
        if ($null -eq $entries -or $entries -is [string] -or $entries -is [System.Collections.IDictionary] -or $entries -isnot [System.Collections.IEnumerable]) {
            throw 'HWPX reference: TOC entries must be an array.'
        }
        foreach ($entry in $entries) {
            $parameters = Get-HwpxReferenceLinkParameters (Get-HwpxReferenceValue $entry 'target' -Required) -InternalOnly
            $text = Get-HwpxReferenceValue $entry 'text' -Required
            $paragraphId = Get-HwpxReferenceNextId ([ref]$cursor)
            $fieldId = Get-HwpxReferenceNextId ([ref]$cursor)
            $runs = New-HwpxReferenceFieldRuns $fieldId $charPr 'HYPERLINK' '' 0 $parameters $text
            $null = $builder.Append((New-HwpxReferenceParagraph $paragraphId $paraPr $runs))
        }
        if ($builder.Length -eq 0) {
            $paragraphId = Get-HwpxReferenceNextId ([ref]$cursor)
            $null = $builder.Append((New-HwpxReferenceParagraph $paragraphId $paraPr (New-HwpxReferenceTextRun '' $charPr)))
        }
        return $builder.ToString()
    }
    $paragraphId = Get-HwpxReferenceNextId ([ref]$cursor)
    switch ($type) {
        'field' {
            $name = Get-HwpxReferenceName $Block
            $value = Get-HwpxReferenceValue $Block 'value' -Required
            $label = [string](Get-HwpxReferenceValue $Block 'label' '')
            $fieldId = Get-HwpxReferenceNextId ([ref]$cursor)
            $parameters = '<hp:parameters cnt="2" name=""><hp:integerParam name="Prop">0</hp:integerParam><hp:stringParam name="Command">clickhere:set:0:0:</hp:stringParam></hp:parameters>'
            $runs = if ($label.Length -gt 0) { New-HwpxReferenceTextRun $label $charPr } else { '' }
            $runs += New-HwpxReferenceFieldRuns $fieldId $charPr 'CLICK_HERE' $name 1 $parameters $value
        }
        'bookmark' {
            $name = Get-HwpxReferenceName $Block
            $text = ConvertTo-HwpxReferenceInlineText (Get-HwpxReferenceValue $Block 'text' '')
            $runs = '<hp:run charPrIDRef="{0}"><hp:ctrl><hp:bookmark name="{1}"/></hp:ctrl><hp:t>{2}</hp:t></hp:run>' -f $charPr, $name, $text
        }
        'hyperlink' {
            $parameters = Get-HwpxReferenceLinkParameters (Get-HwpxReferenceValue $Block 'target' -Required)
            $text = Get-HwpxReferenceValue $Block 'text' -Required
            $fieldId = Get-HwpxReferenceNextId ([ref]$cursor)
            $runs = New-HwpxReferenceFieldRuns $fieldId $charPr 'HYPERLINK' '' 0 $parameters $text
        }
        { $_ -in @('footnote', 'endnote') } {
            $number = Get-HwpxReferenceInteger (Get-HwpxReferenceValue $Block 'number' 1) 'number' 1 65535
            $text = ConvertTo-HwpxReferenceInlineText (Get-HwpxReferenceValue $Block 'text' -Required)
            $noteTag = if ($type -eq 'footnote') { 'footNote' } else { 'endNote' }
            $noteId = Get-HwpxReferenceNextId ([ref]$cursor)
            $listId = Get-HwpxReferenceNextId ([ref]$cursor)
            $nestedId = Get-HwpxReferenceNextId ([ref]$cursor)
            $noteRun = '<hp:run charPrIDRef="{0}"><hp:ctrl><hp:autoNum num="{1}" numType="{2}"><hp:autoNumFormat type="DIGIT" userChar="" prefixChar="" suffixChar=")" supscript="0"/></hp:autoNum></hp:ctrl><hp:t>{3}</hp:t></hp:run>' -f $charPr, $number, $type.ToUpperInvariant(), $text
            $nested = New-HwpxReferenceParagraph $nestedId $paraPr $noteRun
            $subList = New-HwpxReferenceSubList $listId $Width $nested
            $runs = '<hp:run charPrIDRef="{0}"><hp:ctrl><hp:{1} instId="{2}" number="{3}">{4}</hp:{1}></hp:ctrl><hp:t/></hp:run>' -f $charPr, $noteTag, $noteId, $number, $subList
        }
        default { throw "HWPX reference: unsupported block type '$type'." }
    }
    return (New-HwpxReferenceParagraph $paragraphId $paraPr $runs)
}

function New-HwpxSectionReferenceXml {
    <#
    .SYNOPSIS
    Returns hp:ctrl elements for insertion directly inside the first section run.
    .DESCRIPTION
    Document accepts optional header/footer {text,applyPageType} and pageNumber
    {position,formatType,sideChar}. Defaults: BOTH; BOTTOM_CENTER, DIGIT, ''.
    Missing/null references produce no control. Empty header/footer text remains
    an explicit empty control. Empty document returns ''. No secPr is generated;
    startNum.page and visibility/hideFirst belong to the caller's section writer.
    Width sets subList textWidth in HWPUNIT, not a measured line/page geometry.
    .PARAMETER Id
    First caller-reserved UINT32 ID, shared allocation contract with block API.
    Each present header/footer consumes 3 IDs (control, subList, paragraph).
    pageNumber consumes no IDs. The caller must reserve disjoint ranges.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][ValidateRange(0, 4294967295)][long]$Id,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][long]$Width
    )
    $cursor = $Id
    $builder = New-Object System.Text.StringBuilder
    foreach ($kind in @('header', 'footer')) {
        $definition = Get-HwpxReferenceValue $Document $kind
        if ($null -eq $definition) { continue }
        $apply = [string](Get-HwpxReferenceValue $definition 'applyPageType' 'BOTH')
        if ($apply -cnotin @('BOTH', 'ODD', 'EVEN')) { throw "HWPX reference: invalid $kind.applyPageType." }
        $text = Get-HwpxReferenceValue $definition 'text' -Required
        $controlId = Get-HwpxReferenceNextId ([ref]$cursor)
        $listId = Get-HwpxReferenceNextId ([ref]$cursor)
        $paragraphId = Get-HwpxReferenceNextId ([ref]$cursor)
        $paragraph = New-HwpxReferenceParagraph $paragraphId 0 (New-HwpxReferenceTextRun $text 0)
        $subList = New-HwpxReferenceSubList $listId $Width $paragraph
        $null = $builder.Append(('<hp:ctrl><hp:{0} id="{1}" applyPageType="{2}">{3}</hp:{0}></hp:ctrl>' -f $kind, $controlId, $apply, $subList))
    }
    $pageNumber = Get-HwpxReferenceValue $Document 'pageNumber'
    if ($null -ne $pageNumber) {
        $position = [string](Get-HwpxReferenceValue $pageNumber 'position' 'BOTTOM_CENTER')
        $format = [string](Get-HwpxReferenceValue $pageNumber 'formatType' 'DIGIT')
        if ($position -cnotin @('NONE','TOP_LEFT','TOP_CENTER','TOP_RIGHT','BOTTOM_LEFT','BOTTOM_CENTER','BOTTOM_RIGHT','OUTSIDE_TOP','OUTSIDE_BOTTOM','INSIDE_TOP','INSIDE_BOTTOM')) {
            throw 'HWPX reference: invalid pageNumber.position.'
        }
        if ($format -cnotin @('DIGIT','CIRCLED_DIGIT','ROMAN_CAPITAL','ROMAN_SMALL','LATIN_CAPITAL','LATIN_SMALL','CIRCLED_LATIN_CAPITAL','CIRCLED_LATIN_SMALL','HANGUL_SYLLABLE','CIRCLED_HANGUL_SYLLABLE','HANGUL_JAMO','CIRCLED_HANGUL_JAMO','HANGUL_PHONETIC','IDEOGRAPH','CIRCLED_IDEOGRAPH','DECAGON_CIRCLE','DECAGON_CIRCLE_HANJA','SYMBOL','USER_CHAR','SYMBOL2','IMAGE','2DIGIT')) {
            throw 'HWPX reference: invalid pageNumber.formatType.'
        }
        $sideChar = ConvertTo-HwpxReferenceText (Get-HwpxReferenceValue $pageNumber 'sideChar' '')
        $null = $builder.Append(('<hp:ctrl><hp:pageNum pos="{0}" formatType="{1}" sideChar="{2}"/></hp:ctrl>' -f $position, $format, $sideChar))
    }
    return $builder.ToString()
}

Export-ModuleMember -Function New-HwpxReferenceBlockXml, New-HwpxSectionReferenceXml
