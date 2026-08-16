$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpInspect.psm1'
$verifyModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpVerify.psm1'
Import-Module $commonModule -Force
Import-Module $sessionModule -Force
Import-Module $inspectModule -Force
if (Test-Path -LiteralPath $verifyModule) {
    Import-Module $verifyModule -Force
}

$fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
$runNative = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and (Test-Path -LiteralPath $fixtureHwp)

Describe 'HWP 재열기와 시각 검증 실제 한컴 통합 시험' -Tags Native,Verify {
    It '보안 모듈 준비 상태에 따라 PDF·페이지 이미지 또는 명시적 경고를 반환한다' -Skip:(-not $runNative) {
        $result = Invoke-HwpVerify -LiteralPath $fixtureHwp -OutputDirectory $TestDrive

        $result.Status | Should Match '^PASS'
        $result.After.Status | Should Match '^PASS'
        if ($result.VisualVerificationCompleted) {
            Test-Path -LiteralPath $result.PdfPath | Should Be $true
            $result.PageImages.Count | Should Be $result.After.PageCount
            foreach ($image in @($result.PageImages)) {
                Test-Path -LiteralPath $image | Should Be $true
            }
        }
        else {
            $result.Status | Should Be 'PASS_WITH_WARNINGS'
            [string]::IsNullOrWhiteSpace([string]$result.PdfPath) | Should Be $true
            @($result.PageImages).Count | Should Be 0
            ($result.Warnings -join ' ') | Should Match '보안 모듈'
        }
    }
}
