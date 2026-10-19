[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent;$lib=Join-Path $root 'skills/hwp-skill/scripts/lib'
Import-Module (Join-Path $lib 'HwpGenerate.psm1') -Force
Import-Module (Join-Path $lib 'HwpInspect.psm1') -Force
Import-Module (Join-Path $lib 'HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $root 'tests/WindowActivityMonitor.psm1') -Force
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new smoke-test directory.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$script:smokeSteps=[Collections.Generic.List[object]]::new();$script:smokeCurrent=Join-Path $OutputDirectory 'source.hwpx'
function Read-SmokeData($Path){$r=Get-HwpxPackageInspection -LiteralPath $Path;if($r.Errors.Count -gt 0){throw ($r.Errors -join '; ')};return $r.Data}
function Write-SmokeStep($Name,$Operations){
    $next=Join-Path $OutputDirectory ($Name+'.hwpx');$original=$script:smokeCurrent;$hash=(Get-FileHash $original).Hash
    $r=Invoke-HwpxScopedEdit -LiteralPath $original -OutputPath $next -Plan @{version='2.0';operations=@($Operations)}
    if($r.Errors.Count -gt 0 -or -not (Test-Path $next)){throw ($r.Errors -join '; ')}
    if((Get-FileHash $original).Hash -cne $hash){throw 'Smoke source changed.'}
    $null=Read-SmokeData $next;$script:smokeSteps.Add(@{operation=$Name;status=$r.Status;sourcePreserved=$true;path=$next})
    $script:smokeCurrent=$next
}
$monitor=New-HwpSilentActivityMonitor;$monitor.Start()
try {
    $plan=[pscustomobject]@{version='2.0';content=@(
        [pscustomobject]@{type='paragraph';text='무창 편집 검증 예제'},
        [pscustomobject]@{type='paragraph';text='교체 대상'},
        [pscustomobject]@{type='table';rows=4;columns=2;cells=@(
            [pscustomobject]@{row=1;column=1;text='항목'},[pscustomobject]@{row=1;column=2;text='금액'},
            [pscustomobject]@{row=2;column=1;text='가'},[pscustomobject]@{row=2;column=2;text='20'},
            [pscustomobject]@{row=3;column=1;text='나'},[pscustomobject]@{row=3;column=2;text='3'},
            [pscustomobject]@{row=4;column=1;text='다'},[pscustomobject]@{row=4;column=2;text='20'}
        )}
    )}
    $result=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $script:smokeCurrent
    if($result.Errors.Count -gt 0){throw ($result.Errors -join '; ')}
    $data=Read-SmokeData $script:smokeCurrent;$p=$data.Paragraphs|Where-Object text -eq '교체 대상'|Select-Object -First 1
    Write-SmokeStep 'insert-paragraphs' @(@{type='insert-paragraphs';address=$p.address;placement='after';paragraphs=@(@{text='';textStyle=@{fontSizePt=6}},@{text='삭제할 문단'})})
    $data=Read-SmokeData $script:smokeCurrent;$p=$data.Paragraphs|Where-Object text -eq '삭제할 문단'|Select-Object -First 1
    Write-SmokeStep 'delete-paragraph' @(@{type='delete-paragraph';address=$p.address;expectedText=$p.text})
    $data=Read-SmokeData $script:smokeCurrent;$p=$data.Paragraphs|Where-Object text -eq '교체 대상'|Select-Object -First 1
    Write-SmokeStep 'paragraph-content' @(@{type='set-paragraph-content';address=$p.address;expectedText=$p.text;paragraph=@{runs=@(@{text='부분 강조';textStyle=@{bold=$true}},@{text='와 일반 본문'})}})
    $data=Read-SmokeData $script:smokeCurrent;$p=$data.Paragraphs|Where-Object text -eq '부분 강조와 일반 본문'|Select-Object -First 1
    Write-SmokeStep 'paragraph-breaks' @(@{type='set-paragraph-breaks';address=$p.address;pageBreak=$false;columnBreak=$false})
    $data=Read-SmokeData $script:smokeCurrent
    Write-SmokeStep 'sort' @(@{type='sort-table-rows';address=$data.Tables[0].address;startRow=1;endRow=3;column=1;dataType='NUMBER';direction='ASC'})
    $data=Read-SmokeData $script:smokeCurrent
    if(($data.Tables[0].cells|Where-Object columnAddress -eq 0|ForEach-Object {$_.text}) -join ',' -cne '항목,나,가,다'){throw 'Sorted readback differs.'}
    Write-SmokeStep 'table-header' @(@{type='set-table-format';address=$data.Tables[0].address;headerRows=2})
    $data=Read-SmokeData $script:smokeCurrent
    Write-SmokeStep 'cell-direction' @(@{type='set-cell-format';address=$data.Tables[0].cells[6].address;textDirection='VERTICAL';lineWrap='BREAK'})
    Write-SmokeStep 'page-border' @(@{type='set-page-border';sectionIndex=0;applyTo='ODD';style=@{borderType='SOLID';borderColor='#315B77';borderWidthMm=0.2}})
    $main=$script:smokeCurrent
    # A separate geometry-only proof: a pre-existing full-width table is not auto-fitted into columns.
    Write-SmokeStep 'columns-geometry-only' @(@{type='set-columns';sectionIndex=0;count=2;gapMm=5})
    $data=Read-SmokeData $main
} finally {$monitor.Stop()}
$activity=[ordered]@{newHwpProcessIds=@($monitor.NewHwpProcessIds);newWordProcessIds=@($monitor.NewWinwordProcessIds);newExplorerProcessIds=@($monitor.NewExplorerProcessIds);newVisibleWindowHandles=@($monitor.NewVisibleWindowHandles);newVisibleWindowProcesses=@($monitor.NewVisibleWindowProcessIds|ForEach-Object {$p=Get-Process -Id $_ -ErrorAction SilentlyContinue;@{id=$_;name=$(if($p){$p.ProcessName}else{'exited'})}});foregroundCapturedByHwp=$monitor.ForegroundCapturedByHwp;foregroundChanged=$monitor.ForegroundChanged}
$monitor.Dispose()
if($activity.newHwpProcessIds.Count -gt 0 -or $activity.newWordProcessIds.Count -gt 0 -or $activity.foregroundCapturedByHwp){throw 'Unexpected native application activation.'}
$report=[ordered]@{version='2.4.0';mainHwpx=$main;steps=@($script:smokeSteps.ToArray());activity=$activity;structuralReadbackVerified=$true;nativeRenderingVerified=$false;allHancomFeaturesSupported=$false;tableCount=$data.Tables.Count}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'smoke-report.json'),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 12
