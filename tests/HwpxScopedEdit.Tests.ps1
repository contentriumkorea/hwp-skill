# Independent ZIP fixtures: never call the authoring/generation modules.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$scopedModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1'
if (Test-Path -LiteralPath $scopedModule) { Import-Module $scopedModule -Force }

function Read-ScopedTestPart {
    param([string]$Path, [string]$Name)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry($Name)
        if ($null -eq $entry) { return $null }
        $stream = $entry.Open()
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); return ,$memory.ToArray() }
        finally { $stream.Dispose(); $memory.Dispose() }
    } finally { $zip.Dispose() }
}

function Set-ScopedTestPart {
    param([string]$Path, [string]$Name, [byte[]]$Bytes, [switch]$Duplicate)
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $old = $zip.GetEntry($Name)
        if ($null -ne $old -and -not $Duplicate) { $old.Delete() }
        $entry = $zip.CreateEntry($Name)
        $stream = $entry.Open()
        try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
}

function Read-ScopedTestXml {
    param([string]$Path, [string]$Name = 'Contents/section0.xml')
    [xml][Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $Path $Name))
}

function Update-ScopedTestSection {
    param([string]$Path, [scriptblock]$Change)
    $text = [Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $Path 'Contents/section0.xml'))
    $updated = & $Change $text
    Set-ScopedTestPart $Path 'Contents/section0.xml' ([Text.Encoding]::UTF8.GetBytes($updated))
}

function New-ScopedTestFixture {
    param([string]$Path)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $Path
    Update-ScopedTestSection $Path {
        param($text)
        $text = $text.Replace('<hs:sec ', '<hs:sec xmlns:u="urn:scoped-test" u:root="preserve" ')
        $text = $text.Replace('landscape="WIDELY"', 'landscape="WIDELY" u:page="keep"')
        $text = $text.Replace('<hp:t/>', '<hp:t u:text="keep">Before</hp:t>')
        $text.Replace('</hs:sec>', @'
<!--keep this comment--><u:extension u:flag="original"><hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Nested</hp:t></hp:run></hp:p><u:opaque><![CDATA[<untouched>]]></u:opaque></u:extension>
<hp:p id="11" paraPrIDRef="0" u:paragraph="keep"><hp:run charPrIDRef="0" u:run="keep"><hp:t>Alpha</hp:t></hp:run><hp:run charPrIDRef="0"><hp:t>Beta</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>
<hp:p id="12" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Stay</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p></hs:sec>
'@)
    }
    Set-ScopedTestPart $Path 'BinData/opaque.bin' ([byte[]]@(0,255,1,128,13,10,42))
    Set-ScopedTestPart $Path 'Custom/empty.bin' ([byte[]]@())
    Set-ScopedTestPart $Path 'Custom/unknown.xml' ([Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><x:unknown xmlns:x="urn:vendor" value="raw &amp; exact" />'))
    Set-ScopedTestPart $Path 'Preview/vendor-cache.bin' ([byte[]]@(1,2,3))
}

function New-ScopedTestPlan {
    param([object[]]$Operations = @(@{type='set-page'; sectionIndex=0; orientation='LANDSCAPE'}))
    @{ version='2.0'; operations=$Operations }
}

function Add-ScopedTestTable {
    param([string]$Path)
    $builder = [Text.StringBuilder]::new()
    $null = $builder.Append('<hp:p id="90" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:tbl id="91" rowCnt="3" colCnt="3" cellSpacing="0" borderFillIDRef="2"><hp:sz width="12000" height="6000" widthRelTo="ABSOLUTE" heightRelTo="ABSOLUTE"/><hp:inMargin left="0" right="0" top="0" bottom="0"/>')
    for ($row=0; $row -lt 3; $row++) {
        $null = $builder.Append('<hp:tr>')
        for ($col=0; $col -lt 3; $col++) {
            $number = $row*3+$col
            $letter = [string][char](65+$number)
            $extraParagraph = if ($number -eq 0) { '<hp:p id="200" paraPrIDRef="1" u:p="preserve"><hp:run charPrIDRef="1"><hp:t>A2</hp:t></hp:run></hp:p>' } else { '' }
            $null = $builder.Append(('<hp:tc name="" header="0" hasMargin="1" protect="0" editable="0" dirty="0" borderFillIDRef="2"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0"><hp:p id="{0}" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>{1}</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>{2}</hp:subList><hp:cellAddr rowAddr="{3}" colAddr="{4}"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="{5}" height="{6}"/><hp:cellMargin left="100" right="101" top="102" bottom="103"/></hp:tc>' -f ($number+100),$letter,$extraParagraph,$row,$col,(3000+$col*1000),(1000+$row*1000)))
        }
        $null = $builder.Append('</hp:tr>')
    }
    $null = $builder.Append('</hp:tbl></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>')
    Update-ScopedTestSection $Path {param($text) $text.Replace('</hs:sec>',($builder.ToString()+'</hs:sec>'))}
}

function Get-ScopedTestCell {
    param([xml]$Xml, [int]$Row, [int]$Column)
    $Xml.SelectSingleNode(('//*[local-name()="tbl"]/*[local-name()="tr"]/*[local-name()="tc"][*[local-name()="cellAddr"][@rowAddr="{0}" and @colAddr="{1}"]]' -f $Row,$Column))
}

function Set-ScopedTestMergedFixture {
    param([string]$Path)
    $xml = Read-ScopedTestXml $Path
    $anchor = Get-ScopedTestCell $xml 0 0
    $sub = $anchor.SelectSingleNode('*[local-name()="subList"]')
    foreach ($pair in @(@(0,1),@(1,0),@(1,1))) {
        $donor = Get-ScopedTestCell $xml $pair[0] $pair[1]
        foreach ($p in @($donor.SelectNodes('*[local-name()="subList"]/*[local-name()="p"]'))) {$null=$sub.AppendChild($p)}
        $null=$donor.ParentNode.RemoveChild($donor)
    }
    $span=$anchor.SelectSingleNode('*[local-name()="cellSpan"]')
    $span.SetAttribute('rowSpan','2'); $span.SetAttribute('colSpan','2')
    $size=$anchor.SelectSingleNode('*[local-name()="cellSz"]')
    $size.SetAttribute('width','7000'); $size.SetAttribute('height','3000')
    Set-ScopedTestPart $Path 'Contents/section0.xml' ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml))
}

function Assert-ScopedTestBlocked {
    param([string]$Source, [string]$Output, [object]$Plan)
    $before = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
    $filesBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Source)) -Force | Select-Object -ExpandProperty Name)
    $result = Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan $Plan
    $result.Status | Should Be 'BLOCKED'
    $result.Errors.Count | Should BeGreaterThan 0
    (Test-Path -LiteralPath $Output) | Should Be $false
    (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash | Should Be $before
    $filesAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Source)) -Force | Select-Object -ExpandProperty Name)
    @((Compare-Object $filesBefore $filesAfter)).Count | Should Be 0
}

Describe 'Bounded HWPX scoped editing' {
    BeforeEach {
        $caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $caseDir
        $source = Join-Path $caseDir 'source.hwpx'
        $output = Join-Path $caseDir 'copy.hwpx'
        New-ScopedTestFixture $source
    }

    It 'exports the scoped edit entry point' {
        @(Get-Command Invoke-HwpxScopedEdit -ErrorAction SilentlyContinue).Count | Should Be 1
    }

    It 'changes only page orientation and invalidates caches without swapping stored dimensions' {
        $before = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan)
        ($result.Errors -join '; ') | Should Be ''
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.Data.SourceSha256 | Should Be $before
        $result.Data.OutputSha256 | Should Be (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
        $result.Data.NativeLayoutVerified | Should Be $false
        $result.Warnings -join ' ' | Should Match 'render|layout'
        $result.Warnings -join ' ' | Should Match 'cache'
        ($result.Data.ChangedParts -contains 'Contents/section0.xml') | Should Be $true
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $before
        $xml = Read-ScopedTestXml $output
        $page = $xml.SelectSingleNode('//*[local-name()="pagePr"]')
        $page.GetAttribute('landscape') | Should Be 'NARROWLY'
        $page.GetAttribute('width') | Should Be '59528'
        $page.GetAttribute('height') | Should Be '84186'
        $page.GetAttribute('page','urn:scoped-test') | Should Be 'keep'
        @($xml.SelectNodes('//*[local-name()="linesegarray"]')).Count | Should Be 0
        $zip = [IO.Compression.ZipFile]::OpenRead($output)
        try { @($zip.Entries | Where-Object FullName -Like 'Preview/*').Count | Should Be 0 }
        finally { $zip.Dispose() }
        @(Get-ChildItem -LiteralPath $caseDir -Force).Count | Should Be 2
    }

    It 'preserves every untouched payload byte including unknown parts and empty BinData' {
        $null = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan)
        $zip = [IO.Compression.ZipFile]::OpenRead($source)
        try { $names = @($zip.Entries.FullName) } finally { $zip.Dispose() }
        foreach ($name in $names) {
            if ($name -eq 'Contents/section0.xml' -or $name -like 'Preview/*') { continue }
            [Convert]::ToBase64String((Read-ScopedTestPart $output $name)) | Should Be ([Convert]::ToBase64String((Read-ScopedTestPart $source $name)))
        }
        $xml = Read-ScopedTestXml $output
        $xml.DocumentElement.GetAttribute('root','urn:scoped-test') | Should Be 'preserve'
        $xml.SelectSingleNode('//*[local-name()="extension"]').OuterXml | Should Be (Read-ScopedTestXml $source).SelectSingleNode('//*[local-name()="extension"]').OuterXml
        $xml.SelectSingleNode('//comment()').Value | Should Be 'keep this comment'
    }

    It 'addresses only direct paragraphs and direct runs and preserves other paragraph caches' {
        $replacement = 'A & <B> ' + [char]0xD55C + [char]0xAE00 + "`r`nend"
        $plan = New-ScopedTestPlan @(@{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=1;text=$replacement;expectedText='Beta'})
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $xml = Read-ScopedTestXml $output
        $paragraphs = $xml.SelectNodes('/*/*[local-name()="p"]')
        $paragraphs[1].SelectNodes('*[local-name()="run"]')[1].InnerText | Should Be $replacement
        $paragraphs[1].SelectNodes('*[local-name()="run"]')[0].InnerText | Should Be 'Alpha'
        $xml.SelectSingleNode('//*[local-name()="extension"]//*[local-name()="t"]').InnerText | Should Be 'Nested'
        $paragraphs[1].SelectNodes('*[local-name()="linesegarray"]').Count | Should Be 0
        $paragraphs[2].SelectNodes('*[local-name()="linesegarray"]').Count | Should Be 1
    }

    It 'changes text and style references together without rewriting shared header resources' {
        $plan = New-ScopedTestPlan @(
            @{type='replace-run-text';sectionIndex=0;paragraphIndex=0;runIndex=1;text='After';expectedText='Before'},
            @{type='set-run-style';sectionIndex=0;paragraphIndex=0;runIndex=1;charPrIDRef='1'},
            @{type='set-paragraph-style';sectionIndex=0;paragraphIndex=1;paraPrIDRef=2}
        )
        $beforePlan = $plan | ConvertTo-Json -Depth 8 -Compress
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        ($plan | ConvertTo-Json -Depth 8 -Compress) | Should Be $beforePlan
        $xml = Read-ScopedTestXml $output
        $paragraphs = $xml.SelectNodes('/*/*[local-name()="p"]')
        $run = $paragraphs[0].SelectNodes('*[local-name()="run"]')[1]
        $run.InnerText | Should Be 'After'
        $run.GetAttribute('charPrIDRef') | Should Be '1'
        $run.FirstChild.GetAttribute('text','urn:scoped-test') | Should Be 'keep'
        $paragraphs[1].GetAttribute('paraPrIDRef') | Should Be '2'
        [Convert]::ToBase64String((Read-ScopedTestPart $output 'Contents/header.xml')) | Should Be ([Convert]::ToBase64String((Read-ScopedTestPart $source 'Contents/header.xml')))
    }

    It 'accepts JSON objects and an empty replacement text' {
        $plan = '{"version":"2.0","operations":[{"type":"replace-run-text","sectionIndex":0,"paragraphIndex":0,"runIndex":1,"text":"","expectedText":"Before"},{"type":"set-page","sectionIndex":0,"orientation":"PORTRAIT"}]}' | ConvertFrom-Json
        (Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan).Status | Should Be 'PASS_WITH_WARNINGS'
        (Read-ScopedTestXml $output).SelectSingleNode('//*[local-name()="pagePr"]').GetAttribute('landscape') | Should Be 'WIDELY'
        (Read-ScopedTestXml $output).SelectSingleNode('/*/*[local-name()="p"][1]/*[local-name()="run"][2]/*[local-name()="t"]').InnerText | Should Be ''
    }

    It 'never overwrites the source or an existing destination' {
        $before = (Get-FileHash -LiteralPath $source).Hash
        (Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $source -Plan (New-ScopedTestPlan)).Status | Should Be 'BLOCKED'
        [IO.File]::WriteAllBytes($output, [byte[]]@(9,8,7))
        (Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan)).Status | Should Be 'BLOCKED'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) | Should Be 'CQgH'
        (Get-FileHash -LiteralPath $source).Hash | Should Be $before
    }

    It 'preflights a later invalid operation without creating any output or partial' {
        $plan = New-ScopedTestPlan @(
            @{type='set-page';sectionIndex=0;orientation='LANDSCAPE'},
            @{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=0;text='New';expectedText='wrong'}
        )
        Assert-ScopedTestBlocked $source $output $plan
    }

    $badOperations = @(
        @{type='set-page';orientation='LANDSCAPE'},
        @{type='set-page';sectionIndex=9;orientation='LANDSCAPE'},
        @{type='set-page';sectionIndex=-1;orientation='LANDSCAPE'},
        @{type='set-page';sectionIndex='0';orientation='LANDSCAPE'},
        @{type='set-page';sectionIndex=$false;orientation='LANDSCAPE'},
        @{type='set-page';sectionIndex=0.5;orientation='LANDSCAPE'},
        @{type='set-page';sectionIndex=0;orientation='SIDEWAYS'},
        @{type='set-page';sectionIndex=0;orientation='landscape'},
        @{type='set-page';sectionIndex=0;orientation='LANDSCAPE';width=100},
        @{type='unknown';sectionIndex=0},
        @{type='replace-run-text';sectionIndex=0;paragraphIndex=3;runIndex=0;text='New';expectedText='Stay'},
        @{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=9;text='New';expectedText='Alpha'},
        @{type='replace-run-text';sectionIndex=0;paragraphIndex=1;text='New';expectedText='Alpha'},
        @{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=0;text='New'},
        @{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=0;text=7;expectedText='Alpha'},
        @{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=0;text='New';expectedText='alpha'},
        @{type='set-run-style';sectionIndex=0;paragraphIndex=1;runIndex=0;charPrIDRef='999'},
        @{type='set-paragraph-style';sectionIndex=0;paragraphIndex=1;paraPrIDRef='999'},
        @{type='set-run-style';sectionIndex=0;paragraphIndex=1;runIndex=0;charPrIDRef=$true},
        @{type='set-paragraph-style';sectionIndex=0;paragraphIndex=1;paraPrIDRef='1 or 1=1'}
    )
    for ($i=0; $i -lt $badOperations.Count; $i++) {
        It "blocks invalid operation/address/value case $i" {
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($badOperations[$i]))
        }
    }

    It 'blocks invalid plan versions, extra keys, nulls and non-array operations' {
        foreach ($badPlan in @($null,@{},@{version='1.0';operations=@()},@{version='2.0';operations=@()},@{version='2.0';operations=@{type='set-page'}},@{version='2.0';operations=@($null)},@{version='2.0';operations=(New-ScopedTestPlan).operations;extra=1})) {
            Assert-ScopedTestBlocked $source $output $badPlan
        }
    }

    It 'blocks control-bearing runs for both text and character style changes' {
        foreach ($op in @(
            @{type='replace-run-text';sectionIndex=0;paragraphIndex=0;runIndex=0;text='New';expectedText=''},
            @{type='set-run-style';sectionIndex=0;paragraphIndex=0;runIndex=0;charPrIDRef='1'}
        )) { Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($op)) }
    }

    It 'blocks multiple text elements and nested controls inside a text element' {
        Update-ScopedTestSection $source { param($t) $t.Replace('<hp:t>Alpha</hp:t>', '<hp:t>Alpha</hp:t><hp:t>Extra</hp:t>') }
        $plan = New-ScopedTestPlan @(@{type='replace-run-text';sectionIndex=0;paragraphIndex=1;runIndex=0;text='New';expectedText='Alpha'})
        Assert-ScopedTestBlocked $source $output $plan
        Update-ScopedTestSection $source { param($t) $t.Replace('<hp:t>Alpha</hp:t><hp:t>Extra</hp:t>', '<hp:t>Alpha<hp:tab/></hp:t>') }
        Assert-ScopedTestBlocked $source $output $plan
    }

    It 'rejects duplicate writes to the same target property' {
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(
            @{type='set-page';sectionIndex=0;orientation='LANDSCAPE'},
            @{type='set-page';sectionIndex=0;orientation='PORTRAIT'}
        ))
    }

    It 'rejects binary disguises and non-HWPX ZIP mimetypes' {
        [IO.File]::WriteAllBytes($source, [byte[]]@(0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
        New-ScopedTestFixture $source
        Set-ScopedTestPart $source 'mimetype' ([Text.Encoding]::ASCII.GetBytes('application/zip'))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
    }

    It 'rejects DTDs and external entities even in an untouched XML part' {
        Set-ScopedTestPart $source 'Custom/unknown.xml' ([Text.Encoding]::UTF8.GetBytes('<!DOCTYPE x [<!ENTITY data SYSTEM "file:///nonexistent-scoped-secret">]><x>&data;</x>'))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
    }

    It 'rejects duplicate and case-aliased ZIP entry paths' {
        Set-ScopedTestPart $source 'Contents/section0.xml' (Read-ScopedTestPart $source 'Contents/section0.xml') -Duplicate
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
        New-ScopedTestFixture $source
        Set-ScopedTestPart $source 'contents/SECTION0.xml' ([byte[]]@(1))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
    }

    It 'rejects traversal and absolute ZIP entry paths without extracting' {
        foreach ($name in @('../escape.bin','Contents/../escape.bin','/root.bin','C:/drive.bin','Contents\escape.bin','Contents//empty.bin')) {
            New-ScopedTestFixture $source
            Set-ScopedTestPart $source $name ([byte[]]@(1))
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
        }
    }

    It 'rejects excessive decompression of an opaque part' {
        Set-ScopedTestPart $source 'Custom/bomb.bin' ([byte[]]::new(2MB))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
    }

    It 'rejects signed or encrypted packages without removing protection' {
        Set-ScopedTestPart $source 'META-INF/signatures.xml' ([Text.Encoding]::UTF8.GetBytes('<Signature xmlns="http://www.w3.org/2000/09/xmldsig#"/>'))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
    }

    It 'rejects ambiguous page definitions and duplicate style resource IDs' {
        Update-ScopedTestSection $source { param($t) $t.Replace('</hp:secPr>','<hp:pagePr landscape="NARROWLY" width="10" height="20"/></hp:secPr>') }
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan)
        New-ScopedTestFixture $source
        $header = [Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $source 'Contents/header.xml'))
        $header = $header.Replace('<hh:charPr id="1"', '<hh:charPr id="0"')
        Set-ScopedTestPart $source 'Contents/header.xml' ([Text.Encoding]::UTF8.GetBytes($header))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(@{type='set-run-style';sectionIndex=0;paragraphIndex=1;runIndex=0;charPrIDRef='0'}))
    }

    It 'uses spine order for sections and preserves the other section byte for byte' {
        $second = [Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $source 'Contents/section0.xml')).Replace('Before','Second')
        Set-ScopedTestPart $source 'Contents/section1.xml' ([Text.Encoding]::UTF8.GetBytes($second))
        $header = [Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $source 'Contents/header.xml')).Replace('secCnt="1"','secCnt="2"')
        Set-ScopedTestPart $source 'Contents/header.xml' ([Text.Encoding]::UTF8.GetBytes($header))
        $manifest = [Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $source 'Contents/content.hpf'))
        $manifest = $manifest.Replace('</opf:manifest>','<opf:item id="section1" href="Contents/section1.xml" media-type="application/xml"/></opf:manifest>')
        $manifest = $manifest.Replace('<opf:itemref idref="section0"', '<opf:itemref idref="section1" linear="yes"/><opf:itemref idref="section0"')
        Set-ScopedTestPart $source 'Contents/content.hpf' ([Text.Encoding]::UTF8.GetBytes($manifest))
        $plan = New-ScopedTestPlan @(@{type='replace-run-text';sectionIndex=0;paragraphIndex=0;runIndex=1;text='New second';expectedText='Second'})
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        [Convert]::ToBase64String((Read-ScopedTestPart $output 'Contents/section0.xml')) | Should Be ([Convert]::ToBase64String((Read-ScopedTestPart $source 'Contents/section0.xml')))
        (Read-ScopedTestXml $output 'Contents/section1.xml').SelectSingleNode('/*/*[local-name()="p"][1]/*[local-name()="run"][2]/*[local-name()="t"]').InnerText | Should Be 'New second'
        ($result.Data.ChangedParts -contains 'Contents/section1.xml') | Should Be $true
        ($result.Data.ChangedParts -contains 'Contents/section0.xml') | Should Be $false
    }

    It 'blocks a source already held for writing and leaves it unchanged' {
        $before = (Get-FileHash -LiteralPath $source -ErrorAction Stop).Hash
        $writer = [IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        try {
            $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan)
            $result.Status | Should Be 'BLOCKED'
            (Test-Path -LiteralPath $output) | Should Be $false
        }
        finally { $writer.Dispose() }
        (Get-FileHash -LiteralPath $source -ErrorAction Stop).Hash | Should Be $before
    }

    It 'preserves a competing destination and unrelated partial when atomic promotion fails' {
        $unrelated = Join-Path $caseDir '.unrelated.partial.hwpx'
        [IO.File]::WriteAllBytes($unrelated,[byte[]]@(1,2,3))
        # Simulate another writer winning the destination while our partial is verified.
        # Real ZIP writing, re-open verification and File.Move still execute.
        Mock Get-HwpSha256 -ModuleName HwpHwpxScopedEdit {
            param($LiteralPath)
            if ($LiteralPath -like '*.partial.hwpx') {
                [IO.File]::WriteAllBytes((Join-Path ([IO.Path]::GetDirectoryName($LiteralPath)) 'copy.hwpx'),[byte[]]@(9,8,7))
            }
            (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $before = (Get-FileHash -LiteralPath $source).Hash
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan)
        $result.Status | Should Be 'BLOCKED'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) | Should Be 'CQgH'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($unrelated)) | Should Be 'AQID'
        (Get-FileHash -LiteralPath $source).Hash | Should Be $before
        @(Get-ChildItem -LiteralPath $caseDir -Force).Count | Should Be 3
    }

    It 'bounds cumulative replacement text before building a large edited document' {
        $operations = @()
        $largeText = 'x' * 1MB
        $extra = [Text.StringBuilder]::new()
        for ($n=0; $n -lt 17; $n++) {
            $null = $extra.Append('<hp:p paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Small</hp:t></hp:run></hp:p>')
            $operations += @{type='replace-run-text';sectionIndex=0;paragraphIndex=($n+3);runIndex=0;text=$largeText;expectedText='Small'}
        }
        Update-ScopedTestSection $source { param($t) $t.Replace('</hs:sec>',($extra.ToString()+'</hs:sec>')) }
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan $operations)
        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'cumulative.*text'
        (Test-Path -LiteralPath $output) | Should Be $false
        @(Get-ChildItem -LiteralPath $caseDir -Force).Count | Should Be 1
    }
}

Describe 'Scoped inspected-source guard and page geometry' {
    BeforeEach {
        $caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $caseDir
        $source = Join-Path $caseDir 'source.hwpx'
        $output = Join-Path $caseDir 'copy.hwpx'
        New-ScopedTestFixture $source
    }

    It 'accepts an inspected source SHA-256 and rejects stale or malformed guards' {
        $plan = New-ScopedTestPlan
        foreach ($badHash in @(('0' * 64), 'bad', $null, 123)) {
            $plan.sourceSha256 = $badHash
            Assert-ScopedTestBlocked $source $output $plan
        }
        $plan.sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
    }

    It 'sets stored paper dimensions and selective margins while preserving orientation and unknown XML' {
        $plan = New-ScopedTestPlan @(@{type='set-page';sectionIndex=0;paperWidthMm=210;paperHeightMm=297;margins=@{leftMm=20;headerMm=5;gutterMm=0}})
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $page = (Read-ScopedTestXml $output).SelectSingleNode('//*[local-name()="pagePr"]')
        $page.GetAttribute('width') | Should Be '59528'
        $page.GetAttribute('height') | Should Be '84189'
        $page.GetAttribute('landscape') | Should Be 'WIDELY'
        $page.GetAttribute('page','urn:scoped-test') | Should Be 'keep'
        $margin = $page.FirstChild
        $margin.GetAttribute('left') | Should Be '5669'
        $margin.GetAttribute('header') | Should Be '1417'
        $margin.GetAttribute('right') | Should Be '4251'
        $margin.GetAttribute('gutter') | Should Be '0'
    }

    It 'accepts a page wrapper and validates usable area after orientation' {
        $page = @{orientation='LANDSCAPE';paperWidthMm=100;paperHeightMm=200;margins=@{leftMm=60;rightMm=60;topMm=5;bottomMm=5;headerMm=0;footerMm=0;gutterMm=0}}
        $plan = New-ScopedTestPlan @(@{type='set-page';sectionIndex=0;page=$page})
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $xmlPage = (Read-ScopedTestXml $output).SelectSingleNode('//*[local-name()="pagePr"]')
        $xmlPage.GetAttribute('width') | Should Be '28346'
        $xmlPage.GetAttribute('height') | Should Be '56693'
        $xmlPage.GetAttribute('landscape') | Should Be 'NARROWLY'
        $page.orientation = 'PORTRAIT'
        Assert-ScopedTestBlocked $source (Join-Path $caseDir 'blocked.hwpx') $plan
    }

    It 'rejects empty geometry, unsupported keys, invalid units, incomplete pairs and impossible bodies' {
        foreach ($fields in @(
            @{}, @{margins=@{}}, @{paperWidthMm=210}, @{paperWidthMm=0;paperHeightMm=297},
            @{paperWidthMm='210';paperHeightMm=297}, @{margins=@{leftMm=-1}},
            @{margins=@{leftMm=[double]::NaN}}, @{margins=@{leftMm=$true}},
            @{margins=@{leftMm=300}}, @{margins=@{topMm=300}}, @{margins=@{headerMm=300}},
            @{margins=@{unknownMm=1}}, @{page=@{orientation='LANDSCAPE'};orientation='PORTRAIT'},
            @{paperWidthMm=0.000001;paperHeightMm=297}
        )) {
            $op = @{type='set-page';sectionIndex=0}
            foreach ($key in $fields.Keys) { $op[$key] = $fields[$key] }
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($op))
        }
    }
}

Describe 'Scoped rectangular table merging' {
    BeforeEach {
        $caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $caseDir
        $source = Join-Path $caseDir 'source.hwpx'
        $output = Join-Path $caseDir 'copy.hwpx'
        New-ScopedTestFixture $source
        Add-ScopedTestTable $source
        $merge = @{type='merge-cells';sectionIndex=0;tableIndex=0;row=0;column=0;rowSpan=2;columnSpan=2;contentOrder='row-major';expectedTexts=@("A`nA2",'B','D','E')}
    }

    It 'merges a 2x2 region by moving whole paragraphs and retains every outside cell' {
        $before = Read-ScopedTestXml $source
        $result = Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan @($merge))
        ($result.Errors -join '; ') | Should Be ''
        $after = Read-ScopedTestXml $output
        $anchor = Get-ScopedTestCell $after 0 0
        $anchor.GetAttribute('borderFillIDRef') | Should Be '2'
        $anchor.SelectSingleNode('*[local-name()="cellSpan"]').GetAttribute('rowSpan') | Should Be '2'
        $anchor.SelectSingleNode('*[local-name()="cellSpan"]').GetAttribute('colSpan') | Should Be '2'
        $anchor.SelectSingleNode('*[local-name()="cellSz"]').GetAttribute('width') | Should Be '7000'
        $anchor.SelectSingleNode('*[local-name()="cellSz"]').GetAttribute('height') | Should Be '3000'
        $paragraphs = @($anchor.SelectNodes('*[local-name()="subList"]/*[local-name()="p"]'))
        @($paragraphs | ForEach-Object {$_.InnerText}) -join '|' | Should Be 'A|A2|B|D|E'
        $paragraphs[1].GetAttribute('paraPrIDRef') | Should Be '1'
        $paragraphs[1].GetAttribute('p','urn:scoped-test') | Should Be 'preserve'
        $paragraphs[1].FirstChild.GetAttribute('charPrIDRef') | Should Be '1'
        $after.SelectNodes('//*[local-name()="tc"]').Count | Should Be 6
        $anchor.SelectNodes('.//*[local-name()="linesegarray"]').Count | Should Be 0
        foreach ($pair in @(@(0,2),@(1,2),@(2,0),@(2,1),@(2,2))) {
            (Get-ScopedTestCell $after $pair[0] $pair[1]).OuterXml | Should Be (Get-ScopedTestCell $before $pair[0] $pair[1]).OuterXml
        }
        [Convert]::ToBase64String((Read-ScopedTestPart $output 'Contents/header.xml')) | Should Be ([Convert]::ToBase64String((Read-ScopedTestPart $source 'Contents/header.xml')))
        [Convert]::ToBase64String((Read-ScopedTestPart $output 'BinData/opaque.bin')) | Should Be 'AP8BgA0KKg=='
    }

    It 'requires explicit content order and exact row-major expected text' {
        foreach ($change in @(@{contentOrder='column-major'},@{expectedTexts=@('A','B','D','E')},@{expectedTexts=@("A`nA2",'B')},@{rowSpan=1;columnSpan=1},@{rowSpan=4},@{tableIndex=1},@{column=-1},@{row='0'})) {
            $op = $merge.Clone()
            foreach ($key in $change.Keys) {$op[$key]=$change[$key]}
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($op))
        }
        $merge.Remove('contentOrder')
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($merge))
    }

    It 'blocks overlapping occupancy, missing cells and inconsistent dimensions' {
        foreach ($mutation in @(
            @{from='rowAddr="0" colAddr="1"';to='rowAddr="0" colAddr="0"'},
            @{from='rowSpan="1" colSpan="1"';to='rowSpan="2" colSpan="2"'},
            @{from='width="3000" height="2000"';to='width="3001" height="2000"'}
        )) {
            New-ScopedTestFixture $source; Add-ScopedTestTable $source
            Update-ScopedTestSection $source {param($t) $t.Replace($mutation.from,$mutation.to)}
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($merge))
        }
    }

    It 'blocks controls, protected cells and unknown metadata that merging would discard' {
        foreach ($mutation in @(
            @{from='<hp:t>B</hp:t>';to='<hp:t>B</hp:t><hp:ctrl/>'},
            @{from='protect="0"';to='protect="1"'},
            @{from='<hp:cellMargin ';to='<u:unknown/><hp:cellMargin '},
            @{from='<hp:tc name=""';to='<hp:tc u:unknown="keep" name=""'},
            @{from='linkListIDRef="0"';to='linkListIDRef="4"'}
        )) {
            New-ScopedTestFixture $source; Add-ScopedTestTable $source
            Update-ScopedTestSection $source {param($t) $t.Replace($mutation.from,$mutation.to)}
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($merge))
        }
    }

    It 'preflights table edits with later invalid operations and blocks two edits to the same table' {
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($merge,@{type='set-run-style';sectionIndex=0;paragraphIndex=1;runIndex=0;charPrIDRef='999'}))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($merge,$merge))
    }

    It 'applies a guarded JSON plan mixing geometry, shared-style clones, original ID references and a table merge' {
        $plan=@'
{"version":"2.0","operations":[
 {"type":"set-page","sectionIndex":0,"orientation":"LANDSCAPE","margins":{"leftMm":20}},
 {"type":"replace-run-text","sectionIndex":0,"paragraphIndex":0,"runIndex":1,"expectedText":"Before","text":"After"},
 {"type":"set-run-format","sectionIndex":0,"paragraphIndex":1,"runIndex":0,"textStyle":{"bold":true}},
 {"type":"set-paragraph-format","sectionIndex":0,"paragraphIndex":1,"paragraphStyle":{"alignment":"CENTER"}},
 {"type":"set-run-style","sectionIndex":0,"paragraphIndex":2,"runIndex":0,"charPrIDRef":"1"},
 {"type":"set-paragraph-style","sectionIndex":0,"paragraphIndex":2,"paraPrIDRef":"1"},
 {"type":"merge-cells","sectionIndex":0,"tableIndex":0,"row":0,"column":0,"rowSpan":2,"columnSpan":2,"contentOrder":"row-major","expectedTexts":["A\nA2","B","D","E"]}
]}
'@ | ConvertFrom-Json
        $hash=(Get-FileHash -LiteralPath $source).Hash
        $plan | Add-Member NoteProperty sourceSha256 $hash
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        (Get-FileHash -LiteralPath $source).Hash | Should Be $hash
        $xml=Read-ScopedTestXml $output
        $xml.SelectSingleNode('/*/*[local-name()="p"][1]/*[local-name()="run"][2]/*[local-name()="t"]').InnerText | Should Be 'After'
        $xml.SelectSingleNode('/*/*[local-name()="p"][2]').GetAttribute('paraPrIDRef') | Should Be '20'
        $xml.SelectSingleNode('/*/*[local-name()="p"][2]/*[local-name()="run"][1]').GetAttribute('charPrIDRef') | Should Be '7'
        $xml.SelectSingleNode('/*/*[local-name()="p"][3]').GetAttribute('paraPrIDRef') | Should Be '1'
        $xml.SelectNodes('//*[local-name()="tc"]').Count | Should Be 6
        $xml.SelectNodes('//*[local-name()="linesegarray"]').Count | Should Be 0
    }
}

Describe 'Scoped merged-cell splitting' {
    BeforeEach {
        $caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $caseDir
        $source = Join-Path $caseDir 'source.hwpx'
        $output = Join-Path $caseDir 'copy.hwpx'
        New-ScopedTestFixture $source
        Add-ScopedTestTable $source
        Set-ScopedTestMergedFixture $source
        $split = @{type='split-cell';sectionIndex=0;tableIndex=0;row=0;column=0;expectedText="A`nA2`nB`nD`nE"}
    }

    It 'splits using neighbor dimensions, keeps all anchor paragraphs and creates empty styled cells' {
        $before=Read-ScopedTestXml $source
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan @($split))
        ($result.Errors -join '; ') | Should Be ''
        $after=Read-ScopedTestXml $output
        $anchor=Get-ScopedTestCell $after 0 0
        @($anchor.SelectNodes('*[local-name()="subList"]/*[local-name()="p"]') | ForEach-Object {$_.InnerText}) -join '|' | Should Be 'A|A2|B|D|E'
        $anchor.SelectSingleNode('*[local-name()="subList"]/*[local-name()="p"][@id="200"]').GetAttribute('p','urn:scoped-test') | Should Be 'preserve'
        $after.SelectNodes('//*[local-name()="tc"]').Count | Should Be 9
        foreach ($pair in @(@(0,0),@(0,1),@(1,0),@(1,1))) {
            $cell=Get-ScopedTestCell $after $pair[0] $pair[1]
            $cell.SelectSingleNode('*[local-name()="cellSz"]').GetAttribute('width') | Should Be ([string](3000+$pair[1]*1000))
            $cell.SelectSingleNode('*[local-name()="cellSz"]').GetAttribute('height') | Should Be ([string](1000+$pair[0]*1000))
            $cell.SelectSingleNode('*[local-name()="cellSpan"]').GetAttribute('colSpan') | Should Be '1'
            $cell.SelectSingleNode('*[local-name()="cellSpan"]').GetAttribute('rowSpan') | Should Be '1'
            $cell.SelectSingleNode('*[local-name()="cellMargin"]').OuterXml | Should Be (Get-ScopedTestCell $before 0 0).SelectSingleNode('*[local-name()="cellMargin"]').OuterXml
            $cell.GetAttribute('borderFillIDRef') | Should Be '2'
            if ($pair[0] -ne 0 -or $pair[1] -ne 0) {
                $cell.SelectSingleNode('*[local-name()="subList"]').InnerText | Should Be ''
                $cell.SelectSingleNode('.//*[local-name()="run"]').GetAttribute('charPrIDRef') | Should Be '0'
            }
        }
        foreach ($pair in @(@(0,2),@(1,2),@(2,0),@(2,1),@(2,2))) {
            (Get-ScopedTestCell $after $pair[0] $pair[1]).OuterXml | Should Be (Get-ScopedTestCell $before $pair[0] $pair[1]).OuterXml
        }
        $ids=@($after.SelectNodes('//*[local-name()="p"][@id]') | ForEach-Object {$_.GetAttribute('id')})
        @($ids | Select-Object -Unique).Count | Should Be $ids.Count
    }

    It 'rejects covered positions, unmerged targets and mismatched expected text' {
        foreach ($change in @(@{column=1},@{row=2;column=2},@{expectedText='A'},@{row=3})) {
            $op=$split.Clone(); foreach($key in $change.Keys){$op[$key]=$change[$key]}
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($op))
        }
    }

    It 'uses divisible equal tracks only when no neighbor determines a width' {
        # A single 1x2 merged row: no neighbors, exactly divisible width.
        $xml=Read-ScopedTestXml $source
        $table=$xml.SelectSingleNode('//*[local-name()="tbl"]')
        $anchor=Get-ScopedTestCell $xml 0 0
        $rows=@($table.SelectNodes('*[local-name()="tr"]'))
        foreach($row in $rows | Select-Object -Skip 1){$null=$table.RemoveChild($row)}
        foreach($cell in @($rows[0].SelectNodes('*[local-name()="tc"]')) | Select-Object -Skip 1){$null=$rows[0].RemoveChild($cell)}
        $table.SetAttribute('rowCnt','1'); $table.SetAttribute('colCnt','2')
        $anchor.SelectSingleNode('*[local-name()="cellSpan"]').SetAttribute('rowSpan','1')
        $anchor.SelectSingleNode('*[local-name()="cellSz"]').SetAttribute('width','7000')
        Set-ScopedTestPart $source 'Contents/section0.xml' ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml))
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan @($split))
        ($result.Errors -join '; ') | Should Be ''
        (Get-ScopedTestCell (Read-ScopedTestXml $output) 0 1).SelectSingleNode('*[local-name()="cellSz"]').GetAttribute('width') | Should Be '3500'
        Update-ScopedTestSection $source {param($t) $t.Replace('width="7000"','width="7001"')}
        Assert-ScopedTestBlocked $source (Join-Path $caseDir 'blocked.hwpx') (New-ScopedTestPlan @($split))
    }

    It 'blocks controls and unknown cell metadata during splitting' {
        Update-ScopedTestSection $source {param($t) $t.Replace('<hp:t>A</hp:t>','<hp:t>A<hp:tab/></hp:t>')}
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($split))
    }

    It 'does not restore stale table caches when a page edit precedes a structural edit' {
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan @(@{type='set-page';sectionIndex=0;orientation='LANDSCAPE'},$split))
        ($result.Errors -join '; ') | Should Be ''
        (Read-ScopedTestXml $output).SelectNodes('//*[local-name()="linesegarray"]').Count | Should Be 0
    }

    It 'rejects split tracks that would force a neighboring merged region to nonpositive width' {
        $xml=Read-ScopedTestXml $source
        $original=$xml.SelectSingleNode('//*[local-name()="tbl"]')
        $table=$original.CloneNode($false)
        $table.SetAttribute('rowCnt','2'); $table.SetAttribute('colCnt','4')
        $cells=@((Get-ScopedTestCell $xml 0 0),(Get-ScopedTestCell $xml 0 2),(Get-ScopedTestCell $xml 1 2),(Get-ScopedTestCell $xml 2 2))
        $settings=@(@(0,0,2,7000),@(0,2,2,1000),@(1,0,1,5000),@(1,1,3,1000))
        for($r=0;$r -lt 2;$r++) {
            $tr=$xml.CreateElement('hp','tr','http://www.hancom.co.kr/hwpml/2011/paragraph')
            for($n=$r*2;$n -lt $r*2+2;$n++) {
                $cell=$cells[$n].CloneNode($true); $setting=$settings[$n]
                $addr=$cell.SelectSingleNode('*[local-name()="cellAddr"]'); $addr.SetAttribute('rowAddr',[string]$setting[0]); $addr.SetAttribute('colAddr',[string]$setting[1])
                $span=$cell.SelectSingleNode('*[local-name()="cellSpan"]'); $span.SetAttribute('rowSpan','1'); $span.SetAttribute('colSpan',[string]$setting[2])
                $size=$cell.SelectSingleNode('*[local-name()="cellSz"]'); $size.SetAttribute('width',[string]$setting[3]); $size.SetAttribute('height','1000')
                $null=$tr.AppendChild($cell)
            }
            $null=$table.AppendChild($tr)
        }
        $null=$original.ParentNode.ReplaceChild($table,$original)
        Set-ScopedTestPart $source 'Contents/section0.xml' ([Text.Encoding]::UTF8.GetBytes($xml.OuterXml))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @($split))
    }
}

Describe 'Scoped cloned character and paragraph formatting' {
    BeforeEach {
        $caseDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $caseDir
        $source = Join-Path $caseDir 'source.hwpx'
        $output = Join-Path $caseDir 'copy.hwpx'
        New-ScopedTestFixture $source
        $header=Read-ScopedTestXml $source 'Contents/header.xml'
        foreach($kind in @('charPr','paraPr')) {
            $resource=$header.SelectSingleNode(('//*[local-name()="{0}" and @id="0"]' -f $kind))
            $resource.SetAttribute('vendor','urn:scoped-style','preserve') | Out-Null
            $unknown=$header.CreateElement('u','future','urn:scoped-style')
            $unknown.InnerText='opaque extension'
            $null=$resource.AppendChild($unknown)
        }
        Set-ScopedTestPart $source 'Contents/header.xml' ([Text.Encoding]::UTF8.GetBytes($header.OuterXml))
    }

    It 'clones each referenced charPr to a unique ID and changes only explicit character properties' {
        $before=Read-ScopedTestXml $source 'Contents/header.xml'
        $plan=New-ScopedTestPlan @(
            @{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=0;textStyle=@{fontSizePt=12.5;bold=$true;italic=$true;textColor='#123ABC';underline='BOTTOM'}},
            @{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=1;textStyle=@{fontSizePt=14}}
        )
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        ($result.Data.ChangedParts -contains 'Contents/header.xml') | Should Be $true
        $after=Read-ScopedTestXml $output 'Contents/header.xml'
        $original=$after.SelectSingleNode('//*[local-name()="charPr" and @id="0"]')
        $original.OuterXml | Should Be $before.SelectSingleNode('//*[local-name()="charPr" and @id="0"]').OuterXml
        $clone=$after.SelectSingleNode('//*[local-name()="charPr" and @id="7"]')
        $clone.GetAttribute('height') | Should Be '1250'
        $clone.GetAttribute('textColor') | Should Be '#123ABC'
        $clone.SelectNodes('*[local-name()="bold"]').Count | Should Be 1
        $clone.SelectNodes('*[local-name()="italic"]').Count | Should Be 1
        $clone.SelectSingleNode('*[local-name()="underline"]').GetAttribute('type') | Should Be 'BOTTOM'
        $clone.GetAttribute('vendor','urn:scoped-style') | Should Be 'preserve'
        $clone.SelectSingleNode('*[local-name()="future"]').OuterXml | Should Be $original.SelectSingleNode('*[local-name()="future"]').OuterXml
        $clone.SelectSingleNode('*[local-name()="fontRef"]').OuterXml | Should Be $original.SelectSingleNode('*[local-name()="fontRef"]').OuterXml
        $after.SelectSingleNode('//*[local-name()="charProperties"]').GetAttribute('itemCnt') | Should Be '9'
        $xml=Read-ScopedTestXml $output
        $runs=$xml.SelectNodes('/*/*[local-name()="p"][2]/*[local-name()="run"]')
        $runs[0].GetAttribute('charPrIDRef') | Should Be '7'
        $runs[1].GetAttribute('charPrIDRef') | Should Be '8'
        $xml.SelectSingleNode('/*/*[local-name()="p"][3]/*[local-name()="run"]').GetAttribute('charPrIDRef') | Should Be '0'
    }

    It 'clones paraPr and updates both canonical switch branches without losing extensions' {
        $before=Read-ScopedTestXml $source 'Contents/header.xml'
        $style=@{alignment='CENTER';lineSpacingPercent=220;leftMarginMm=10;rightMarginMm=5;indentMm=-3;marginBeforeMm=2;marginAfterMm=4;keepWithNext=$true;keepLines=$true;pageBreakBefore=$true}
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan @(@{type='set-paragraph-format';sectionIndex=0;paragraphIndex=1;paragraphStyle=$style}))
        ($result.Errors -join '; ') | Should Be ''
        $after=Read-ScopedTestXml $output 'Contents/header.xml'
        $after.SelectSingleNode('//*[local-name()="paraPr" and @id="0"]').OuterXml | Should Be $before.SelectSingleNode('//*[local-name()="paraPr" and @id="0"]').OuterXml
        $clone=$after.SelectSingleNode('//*[local-name()="paraPr" and @id="20"]')
        $clone.SelectSingleNode('*[local-name()="align"]').GetAttribute('horizontal') | Should Be 'CENTER'
        $clone.SelectNodes('.//*[local-name()="lineSpacing"]').Count | Should Be 2
        foreach($line in $clone.SelectNodes('.//*[local-name()="lineSpacing"]')) {$line.GetAttribute('value') | Should Be '220'; $line.GetAttribute('type') | Should Be 'PERCENT'}
        foreach($expected in @(
            @{branch='case';left='2835';right='1417';intent='-850';prev='567';next='1134'},
            @{branch='default';left='5670';right='2834';intent='-1700';prev='1134';next='2268'}
        )) {
            $margin=$clone.SelectSingleNode('.//*[local-name()="'+$expected.branch+'"]/*[local-name()="margin"]')
            foreach($name in @('left','right','intent','prev','next')) {
                $margin.SelectSingleNode('*[local-name()="'+$name+'"]').GetAttribute('value') | Should Be $expected[$name]
            }
        }
        foreach($name in @('keepWithNext','keepLines','pageBreakBefore')) {$clone.SelectSingleNode('*[local-name()="breakSetting"]').GetAttribute($name) | Should Be '1'}
        $clone.GetAttribute('vendor','urn:scoped-style') | Should Be 'preserve'
        $after.SelectSingleNode('//*[local-name()="paraProperties"]').GetAttribute('itemCnt') | Should Be '21'
        (Read-ScopedTestXml $output).SelectSingleNode('/*/*[local-name()="p"][2]').GetAttribute('paraPrIDRef') | Should Be '20'
    }

    It 'supports explicit false without removing the original shared bold resource' {
        $header=Read-ScopedTestXml $source 'Contents/header.xml'
        $resource=$header.SelectSingleNode('//*[local-name()="charPr" and @id="0"]')
        $underline=$resource.SelectSingleNode('*[local-name()="underline"]')
        foreach($name in @('italic','bold')) {$null=$resource.InsertBefore($header.CreateElement('hh',$name,'http://www.hancom.co.kr/hwpml/2011/head'),$underline)}
        Set-ScopedTestPart $source 'Contents/header.xml' ([Text.Encoding]::UTF8.GetBytes($header.OuterXml))
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan (New-ScopedTestPlan @(@{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=0;textStyle=@{bold=$false;italic=$false}}))
        ($result.Errors -join '; ') | Should Be ''
        $after=Read-ScopedTestXml $output 'Contents/header.xml'
        $after.SelectSingleNode('//*[local-name()="charPr" and @id="7"]').SelectNodes('*[local-name()="bold" or local-name()="italic"]').Count | Should Be 0
        $after.SelectSingleNode('//*[local-name()="charPr" and @id="0"]').SelectNodes('*[local-name()="bold" or local-name()="italic"]').Count | Should Be 2
    }

    It 'keeps italic then bold then underline across key orders and preexisting flags' {
        $cases=@(
            @{existing=@();json='{"bold":true,"italic":true,"underline":"BOTTOM"}';want='italic,bold,underline'},
            @{existing=@();json='{"underline":"BOTTOM","italic":true,"bold":true}';want='italic,bold,underline'},
            @{existing=@('italic');json='{"bold":true,"underline":"BOTTOM"}';want='italic,bold,underline'},
            @{existing=@('bold');json='{"italic":true,"underline":"BOTTOM"}';want='italic,bold,underline'},
            @{existing=@('italic','bold');json='{"underline":"TOP"}';want='italic,bold,underline'},
            @{existing=@('italic','bold');json='{"bold":false,"italic":true}';want='italic,underline'},
            @{existing=@('italic','bold');json='{"italic":false,"bold":true}';want='bold,underline'},
            @{existing=@('italic','bold');json='{"italic":false,"bold":false}';want='underline'}
        )
        for($n=0;$n -lt $cases.Count;$n++) {
            New-ScopedTestFixture $source
            $header=Read-ScopedTestXml $source 'Contents/header.xml'
            $resource=$header.SelectSingleNode('//*[local-name()="charPr" and @id="0"]')
            $underline=$resource.SelectSingleNode('*[local-name()="underline"]')
            foreach($name in $cases[$n].existing) {$null=$resource.InsertBefore($header.CreateElement('hh',$name,'http://www.hancom.co.kr/hwpml/2011/head'),$underline)}
            $original=$resource.OuterXml
            Set-ScopedTestPart $source 'Contents/header.xml' ([Text.Encoding]::UTF8.GetBytes($header.OuterXml))
            $style=$cases[$n].json | ConvertFrom-Json
            $destination=Join-Path $caseDir ("order-$n.hwpx")
            $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $destination -Plan (New-ScopedTestPlan @(@{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=0;textStyle=$style}))
            ($result.Errors -join '; ') | Should Be ''
            $after=Read-ScopedTestXml $destination 'Contents/header.xml'
            $clone=$after.SelectSingleNode('//*[local-name()="charPr" and @id="7"]')
            $actual=@($clone.ChildNodes | Where-Object {$_.NamespaceURI -eq 'http://www.hancom.co.kr/hwpml/2011/head' -and $_.LocalName -in @('italic','bold','underline')} | ForEach-Object {$_.LocalName}) -join ','
            $actual | Should Be $cases[$n].want
            $after.SelectSingleNode('//*[local-name()="charPr" and @id="0"]').OuterXml | Should Be $original
        }
    }

    It 'rejects unsupported or malformed formatting and conflicting reference edits' {
        foreach($style in @(@{},@{fontFamily='Arial'},@{bold='false'},@{fontSizePt=0},@{fontSizePt=[double]::Infinity},@{textColor='red'},@{underline='DOUBLE'})) {
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(@{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=0;textStyle=$style}))
        }
        foreach($style in @(@{},@{alignment='diagonal'},@{lineSpacingPercent=0},@{lineSpacingPercent=120.5},@{leftMarginMm=-1},@{keepLines='true'},@{unsupported=1})) {
            Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(@{type='set-paragraph-format';sectionIndex=0;paragraphIndex=1;paragraphStyle=$style}))
        }
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(@{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=0;textStyle=@{bold=$true}},@{type='set-run-style';sectionIndex=0;paragraphIndex=1;runIndex=0;charPrIDRef='1'}))
    }

    It 'rejects missing or duplicate original resources before cloning' {
        Update-ScopedTestSection $source {param($t) $t.Replace('charPrIDRef="0"','charPrIDRef="999"')}
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(@{type='set-run-format';sectionIndex=0;paragraphIndex=1;runIndex=0;textStyle=@{bold=$true}}))
        New-ScopedTestFixture $source
        $header=[Text.Encoding]::UTF8.GetString((Read-ScopedTestPart $source 'Contents/header.xml')).Replace('<hh:paraPr id="1"','<hh:paraPr id="0"')
        Set-ScopedTestPart $source 'Contents/header.xml' ([Text.Encoding]::UTF8.GetBytes($header))
        Assert-ScopedTestBlocked $source $output (New-ScopedTestPlan @(@{type='set-paragraph-format';sectionIndex=0;paragraphIndex=1;paragraphStyle=@{alignment='CENTER'}}))
    }
}
