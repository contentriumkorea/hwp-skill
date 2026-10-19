Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
function Invoke-Pm($Source,$Output,$Op){Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=@($Op)}}
function Get-PmXml($Path){$z=[IO.Compression.ZipFile]::OpenRead($Path);try{$r=[IO.StreamReader]::new($z.GetEntry('Contents/section0.xml').Open());try{[xml]$r.ReadToEnd()}finally{$r.Dispose()}}finally{$z.Dispose()}}
Describe 'Guarded paragraph moves preserve original content and section controls' {
 BeforeEach {
  $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
  $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'output.hwpx'
  $g=Invoke-HwpGenerate -NewDocument -OutputPath $source -Plan ([pscustomobject]@{version='2.0';content=@(
   [pscustomobject]@{type='paragraph';text='Alpha'},
   [pscustomobject]@{type='paragraph';runs=@([pscustomobject]@{text='Beta';textStyle=@{bold=$true}},[pscustomobject]@{text="`tTail";textStyle=@{italic=$true}})},
   [pscustomobject]@{type='paragraph';text='Gamma'}
  )})
  ($g.Errors -join '; ')|Should Be ''
  $data=(Get-HwpxPackageInspection -LiteralPath $source).Data
  $a=@($data.Paragraphs|Where-Object text -eq Alpha)[0];$b=@($data.Paragraphs|Where-Object text -eq "Beta`tTail")[0];$c=@($data.Paragraphs|Where-Object text -eq Gamma)[0]
  $sha=(Get-FileHash $source).Hash
 }
 It 'moves an entire rich paragraph before a sibling with run refs and IDs preserved' {
  $op=@{type='move-paragraph';address=$c.address;targetAddress=$b.address;placement='before';expectedText='Gamma'}
  $r=Invoke-Pm $source $output $op;($r.Errors -join '; ')|Should Be ''
  $after=(Get-HwpxPackageInspection -LiteralPath $output).Data
  (@($after.Paragraphs|Where-Object {$_.text -in @('Alpha',"Beta`tTail",'Gamma')}|ForEach-Object text) -join '|')|Should BeExactly "Alpha|Gamma|Beta`tTail"
  $x=Get-PmXml $source;$y=Get-PmXml $output
  $x.SelectSingleNode('//*[local-name()="p" and *[local-name()="run"]/*[local-name()="t" and text()="Beta"]]').OuterXml|Should BeExactly $y.SelectSingleNode('//*[local-name()="p" and *[local-name()="run"]/*[local-name()="t" and text()="Beta"]]').OuterXml
  (Get-FileHash $source).Hash|Should Be $sha
 }
 It 'moves a rich paragraph after its sibling without flattening tab text' {
  $r=Invoke-Pm $source $output @{type='move-paragraph';address=$b.address;targetAddress=$c.address;placement='after';expectedText="Beta`tTail"}
  ($r.Errors -join '; ')|Should Be ''
  $p=(Get-HwpxPackageInspection -LiteralPath $output).Data.Paragraphs
  (@($p|Where-Object {$_.text -in @('Alpha',"Beta`tTail",'Gamma')}|ForEach-Object text) -join '|')|Should BeExactly "Alpha|Gamma|Beta`tTail"
  (Get-FileHash $source).Hash|Should Be $sha
 }
 It 'refuses a self target without writing' {
  $r=Invoke-Pm $source $output @{type='move-paragraph';address=$b.address;targetAddress=$b.address;placement='after';expectedText="Beta`tTail"}
  $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false
 }
 It 'requires exact original text including invisible characters' {
  $r=Invoke-Pm $source $output @{type='move-paragraph';address=$c.address;targetAddress=$b.address;placement='before';expectedText=('Ga'+[char]0xAD+'mma')}
  $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false
 }
 It 'rejects stale destination hashes' {
  $target=@{};foreach($property in $c.address.PSObject.Properties){$target[$property.Name]=$property.Value};$target.sourceSha256='0'*64
  $r=Invoke-Pm $source $output @{type='move-paragraph';address=$b.address;targetAddress=$target;placement='after';expectedText="Beta`tTail"}
  $r.Status|Should Be BLOCKED;($r.Errors -join '; ')|Should Match 'sourceSha256 does not match';Test-Path $output|Should Be $false
 }
 It 'does not normalize an expected-text guard that differs from inspected line breaks' {
  $middle=Join-Path $dir 'multiline.hwpx'
  $r=Invoke-Pm $source $middle @{type='set-paragraph-content';address=$b.address;expectedText="Beta`tTail";paragraph=@{text="Beta`nTail"}}
  ($r.Errors -join '; ')|Should Be ''
  $next=(Get-HwpxPackageInspection -LiteralPath $middle).Data
  $multi=@($next.Paragraphs|Where-Object text -eq "Beta`nTail")[0];$anchor=@($next.Paragraphs|Where-Object text -eq Gamma)[0]
  foreach($guard in @("Beta`rTail","Beta`r`nTail")){
   $r=Invoke-Pm $middle $output @{type='move-paragraph';address=$multi.address;targetAddress=$anchor.address;placement='after';expectedText=$guard}
   $r.Status|Should Be BLOCKED;($r.Errors -join '; ')|Should Match 'expectedText does not match';Test-Path $output|Should Be $false
  }
 }
 It 'checks preparation budgets before attempting to parse source text' {
  $module=Get-Module HwpHwpxScopedEdit
  $errorText=& $module {
   [xml]$xml='<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:p><hp:run/></hp:p><hp:p/></hs:sec>'
   $p=$xml.DocumentElement.FirstChild;$anchor=$xml.DocumentElement.LastChild
   try{$null=New-ScopedParagraphMove $p $anchor @{type='move-paragraph';address=@{};targetAddress=@{};placement='after';expectedText=''} @{} @{MovePreparedCharacters=16MB};'DID_NOT_THROW'}catch{$_.Exception.Message}
  }
  $errorText|Should Match 'preparation exceeds'
 }
 It 'refuses movement of a paragraph carrying section properties' {
  $first=@($data.Paragraphs|Where-Object {$_.address.path.Count -eq 1})[0]
  $r=Invoke-Pm $source $output @{type='move-paragraph';address=$first.address;targetAddress=$c.address;placement='after';expectedText=$first.text}
  $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false
 }
 It 'refuses insertion before the section property paragraph' {
  $first=@($data.Paragraphs|Where-Object {$_.address.path.Count -eq 1})[0]
  $r=Invoke-Pm $source $output @{type='move-paragraph';address=$c.address;targetAddress=$first.address;placement='before';expectedText='Gamma'}
  $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false
 }
 It 'rejects hidden enum and field-name variants' {
  foreach($mode in @('placement','key')){
   $op=@{type='move-paragraph';address=$c.address;targetAddress=$b.address;placement='before';expectedText='Gamma'}
   if($mode -eq 'placement'){$op.placement='be'+[char]0xAD+'fore'}else{$op['unknown'+[char]0xAD]=$true}
   $r=Invoke-Pm $source $output $op;$r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false
  }
 }
}
