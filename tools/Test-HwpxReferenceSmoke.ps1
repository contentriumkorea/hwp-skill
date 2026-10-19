[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,[string]$SkillRoot)
$ErrorActionPreference='Stop';$root=Split-Path $PSScriptRoot -Parent
if([string]::IsNullOrWhiteSpace($SkillRoot)){$SkillRoot=Join-Path $root 'skills/hwp-skill'}
$lib=Join-Path $SkillRoot 'scripts/lib'
foreach($module in @('HwpGenerate','HwpInspect','HwpHwpxScopedEdit')){Import-Module (Join-Path $lib ($module+'.psm1')) -Force}
Import-Module (Join-Path $root 'tests/WindowActivityMonitor.psm1') -Force
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new smoke directory.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$script:refCurrent=Join-Path $OutputDirectory 'source.hwpx';$steps=[Collections.Generic.List[object]]::new()
function Invoke-ReferenceSmokeStep($Name,$Operations){
    $next=Join-Path $OutputDirectory ($Name+'.hwpx');$before=$script:refCurrent;$sha=(Get-FileHash $before).Hash
    $plan=@{version='2.0';operations=@($Operations)}
    [IO.File]::WriteAllText((Join-Path $OutputDirectory ($Name+'.json')),($plan|ConvertTo-Json -Depth 35),[Text.UTF8Encoding]::new($false))
    $result=Invoke-HwpxScopedEdit -LiteralPath $before -OutputPath $next -Plan $plan
    if($result.Errors.Count -gt 0){throw ($result.Errors -join '; ')}
    $inspection=Get-HwpxPackageInspection -LiteralPath $next
    if($inspection.Errors.Count -gt 0 -or (Get-FileHash $before).Hash -cne $sha){throw 'Readback or original preservation failed.'}
    $steps.Add(@{name=$Name;status=$result.Status;sourcePreserved=$true;output=$next});$script:refCurrent=$next
}
$monitor=New-HwpSilentActivityMonitor;$monitor.Start()
try{
    $image=(Resolve-Path (Join-Path $root 'tests/fixtures/source/fixture-blue.png')).Path
    $plan=[pscustomobject]@{version='2.0';content=@(
        [pscustomobject]@{type='paragraph';text="Label`tValue"},
        [pscustomobject]@{type='footnote';text='Footnote content is retained.'},
        [pscustomobject]@{type='endnote';text='Endnote content is retained.'},
        [pscustomobject]@{type='image';path=$image;widthMm=25.4;heightMm=12.7}
    )}
    $generated=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $script:refCurrent
    if($generated.Errors.Count -gt 0){throw ($generated.Errors -join '; ')}
    $source=$script:refCurrent;$original=(Get-FileHash $source).Hash
    $data=(Get-HwpxPackageInspection -LiteralPath $source).Data
    $paragraph=@($data.Paragraphs|Where-Object text -eq "Label`tValue")[0]
    Invoke-ReferenceSmokeStep 'tabs-footnote' @(
        @{type='set-paragraph-tabs';address=$paragraph.address;tabs=@(@{positionMm=25.4;alignment='LEFT';leader='DOT'})},
        @{type='set-note-settings';sectionIndex=0;kind='footnote';settings=@{numbering=@{type='ON_PAGE';newNum=1};noteSpacing=@{betweenNotesMm=2.54}}}
    )
    Invoke-ReferenceSmokeStep 'header' @(@{type='set-header-footer';sectionIndex=0;kind='header';applyTo='BOTH';expectedText='';paragraphs=@(@{runs=@(@{text='Contentrium';textStyle=@{bold=$true}},@{text="`tReport"});paragraphStyle=@{alignment='RIGHT'}})})
    Invoke-ReferenceSmokeStep 'footer' @(@{type='set-header-footer';sectionIndex=0;kind='footer';applyTo='BOTH';expectedText='';paragraphs=@(@{text='Retained footer'})})
    Invoke-ReferenceSmokeStep 'endnote' @(@{type='set-note-settings';sectionIndex=0;kind='endnote';settings=@{placement=@{place='END_OF_SECTION'}}})
    $data=(Get-HwpxPackageInspection -LiteralPath $script:refCurrent).Data
    if(@($data.Paragraphs|Where-Object text -eq "Label`tValue").Count -ne 1){throw 'Body text or tabs changed.'}
    $para=@($data.Paragraphs|Where-Object text -eq "Label`tValue")[0];$style=@($data.Resources.paraShapes|Where-Object id -eq $para.paraShapeId)[0]
    $tabs=@($data.Resources.tabProperties|Where-Object id -eq $style.tabDefinitionId)[0]
    if($tabs.stops[0].positionMm -ne 25.4 -or $tabs.stops[0].leader -cne 'DOT'){throw 'Tab readback differs.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($script:refCurrent)
    try{
        $reader=[IO.StreamReader]::new($zip.GetEntry('Contents/section0.xml').Open());try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if($xml.SelectSingleNode('//*[local-name()="header"]').InnerText -cne "ContentriumReport" -or $xml.SelectSingleNode('//*[local-name()="footer"]').InnerText -cne 'Retained footer'){throw 'Header/footer readback differs.'}
        if($xml.SelectSingleNode('//*[local-name()="footNotePr"]/*[local-name()="numbering"]').GetAttribute('type') -cne 'ON_PAGE'){throw 'Footnote numbering differs.'}
        if($xml.SelectSingleNode('//*[local-name()="endNotePr"]/*[local-name()="placement"]').GetAttribute('place') -cne 'END_OF_SECTION'){throw 'Endnote placement differs.'}
        if($xml.SelectNodes('//*[local-name()="footNote"]').Count -ne 1 -or $xml.SelectNodes('//*[local-name()="endNote"]').Count -ne 1){throw 'Existing notes were lost.'}
        $stream=$zip.GetEntry('BinData/image1.PNG').Open();$memory=[IO.MemoryStream]::new()
        try{$stream.CopyTo($memory);if([Convert]::ToBase64String($memory.ToArray()) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($image))){throw 'Image bytes changed.'}}finally{$stream.Dispose();$memory.Dispose()}
    }finally{$zip.Dispose()}
    if((Get-FileHash $source).Hash -cne $original){throw 'Source changed.'}
}finally{$monitor.Stop()}
$activity=@{newHwpProcessIds=@($monitor.NewHwpProcessIds);newWordProcessIds=@($monitor.NewWinwordProcessIds);newExplorerProcessIds=@($monitor.NewExplorerProcessIds);newVisibleWindowHandles=@($monitor.NewVisibleWindowHandles);foregroundCapturedByHwp=$monitor.ForegroundCapturedByHwp;foregroundChanged=$monitor.ForegroundChanged};$monitor.Dispose()
if($activity.newHwpProcessIds.Count -gt 0 -or $activity.newWordProcessIds.Count -gt 0 -or $activity.foregroundCapturedByHwp){throw 'Unexpected native app activation.'}
$report=@{version=(Get-Content (Join-Path $SkillRoot 'version.json') -Raw|ConvertFrom-Json).version;skillRoot=$SkillRoot;source=$source;output=$script:refCurrent;steps=@($steps.ToArray());activity=$activity;embeddedImagePreserved=$true;sourcePreserved=$true;nativeRenderingVerified=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'smoke-report.json'),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false));$report|ConvertTo-Json -Depth 10
