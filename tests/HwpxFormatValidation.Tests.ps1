Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Describe 'Exact color validation in the shared scoped formatter' {
 It 'rejects a final newline instead of writing an invalid XML color' {
  $source=Join-Path $TestDrive 'source.hwpx';$out=Join-Path $TestDrive 'out.hwpx'
  $g=Invoke-HwpGenerate -NewDocument -OutputPath $source -Plan @{version='2.0';content=@(@{type='paragraph';text='Color target'})}
  ($g.Errors -join '; ')|Should Be ''
  $p=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs|Where-Object text -eq 'Color target')[0]
  $address=@{};foreach($prop in $p.address.PSObject.Properties){$address[$prop.Name]=$prop.Value}
  $address.path=@($address.path)+@(0);$address.kind='run'
  $sha=(Get-FileHash $source).Hash
  $r=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $out -Plan @{version='2.0';operations=@(@{type='set-run-format';address=$address;textStyle=@{textColor="#112233`n"}})}
  $r.Status|Should Be BLOCKED;($r.Errors -join '; ')|Should Match 'textColor must be';Test-Path $out|Should Be $false
  (Get-FileHash $source).Hash|Should Be $sha
 }
}
