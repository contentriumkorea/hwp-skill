# Independent, hand-authored XML; no generator, native host or public dispatcher.
$script:TrModule = Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force -PassThru
$trHelper = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxTextRangeEdit.ps1'
$script:TrHelper = $trHelper

function New-TrFixture([string]$Runs = '<hp:run charPrIDRef="1"><hp:t>pre AB</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>CD post</hp:t></hp:run><hp:run charPrIDRef="3"><hp:t> untouched</hp:t></hp:run>') {
    $xml = [xml]::new(); $xml.PreserveWhitespace = $true
    $xml.LoadXml('<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:p id="17" paraPrIDRef="0" styleIDRef="0" pageBreak="1" columnBreak="0" merged="0">' + $Runs + '</hp:p></hs:sec>')
    [xml]$header = '<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"><hh:refList><hh:charProperties itemCnt="3"><hh:charPr id="1"/><hh:charPr id="2"/><hh:charPr id="3"/></hh:charProperties><hh:paraProperties itemCnt="1"><hh:paraPr id="0"/></hh:paraProperties><hh:styles itemCnt="1"><hh:style id="0"/></hh:styles></hh:refList></hh:head>'
    $sections = [Collections.Generic.List[string]]::new(); $sections.Add('Contents/section0.xml')
    return @{ Paragraph=$xml.DocumentElement.FirstChild; Package=@{ Xml=@{'Contents/section0.xml'=$xml; 'Contents/header.xml'=$header}; Sections=$sections; SourceSha256=('a'*64) }; Allocation=@{} }
}
function New-TrOperation([string]$Expected='pre ABCD post untouched',[string]$Find='ABCD',[string]$Replacement='X') {
    return @{ type='replace-paragraph-text'; address=@{version='1.0';sourceSha256=('a'*64);part='Contents/section0.xml';path=@(0);kind='p'}; expectedText=$Expected;find=$Find;replacement=$Replacement }
}
function Invoke-TrReplacement($Fixture,$Operation,$Budget=$Fixture.Allocation) {
    & $script:TrModule { param($P,$O,$K,$A,$Path) if(Test-Path -LiteralPath $Path){. $Path}; New-ScopedTextRangeReplacement $P $O $K $A } $Fixture.Paragraph $Operation $Fixture.Package $Budget $script:TrHelper
}
function Get-TrText($Paragraph) {
    # Independent readback including tab and line-break elements.
    $parts = foreach ($t in $Paragraph.SelectNodes('*[local-name()="run"]/*[local-name()="t"]')) {
        foreach ($node in $t.ChildNodes) {
            if ($node.LocalName -ceq 'tab') { "`t" }
            elseif ($node.LocalName -ceq 'lineBreak') { "`n" }
            else { $node.Value }
        }
    }
    return $parts -join ''
}
function Assert-TrAtomicFailure($Fixture,$Operation,[string]$Message) {
    $before=$Fixture.Paragraph.OwnerDocument.OuterXml
    $header=$Fixture.Package.Xml['Contents/header.xml'].OuterXml
    $allocation=ConvertTo-Json -InputObject $Fixture.Allocation -Depth 20 -Compress
    $caught=$null
    try { $null=Invoke-TrReplacement $Fixture $Operation } catch { $caught=$_.Exception }
    ($null -ne $caught) | Should Be $true
    $caught.Message | Should BeLike $Message
    $Fixture.Paragraph.OwnerDocument.OuterXml | Should BeExactly $before
    $Fixture.Package.Xml['Contents/header.xml'].OuterXml | Should BeExactly $header
    (ConvertTo-Json -InputObject $Fixture.Allocation -Depth 20 -Compress) | Should BeExactly $allocation
}

Describe 'Private paragraph literal range replacement' {
    It 'returns one detached paragraph preserving run styles, suffixes, flags and original bytes' {
        $f=New-TrFixture; $before=$f.Paragraph.OuterXml
        $p=Invoke-TrReplacement $f (New-TrOperation)
        $p -is [Xml.XmlElement] | Should Be $true
        $p.LocalName | Should BeExactly 'p'
        ($null -eq $p.ParentNode) | Should Be $true
        (Get-TrText $p) | Should BeExactly 'pre X post untouched'
        $runs=$p.SelectNodes('*[local-name()="run"]')
        $runs.Count | Should Be 3
        $runs[0].InnerText | Should BeExactly 'pre X'
        $runs[1].InnerText | Should BeExactly ' post'
        ($runs | ForEach-Object {$_.GetAttribute('charPrIDRef')}) -join ',' | Should BeExactly '1,2,3'
        $runs[2].OuterXml | Should BeExactly $f.Paragraph.LastChild.OuterXml
        foreach($a in $f.Paragraph.Attributes) { $p.GetAttribute($a.Name) | Should BeExactly $a.Value }
        $f.Paragraph.OuterXml | Should BeExactly $before
    }
    It 'matches ordinal literals without regex, evaluation, case folding or recursive replacements' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t>a.* $1 $(x) A.* a.*</hp:t></hp:run>'
        $p=Invoke-TrReplacement $f (New-TrOperation 'a.* $1 $(x) A.* a.*' 'a.*' '$1 a.*')
        (Get-TrText $p) | Should BeExactly '$1 a.* $1 $(x) A.* a.*'
    }
    It 'defaults to the first match and applies replaceAll to original non-overlapping matches' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t>a</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>baa</hp:t></hp:run><hp:run charPrIDRef="3"><hp:t>bab</hp:t></hp:run>'
        $op=New-TrOperation 'abaabab' 'ab' 'abX'
        (Get-TrText (Invoke-TrReplacement $f $op)) | Should BeExactly 'abXaabab'
        $op.replaceAll=$true; $p=Invoke-TrReplacement $f $op
        (Get-TrText $p) | Should BeExactly 'abXaabXabX'
        $p.FirstChild.InnerText | Should BeExactly 'abX'
        $p.ChildNodes[1].InnerText | Should BeExactly 'aabX'
        $p.ChildNodes[2].InnerText | Should BeExactly 'abX'
    }
    It 'does not overlap matches and accepts deletion while retaining empty runs' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t>a</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>aaa</hp:t></hp:run>'
        $op=New-TrOperation 'aaaa' 'aa' ''; $op.replaceAll=$true
        $p=Invoke-TrReplacement $f $op
        (Get-TrText $p) | Should BeExactly ''
        $p.SelectNodes('*[local-name()="run"]').Count | Should Be 2
        $p.SelectNodes('*[local-name()="run"]/*[local-name()="t"]').Count | Should Be 2
    }
    It 'starts at a run boundary after an empty styled run and leaves untouched runs intact' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t/></hp:run><hp:run charPrIDRef="2"><hp:t>AB</hp:t></hp:run><hp:run charPrIDRef="3"><hp:t>CD!</hp:t></hp:run>'
        $p=Invoke-TrReplacement $f (New-TrOperation 'ABCD!' 'ABCD' 'Z')
        $p.FirstChild.OuterXml | Should BeExactly $f.Paragraph.FirstChild.OuterXml
        $p.ChildNodes[1].InnerText | Should BeExactly 'Z'
        $p.ChildNodes[1].GetAttribute('charPrIDRef') | Should BeExactly '2'
        $p.LastChild.InnerText | Should BeExactly '!'
    }
    It 'preserves original tab metadata and line breaks even inside a changed run' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t>L<hp:tab width="720" leader="3" type="1"/>AB<hp:lineBreak/>R</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>!</hp:t></hp:run>'
        $tab=$f.Paragraph.SelectSingleNode('.//*[local-name()="tab"]').OuterXml
        $p=Invoke-TrReplacement $f (New-TrOperation "L`tAB`nR!" 'AB' "X`tY`nZ")
        (Get-TrText $p) | Should BeExactly "L`tX`tY`nZ`nR!"
        $p.SelectSingleNode('.//*[local-name()="tab"]').OuterXml | Should BeExactly $tab
        $p.SelectNodes('.//*[local-name()="tab"]').Count | Should Be 2
        $p.SelectNodes('.//*[local-name()="lineBreak"]').Count | Should Be 2
        $p.SelectNodes('*[local-name()="run"]/*[local-name()="t"]').Count | Should Be 2
    }
    It 'matches across tabs and line breaks with LF search text and normalizes CRLF guards and replacements' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t>A<hp:tab width="77"/>B</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t><hp:lineBreak/>C</hp:t></hp:run>'
        $p=Invoke-TrReplacement $f (New-TrOperation "A`tB`r`nC" "`tB`n" "Q`r`n")
        (Get-TrText $p) | Should BeExactly "AQ`nC"
    }
    It 'preserves valid surrogate pairs and XML escaping across formatting boundaries' {
        $face=[char]::ConvertFromUtf32(0x1F600)
        $f=New-TrFixture ('<hp:run charPrIDRef="1"><hp:t>A'+$face+'</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>B&amp;C</hp:t></hp:run>')
        $p=Invoke-TrReplacement $f (New-TrOperation ('A'+$face+'B&C') ($face+'B') '<&>')
        (Get-TrText $p) | Should BeExactly 'A<&>&C'
        $p.FirstChild.InnerText | Should BeExactly 'A<&>'
        [xml]$roundtrip=$p.OuterXml
        $roundtrip.DocumentElement.InnerText | Should BeExactly 'A<&>&C'
    }
    It 'invalidates only the changed paragraph line cache' {
        $f=New-TrFixture; $ns=$f.Paragraph.NamespaceURI
        $cache=$f.Paragraph.OwnerDocument.CreateElement('hp','linesegarray',$ns)
        $null=$f.Paragraph.AppendChild($cache)
        $p=Invoke-TrReplacement $f (New-TrOperation)
        $p.SelectNodes('*[local-name()="linesegarray"]').Count | Should Be 0
        $f.Paragraph.SelectNodes('*[local-name()="linesegarray"]').Count | Should Be 1
    }
    It 'rejects stale text, absent literal and empty literal atomically' {
        Assert-TrAtomicFailure (New-TrFixture) (New-TrOperation 'wrong') '*expectedText*'
        Assert-TrAtomicFailure (New-TrFixture) (New-TrOperation 'pre ABCD post untouched' 'missing') '*match*'
        Assert-TrAtomicFailure (New-TrFixture) (New-TrOperation 'pre ABCD post untouched' '') '*find*'
    }
    It 'does not accept linguistically equal but ordinally different whole-paragraph guards' {
        $op=New-TrOperation ('pre A'+[char]0xAD+'BCD post untouched')
        Assert-TrAtomicFailure (New-TrFixture) $op '*expectedText*'
        $op=New-TrOperation ('pre ABCD post untouched'+[char]0x200B)
        Assert-TrAtomicFailure (New-TrFixture) $op '*expectedText*'
    }
    It 'preserves multiple text nodes and CDATA fragments around a match' {
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t><![CDATA[left ]]><![CDATA[AB]]>CD<hp:tab width="91"/><![CDATA[right]]></hp:t></hp:run>'
        $p=Invoke-TrReplacement $f (New-TrOperation "left ABCD`tright" 'BC' 'X')
        (Get-TrText $p) | Should BeExactly "left AXD`tright"
        $p.FirstChild.FirstChild.FirstChild.NodeType.ToString() | Should BeExactly 'CDATA'
        $p.SelectSingleNode('.//*[local-name()="tab"]').GetAttribute('width') | Should BeExactly '91'
    }
    It 'never treats a supplementary character as two independent matches' {
        $face=[char]::ConvertFromUtf32(0x1F600)
        $f=New-TrFixture ('<hp:run charPrIDRef="1"><hp:t>'+$face+'</hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>'+$face+'Z</hp:t></hp:run>')
        $op=New-TrOperation ($face+$face+'Z') $face 'Q'; $op.replaceAll=$true
        $p=Invoke-TrReplacement $f $op
        (Get-TrText $p) | Should BeExactly 'QQZ'
        $p.FirstChild.InnerText | Should BeExactly 'Q'
        $p.LastChild.InnerText | Should BeExactly 'QZ'
    }
    It 'rejects incorrect operation types, coercions, missing keys and unknown keys' {
        foreach($key in @('expectedText','find','replacement')) {
            $op=New-TrOperation; $op[$key]=42; Assert-TrAtomicFailure (New-TrFixture) $op '*string*'
            $op=New-TrOperation; $op.Remove($key); Assert-TrAtomicFailure (New-TrFixture) $op '*Missing*'
        }
        $op=New-TrOperation; $op.replaceAll='true'; Assert-TrAtomicFailure (New-TrFixture) $op '*Boolean*'
        $op=New-TrOperation; $op.extra=1; Assert-TrAtomicFailure (New-TrFixture) $op '*Unrecognized*'
        $op=New-TrOperation; $op.type='replace-run-text'; Assert-TrAtomicFailure (New-TrFixture) $op '*type*'
    }
    It 'rejects stale or wrong paragraph addresses before preparing edits' {
        $op=New-TrOperation; $op.address.sourceSha256='b'*64; Assert-TrAtomicFailure (New-TrFixture) $op '*sourceSha256*'
        $op=New-TrOperation; $op.address.kind='run'; Assert-TrAtomicFailure (New-TrFixture) $op '*kind*'
        $op=New-TrOperation; $op.address.path=@(0,0); Assert-TrAtomicFailure (New-TrFixture) $op '*kind*'
        $f=New-TrFixture; $op=New-TrOperation; $other=$f.Paragraph.CloneNode($true)
        $null=$f.Paragraph.ParentNode.AppendChild($other); $op.address.path=@(1)
        Assert-TrAtomicFailure $f $op '*target*'
    }
    It 'rejects controls, fields, bookmarks, unknown children and inline metadata' {
        foreach($body in @('<hp:ctrl/>','<hp:fieldBegin/>','<hp:bookmark/>','<hp:t>A<hp:unknown/>B</hp:t>','<hp:t>A<hp:lineBreak extra="1"/>B</hp:t>','<hp:t>A<hp:tab extra="1"/>B</hp:t>','<hp:t extra="1">AB</hp:t>','<hp:t>AB</hp:t><hp:t/>','<hp:t>A<!--hidden-->B</hp:t>')) {
            $f=New-TrFixture ('<hp:run charPrIDRef="1">'+$body+'</hp:run>')
            Assert-TrAtomicFailure $f (New-TrOperation 'AB' 'A' 'X') '*'
        }
        foreach($target in @('paragraph','run')) {
            $f=New-TrFixture; $node=if($target -eq 'paragraph'){$f.Paragraph}else{$f.Paragraph.FirstChild}
            $node.SetAttribute('mystery','1'); Assert-TrAtomicFailure $f (New-TrOperation) '*metadata*'
        }
    }
    It 'rejects invalid style references and invalid XML characters or UTF16 in every string' {
        $f=New-TrFixture; $f.Paragraph.FirstChild.SetAttribute('charPrIDRef','99'); Assert-TrAtomicFailure $f (New-TrOperation) '*resource*'
        $f=New-TrFixture; $f.Paragraph.SetAttribute('paraPrIDRef','99'); Assert-TrAtomicFailure $f (New-TrOperation) '*resource*'
        foreach($key in @('expectedText','find','replacement')) {
            foreach($bad in @([string][char]0,[string][char]0xD800,[string][char]0xDC00)) {
                $op=New-TrOperation; $op[$key]=$bad; Assert-TrAtomicFailure (New-TrFixture) $op '*'
            }
        }
    }
    It 'rejects strings and expanded paragraph output above one MiB before mutation' {
        foreach($key in @('expectedText','find','replacement')) {
            $op=New-TrOperation; $op[$key]='x'*(1MB+1); Assert-TrAtomicFailure (New-TrFixture) $op '*1 MiB*'
        }
        $op=New-TrOperation 'pre ABCD post untouched' 'ABCD' ('x'*1MB)
        Assert-TrAtomicFailure (New-TrFixture) $op '*1 MiB*'
    }
    It 'bounds replacement count, run count and cumulative prepared memory atomically' {
        $f=New-TrFixture ('<hp:run charPrIDRef="1"><hp:t>'+('a'*10001)+'</hp:t></hp:run>')
        $op=New-TrOperation ('a'*10001) 'a' 'b'; $op.replaceAll=$true
        Assert-TrAtomicFailure $f $op '*10000*'
        $f=New-TrFixture ('<hp:run charPrIDRef="1"><hp:t>a</hp:t></hp:run>'*4097)
        Assert-TrAtomicFailure $f (New-TrOperation ('a'*4097) 'a' 'b') '*4096*'
        $f=New-TrFixture; $f.Allocation.TextRangePreparedCharacters=[long](16MB)
        Assert-TrAtomicFailure $f (New-TrOperation) '*16 MiB*'
        $f=New-TrFixture; $f.Allocation.TextRangeReplacementCharacters=[long](16MB)
        Assert-TrAtomicFailure $f (New-TrOperation) '*16 MiB*'
    }
    It 'bounds input DOM nodes and replacement inline node expansion before editing' {
        $f=New-TrFixture ('<hp:run charPrIDRef="1"><hp:t>'+('<hp:tab/>'*65536)+'A</hp:t></hp:run>')
        Assert-TrAtomicFailure $f (New-TrOperation (("`t"*65536)+'A') 'A' 'B') '*65536*'
        $f=New-TrFixture '<hp:run charPrIDRef="1"><hp:t>A</hp:t></hp:run>'
        Assert-TrAtomicFailure $f (New-TrOperation 'A' 'A' ("`t"*40000)) '*65536*'
    }
    It 'tracks successful allocations without adding or changing style resources' {
        $f=New-TrFixture; $header=$f.Package.Xml['Contents/header.xml'].OuterXml
        $p=Invoke-TrReplacement $f (New-TrOperation)
        $f.Allocation.TextRangeReplacementCharacters | Should Be 1
        $f.Allocation.TextRangePreparedCharacters | Should Be $p.OuterXml.Length
        $q=Invoke-TrReplacement $f (New-TrOperation)
        $f.Allocation.TextRangeReplacementCharacters | Should Be 2
        $f.Allocation.TextRangePreparedCharacters | Should Be ($p.OuterXml.Length+$q.OuterXml.Length)
        $f.Package.Xml['Contents/header.xml'].OuterXml | Should BeExactly $header
    }
    It 'keeps original package and allocation intact when a later preparation in a batch fails' {
        $f=New-TrFixture; $before=$f.Paragraph.OwnerDocument.OuterXml; $header=$f.Package.Xml['Contents/header.xml'].OuterXml
        # Parent owns commit; this harness stages clones and commits only after all guards pass.
        $failed=$false; $staged=[Collections.Generic.List[object]]::new(); $scratch=@{}
        try {
            foreach($op in @((New-TrOperation),(New-TrOperation 'stale'))) {
                $p=Invoke-TrReplacement $f $op $scratch
                $staged.Add($p)
            }
            foreach($p in $staged) { $null=$f.Paragraph.ParentNode.ReplaceChild($p,$f.Paragraph) }
        } catch { $failed=$true }
        $failed | Should Be $true
        $staged.Count | Should Be 1
        $f.Paragraph.OwnerDocument.OuterXml | Should BeExactly $before
        $f.Package.Xml['Contents/header.xml'].OuterXml | Should BeExactly $header
        $f.Allocation.Count | Should Be 0
    }
}
