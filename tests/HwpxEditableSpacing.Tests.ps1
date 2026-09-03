# Exercise the published recipes and real ZIP output, not matching instruction prose.
$editableSkillRoot = if ($env:HWP_EDITABLE_SPACING_SKILL_ROOT) { $env:HWP_EDITABLE_SPACING_SKILL_ROOT } else { Join-Path $PSScriptRoot '../skills/hwp-skill' }
Import-Module (Join-Path $editableSkillRoot 'scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $editableSkillRoot 'scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-EditableSpacingXml {
    param([string]$Path, [string]$Part)
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry($Part).Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function Get-EditableSpacingParagraphs {
    param([string]$Path)
    $section=Read-EditableSpacingXml $Path 'Contents/section0.xml'
    $header=Read-EditableSpacingXml $Path 'Contents/header.xml'
    $records=@(foreach ($p in $section.SelectNodes("/*/*[local-name()='p']")) {
        $run=$p.SelectSingleNode("*[local-name()='run'][*[local-name()='t']]")
        if ($null -eq $run -or $p.SelectNodes(".//*[local-name()='tbl' or local-name()='pic']").Count) { continue }
        [pscustomobject]@{
            Node=$p
            Text=(@($p.SelectNodes("*[local-name()='run']/*[local-name()='t']") | ForEach-Object { $_.InnerText }) -join '')
            FontSize=[int]$header.SelectSingleNode("//*[local-name()='charPr' and @id='$($run.GetAttribute('charPrIDRef'))']").GetAttribute('height')
            ParagraphStyle=$header.SelectSingleNode("//*[local-name()='paraPr' and @id='$($p.GetAttribute('paraPrIDRef'))']")
        }
    })
    # Only inspect gaps between actual content; section anchors/trailing caret paragraphs are not a report gap.
    $first=-1; $last=-1
    for ($i=0; $i -lt $records.Count; $i++) {
        if ($records[$i].Text.Length) { if ($first -lt 0) { $first=$i }; $last=$i }
    }
    if ($first -ge 0) { $records[$first..$last] }
}

function Write-EditableSpacingFixture {
    param([object]$Plan,[string]$Path)
    $result=Invoke-HwpGenerate -NewDocument -Plan $Plan -OutputPath $Path
    ($result.Errors -join '; ') | Should Be ''
    $result.Status | Should Be 'PASS_WITH_WARNINGS'
}

function Assert-EditableSpacingDefaults {
    param([object[]]$Paragraphs)
    foreach ($p in $Paragraphs) {
        foreach ($margin in $p.ParagraphStyle.SelectNodes(".//*[local-name()='prev' or local-name()='next']")) {
            $margin.GetAttribute('value') | Should Be '0'
        }
        foreach ($line in $p.ParagraphStyle.SelectNodes(".//*[local-name()='lineSpacing']")) {
            $line.GetAttribute('type') | Should Be 'PERCENT'
            $line.GetAttribute('value') | Should Be '160'
        }
    }
}

Describe 'Editable report spacing with real blank paragraphs' {
    It 'generates the first authoring recipe with an editable empty paragraph between title and body' {
        $guide=Get-Content -LiteralPath (Join-Path $editableSkillRoot 'references/authoring.md') -Raw -Encoding UTF8
        $plan=[regex]::Match($guide,'(?s)```json\s*(.*?)\s*```').Groups[1].Value | ConvertFrom-Json
        $path=Join-Path $TestDrive 'editable-guide.hwpx'
        Write-EditableSpacingFixture $plan $path
        $paragraphs=@(Get-EditableSpacingParagraphs $path)
        $blanks=@($paragraphs | Where-Object { $_.Text -eq '' })
        ($blanks.Count -ge 1) | Should Be $true
        $paragraphs[0].Text | Should Be '업무 보고서'
        $paragraphs[1].Text | Should Be ''
        $paragraphs[1].FontSize | Should Be 600
        $paragraphs[2].Text | Should Be '업무 보고서 본문'
        $paragraphs[2].FontSize | Should Be 1100
        Assert-EditableSpacingDefaults $paragraphs
        $blanks[0].Node.SelectNodes(".//*[local-name()='lineBreak' or local-name()='tbl' or local-name()='pic']").Count | Should Be 0
    }

    It 'keeps the legacy report example uniformly spaced with an editable gap instead of title margins' {
        $plan=Get-Content -LiteralPath (Join-Path $editableSkillRoot 'examples/generate-new.plan.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $path=Join-Path $TestDrive 'editable-legacy.hwpx'
        Write-EditableSpacingFixture $plan $path
        $paragraphs=@(Get-EditableSpacingParagraphs $path)
        Assert-EditableSpacingDefaults $paragraphs
        $paragraphs[0].Text | Should Be '업무 보고서'
        $paragraphs[0].FontSize | Should Be 1800
        $paragraphs[1].Text | Should Be ''
        $paragraphs[1].FontSize | Should Be 900
        $paragraphs[2].FontSize | Should Be 1000
    }

    foreach ($version in @('1.0','2.0')) {
        It "preserves separately sized blank paragraphs and body font for plan $version" {
            $plan=@{version=$version;document=@{textStyle=@{fontSizePt=11};paragraphStyle=@{lineSpacingPercent=160;marginBeforeMm=0;marginAfterMm=0}};content=@(
                @{type='paragraph';text='본문 A'},
                @{type='paragraph';text='';textStyle=@{fontSizePt=6}},
                @{type='paragraph';text='본문 B'},
                @{type='paragraph';text='';textStyle=@{fontSizePt=9}},
                @{type='paragraph';text='본문 C'}
            )} | ConvertTo-Json -Depth 15 | ConvertFrom-Json
            $path=Join-Path $TestDrive ('editable-'+$version+'.hwpx')
            Write-EditableSpacingFixture $plan $path
            $paragraphs=@(Get-EditableSpacingParagraphs $path)
            $paragraphs.Count | Should Be 5
            ($paragraphs.Text -join '|') | Should Be '본문 A||본문 B||본문 C'
            ($paragraphs.FontSize -join ',') | Should Be '1100,600,1100,900,1100'
            Assert-EditableSpacingDefaults $paragraphs
            (Read-EditableSpacingXml $path 'Contents/section0.xml').SelectNodes("//*[local-name()='linesegarray']").Count | Should Be 0
        }
    }

    It 'changes only a blank paragraph font while preserving body formatting and original bytes' {
        $plan=@{version='2.0';document=@{textStyle=@{fontSizePt=11};paragraphStyle=@{lineSpacingPercent=160;marginBeforeMm=0;marginAfterMm=0}};content=@(
            @{type='paragraph';text='본문 A'},@{type='paragraph';text='';textStyle=@{fontSizePt=6}},@{type='paragraph';text='본문 B'}
        )} | ConvertTo-Json -Depth 15 | ConvertFrom-Json
        $source=Join-Path $TestDrive 'editable-source.hwpx'
        $output=Join-Path $TestDrive 'editable-changed.hwpx'
        Write-EditableSpacingFixture $plan $source
        $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $before=@(Get-EditableSpacingParagraphs $source)
        $blankIndex=[array]::IndexOf(@($before[1].Node.ParentNode.SelectNodes("*[local-name()='p']")), $before[1].Node)
        ($blankIndex -ge 0) | Should Be $true
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{
            version='2.0';sourceSha256=$hash;operations=@(@{type='set-run-format';sectionIndex=0;paragraphIndex=$blankIndex;runIndex=0;textStyle=@{fontSizePt=12}})
        }
        ($result.Errors -join '; ') | Should Be ''
        $after=@(Get-EditableSpacingParagraphs $output)
        ($after.FontSize -join ',') | Should Be '1100,1200,1100'
        $after[1].Text | Should Be ''
        foreach ($index in @(0,2)) { $after[$index].Node.OuterXml | Should Be $before[$index].Node.OuterXml }
        Assert-EditableSpacingDefaults $after
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash | Should Be $hash
    }
}
