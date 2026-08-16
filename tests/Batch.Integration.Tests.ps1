$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpInspect.psm1'
$batchModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpBatch.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $inspectModule -Force
Import-Module $batchModule -Force
Import-Module $helperModule -Force

$fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
$runNative = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and (Test-Path -LiteralPath $fixtureHwp)

Describe 'HWP 일괄 적용 실제 한컴 통합 시험' -Tags Native,Batch {
    It '입력 한 건을 독립 결과 HWP로 만들고 원본을 보존한다' -Skip:(-not $runNative) {
        $input = Join-Path $TestDrive 'batch-source.hwp'
        Copy-Item -LiteralPath $fixtureHwp -Destination $input
        $sourceHash = Get-HwpSha256 -LiteralPath $input
        $plan = New-ValidPlan -SourcePath $input -SourceSha256 $sourceHash

        $result = Invoke-HwpBatch -InputPaths @($input) -Plan $plan -Apply

        $result.Status | Should Be 'PASS'
        $result.DryRun | Should Be $false
        @($result.Items).Count | Should Be 1
        $result.Items[0].Status | Should Be 'PASS'
        Test-Path -LiteralPath $result.Items[0].OutputPath | Should Be $true
        (Get-HwpInspection -LiteralPath $result.Items[0].OutputPath).Text | Should Match '새 문구'
        (Get-HwpSha256 -LiteralPath $input) | Should Be $sourceHash
    }
}
