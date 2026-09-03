$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilitiesModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1'
$batchModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpBatch.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $executionModule -Force
Import-Module $capabilitiesModule -Force
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
        $interactiveExecutionContext = New-TestInteractiveExecutionContext
        $interactiveCapabilities = Get-HwpCapabilitySnapshot -ExecutionContext $interactiveExecutionContext

        $result = Invoke-HwpBatch -InputPaths @($input) -Plan $plan -Apply `
            -ExecutionContext $interactiveExecutionContext -Capabilities $interactiveCapabilities

        $result.Status | Should Be 'PASS'
        $result.DryRun | Should Be $false
        @($result.Items).Count | Should Be 1
        $result.Items[0].Status | Should Be 'PASS'
        Test-Path -LiteralPath $result.Items[0].OutputPath | Should Be $true
        (Get-HwpInspection -LiteralPath $result.Items[0].OutputPath `
            -ExecutionContext $interactiveExecutionContext -Capabilities $interactiveCapabilities).Text |
            Should Match '새 문구'
        (Get-HwpSha256 -LiteralPath $input) | Should Be $sourceHash
    }
}

Describe 'Invoke-HwpBatch 사전 차단' {
    It 'silent 일괄 적용은 파일별 BLOCKED 항목을 유지한다' {
        $input = Join-Path $TestDrive 'silent-batch.hwp'
        Copy-Item -LiteralPath $fixtureHwp -Destination $input
        $sourceHash = Get-HwpSha256 -LiteralPath $input
        $plan = New-ValidPlan -SourcePath $input -SourceSha256 $sourceHash
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
        $inspectorCalls = [pscustomobject]@{ Value = 0 }
        $applyCalls = [pscustomobject]@{ Value = 0 }
        $inspector = {
            param($path, $context, $snapshot)
            $inspectorCalls.Value++
            if ($context.Mode -ne 'silent') { throw "unexpected mode: $($context.Mode)" }
            if ($snapshot.executionMode -ne 'silent') { throw "unexpected snapshot mode: $($snapshot.executionMode)" }
            return [pscustomobject]@{
                Status = 'PASS'
                Warnings = @()
                Errors = @()
            }
        }.GetNewClosure()
        $applyInvoker = {
            param($path, $itemPlan, $output, $approveAdvanced, $context, $snapshot)
            $applyCalls.Value++
            if ($context.Mode -ne 'silent') { throw "unexpected mode: $($context.Mode)" }
            if ($snapshot.executionMode -ne 'silent') { throw "unexpected snapshot mode: $($snapshot.executionMode)" }
            return [pscustomobject]@{
                Status = 'BLOCKED'
                OutputPath = $output
                Warnings = @()
                Errors = @('silent 백엔드가 없어 적용하지 않습니다.')
            }
        }.GetNewClosure()

        $result = Invoke-HwpBatch -InputPaths @($input) -Plan $plan -Apply `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities `
            -Inspector $inspector -ApplyInvoker $applyInvoker

        $result.Status | Should Be 'BLOCKED'
        @($result.Items).Count | Should Be 1
        $result.Items[0].Status | Should Be 'BLOCKED'
        $inspectorCalls.Value | Should Be 1
        $applyCalls.Value | Should Be 1
    }
}
