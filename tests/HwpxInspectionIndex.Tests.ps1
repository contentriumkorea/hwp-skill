Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force -WarningAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Independent pre-index address oracle: counts element siblings, never IDs,
# dictionary entries, or inspector-produced paths. Used only for differential tests.
$indexLegacyAddress = {
    param([Xml.XmlNode]$Node,[string]$Part,[string]$SourceSha256)
    if ([string]::IsNullOrEmpty($SourceSha256)) { return $null }
    $positions=[Collections.Generic.List[int]]::new()
    $cursor=$Node
    while ($cursor.ParentNode -is [Xml.XmlElement]) {
        $ordinal=0
        for($before=$cursor.PreviousSibling;$null -ne $before;$before=$before.PreviousSibling) {
            if($before.NodeType -eq [Xml.XmlNodeType]::Element){$ordinal++}
        }
        $positions.Insert(0,$ordinal)
        $cursor=$cursor.ParentNode
    }
    if($cursor.LocalName -cne 'sec' -or $cursor.NamespaceURI -cne 'http://www.hancom.co.kr/hwpml/2011/section'){return $null}
    [pscustomobject][ordered]@{version='1.0';sourceSha256=$SourceSha256;part=$Part;path=@($positions);kind=$Node.LocalName}
}

function New-IndexParagraph([string]$Text,[string]$Inline='') {
    '<hp:p id="0" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>'+[Security.SecurityElement]::Escape($Text)+'</hp:t>'+$Inline+'</hp:run></hp:p>'
}
function New-IndexTable([string]$Content) {
    '<hp:tbl id="0" rowCnt="1" colCnt="1" cellSpacing="0"><hp:sz width="3000" height="2000"/><hp:tr><x:opaque/><hp:tc name="same" borderFillIDRef="1"><hp:subList>'+$Content+'</hp:subList><hp:cellAddr rowAddr="0" colAddr="0"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="3000" height="2000"/></hp:tc></hp:tr></hp:tbl>'
}
function New-IndexAdversarialSection {
    $inner=New-IndexTable (New-IndexParagraph '中첩 😀 & < >')
    $outer=New-IndexTable (New-IndexParagraph 'outer' $inner)
    $header='<hp:ctrl><hp:header id="0"><hp:subList><x:opaque/>'+(New-IndexParagraph '머리말')+'</hp:subList></hp:header></hp:ctrl>'
    $footer='<hp:ctrl><hp:footer id="0"><hp:subList>'+(New-IndexParagraph '꼬리말')+'</hp:subList></hp:footer></hp:ctrl>'
    '<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:x="urn:inspection-index">'+
        "`n <!--comment--><?probe keep?><x:opaque id=`"0`"/>`n"+
        (New-IndexParagraph "한글 é 😀`tTAB`nLINE" ($header+$footer))+
        '<x:p id="0"><x:run><x:t>foreign namespace</x:t></x:run></x:p>'+
        (New-IndexParagraph 'body table anchor' $outer)+
        '<![CDATA[nonparagraph text]]><x:tail/>'+(New-IndexParagraph 'last')+'</hs:sec>'
}
function Write-IndexPart([string]$Path,[string]$Xml) {
    $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $zip.GetEntry('Contents/section0.xml').Delete()
        $stream=$zip.CreateEntry('Contents/section0.xml').Open()
        try {$bytes=[Text.Encoding]::UTF8.GetBytes($Xml);$stream.Write($bytes,0,$bytes.Length)} finally {$stream.Dispose()}
    } finally {$zip.Dispose()}
}
function New-IndexFixture([string]$Path,[string]$Xml) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $Path
    Write-IndexPart $Path $Xml
}
function Get-IndexLegacyInspection([string]$Path) {
    # Execute the actual inspector with only the address provider replaced by the
    # independent legacy oracle; restore it even if parsing or an assertion fails.
    & (Get-Module HwpInspect) {
        param($File,$Oracle)
        $original=(Get-Command New-HwpxNodeAddress).ScriptBlock
        try {
            Set-Item Function:script:New-HwpxNodeAddress -Value $Oracle
            Get-HwpxPackageInspection -LiteralPath $File
        } finally {Set-Item Function:script:New-HwpxNodeAddress -Value $original}
    } $Path $indexLegacyAddress
}

Describe 'Inspection-scoped element ordinals preserve canonical addresses' {
    It 'distinguishes identical sibling nodes by reference and ignores non-element siblings' {
        # Catches ID/XML-string keyed maps and indexes that count comments/text.
        & (Get-Module HwpInspect) {
            $doc=[Xml.XmlDocument]::new();$doc.PreserveWhitespace=$true
            $doc.LoadXml('<sec xmlns="http://www.hancom.co.kr/hwpml/2011/section"> text <!--c--><?pi x?><opaque/><p id="0"/> <![CDATA[text]]><p id="0"/></sec>')
            $nodes=$doc.SelectNodes('//*[local-name()="p"]')
            $ordinals=New-HwpxNodeOrdinalIndex -Document $doc
            $ordinals[$nodes[0]] | Should Be 1
            $ordinals[$nodes[1]] | Should Be 2
            $ordinals.Count | Should Be 3
            $other=[Xml.XmlDocument]::new();$other.LoadXml($doc.OuterXml)
            $ordinals.ContainsKey($other.SelectSingleNode('//*[local-name()="p"]')) | Should Be $false
            $address=New-HwpxNodeAddress $nodes[1] 'Contents/section0.xml' ('a'*64) -NodeOrdinals $ordinals
            ($address.path -join ',') | Should Be '2'
            $address.kind | Should Be 'p'
        }
    }
    It 'matches full legacy inspection JSON for nested tables, headers, footers and foreign siblings' {
        # Catches changed control/table/cell/p/run addresses, namespace filtering,
        # traversal order, or output fields against the old address algorithm.
        $path=Join-Path $TestDrive 'adversarial.hwpx'
        New-IndexFixture $path (New-IndexAdversarialSection)
        $hash=(Get-FileHash -LiteralPath $path).Hash
        $expected=Get-IndexLegacyInspection $path
        $actual=Get-HwpxPackageInspection -LiteralPath $path
        $actual.Status | Should Be 'PASS_WITH_WARNINGS'
        ($actual.Errors -join ';') | Should Be ''
        @($actual.Data.Tables).Count | Should Be 2
        ($actual.Data.Paragraphs.text -ccontains '머리말') | Should Be $true
        ($actual.Data.Paragraphs.text -ccontains '꼬리말') | Should Be $true
        ($actual.Data.Paragraphs.text -ccontains '中첩 😀 & < >') | Should Be $true
        (ConvertTo-Json -InputObject $actual -Depth 100 -Compress) | Should Be (ConvertTo-Json -InputObject $expected -Depth 100 -Compress)
        (Get-FileHash -LiteralPath $path).Hash | Should Be $hash
    }
    It 'rebuilds ordinals and source bindings after the same package path changes' {
        # Catches pathname/hash-independent persistent DOM/index reuse.
        $path=Join-Path $TestDrive 'changed.hwpx'
        $xml='<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">'+(New-IndexParagraph 'same ID')+'</hs:sec>'
        New-IndexFixture $path $xml
        $before=Get-HwpxPackageInspection -LiteralPath $path
        Write-IndexPart $path $xml.Replace('<hp:p','<other/><!--insert--><hp:p')
        $after=Get-HwpxPackageInspection -LiteralPath $path
        $after.Status | Should Be 'PASS_WITH_WARNINGS'
        ($before.Data.Paragraphs[0].address.path -join ',') | Should Be '0'
        ($after.Data.Paragraphs[0].address.path -join ',') | Should Be '1'
        ($before.Data.SourceSha256 -ceq $after.Data.SourceSha256) | Should Be $false
        $after.Data.Paragraphs[0].address.sourceSha256 | Should Be $after.Data.SourceSha256
        $expected=Get-IndexLegacyInspection $path
        (ConvertTo-Json -InputObject $after -Depth 100 -Compress) | Should Be (ConvertTo-Json -InputObject $expected -Depth 100 -Compress)
    }
    It 'retains standalone helper defaults, empty hashes and wrong section namespace semantics' {
        # Catches positional-parameter regressions and new unconditional addresses.
        & (Get-Module HwpInspect) {
            [xml]$doc='<sec xmlns="http://www.hancom.co.kr/hwpml/2011/section"><unknown/><p><run/></p></sec>'
            $node=$doc.DocumentElement.LastChild.FirstChild
            $address=New-HwpxNodeAddress $node 'part' ('b'*64)
            ($address.path -join ',') | Should Be '1,0'
            $indexed=New-HwpxNodeAddress $node 'part' ('b'*64) -NodeOrdinals (New-HwpxNodeOrdinalIndex $doc)
            (ConvertTo-Json $indexed -Depth 10 -Compress) | Should Be (ConvertTo-Json $address -Depth 10 -Compress)
            $null -eq (New-HwpxNodeAddress $node 'part' '') | Should Be $true
            [xml]$wrong='<sec xmlns="urn:wrong"><p/></sec>'
            $null -eq (New-HwpxNodeAddress $wrong.DocumentElement.FirstChild 'part' ('b'*64) -NodeOrdinals (New-HwpxNodeOrdinalIndex $wrong)) | Should Be $true
        }
    }
    It 'keeps an exact-budget index but discards it before adding the next unknown element' {
        # Catches off-by-one truncation and partial maps escaping on overflow.
        & (Get-Module HwpInspect) {
            [xml]$exact='<sec xmlns="http://www.hancom.co.kr/hwpml/2011/section" xmlns:x="urn:unknown"><x:q/><!--skip--><x:q/><p/></sec>'
            $map=New-HwpxNodeOrdinalIndex -Document $exact -MaximumEntries 3
            $map.Count | Should Be 3
            $map[$exact.DocumentElement.LastChild] | Should Be 2
            [xml]$over='<sec xmlns="http://www.hancom.co.kr/hwpml/2011/section" xmlns:x="urn:unknown"><x:q/><!--skip--><x:q/><x:q/><p/></sec>'
            $map=New-HwpxNodeOrdinalIndex -Document $over -MaximumEntries 3
            ($null -eq $map) | Should Be $true
            $address=New-HwpxNodeAddress $over.DocumentElement.LastChild 'part' ('c'*64) -NodeOrdinals $map
            ($address.path -join ',') | Should Be '3'
        }
    }
    It 'preserves full legacy inspection JSON when the index budget forces fallback' {
        # Runs the actual bounded builder at a tiny private budget, not a null-map mock.
        $path=Join-Path $TestDrive 'budget-fallback.hwpx'
        New-IndexFixture $path (New-IndexAdversarialSection)
        $hash=(Get-FileHash -LiteralPath $path).Hash
        $expected=Get-IndexLegacyInspection $path
        $actual=& (Get-Module HwpInspect) {
            param($File)
            $originalIndex=(Get-Command New-HwpxNodeOrdinalIndex).ScriptBlock
            $bounded={
                param([Xml.XmlDocument]$Document)
                & $originalIndex -Document $Document -MaximumEntries 1
            }.GetNewClosure()
            try {
                Set-Item Function:script:New-HwpxNodeOrdinalIndex -Value $bounded
                Get-HwpxPackageInspection -LiteralPath $File
            } finally {Set-Item Function:script:New-HwpxNodeOrdinalIndex -Value $originalIndex}
        } $path
        $actual.Status | Should Be 'PASS_WITH_WARNINGS'
        (ConvertTo-Json -InputObject $actual -Depth 100 -Compress) | Should Be (ConvertTo-Json -InputObject $expected -Depth 100 -Compress)
        (Get-FileHash -LiteralPath $path).Hash | Should Be $hash
    }
    It 'returns no index for 200000 unknown leaves under the default private budget' {
        # Catches unbounded indexing of otherwise valid extension XML.
        & (Get-Module HwpInspect) {
            [xml]$doc='<sec xmlns="http://www.hancom.co.kr/hwpml/2011/section" xmlns:x="urn:unknown"><x:opaque>'+('<x:q/>'*200000)+'</x:opaque><p><run><t>body</t></run></p></sec>'
            $map=New-HwpxNodeOrdinalIndex -Document $doc
            ($null -eq $map) | Should Be $true
        }
    }
    It 'rejects private index budgets outside the supported range' {
        & (Get-Module HwpInspect) {
            [xml]$doc='<root/>'
            {New-HwpxNodeOrdinalIndex -Document $doc -MaximumEntries 0} | Should Throw
            {New-HwpxNodeOrdinalIndex -Document $doc -MaximumEntries 100001} | Should Throw
        }
    }
}
