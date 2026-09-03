[CmdletBinding()]
param(
    [ValidateSet('Static','Native','All')]
    [string]$Suite = 'Static',
    [switch]$AllowInteractiveNative
)

$allTests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File)
$nativeTests = @($allTests | Where-Object Name -Like '*.Integration.Tests.ps1')
$staticTests = @($allTests | Where-Object Name -NotLike '*.Integration.Tests.ps1')

if ($Suite -in @('Native', 'All') -and -not $AllowInteractiveNative) {
    Write-Error '네이티브 시험은 -AllowInteractiveNative의 명시적 승인이 필요합니다.'
    exit 2
}

$selected = switch ($Suite) {
    'Static' { $staticTests }
    'Native' { $nativeTests }
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
