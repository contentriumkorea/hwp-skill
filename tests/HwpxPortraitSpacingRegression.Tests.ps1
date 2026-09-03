# Expectations come from the Hancom-authored bundled template, not writer helpers.
$regressionLib = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib'
Import-Module (Join-Path $regressionLib 'HwpGenerate.psm1') -Force
Import-Module (Join-Path $regressionLib 'HwpInspect.psm1') -Force
Import-Module (Join-Path $regressionLib 'HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $regressionLib 'HwpAuthoringVerify.psm1') -Force
Import-Module (Join-Path $regressionLib 'HwpAuthoringPlan.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-PortraitSpacingPart {
    param([string]$Path, [string]$Part='Contents/section0.xml')
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry($Part).Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function New-PortraitSpacingDocument {
    param([string]$Path, [string]$Version='2.0', [object]$ParagraphStyle=$null, [string]$Orientation='')
    $plan=[pscustomobject]@{version=$Version;document=[pscustomobject]@{};content=@(
        [pscustomobject]@{type='paragraph';text="First line`nSecond line"}
    )}
    if ($null -ne $ParagraphStyle) { $plan.document | Add-Member NoteProperty paragraphStyle $ParagraphStyle }
    if ($Orientation) { $plan.document | Add-Member NoteProperty page ([pscustomobject]@{orientation=$Orientation}) }
    $result=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $Path
    ($result.Errors -join '; ') | Should Be ''
    $result.Status | Should Be 'PASS_WITH_WARNINGS'
    return $result
}

function Get-PortraitSpacingStyle {
    param([string]$Path)
    $section=Read-PortraitSpacingPart $Path
    $paragraph=$section.SelectSingleNode("/*/*[local-name()='p'][.//*[local-name()='t' and contains(.,'First line')]]")
    $header=Read-PortraitSpacingPart $Path 'Contents/header.xml'
    return ,$header.SelectSingleNode("//*[local-name()='paraPr' and @id='$($paragraph.GetAttribute('paraPrIDRef'))']")
}

function Edit-PortraitSpacingTestPart {
    param([string]$Path, [string]$Part, [scriptblock]$Change)
    $doc=Read-PortraitSpacingPart $Path $Part
    & $Change $doc | Out-Null
    $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $zip.GetEntry($Part).Delete()
        $writer=[IO.StreamWriter]::new($zip.CreateEntry($Part).Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write($doc.OuterXml) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}

Describe 'Native-authored portrait and paragraph-unit regressions' {
    It 'reads the untouched Hancom portrait template as portrait' {
        $template=Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx'
        $xml=Read-PortraitSpacingPart $template
        $page=$xml.SelectSingleNode("//*[local-name()='pagePr']")
        $page.GetAttribute('landscape') | Should Be 'WIDELY'
        # Saved line width 51024 is the portrait paper width minus left/right margins.
        $line=$xml.SelectSingleNode("//*[local-name()='lineseg']")
        $line.GetAttribute('horzsize') | Should Be '51024'
        $read=Get-HwpInspection -LiteralPath $template
        $read.Sections[0].PageDefinitions[0].Orientation | Should Be 'PORTRAIT'
    }

    foreach ($version in @('1.0','2.0')) {
        It "writes default portrait for plan $version using WIDELY" {
            $path=Join-Path $TestDrive ('default-'+$version+'.hwpx')
            $null=New-PortraitSpacingDocument $path $version
            (Read-PortraitSpacingPart $path).SelectSingleNode("//*[local-name()='pagePr']").GetAttribute('landscape') | Should Be 'WIDELY'
        }
        It "writes explicit landscape for plan $version using NARROWLY" {
            $path=Join-Path $TestDrive ('landscape-'+$version+'.hwpx')
            $null=New-PortraitSpacingDocument $path $version -Orientation LANDSCAPE
            $page=(Read-PortraitSpacingPart $path).SelectSingleNode("//*[local-name()='pagePr']")
            $page.GetAttribute('landscape') | Should Be 'NARROWLY'
            $page.GetAttribute('width') | Should Be '59528'
            $page.GetAttribute('height') | Should Be '84189'
        }
        It "does not invent fixed 10pt 160-percent line-cache geometry for plan $version" {
            $path=Join-Path $TestDrive ('cache-'+$version+'.hwpx')
            $null=New-PortraitSpacingDocument $path $version -ParagraphStyle ([pscustomobject]@{lineSpacingPercent=180})
            (Read-PortraitSpacingPart $path).SelectNodes("//*[local-name()='linesegarray']").Count | Should Be 0
        }
    }

    It 'keeps default body spacing at 160 percent and paragraph before/after at zero' {
        $path=Join-Path $TestDrive 'spacing-default.hwpx'
        $null=New-PortraitSpacingDocument $path
        $style=Get-PortraitSpacingStyle $path
        foreach ($line in $style.SelectNodes(".//*[local-name()='lineSpacing']")) {
            $line.GetAttribute('type') | Should Be 'PERCENT'
            $line.GetAttribute('value') | Should Be '160'
        }
        $style.SelectNodes(".//*[local-name()='lineSpacing']").Count | Should Be 2
        foreach ($margin in $style.SelectNodes(".//*[local-name()='prev' or local-name()='next']")) {
            $margin.GetAttribute('value') | Should Be '0'
        }
    }

    foreach ($kind in @('FIXED','AT_LEAST')) {
        It "writes $kind spacing in modern and legacy paragraph units" {
            $path=Join-Path $TestDrive ($kind+'.hwpx')
            $style=[pscustomobject]@{lineSpacing=[pscustomobject]@{type=$kind;valuePt=14};marginBeforeMm=10;marginAfterMm=5;indentMm=-2}
            $null=New-PortraitSpacingDocument $path -ParagraphStyle $style
            $paragraph=Get-PortraitSpacingStyle $path
            $case=$paragraph.SelectSingleNode("*[local-name()='switch']/*[local-name()='case']")
            $fallback=$paragraph.SelectSingleNode("*[local-name()='switch']/*[local-name()='default']")
            $case | Should Not BeNullOrEmpty
            $case.GetAttribute('required-namespace','http://www.hancom.co.kr/hwpml/2011/paragraph') | Should Be 'http://www.hancom.co.kr/hwpml/2016/HwpUnitChar'
            $case.SelectSingleNode("*[local-name()='lineSpacing']").GetAttribute('value') | Should Be '1400'
            $fallback.SelectSingleNode("*[local-name()='lineSpacing']").GetAttribute('value') | Should Be '2800'
            $case.SelectSingleNode(".//*[local-name()='prev']").GetAttribute('value') | Should Be '2835'
            $fallback.SelectSingleNode(".//*[local-name()='prev']").GetAttribute('value') | Should Be '5670'
            $case.SelectSingleNode(".//*[local-name()='next']").GetAttribute('value') | Should Be '1417'
            $fallback.SelectSingleNode(".//*[local-name()='next']").GetAttribute('value') | Should Be '2834'
            $case.SelectSingleNode(".//*[local-name()='intent']").GetAttribute('value') | Should Be '-567'
            $fallback.SelectSingleNode(".//*[local-name()='intent']").GetAttribute('value') | Should Be '-1134'
        }
    }

    It 'does not double percentage spacing when creating compatibility branches' {
        $path=Join-Path $TestDrive 'percent.hwpx'
        $null=New-PortraitSpacingDocument $path -ParagraphStyle ([pscustomobject]@{lineSpacingPercent=180;marginAfterMm=10})
        $style=Get-PortraitSpacingStyle $path
        $style.SelectNodes(".//*[local-name()='lineSpacing']").Count | Should Be 2
        foreach ($line in $style.SelectNodes(".//*[local-name()='lineSpacing']")) { $line.GetAttribute('value') | Should Be '180' }
    }

    It 'uses legacy units when editing the existing template paragraph margins' {
        $source=Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx'
        $path=Join-Path $TestDrive 'edited-margins.hwpx'
        $before=(Get-FileHash -LiteralPath $source).Hash
        $plan=@{version='2.0';operations=@(@{type='set-paragraph-format';sectionIndex=0;paragraphIndex=0;paragraphStyle=@{marginBeforeMm=10;lineSpacingPercent=180}})}
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $path -Plan $plan
        ($result.Errors -join '; ') | Should Be ''
        $xml=Read-PortraitSpacingPart $path
        $id=$xml.SelectSingleNode("/*/*[local-name()='p']").GetAttribute('paraPrIDRef')
        $head=Read-PortraitSpacingPart $path 'Contents/header.xml'
        $style=$head.SelectSingleNode("//*[local-name()='paraPr' and @id='$id']")
        $style.SelectSingleNode(".//*[local-name()='case']//*[local-name()='prev']").GetAttribute('value') | Should Be '2835'
        $style.SelectSingleNode(".//*[local-name()='default']//*[local-name()='prev']").GetAttribute('value') | Should Be '5670'
        (Get-FileHash -LiteralPath $source).Hash | Should Be $before
    }

    It 'rejects a legacy fixed-spacing value with modern units before promotion' {
        $path=Join-Path $TestDrive 'bad-legacy.hwpx'
        $style=[pscustomobject]@{lineSpacing=[pscustomobject]@{type='FIXED';valuePt=14}}
        $null=New-PortraitSpacingDocument $path -ParagraphStyle $style
        $plan=ConvertTo-HwpAuthoringPlan ('{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
        Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
            param($doc)
            $doc.SelectSingleNode("//*[local-name()='default']/*[local-name()='lineSpacing' and @type='FIXED']").SetAttribute('value','1400')
        }
        $result=Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'lineSpacing'
    }

    It 'rejects doubled percentage spacing in the fallback branch' {
        $path=Join-Path $TestDrive 'bad-percent.hwpx'
        $null=New-PortraitSpacingDocument $path -ParagraphStyle ([pscustomobject]@{lineSpacingPercent=180})
        $plan=ConvertTo-HwpAuthoringPlan ('{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
        Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
            param($doc)
            $doc.SelectSingleNode("//*[local-name()='default']/*[local-name()='lineSpacing' and @value='180']").SetAttribute('value','360')
        }
        $result=Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'lineSpacing'
    }

    It 'rejects unequal paragraph-margin measurements between compatibility branches' {
        $path=Join-Path $TestDrive 'bad-margins.hwpx'
        $null=New-PortraitSpacingDocument $path -ParagraphStyle ([pscustomobject]@{marginBeforeMm=10})
        $plan=ConvertTo-HwpAuthoringPlan ('{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
        Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
            param($doc)
            $doc.SelectSingleNode("//*[local-name()='default']//*[local-name()='prev' and @value='5670']").SetAttribute('value','2835')
        }
        $result=Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'margin'
    }

    It 'rejects invented line caches in V1 as well as V2' {
        $path=Join-Path $TestDrive 'bad-v1-cache.hwpx'
        $null=New-PortraitSpacingDocument $path '1.0'
        $plan=ConvertTo-HwpAuthoringPlan ('{"version":"1.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
        Edit-PortraitSpacingTestPart $path 'Contents/section0.xml' {
            param($doc)
            $null=$doc.DocumentElement.AppendChild($doc.CreateElement('hp','linesegarray','http://www.hancom.co.kr/hwpml/2011/paragraph'))
        }
        $result=Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'linesegarray'
    }

    It 'provides a runnable simple portrait-report recipe before advanced examples' {
        $guide=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/references/authoring.md') -Raw -Encoding UTF8
        $firstJson=[regex]::Match($guide,'(?s)```json\s*(.*?)\s*```')
        $firstJson.Success | Should Be $true
        $plan=$firstJson.Groups[1].Value | ConvertFrom-Json
        $plan.document.page.orientation | Should Be 'PORTRAIT'
        $plan.document.page.paperSize | Should Be 'A4'
        $plan.document.paragraphStyle.lineSpacingPercent | Should Be 160
        $plan.document.paragraphStyle.marginBeforeMm | Should Be 0
        $plan.document.paragraphStyle.marginAfterMm | Should Be 0
        $path=Join-Path $TestDrive 'guide-basic.hwpx'
        $result=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $path
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        (Read-PortraitSpacingPart $path).SelectSingleNode("//*[local-name()='pagePr']").GetAttribute('landscape') | Should Be 'WIDELY'
    }

    It 'round-trips scoped margins on a legacy direct paragraph without doubling inspected mm' {
        $source=Join-Path $TestDrive 'legacy-source.hwpx'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $source
        Edit-PortraitSpacingTestPart $source 'Contents/header.xml' {
            param($doc)
            $shape=$doc.SelectSingleNode("//*[local-name()='paraPr' and @id='0']")
            $switch=$shape.SelectSingleNode("*[local-name()='switch']")
            $fallback=$switch.SelectSingleNode("*[local-name()='default']")
            foreach($child in @($fallback.ChildNodes)) { $null=$shape.InsertBefore($child.CloneNode($true),$switch) }
            $null=$shape.RemoveChild($switch)
        }
        $before=(Get-FileHash -LiteralPath $source).Hash
        $path=Join-Path $TestDrive 'legacy-edited.hwpx'
        $plan=@{version='2.0';operations=@(@{type='set-paragraph-format';sectionIndex=0;paragraphIndex=0;paragraphStyle=@{leftMarginMm=10;indentMm=-5;marginBeforeMm=10;marginAfterMm=5}})}
        $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $path -Plan $plan
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $section=Read-PortraitSpacingPart $path
        $id=[int]$section.SelectSingleNode("/*/*[local-name()='p']").GetAttribute('paraPrIDRef')
        $read=Get-HwpInspection -LiteralPath $path
        $shape=@($read.Resources.paraShapes | Where-Object id -eq $id)[0]
        $shape.margins.left.raw | Should Be 5670
        [Math]::Round($shape.margins.left.millimeter,2) | Should Be 10
        [Math]::Round($shape.margins.before.millimeter,2) | Should Be 10
        [Math]::Round($shape.margins.after.millimeter,2) | Should Be 5
        $shape.indent.raw | Should Be -2834
        [Math]::Round($shape.indent.millimeter,2) | Should Be -5
        (Get-FileHash -LiteralPath $source).Hash | Should Be $before
    }

    It 'reports equal physical fixed spacing from modern and legacy resources while preserving raw values' {
        $path=Join-Path $TestDrive 'modern-spacing-read.hwpx'
        $null=New-PortraitSpacingDocument $path -ParagraphStyle ([pscustomobject]@{lineSpacing=[pscustomobject]@{type='FIXED';valuePt=14}})
        $modern=Get-HwpInspection -LiteralPath $path
        $shape=@($modern.Resources.paraShapes | Where-Object {$_.lineSpacing.type -eq 'FIXED'})[0]
        $shape.lineSpacing.value | Should Be 1400
        $shape.lineSpacing.measurement.point | Should Be 14
        Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
            param($doc)
            $shape=$doc.SelectSingleNode("//*[local-name()='paraPr'][.//*[local-name()='lineSpacing' and @type='FIXED']]")
            $switch=$shape.SelectSingleNode("*[local-name()='switch']")
            $fallback=$switch.SelectSingleNode("*[local-name()='default']")
            foreach($child in @($fallback.ChildNodes)) { $null=$shape.InsertBefore($child.CloneNode($true),$switch) }
            $null=$shape.RemoveChild($switch)
        }
        $legacy=Get-HwpInspection -LiteralPath $path
        $shape=@($legacy.Resources.paraShapes | Where-Object {$_.lineSpacing.type -eq 'FIXED'})[0]
        $shape.lineSpacing.value | Should Be 2800
        $shape.lineSpacing.measurement.raw | Should Be 2800
        $shape.lineSpacing.measurement.point | Should Be 14
    }

    It 'allows unused character-unit paragraph resources outside the generated spacing contract' {
        $path=Join-Path $TestDrive 'unused-char-units.hwpx'
        $null=New-PortraitSpacingDocument $path
        $plan=ConvertTo-HwpAuthoringPlan ('{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
        Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
            param($doc)
            $original=$doc.SelectSingleNode("//*[local-name()='paraPr' and @id='0']")
            $unused=$original.CloneNode($true)
            $unused.SetAttribute('id','999')
            $unused.SelectSingleNode(".//*[local-name()='case']//*[local-name()='left']").SetAttribute('unit','CHAR')
            $null=$original.ParentNode.AppendChild($unused)
            $original.ParentNode.SetAttribute('itemCnt',[string]$original.ParentNode.ChildNodes.Count)
        }
        (Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan).Status | Should Be 'PASS'
    }

    foreach($badType in @('','TYPO')) {
        It "rejects missing or unknown line-spacing type '$badType' in both branches" {
            $path=Join-Path $TestDrive ('invalid-type-'+$badType+'.hwpx')
            $null=New-PortraitSpacingDocument $path -ParagraphStyle ([pscustomobject]@{lineSpacing=[pscustomobject]@{type='FIXED';valuePt=14}})
            $plan=ConvertTo-HwpAuthoringPlan ('{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
            Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
                param($doc)
                foreach($line in $doc.SelectNodes("//*[local-name()='lineSpacing' and @type='FIXED']")) {
                    if($badType) {$line.SetAttribute('type',$badType)} else {$line.RemoveAttribute('type')}
                }
            }
            $result=Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
            $result.Status | Should Be 'FAILED'
            ($result.Errors -join ' ') | Should Match 'lineSpacing'
        }
    }

    It 'rejects a legacy spacing value beyond the native signed integer range' {
        $path=Join-Path $TestDrive 'spacing-overflow.hwpx'
        $null=New-PortraitSpacingDocument $path -ParagraphStyle ([pscustomobject]@{lineSpacing=[pscustomobject]@{type='FIXED';valuePt=14}})
        $plan=ConvertTo-HwpAuthoringPlan ('{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}' | ConvertFrom-Json)
        Edit-PortraitSpacingTestPart $path 'Contents/header.xml' {
            param($doc)
            $doc.SelectSingleNode("//*[local-name()='case']/*[local-name()='lineSpacing' and @type='FIXED']").SetAttribute('value','2147483647')
            $doc.SelectSingleNode("//*[local-name()='default']/*[local-name()='lineSpacing' and @type='FIXED']").SetAttribute('value','4294967294')
        }
        $result=Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'lineSpacing'
    }
}
