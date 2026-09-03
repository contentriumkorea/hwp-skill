$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilitiesModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1'
$generateModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $executionModule -Force
Import-Module $capabilitiesModule -Force
Import-Module $inspectModule -Force
Import-Module $helperModule -Force
if (Test-Path -LiteralPath $generateModule) {
    Import-Module $generateModule -Force
}

$fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
$fixtureHwt = Join-Path $PSScriptRoot 'fixtures/source/native-template.hwt'
$runNative = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and
    (Test-Path -LiteralPath $fixtureHwp) -and (Test-Path -LiteralPath $fixtureHwt)

Describe 'HWT/HWP 양식 기반 생성 실제 한컴 통합 시험' -Tags Native,Generate {
    It 'HWT 양식은 작업 단계 한컴 실행을 막고 HWPX 양식을 요구한다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwt
        $output1 = Join-Path $TestDrive '양식생성-1.hwp'
        $output2 = Join-Path $TestDrive '양식생성-2.hwp'
        $interactiveExecutionContext = New-TestInteractiveExecutionContext
        $interactiveCapabilities = Get-HwpCapabilitySnapshot -ExecutionContext $interactiveExecutionContext

        $plan1 = New-ValidPlan -SourcePath $fixtureHwt -SourceSha256 $sourceHash
        $plan1.operations = @((New-FieldOperation -Name '담당자' -Before '시험 담당자' -After '김한글'))
        $plan2 = New-ValidPlan -SourcePath $fixtureHwt -SourceSha256 $sourceHash
        $plan2.operations = @((New-FieldOperation -Name '담당자' -Before '시험 담당자' -After '박문서'))

        $result1 = Invoke-HwpGenerate -TemplatePath $fixtureHwt -Plan $plan1 -OutputPath $output1 `
            -ExecutionContext $interactiveExecutionContext -Capabilities $interactiveCapabilities
        $result2 = Invoke-HwpGenerate -TemplatePath $fixtureHwt -Plan $plan2 -OutputPath $output2 `
            -ExecutionContext $interactiveExecutionContext -Capabilities $interactiveCapabilities

        $result1.Status | Should Be 'BLOCKED'
        $result2.Status | Should Be 'BLOCKED'
        ($result1.Errors -join ' ') | Should Match 'HWPX'
        ($result2.Errors -join ' ') | Should Match 'HWPX'
        Test-Path -LiteralPath $output1 | Should Be $false
        Test-Path -LiteralPath $output2 | Should Be $false
        (Get-HwpSha256 -LiteralPath $fixtureHwt) | Should Be $sourceHash
    }

    It '빈 문서 계획으로 제목·본문·표를 가진 재열 수 있는 HWP를 만든다' -Skip:(-not $runNative) {
        $output = Join-Path $TestDrive '새공공문서.hwp'
        $observation = [pscustomobject]@{ SawStaging = $false }
        $interactiveExecutionContext = New-TestInteractiveExecutionContext
        $interactiveCapabilities = Get-HwpCapabilitySnapshot -ExecutionContext $interactiveExecutionContext
        $inspector = {
            param($path, $executionContext, $capabilities)
            if ($path -notmatch '\.partial\.hwpx$') { throw "임시 검증 경로가 아닙니다: $path" }
            if (Test-Path -LiteralPath $output) { throw '재열기 검사 전에 최종 결과가 생성되었습니다.' }
            if ([string]$executionContext.Mode -ne 'interactive' -or -not [bool]$executionContext.AllowInteractiveWindow) {
                throw '승인된 interactive 실행 컨텍스트가 전달되지 않았습니다.'
            }
            $observation.SawStaging = $true
            Get-HwpInspection -LiteralPath $path -ExecutionContext $executionContext -Capabilities $capabilities
        }.GetNewClosure()
        $plan = [pscustomobject]@{
            version = '1.0'
            content = @(
                [pscustomobject]@{ type = 'paragraph'; text = '가상 공공문서' },
                [pscustomobject]@{ type = 'paragraph'; text = '안전한 빈 문서 생성 시험입니다.' },
                [pscustomobject]@{
                    type = 'table'
                    rows = 2
                    columns = 2
                    cells = @(
                        [pscustomobject]@{ row = 1; column = 1; text = '항목' },
                        [pscustomobject]@{ row = 1; column = 2; text = '내용' },
                        [pscustomobject]@{ row = 2; column = 1; text = '상태' },
                        [pscustomobject]@{ row = 2; column = 2; text = '완료' }
                    )
                }
            )
        }

        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output `
            -ExecutionContext $interactiveExecutionContext -Capabilities $interactiveCapabilities `
            -Inspector $inspector

        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.After.Text | Should Match '가상 공공문서'
        $result.After.Text | Should Match '안전한 빈 문서 생성 시험입니다\.'
        $result.After.Text | Should Match '항목'
        $result.After.Text | Should Match '완료'
        @($result.After.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 1
        $observation.SawStaging | Should Be $true
        Test-Path -LiteralPath $result.OutputPath | Should Be $true
    }
}

Describe 'Invoke-HwpGenerate 사전 차단' {
    It 'silent HWPX 생성은 직접 작성하고 세션을 호출하지 않는다' {
        $output = Join-Path $TestDrive 'silent-generate.hwpx'
        $plan = [pscustomobject]@{
            version = '1.0'
            content = @([pscustomobject]@{ type = 'paragraph'; text = 'HWPX 생성 차단' })
        }
        $hwpExecutionContext = New-HwpExecutionContext
        $capabilities = Get-HwpCapabilitySnapshot -ExecutionContext $hwpExecutionContext `
            -NativeRegistrationProbe { $true } -PortableBackendProbe { $false } -IsolatedWorkerProbe { $false }
        $calls = [pscustomobject]@{ Value = 0 }
        $factory = ({ param($context) $calls.Value++; throw '세션 호출 금지' }.GetNewClosure())

        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities -SessionFactory $factory

        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.After.Text | Should Match 'HWPX 생성 차단'
        $calls.Value | Should Be 0
        Test-Path -LiteralPath $output | Should Be $true
    }

    It 'silent 생성은 지원되지 않는 백엔드에서 세션 팩터리를 호출하지 않는다' {
        $output = Join-Path $TestDrive 'silent-generate.hwp'
        $plan = [pscustomobject]@{
            version = '1.0'
            content = @(
                [pscustomobject]@{ type = 'paragraph'; text = 'silent 생성 차단' }
            )
        }
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

        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities -SessionFactory $factory

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'GUI로 자동 전환'
        $calls.Value | Should Be 0
    }
}
