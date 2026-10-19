[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory,[string]$SkillRoot)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if([string]::IsNullOrWhiteSpace($SkillRoot)){$SkillRoot=Join-Path $root 'skills/hwp-skill'}
$lib=Join-Path $SkillRoot 'scripts/lib'
Import-Module (Join-Path $lib 'HwpGenerate.psm1') -Force
Import-Module (Join-Path $lib 'HwpInspect.psm1') -Force
Import-Module (Join-Path $lib 'HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $lib 'HwpHwpxModel.psm1') -Force
Import-Module (Join-Path $root 'tests/WindowActivityMonitor.psm1') -Force
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new smoke-test directory.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$source=Join-Path $OutputDirectory 'source.hwpx';$output=Join-Path $OutputDirectory 'edited.hwpx'
$monitor=New-HwpSilentActivityMonitor;$monitor.Start()
try {
    $image=(Resolve-Path (Join-Path $root 'tests/fixtures/source/fixture-blue.png')).Path
    $plan=[pscustomobject]@{version='2.0';content=@(
        [pscustomobject]@{type='paragraph';runs=@([pscustomobject]@{text='before AB';textStyle=[pscustomobject]@{bold=$true}},[pscustomobject]@{text='CD after';textStyle=[pscustomobject]@{italic=$true}})},
        [pscustomobject]@{type='shape';shape='rectangle';widthMm=25.4;heightMm=12.7},
        [pscustomobject]@{type='image';path=$image;widthMm=25.4;heightMm=12.7}
    )}
    $generated=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $source
    if($generated.Errors.Count -gt 0){throw ($generated.Errors -join '; ')}
    $before=(Get-HwpxPackageInspection -LiteralPath $source).Data;$hash=(Get-FileHash $source).Hash
    $p=@($before.Paragraphs|Where-Object text -eq 'before ABCD after')[0]
    $pic=@($before.Controls|Where-Object ctrlId -eq 'pic')[0]
    $shape=@($before.Controls|Where-Object ctrlId -eq 'rect')[0]
    $ops=@(
        @{type='set-section-settings';sectionIndex=0;settings=@{startNumbers=@{page=7};visibility=@{hideFirstPageNum=$true};pageNumber=@{position='BOTTOM_CENTER';format='DIGIT';sideChar='-'}}},
        @{type='replace-paragraph-text';address=$p.address;expectedText='before ABCD after';find='ABCD';replacement='X'},
        @{type='set-object-format';address=$shape.address;placement=@{horizontalOffsetMm=12.7};altText='shape retained'},
        @{type='set-object-format';address=$pic.address;widthMm=50.8;crop=@{left=0.25};rotation=90;flipVertical=$true}
    )
    $editPlan=@{version='2.0';operations=$ops}
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'edit-plan.json'),($editPlan|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    $edited=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan $editPlan
    if($edited.Errors.Count -gt 0){throw ($edited.Errors -join '; ')}
    $inspection=Get-HwpxPackageInspection -LiteralPath $output
    if($inspection.Errors.Count -gt 0){throw ($inspection.Errors -join '; ')}
    if(@($inspection.Data.Paragraphs|Where-Object text -eq 'before X after').Count -ne 1){throw 'Text range readback failed.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($output)
    try {
        $reader=[IO.StreamReader]::new($zip.GetEntry('Contents/section0.xml').Open())
        try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
        if($xml.SelectSingleNode('//*[local-name()="startNum"]').GetAttribute('page') -cne '7'){throw 'Start number readback failed.'}
        if($xml.SelectSingleNode('//*[local-name()="pageNum"]').GetAttribute('pos') -cne 'BOTTOM_CENTER'){throw 'Page number readback failed.'}
        $node=$xml.SelectSingleNode('//*[local-name()="pic"]')
        if($node.SelectSingleNode('*[local-name()="sz"]').GetAttribute('width') -cne '14400' -or $node.SelectSingleNode('*[local-name()="imgClip"]').GetAttribute('left') -cne '3600'){throw 'Picture readback failed.'}
        $stream=$zip.GetEntry('BinData/image1.PNG').Open();$memory=[IO.MemoryStream]::new()
        try{$stream.CopyTo($memory);if([Convert]::ToBase64String($memory.ToArray()) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($image))){throw 'Embedded asset bytes changed.'}}finally{$stream.Dispose();$memory.Dispose()}
    }finally{$zip.Dispose()}
    if((Get-FileHash $source).Hash -cne $hash){throw 'Original file changed.'}
    $model=Get-HwpxFormatModel -ModelClass CSectionDefinitionType
    if($model.classes[0].name -cne 'CSectionDefinitionType'){throw 'Model query failed.'}
} finally {$monitor.Stop()}
$activity=@{newHwpProcessIds=@($monitor.NewHwpProcessIds);newWordProcessIds=@($monitor.NewWinwordProcessIds);newExplorerProcessIds=@($monitor.NewExplorerProcessIds);newVisibleWindowHandles=@($monitor.NewVisibleWindowHandles);newVisibleWindowProcessIds=@($monitor.NewVisibleWindowProcessIds);foregroundCapturedByHwp=$monitor.ForegroundCapturedByHwp;foregroundChanged=$monitor.ForegroundChanged}
$monitor.Dispose()
if($activity.newHwpProcessIds.Count -gt 0 -or $activity.newWordProcessIds.Count -gt 0 -or $activity.foregroundCapturedByHwp){throw 'Unexpected native activation.'}
$report=@{version=(Get-Content (Join-Path $SkillRoot 'version.json') -Raw|ConvertFrom-Json).version;skillRoot=$SkillRoot;source=$source;output=$output;sourcePreserved=$true;embeddedImageBytesPreserved=$true;structuralReadbackVerified=$true;nativeRenderingVerified=$false;allHancomFeaturesSupported=$false;activity=$activity}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'smoke-report.json'),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 10
