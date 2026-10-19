param([Parameter(Mandatory)][string]$OutputDirectory,[string]$SkillRoot)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Split-Path $PSScriptRoot -Parent
if([string]::IsNullOrWhiteSpace($SkillRoot)){$SkillRoot=Join-Path $root 'skills/hwp-skill'}
$cli=Join-Path $SkillRoot 'scripts/Invoke-HwpSkill.ps1'
$shell=(Get-Process -Id $PID).Path
Import-Module (Join-Path $root 'tests/WindowActivityMonitor.psm1') -Force
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new smoke directory.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$OutputDirectory=(Resolve-Path $OutputDirectory).Path
function Invoke-RsCli([string[]]$Arguments){
 $raw=& $shell -NoProfile -NonInteractive -File $cli @Arguments
 $result=($raw -join "`n")|ConvertFrom-Json
 if($LASTEXITCODE -ne 0 -or $result.errors.Count -gt 0){throw ('Public CLI failed: '+($result.errors -join '; '))}
 return $result
}
function Write-RsPlan($Name,$Plan){
 $path=Join-Path $OutputDirectory ($Name+'.json')
 [IO.File]::WriteAllText($path,($Plan|ConvertTo-Json -Depth 35),[Text.UTF8Encoding]::new($false))
 return $path
}
function Read-RsPart($Path,$Part){
 $zip=[IO.Compression.ZipFile]::OpenRead($Path)
 try{$s=$zip.GetEntry($Part).Open();$m=[IO.MemoryStream]::new();try{$s.CopyTo($m);return ,$m.ToArray()}finally{$s.Dispose();$m.Dispose()}}finally{$zip.Dispose()}
}
$monitor=New-HwpSilentActivityMonitor;$monitor.Start()
try{
 $source=Join-Path $OutputDirectory 'source.hwpx'
 $image=(Resolve-Path (Join-Path $root 'tests/fixtures/source/fixture-blue.png')).Path
 $plan=@{version='2.0';document=@{styles=@(@{name='Body';textStyle=@{fontSizePt=11};paragraphStyle=@{alignment='LEFT'}})};content=@(
  @{type='paragraph';text='Alpha'},
  @{type='paragraph';runs=@(@{text='Beta';textStyle=@{bold=$true}},@{text="`tTail";textStyle=@{italic=$true}})},
  @{type='paragraph';text='Gamma'},
  @{type='table';rows=2;columns=2;widthMm=100;cells=@(@{row=1;column=1;text='Cell';style=@{fillColor='#EEEEEE'}})},
  @{type='image';path=$image;widthMm=25.4;heightMm=12.7}
 )}
 $generated=Invoke-RsCli @('generate','-NewDocument','-PlanPath',(Write-RsPlan 'generate' $plan),'-OutputPath',$source)
 $sha=(Get-FileHash $source).Hash
 $read=Invoke-RsCli @('inspect','-LiteralPath',$source)
 $b=@($read.paragraphs|Where-Object text -eq "Beta`tTail")[0];$c=@($read.paragraphs|Where-Object text -eq Gamma)[0]
 $move=Join-Path $OutputDirectory 'move.hwpx'
 $op=@{type='move-paragraph';address=$c.address;targetAddress=$b.address;placement='before';expectedText='Gamma'}
 $null=Invoke-RsCli @('edit-hwpx','-LiteralPath',$source,'-PlanPath',(Write-RsPlan 'move' @{version='2.0';operations=@($op)}),'-OutputPath',$move,'-ApproveAdvanced')
 $read=Invoke-RsCli @('inspect','-LiteralPath',$move)
 $order=@($read.paragraphs|Where-Object {$_.text -in @('Alpha',"Beta`tTail",'Gamma')}|ForEach-Object text)-join '|'
 if($order -cne "Alpha|Gamma|Beta`tTail"){throw 'Move order differs.'}
 $body=@($read.resources.styles|Where-Object name -eq Body)[0];$b=@($read.paragraphs|Where-Object text -eq "Beta`tTail")[0]
 $styled=Join-Path $OutputDirectory 'style.hwpx'
 $op=@{type='apply-named-style';address=$b.address;styleId=$body.id;expectedText="Beta`tTail";name='Body Copy';textStyle=@{bold=$true};paragraphStyle=@{alignment='RIGHT'}}
 $null=Invoke-RsCli @('edit-hwpx','-LiteralPath',$move,'-PlanPath',(Write-RsPlan 'style' @{version='2.0';operations=@($op)}),'-OutputPath',$styled,'-ApproveAdvanced')
 $read=Invoke-RsCli @('inspect','-LiteralPath',$styled)
 $copy=@($read.resources.styles|Where-Object name -eq 'Body Copy')[0];$b=@($read.paragraphs|Where-Object text -eq "Beta`tTail")[0]
 if($copy.id -eq $body.id -or $b.styleId -ne $copy.id){throw 'Named style clone/apply differs.'}
 if(@($read.resources.styles|Where-Object {$_.id -eq $body.id -and $_.name -eq 'Body'}).Count -ne 1){throw 'Original named style lost.'}
 $out=Join-Path $OutputDirectory 'diagonal.hwpx'
 $cell=$read.tables[0].cells[0]
 $op=@{type='set-cell-diagonal';address=$cell.address;direction='SLASH';line=@{type='SOLID';widthMm=0.12;color='#123456'}}
 $null=Invoke-RsCli @('edit-hwpx','-LiteralPath',$styled,'-PlanPath',(Write-RsPlan 'diagonal' @{version='2.0';operations=@($op)}),'-OutputPath',$out,'-ApproveAdvanced')
 $read=Invoke-RsCli @('inspect','-LiteralPath',$out)
 [xml]$section=[Text.Encoding]::UTF8.GetString((Read-RsPart $out 'Contents/section0.xml'))
 [xml]$head=[Text.Encoding]::UTF8.GetString((Read-RsPart $out 'Contents/header.xml'))
 $tc=$section.SelectSingleNode('//*[local-name()="tc"]');$id=$tc.GetAttribute('borderFillIDRef')
 $bf=$head.SelectSingleNode('//*[local-name()="borderFill" and @id="'+$id+'"]')
 if($bf.SelectSingleNode('*[local-name()="slash"]').GetAttribute('type') -cne 'CENTER' -or $bf.SelectSingleNode('*[local-name()="diagonal"]').GetAttribute('color') -cne '#123456'){throw 'Diagonal readback differs.'}
 if([Convert]::ToBase64String((Read-RsPart $source 'BinData/image1.PNG')) -cne [Convert]::ToBase64String((Read-RsPart $out 'BinData/image1.PNG'))){throw 'Embedded image changed.'}
 if((Get-FileHash $source).Hash -cne $sha){throw 'Source changed.'}
 $cap=Invoke-RsCli @('capabilities')
 if($cap.data.skillVersion -cne '2.7.0' -or $cap.data.authoring.scopedEditOperations.Count -ne 36){throw 'Capabilities differ.'}
}finally{$monitor.Stop()}
$activity=@{newHwpProcessIds=@($monitor.NewHwpProcessIds);newWordProcessIds=@($monitor.NewWinwordProcessIds);newExplorerProcessIds=@($monitor.NewExplorerProcessIds);newVisibleWindowHandles=@($monitor.NewVisibleWindowHandles);foregroundChanged=$monitor.ForegroundChanged;foregroundCapturedByHwp=$monitor.ForegroundCapturedByHwp}
$monitor.Dispose()
if($activity.newHwpProcessIds.Count -or $activity.newWordProcessIds.Count -or $activity.foregroundCapturedByHwp){throw 'Unexpected native activation.'}
$report=@{version=$cap.data.skillVersion;operations=36;skillRoot=$SkillRoot;shell=$shell;output=$out;sourcePreserved=$true;embeddedImagePreserved=$true;activity=$activity;nativeRenderingVerified=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'smoke-report.json'),($report|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Depth 12
