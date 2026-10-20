Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force

function Read-NumberingReuseXml($Path, $Part) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry($Part).Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function New-NumberingReusePackage($Plan, $Path) {
    # Exercise the public validation and promotion path, not a pre-normalized plan.
    ($Plan.PSObject.Properties.Name -contains 'sourceVersion') | Should Be $false
    (Test-HwpNewDocumentPlan -Plan $Plan).Status | Should Be 'PASS'
    $result = Invoke-HwpGenerate -NewDocument -Plan $Plan -OutputPath $Path
    $result.Status | Should Be 'PASS_WITH_WARNINGS'
    $result.StructuralVerification.Status | Should Be 'PASS'
    $result.StructuralVerification.NativeLayoutVerified | Should Be $false
    Read-NumberingReuseXml $Path 'Contents/header.xml'
}

function Get-NumberingReuseParagraph($Header, $Section, $Text) {
    $paragraph = @($Section.SelectNodes("//*[local-name()='p']") | Where-Object {
        (@($_.SelectNodes("./*[local-name()='run']/*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join '') -ceq $Text
    })
    $paragraph.Count | Should Be 1
    $id = $paragraph[0].GetAttribute('paraPrIDRef')
    $shape = $Header.SelectSingleNode("//*[local-name()='paraPr' and @id='$id']")
    [pscustomobject]@{
        Paragraph = $paragraph[0]
        Shape = $shape
        Heading = $shape.SelectSingleNode("*[local-name()='heading']")
    }
}

Describe 'Generated HWPX numbering resource reuse' {
    It 'shares a numbering ID when only paragraph layout changes' {
        $plan = @'
{"version":"2.0","content":[
 {"type":"paragraph","text":"first","paragraphStyle":{"list":{"type":"NUMBER","level":1,"start":3}}},
 {"type":"paragraph","text":"second","paragraphStyle":{"keepWithNext":true,"keepLines":true,"alignment":"LEFT","list":{"type":"NUMBER","level":1,"start":3}}}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'paragraph-layout.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $section = Read-NumberingReuseXml $path 'Contents/section0.xml'
        $first = Get-NumberingReuseParagraph $header $section 'first'
        $second = Get-NumberingReuseParagraph $header $section 'second'

        $second.Paragraph.GetAttribute('paraPrIDRef') | Should Not Be $first.Paragraph.GetAttribute('paraPrIDRef')
        $second.Shape.SelectSingleNode("*[local-name()='breakSetting']").GetAttribute('keepWithNext') | Should Be '1'
        $second.Shape.SelectSingleNode("*[local-name()='align']").GetAttribute('horizontal') | Should Be 'LEFT'
        $second.Heading.GetAttribute('idRef') | Should Be $first.Heading.GetAttribute('idRef')
        $id = $first.Heading.GetAttribute('idRef')
        $numbering = $header.SelectSingleNode("//*[local-name()='numbering' and @id='$id']")
        $numbering.GetAttribute('start') | Should Be '3'
        @($numbering.SelectNodes("*[local-name()='paraHead' and @numFormat='DIGIT' and @start='3']")).Count | Should Be 7
    }

    It 'shares equivalent defaulted definitions regardless of property order' {
        $plan = @'
{"version":"2.0","content":[
 {"type":"paragraph","text":"implicit","paragraphStyle":{"list":{"type":"NUMBER"}}},
 {"type":"paragraph","text":"explicit","paragraphStyle":{"marginAfterMm":2,"list":{"start":1,"level":1,"type":"NUMBER"}}}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'defaulted.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $section = Read-NumberingReuseXml $path 'Contents/section0.xml'
        $a = Get-NumberingReuseParagraph $header $section 'implicit'
        $b = Get-NumberingReuseParagraph $header $section 'explicit'
        $b.Heading.GetAttribute('idRef') | Should Be $a.Heading.GetAttribute('idRef')
        $id = $a.Heading.GetAttribute('idRef')
        $header.SelectSingleNode("//*[local-name()='numbering' and @id='$id']").GetAttribute('start') | Should Be '1'
    }

    It 'reuses numbering across sections and styled cell paragraphs' {
        $plan = @'
{"version":"2.0","sections":[
 {"content":[{"type":"paragraph","text":"body","paragraphStyle":{"list":{"type":"NUMBER","level":1,"start":4}}}]},
 {"document":{"page":{"orientation":"LANDSCAPE"}},"content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"paragraphs":[{"type":"paragraph","text":"cell","paragraphStyle":{"keepWithNext":true,"list":{"start":4,"type":"NUMBER","level":1}}}]}]}]}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'sections-cell.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $body = Get-NumberingReuseParagraph $header (Read-NumberingReuseXml $path 'Contents/section0.xml') 'body'
        $cell = Get-NumberingReuseParagraph $header (Read-NumberingReuseXml $path 'Contents/section1.xml') 'cell'
        $cell.Heading.GetAttribute('idRef') | Should Be $body.Heading.GetAttribute('idRef')
        $header.DocumentElement.GetAttribute('secCnt') | Should Be '2'
        $cell.Shape.SelectSingleNode("*[local-name()='breakSetting']").GetAttribute('keepWithNext') | Should Be '1'
    }

    It 'keeps different starts in separate real numbering definitions' {
        $plan = @'
{"version":"2.0","content":[
 {"type":"paragraph","text":"one","paragraphStyle":{"list":{"type":"NUMBER","start":1}}},
 {"type":"paragraph","text":"seven","paragraphStyle":{"list":{"type":"NUMBER","start":7}}}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'starts.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $section = Read-NumberingReuseXml $path 'Contents/section0.xml'
        $one = Get-NumberingReuseParagraph $header $section 'one'
        $seven = Get-NumberingReuseParagraph $header $section 'seven'
        $seven.Heading.GetAttribute('idRef') | Should Not Be $one.Heading.GetAttribute('idRef')
        foreach ($pair in @(@($one, '1'), @($seven, '7'))) {
            $id = $pair[0].Heading.GetAttribute('idRef')
            $node = $header.SelectSingleNode("//*[local-name()='numbering' and @id='$id']")
            $node.GetAttribute('start') | Should Be $pair[1]
            @($node.SelectNodes("*[local-name()='paraHead' and @numFormat='DIGIT' and @start='$($pair[1])']")).Count | Should Be 7
        }
    }

    It 'keeps NUMBER and OUTLINE types and levels distinct' {
        $plan = @'
{"version":"2.0","content":[
 {"type":"paragraph","text":"number","paragraphStyle":{"list":{"type":"NUMBER","level":1}}},
 {"type":"paragraph","text":"outline","paragraphStyle":{"list":{"type":"OUTLINE","level":1}}},
 {"type":"paragraph","text":"level-two","paragraphStyle":{"list":{"type":"OUTLINE","level":2}}}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'kinds.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $section = Read-NumberingReuseXml $path 'Contents/section0.xml'
        $number = Get-NumberingReuseParagraph $header $section 'number'
        $outline = Get-NumberingReuseParagraph $header $section 'outline'
        $level = Get-NumberingReuseParagraph $header $section 'level-two'
        $number.Heading.GetAttribute('type') | Should Be 'NUMBER'
        $outline.Heading.GetAttribute('type') | Should Be 'OUTLINE'
        $level.Heading.GetAttribute('level') | Should Be '1'
        @(@($number, $outline, $level) | ForEach-Object { $_.Heading.GetAttribute('idRef') } | Select-Object -Unique).Count | Should Be 3
    }

    It 'shares equivalent bullets while retaining different bullet characters' {
        $plan = @'
{"version":"2.0","content":[
 {"type":"paragraph","text":"bullet-default","paragraphStyle":{"list":{"type":"BULLET"}}},
 {"type":"paragraph","text":"bullet-explicit","paragraphStyle":{"keepWithNext":true,"list":{"character":"\u2022","level":1,"type":"BULLET"}}},
 {"type":"paragraph","text":"bullet-square","paragraphStyle":{"list":{"type":"BULLET","character":"\u25a0"}}}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'bullets.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $section = Read-NumberingReuseXml $path 'Contents/section0.xml'
        $a = Get-NumberingReuseParagraph $header $section 'bullet-default'
        $b = Get-NumberingReuseParagraph $header $section 'bullet-explicit'
        $c = Get-NumberingReuseParagraph $header $section 'bullet-square'
        $b.Heading.GetAttribute('idRef') | Should Be $a.Heading.GetAttribute('idRef')
        $c.Heading.GetAttribute('idRef') | Should Not Be $a.Heading.GetAttribute('idRef')
        $id = $a.Heading.GetAttribute('idRef')
        $header.SelectSingleNode("//*[local-name()='bullet' and @id='$id']").GetAttribute('char') | Should Be ([string][char]0x2022)
        $id = $c.Heading.GetAttribute('idRef')
        $header.SelectSingleNode("//*[local-name()='bullet' and @id='$id']").GetAttribute('char') | Should Be ([string][char]0x25a0)
    }

    It 'preserves existing template resources and unrelated run and tab formatting' {
        $plan = @'
{"version":"2.0","document":{"textStyle":{"bold":true}},"content":[
 {"type":"paragraph","text":"listed","paragraphStyle":{"list":{"type":"NUMBER","start":5}}},
 {"type":"paragraph","runs":[{"text":"plain","textStyle":{"bold":false,"textColor":"#123456"}}],"paragraphStyle":{"tabs":[{"positionMm":25,"alignment":"RIGHT","leader":"DOT"}]}}
]}
'@ | ConvertFrom-Json
        $path = Join-Path $TestDrive 'preserved.hwpx'
        $header = New-NumberingReusePackage $plan $path
        $template = Read-NumberingReuseXml (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') 'Contents/header.xml'
        foreach ($node in $template.SelectNodes("//*[local-name()='refList']/*/*[@id]")) {
            $kind = $node.LocalName
            $id = $node.GetAttribute('id')
            $header.SelectSingleNode("//*[local-name()='refList']/*/*[local-name()='$kind' and @id='$id']").OuterXml | Should BeExactly $node.OuterXml
        }
        $section = Read-NumberingReuseXml $path 'Contents/section0.xml'
        $plain = Get-NumberingReuseParagraph $header $section 'plain'
        $charId = $plain.Paragraph.SelectSingleNode("*[local-name()='run']").GetAttribute('charPrIDRef')
        $char = $header.SelectSingleNode("//*[local-name()='charPr' and @id='$charId']")
        $char.SelectSingleNode("*[local-name()='bold']") | Should BeNullOrEmpty
        $char.GetAttribute('textColor') | Should Be '#123456'
        $tabId = $plain.Shape.GetAttribute('tabPrIDRef')
        $tab = $header.SelectSingleNode("//*[local-name()='tabPr' and @id='$tabId']/*[local-name()='tabItem']")
        $tab.GetAttribute('type') | Should Be 'RIGHT'
        $tab.GetAttribute('leader') | Should Be 'DOT'
        @($section.SelectNodes("//*[local-name()='linesegarray']")).Count | Should Be 0
        foreach ($collection in $header.SelectNodes("//*[local-name()='refList']/*[@itemCnt]")) {
            [int]$collection.GetAttribute('itemCnt') | Should Be @($collection.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element }).Count
        }
    }

    It 'rejects unsupported numFormat before writing an output' {
        $plan = '{"version":"2.0","content":[{"type":"paragraph","text":"invalid","paragraphStyle":{"list":{"type":"NUMBER","numFormat":"ROMAN_CAPITAL"}}}]}' | ConvertFrom-Json
        $path = Join-Path $TestDrive 'unsupported.hwpx'
        (Test-HwpNewDocumentPlan -Plan $plan).Status | Should Be 'BLOCKED'
        (Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $path).Status | Should Be 'BLOCKED'
        Test-Path -LiteralPath $path | Should Be $false
    }
}
