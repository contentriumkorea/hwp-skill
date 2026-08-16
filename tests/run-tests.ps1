[CmdletBinding()]
param(
    [ValidateSet('Static','Integration','All')]
    [string]$Suite = 'All'
)

$allTests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File)
$selected = switch ($Suite) {
    'Static' { @($allTests | Where-Object Name -NotLike '*.Integration.Tests.ps1') }
    'Integration' { @($allTests | Where-Object Name -Like '*.Integration.Tests.ps1') }
    default { $allTests }
}

if ($selected.Count -eq 0) {
    Write-Error "실행할 $Suite 시험을 찾지 못했습니다."
    exit 1
}

$result = Invoke-Pester -Script @($selected.FullName) -PassThru
if ($result.FailedCount -gt 0) {
    exit 1
}

exit 0
