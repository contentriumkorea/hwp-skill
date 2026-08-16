$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'
$capabilitiesModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpInspect.psm1'
$verifyModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpVerify.psm1'
Import-Module $commonModule -Force
Import-Module $executionModule -Force
Import-Module $sessionModule -Force
Import-Module $capabilitiesModule -Force
Import-Module $inspectModule -Force
if (Test-Path -LiteralPath $verifyModule) {
    Import-Module $verifyModule -Force
}

$fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
$runNative = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and (Test-Path -LiteralPath $fixtureHwp)

Describe 'HWP 재열기와 시각 검증 실제 한컴 통합 시험' -Tags Native,Verify {
    It '보안 모듈 준비 상태에 따라 PDF·페이지 이미지 또는 명시적 경고를 반환한다' -Skip:(-not $runNative) {
        $interactiveExecutionContext = New-TestInteractiveExecutionContext
        $interactiveCapabilities = Get-HwpCapabilitySnapshot -ExecutionContext $interactiveExecutionContext
        $result = Invoke-HwpVerify -LiteralPath $fixtureHwp -OutputDirectory $TestDrive `
            -ExecutionContext $interactiveExecutionContext -Capabilities $interactiveCapabilities

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

Describe 'Invoke-HwpVerify 사전 차단' {
    It 'silent 검증은 지원되지 않는 백엔드에서 시각 검증 세션을 호출하지 않는다' {
        $hwpExecutionContext = [pscustomobject]@{
            SchemaVersion = '1.0'
            Mode = 'silent'
            AllowInteractiveWindow = $false
        }
        $capabilities = [pscustomobject]@{
            executionMode = 'silent'
            backends = @(
                [pscustomobject]@{ id = 'hwpx-direct'; available = $true; formats = @('HWPX-ZIP'); operations = @('inspect'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hwp-portable'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-isolated'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'separate-session'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-interactive'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'current-session'; reason = 'test' }
            )
        }
        $calls = [pscustomobject]@{ Value = 0 }
        $factory = ({ param($context) $calls.Value++; throw '세션 호출 금지' }.GetNewClosure())

        $result = Invoke-HwpVerify -LiteralPath $fixtureHwp -OutputDirectory $TestDrive `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities -SessionFactory $factory

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'silent'
        $calls.Value | Should Be 0
    }
}
