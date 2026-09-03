# Focused tests: import only the reference serializer, never the shared writer.
$referenceModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxReferences.psm1'

function Read-ReferenceFragment {
    param([AllowEmptyString()][string]$Fragment)
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.LoadXml('<root xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core">' + $Fragment + '</root>')
    $namespaces = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespaces.AddNamespace('hp', 'http://www.hancom.co.kr/hwpml/2011/paragraph')
    $namespaces.AddNamespace('hc', 'http://www.hancom.co.kr/hwpml/2011/core')
    return @{ Xml = $document; Ns = $namespaces }
}

function Assert-ReferencePairs {
    param($Parsed)
    $begins = @($Parsed.Xml.SelectNodes('//hp:fieldBegin', $Parsed.Ns))
    $ends = @($Parsed.Xml.SelectNodes('//hp:fieldEnd', $Parsed.Ns))
    $ends.Count | Should Be $begins.Count
    @($begins | ForEach-Object { $_.GetAttribute('id') } | Select-Object -Unique).Count | Should Be $begins.Count
    foreach ($begin in $begins) {
        $matches = @($ends | Where-Object { $_.GetAttribute('beginIDRef') -eq $begin.GetAttribute('id') })
        $matches.Count | Should Be 1
        $matches[0].GetAttribute('fieldid') | Should Be $begin.GetAttribute('fieldid')
        $begin.ParentNode.LocalName | Should Be 'ctrl'
        $matches[0].ParentNode.LocalName | Should Be 'ctrl'
    }
    $ids = @($Parsed.Xml.SelectNodes('//@id | //@instId', $Parsed.Ns) | ForEach-Object { $_.Value })
    @($ids | Select-Object -Unique).Count | Should Be $ids.Count
}

function Assert-ReferenceInlineContent {
    param($Parsed, [string]$XPath)
    $textNode = $Parsed.Xml.SelectSingleNode($XPath, $Parsed.Ns)
    ($null -ne $textNode) | Should Be $true
    # Check node order directly; InnerText alone would lose control positions.
    (@($textNode.ChildNodes) | ForEach-Object { $_.Name }) -join '|' | Should Be 'hp:tab|hp:tab|#text|hp:tab|#text|hp:lineBreak|#text|hp:lineBreak|#text|hp:lineBreak|hp:lineBreak'
    (@($textNode.ChildNodes) | Where-Object NodeType -eq 'Text' | ForEach-Object { $_.Value }) -join '|' | Should Be '첫 & <tag> &#xA;|중간|다음|마지막'
    foreach ($tab in $textNode.SelectNodes('hp:tab', $Parsed.Ns)) {
        $tab.GetAttribute('width') | Should Be '0'
        $tab.GetAttribute('leader') | Should Be '0'
        $tab.GetAttribute('type') | Should Be '0'
    }
    @($Parsed.Xml.SelectNodes('//hp:run/hp:lineBreak | //hp:run/hp:tab', $Parsed.Ns)).Count | Should Be 0
    @($Parsed.Xml.SelectNodes('//hp:lineBreak[not(parent::hp:t)] | //hp:tab[not(parent::hp:t)]', $Parsed.Ns)).Count | Should Be 0
    $textNode.InnerText.Contains("`r") | Should Be $false
    $textNode.InnerText.Contains("`n") | Should Be $false
    $textNode.InnerText.Contains("`t") | Should Be $false
}

function Assert-ReferenceFailure {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$ExpectedMessage,
        [string]$ExpectedErrorId = $ExpectedMessage,
        [string]$ExpectedExceptionType = 'System.Management.Automation.RuntimeException',
        [string]$ExpectedInnerExceptionType,
        [string]$ExpectedParameterName
    )
    # Pester 3.4's message-less Should Throw calls Message.Contains($null).
    # That returns false on PS7/.NET even after the exception was caught.
    # Its explicit-message variant only checks a substring. Capture directly
    # and compare exact identities/messages; keep assertions outside the catch
    # so a failed assertion cannot itself satisfy the expected rejection.
    if ([string]::IsNullOrEmpty($ExpectedErrorId)) { throw 'Reference failure assertion requires an exact error ID or message.' }
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    if ($null -eq $failure) { throw 'Expected reference operation to throw, but it succeeded.' }
    if ($failure.Exception.GetType().FullName -cne $ExpectedExceptionType) {
        throw "Expected exception type '$ExpectedExceptionType', got '$($failure.Exception.GetType().FullName)'."
    }
    if ($failure.FullyQualifiedErrorId -cne $ExpectedErrorId) {
        throw "Expected error ID '$ExpectedErrorId', got '$($failure.FullyQualifiedErrorId)'."
    }
    if ($PSBoundParameters.ContainsKey('ExpectedMessage') -and $failure.Exception.Message -cne $ExpectedMessage) {
        throw "Expected exact message '$ExpectedMessage', got '$($failure.Exception.Message)'."
    }
    if ($PSBoundParameters.ContainsKey('ExpectedInnerExceptionType')) {
        if ($null -eq $failure.Exception.InnerException -or $failure.Exception.InnerException.GetType().FullName -cne $ExpectedInnerExceptionType) {
            throw "Expected inner exception type '$ExpectedInnerExceptionType', got '$($failure.Exception.InnerException)'."
        }
    }
    if ($PSBoundParameters.ContainsKey('ExpectedParameterName') -and $failure.Exception.ParameterName -cne $ExpectedParameterName) {
        throw "Expected rejected parameter '$ExpectedParameterName', got '$($failure.Exception.ParameterName)'."
    }
}

Describe 'HWPX reference XML helpers in isolation' {
    BeforeAll {
        if (Test-Path -LiteralPath $referenceModule) { Import-Module $referenceModule -Force }
    }

    It 'exports both requested XML helper APIs' {
        @(Get-Command New-HwpxReferenceBlockXml, New-HwpxSectionReferenceXml -ErrorAction SilentlyContinue).Count | Should Be 2
    }

    It 'creates an editable named field with the value between real balanced controls' {
        $raw = New-HwpxReferenceBlockXml -Block @{ type = 'field'; name = '이름 & "담당"'; label = '담당: '; value = '김<한> & "글"'; __charPrId = 7; __paraPrId = 9 } -Id 100 -Width 32000
        $p = Read-ReferenceFragment $raw
        $paragraph = $p.Xml.SelectSingleNode('/root/hp:p', $p.Ns)
        $paragraph.GetAttribute('id') | Should Be '100'
        $paragraph.GetAttribute('paraPrIDRef') | Should Be '9'
        @($paragraph.SelectNodes('hp:run[@charPrIDRef="7"]', $p.Ns)).Count | Should Be 4
        $begin = $paragraph.SelectSingleNode('hp:run/hp:ctrl/hp:fieldBegin', $p.Ns)
        $begin.GetAttribute('type') | Should Be 'CLICK_HERE'
        $begin.GetAttribute('editable') | Should Be '1'
        $begin.GetAttribute('name') | Should Be '이름 & "담당"'
        $runs = @($paragraph.SelectNodes('hp:run', $p.Ns))
        $runs[0].InnerText | Should Be '담당: '
        $runs[1].FirstChild.FirstChild.LocalName | Should Be 'fieldBegin'
        $runs[2].InnerText | Should Be '김<한> & "글"'
        $runs[3].FirstChild.FirstChild.LocalName | Should Be 'fieldEnd'
        $parameters = $begin.SelectSingleNode('hp:parameters', $p.Ns)
        [int]$parameters.GetAttribute('cnt') | Should Be $parameters.ChildNodes.Count
        Assert-ReferencePairs $p
        $raw | Should Not Match 'xmlns|<\?xml|lineseg'
    }

    It 'preserves an intentionally empty field value and default style zero' {
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block ([pscustomobject]@{ type = 'field'; name = 'empty'; value = '' }) -Id 10 -Width 20000)
        $p.Xml.SelectSingleNode('/root/hp:p', $p.Ns).GetAttribute('paraPrIDRef') | Should Be '0'
        $p.Xml.SelectSingleNode('/root/hp:p/hp:run[2]/hp:t', $p.Ns).InnerText | Should Be ''
        @($p.Xml.SelectNodes('//hp:run[@charPrIDRef!="0"]', $p.Ns)).Count | Should Be 0
        Assert-ReferencePairs $p
    }

    It 'writes named bookmark controls with escaped optional display text' {
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'bookmark'; name = '절 & "1"'; text = '<제목>' } -Id 20 -Width 20000)
        $bookmark = $p.Xml.SelectSingleNode('/root/hp:p/hp:run/hp:ctrl/hp:bookmark', $p.Ns)
        $bookmark.GetAttribute('name') | Should Be '절 & "1"'
        $bookmark.Attributes.Count | Should Be 1
        $p.Xml.SelectSingleNode('/root/hp:p/hp:run/hp:t', $p.Ns).InnerText | Should Be '<제목>'
        $empty = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'bookmark'; name = 'empty' } -Id 21 -Width 20000)
        $empty.Xml.SelectSingleNode('/root/hp:p', $empty.Ns).InnerText | Should Be ''
    }

    It 'serializes safe web links without losing query delimiters or escaping quotes twice' {
        $target = 'https://example.test/a;b?q="x"&n=1#part'
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'hyperlink'; text = '링크 & <보기>'; target = $target } -Id 30 -Width 21000)
        $begin = $p.Xml.SelectSingleNode('//hp:fieldBegin', $p.Ns)
        $begin.GetAttribute('type') | Should Be 'HYPERLINK'
        $begin.GetAttribute('editable') | Should Be '0'
        $begin.SelectSingleNode('hp:parameters/hp:stringParam[@name="Path"]', $p.Ns).InnerText | Should Be $target
        $begin.SelectSingleNode('hp:parameters/hp:stringParam[@name="Command"]', $p.Ns).InnerText | Should Be 'https\://example.test/a\;b\?q="x"&n=1#part;1;0;0;'
        $p.Xml.SelectSingleNode('/root/hp:p/hp:run[2]/hp:t', $p.Ns).InnerText | Should Be '링크 & <보기>'
        Assert-ReferencePairs $p
    }

    It 'supports HTTP and converts internal bookmark targets to document-link commands' {
        foreach ($target in @('http://example.test/', '#절 & "1"')) {
            $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'hyperlink'; text = 'jump'; target = $target } -Id 40 -Width 21000)
            $command = $p.Xml.SelectSingleNode('//hp:stringParam[@name="Command"]', $p.Ns).InnerText
            # Hancom ParameterSetTable_2504 pp.174-176: current document is
            # an empty document path followed by '?' and the bookmark name.
            if ($target.StartsWith('#')) { $command | Should Be '?절 & "1";0;0;0;' }
            else { $command | Should Be 'http\://example.test/;1;0;0;' }
        }
    }

    It 'rejects blank unsafe malformed or relative hyperlink targets before returning XML' {
        # A valid baseline prevents a missing/broken serializer from making
        # every negative test pass merely because every call throws.
        $valid = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'hyperlink'; text = 'ok'; target = 'https://example.test' } -Id 50 -Width 21000)
        @($valid.Xml.SelectNodes('//hp:fieldBegin', $valid.Ns)).Count | Should Be 1
        $invalidLinks = @(
            @{ Targets = @('', ' ', "https://example.test/`nfile"); Message = 'HWPX reference: hyperlink target must be a nonblank HTTP(S) URI or #bookmark.' }
            @{ Targets = @('#', '#   '); Message = 'HWPX reference: internal target must name a bookmark.' }
            @{ Targets = @('javascript:alert(1)', 'data:text/html,test', 'file:///C:/test', 'mailto:a@example.test', 'ftp://example.test', '//example.test', 'relative/path', 'https://', 'https:/example.test', 'https://bad host/', 'https://example.test/%ZZ', 'https://example.test\path'); Message = 'HWPX reference: invalid or disallowed hyperlink URI.' }
        )
        foreach ($invalidLink in $invalidLinks) {
            foreach ($target in $invalidLink.Targets) {
                Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'hyperlink'; text = 'unsafe'; target = $target } -Id 50 -Width 21000 } -ExpectedMessage $invalidLink.Message
            }
        }
    }

    It 'writes real footnotes and endnotes with matching automatic numbers and nested paragraphs' {
        foreach ($kind in @('footnote', 'endnote')) {
            $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = $kind; text = '주석 & <본문>'; number = 12; __charPrId = 3; __paraPrId = 4 } -Id 60 -Width 18000)
            $tag = if ($kind -eq 'footnote') { 'footNote' } else { 'endNote' }
            $note = $p.Xml.SelectSingleNode('/root/hp:p/hp:run/hp:ctrl/hp:' + $tag, $p.Ns)
            $note.GetAttribute('number') | Should Be '12'
            $note.SelectSingleNode('hp:subList', $p.Ns).GetAttribute('textWidth') | Should Be '18000'
            $note.SelectSingleNode('hp:subList/hp:p', $p.Ns).GetAttribute('paraPrIDRef') | Should Be '4'
            $auto = $note.SelectSingleNode('hp:subList/hp:p/hp:run/hp:ctrl/hp:autoNum', $p.Ns)
            $auto.GetAttribute('num') | Should Be '12'
            $auto.GetAttribute('numType') | Should Be $kind.ToUpperInvariant()
            $auto.SelectSingleNode('hp:autoNumFormat', $p.Ns).GetAttribute('type') | Should Be 'DIGIT'
            $note.SelectSingleNode('hp:subList/hp:p/hp:run/hp:t', $p.Ns).InnerText | Should Be '주석 & <본문>'
            @($p.Xml.SelectNodes('//hp:run[@charPrIDRef!="3"]', $p.Ns)).Count | Should Be 0
            @($p.Xml.SelectNodes('//hp:linesegarray | //hp:pageNum', $p.Ns)).Count | Should Be 0
            Assert-ReferencePairs $p
        }
    }

    It 'defaults omitted note numbering to one and rejects numbers outside the official UINT16 storage' {
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'footnote'; text = 'note' } -Id 70 -Width 18000)
        $p.Xml.SelectSingleNode('//hp:footNote', $p.Ns).GetAttribute('number') | Should Be '1'
        foreach ($number in @(-1, 0, 1.5, 65536, 'x')) {
            Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'endnote'; text = 'note'; number = $number } -Id 70 -Width 18000 } -ExpectedMessage "HWPX reference: 'number' must be an integer from 1 to 65535."
        }
    }

    It 'creates a linked TOC with optional title unique IDs and no invented page numbers' {
        $block = @{ type = 'toc'; title = '차례 & 안내'; entries = @(@{ text = '첫 절'; target = '#first' }, @{ text = '둘째 절'; target = '#second' }); __charPrId = 6; __paraPrId = 8 }
        $raw = New-HwpxReferenceBlockXml -Block $block -Id 200 -Width 23000
        $p = Read-ReferenceFragment $raw
        @($p.Xml.SelectNodes('/root/hp:p', $p.Ns)).Count | Should Be 3
        $p.Xml.SelectSingleNode('/root/hp:p[1]', $p.Ns).InnerText | Should Be '차례 & 안내'
        @($p.Xml.SelectNodes('//hp:fieldBegin[@type="HYPERLINK"]', $p.Ns)).Count | Should Be 2
        ($p.Xml.SelectNodes('//hp:t', $p.Ns) | ForEach-Object { $_.InnerText }) -join '|' | Should Be '차례 & 안내|첫 절|둘째 절'
        @($p.Xml.SelectNodes('//hp:p[@paraPrIDRef!="8"] | //hp:run[@charPrIDRef!="6"]', $p.Ns)).Count | Should Be 0
        $raw | Should Not Match 'pageNum|autoNum|lineseg|TABLEOFCONTENTS|xmlns'
        # Reserve 5 IDs for the title and two (paragraph + field) entries.
        $next = New-HwpxReferenceBlockXml -Block @{ type = 'field'; name = 'next'; value = 'value' } -Id 205 -Width 23000
        Assert-ReferencePairs (Read-ReferenceFragment ($raw + $next))
    }

    It 'does not invent a TOC title and rejects external or blank entry targets' {
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'toc'; entries = @(@{ text = 'Only'; target = '#one' }) } -Id 220 -Width 23000)
        @($p.Xml.SelectNodes('/root/hp:p', $p.Ns)).Count | Should Be 1
        $invalidEntries = @(
            @{ Target = 'https://example.test'; Message = 'HWPX reference: TOC entries require #bookmark targets.' }
            @{ Target = ''; Message = 'HWPX reference: hyperlink target must be a nonblank HTTP(S) URI or #bookmark.' }
            @{ Target = '#'; Message = 'HWPX reference: internal target must name a bookmark.' }
            @{ Target = '# '; Message = 'HWPX reference: internal target must name a bookmark.' }
        )
        foreach ($invalidEntry in $invalidEntries) {
            Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'toc'; entries = @(@{ text = 'bad'; target = $invalidEntry.Target }) } -Id 220 -Width 23000 } -ExpectedMessage $invalidEntry.Message
        }
    }

    It 'emits a complete empty paragraph for an empty TOC and escapes internal command separators' {
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'toc'; entries = @() } -Id 230 -Width 23000)
        @($p.Xml.SelectNodes('/root/hp:p', $p.Ns)).Count | Should Be 1
        $p.Xml.SelectSingleNode('/root/hp:p', $p.Ns).InnerText | Should Be ''
        $link = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'hyperlink'; target = '#name?;:\'; text = 'jump' } -Id 231 -Width 23000)
        $link.Xml.SelectSingleNode('//hp:stringParam[@name="Command"]', $link.Ns).InnerText | Should Be '?name\?\;\:\\;0;0;0;'
    }

    It 'nests multiline and tab controls inside t in every reference block without losing text order' {
        $mixedText = "`t`t첫 & <tag> &#xA;`t중간`r`n다음`r마지막`n`n"
        $inlineCases = @(
            @{ Block = @{ type = 'field'; name = 'f'; label = $mixedText; value = $mixedText }; Paths = @('/root/hp:p/hp:run[1]/hp:t', '/root/hp:p/hp:run[3]/hp:t') }
            @{ Block = @{ type = 'bookmark'; name = 'b'; text = $mixedText }; Paths = @('/root/hp:p/hp:run/hp:t') }
            @{ Block = @{ type = 'hyperlink'; target = '#b'; text = $mixedText }; Paths = @('/root/hp:p/hp:run[2]/hp:t') }
            @{ Block = @{ type = 'footnote'; text = $mixedText }; Paths = @('//hp:footNote/hp:subList/hp:p/hp:run/hp:t') }
            @{ Block = @{ type = 'endnote'; text = $mixedText }; Paths = @('//hp:endNote/hp:subList/hp:p/hp:run/hp:t') }
            @{ Block = @{ type = 'toc'; title = $mixedText; entries = @(@{ text = $mixedText; target = '#b' }) }; Paths = @('/root/hp:p[1]/hp:run/hp:t', '/root/hp:p[2]/hp:run[2]/hp:t') }
        )
        foreach ($inlineCase in $inlineCases) {
            $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block $inlineCase.Block -Id 700 -Width 20000)
            foreach ($path in $inlineCase.Paths) { Assert-ReferenceInlineContent $p $path }
            Assert-ReferencePairs $p
        }
    }

    It 'nests header and footer line breaks and tabs inside t' {
        $mixedText = "`t`t첫 & <tag> &#xA;`t중간`r`n다음`r마지막`n`n"
        $p = Read-ReferenceFragment (New-HwpxSectionReferenceXml -Document @{ header = @{ text = $mixedText }; footer = @{ text = $mixedText } } -Id 800 -Width 20000)
        Assert-ReferenceInlineContent $p '//hp:header/hp:subList/hp:p/hp:run/hp:t'
        Assert-ReferenceInlineContent $p '//hp:footer/hp:subList/hp:p/hp:run/hp:t'
        Assert-ReferencePairs $p
    }

    It 'keeps field-name whitespace as attribute data when display text gains controls' {
        $name = "name`t&`r`n<tag>"
        $p = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'field'; name = $name; value = "A`tB`nC" } -Id 900 -Width 20000)
        $p.Xml.SelectSingleNode('//hp:fieldBegin', $p.Ns).GetAttribute('name') | Should Be $name
        @($p.Xml.SelectNodes('//hp:t/hp:tab', $p.Ns)).Count | Should Be 1
        @($p.Xml.SelectNodes('//hp:t/hp:lineBreak', $p.Ns)).Count | Should Be 1
        @($p.Xml.SelectNodes('//hp:fieldBegin//hp:tab | //hp:fieldBegin//hp:lineBreak', $p.Ns)).Count | Should Be 0
    }

    It 'returns inline header footer and page-number controls for the first section run' {
        $document = @{ header = @{ text = '머리 & "말"'; applyPageType = 'ODD' }; footer = @{ text = '꼬리 <말>'; applyPageType = 'EVEN' }; pageNumber = @{ position = 'BOTTOM_CENTER'; formatType = 'ROMAN_SMALL'; sideChar = '"&' } }
        $raw = New-HwpxSectionReferenceXml -Document $document -Id 300 -Width 29000
        $p = Read-ReferenceFragment ('<hp:p id="0"><hp:run charPrIDRef="0">' + $raw + '</hp:run></hp:p>')
        $header = $p.Xml.SelectSingleNode('/root/hp:p/hp:run/hp:ctrl/hp:header', $p.Ns)
        $footer = $p.Xml.SelectSingleNode('/root/hp:p/hp:run/hp:ctrl/hp:footer', $p.Ns)
        $header.GetAttribute('applyPageType') | Should Be 'ODD'
        $footer.GetAttribute('applyPageType') | Should Be 'EVEN'
        $header.SelectSingleNode('hp:subList/hp:p/hp:run/hp:t', $p.Ns).InnerText | Should Be '머리 & "말"'
        $footer.SelectSingleNode('hp:subList/hp:p/hp:run/hp:t', $p.Ns).InnerText | Should Be '꼬리 <말>'
        $header.SelectSingleNode('hp:subList', $p.Ns).GetAttribute('textWidth') | Should Be '29000'
        $page = $p.Xml.SelectSingleNode('/root/hp:p/hp:run/hp:ctrl/hp:pageNum', $p.Ns)
        $page.GetAttribute('pos') | Should Be 'BOTTOM_CENTER'
        $page.GetAttribute('formatType') | Should Be 'ROMAN_SMALL'
        $page.GetAttribute('sideChar') | Should Be '"&'
        $raw | Should Not Match 'secPr|startNum|visibility|hideFirst|lineseg|xmlns'
        Assert-ReferencePairs $p
    }

    It 'handles absent section references and default header footer and page-number options' {
        (New-HwpxSectionReferenceXml -Document @{} -Id 400 -Width 20000) | Should Be ''
        $p = Read-ReferenceFragment (New-HwpxSectionReferenceXml -Document ([pscustomobject]@{ header = @{ text = '' }; footer = @{ text = 'f' }; pageNumber = @{} }) -Id 400 -Width 20000)
        $p.Xml.SelectSingleNode('//hp:header', $p.Ns).GetAttribute('applyPageType') | Should Be 'BOTH'
        $p.Xml.SelectSingleNode('//hp:footer', $p.Ns).GetAttribute('applyPageType') | Should Be 'BOTH'
        $p.Xml.SelectSingleNode('//hp:pageNum', $p.Ns).GetAttribute('pos') | Should Be 'BOTTOM_CENTER'
        $p.Xml.SelectSingleNode('//hp:pageNum', $p.Ns).GetAttribute('formatType') | Should Be 'DIGIT'
        $p.Xml.SelectSingleNode('//hp:pageNum', $p.Ns).GetAttribute('sideChar') | Should Be ''
    }

    It 'accepts official page enums and rejects unknown section-control values' {
        foreach ($position in @('NONE','TOP_LEFT','TOP_CENTER','TOP_RIGHT','BOTTOM_LEFT','BOTTOM_CENTER','BOTTOM_RIGHT','OUTSIDE_TOP','OUTSIDE_BOTTOM','INSIDE_TOP','INSIDE_BOTTOM')) {
            $p = Read-ReferenceFragment (New-HwpxSectionReferenceXml -Document @{ pageNumber = @{ position = $position; formatType = 'CIRCLED_HANGUL_SYLLABLE' } } -Id 500 -Width 20000)
            $p.Xml.SelectSingleNode('//hp:pageNum', $p.Ns).GetAttribute('pos') | Should Be $position
        }
        $invalidSections = @(
            @{ Document = @{ header = @{ text = 'h'; applyPageType = 'FIRST' } }; Message = 'HWPX reference: invalid header.applyPageType.' }
            @{ Document = @{ footer = @{ text = 'f'; applyPageType = 'ALL' } }; Message = 'HWPX reference: invalid footer.applyPageType.' }
            @{ Document = @{ pageNumber = @{ position = 'BOTTOM_MIDDLE' } }; Message = 'HWPX reference: invalid pageNumber.position.' }
            @{ Document = @{ pageNumber = @{ formatType = 'DECIMAL' } }; Message = 'HWPX reference: invalid pageNumber.formatType.' }
        )
        foreach ($invalidSection in $invalidSections) {
            Assert-ReferenceFailure -Action { New-HwpxSectionReferenceXml -Document $invalidSection.Document -Id 500 -Width 20000 } -ExpectedMessage $invalidSection.Message
        }
    }

    It 'rejects bad XML characters missing required fields bad sizes IDs and unsupported blocks' {
        $valid = Read-ReferenceFragment (New-HwpxReferenceBlockXml -Block @{ type = 'bookmark'; name = 'ok' } -Id 600 -Width 20000)
        @($valid.Xml.SelectNodes('//hp:bookmark', $valid.Ns)).Count | Should Be 1
        $invalidBlocks = @(
            @{ Block = @{ type = 'field'; name = ''; value = 'a' }; Message = 'HWPX reference: name must not be blank.' }
            @{ Block = @{ type = 'field'; name = 'n' }; Message = "HWPX reference: missing 'value'." }
            @{ Block = @{ type = 'bookmark'; name = ' ' }; Message = 'HWPX reference: name must not be blank.' }
            @{ Block = @{ type = 'paragraph'; text = 'x' }; Message = "HWPX reference: unsupported block type 'paragraph'." }
            @{ Block = @{ type = 'field'; name = 'n'; value = 'x'; __charPrId = -1 }; Message = "HWPX reference: '__charPrId' must be an integer from 0 to 4294967295." }
        )
        foreach ($invalidBlock in $invalidBlocks) {
            Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block $invalidBlock.Block -Id 600 -Width 20000 } -ExpectedMessage $invalidBlock.Message
        }
        # Framework-generated diagnostics can be localized. Match their exact
        # error ID, exception type, and inner type/parameter instead of prose.
        Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'bookmark'; name = 'x'; text = ([string][char]1) } -Id 600 -Width 20000 } -ExpectedErrorId 'XmlException,New-HwpxReferenceBlockXml' -ExpectedExceptionType 'System.Management.Automation.MethodInvocationException' -ExpectedInnerExceptionType 'System.Xml.XmlException'
        Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'bookmark'; name = 'n' } -Id -1 -Width 20000 } -ExpectedErrorId 'ParameterArgumentValidationError,New-HwpxReferenceBlockXml' -ExpectedExceptionType 'System.Management.Automation.ParameterBindingValidationException' -ExpectedParameterName 'Id'
        Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'field'; name = 'n'; value = 'x' } -Id 4294967295 -Width 20000 } -ExpectedMessage 'HWPX reference: ID range exceeds UINT32.'
        Assert-ReferenceFailure -Action { New-HwpxReferenceBlockXml -Block @{ type = 'bookmark'; name = 'n' } -Id 600 -Width 0 } -ExpectedErrorId 'ParameterArgumentValidationError,New-HwpxReferenceBlockXml' -ExpectedExceptionType 'System.Management.Automation.ParameterBindingValidationException' -ExpectedParameterName 'Width'
    }
}
