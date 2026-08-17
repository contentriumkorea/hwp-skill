$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilityModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpInspect.psm1'
$generateModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpGenerate.psm1'
$hwpxModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpHwpx.psm1'
$convertModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpConvert.psm1'
$imageFixture = Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'

Describe 'HWPX 직접 작성 및 최종 변환 경계' {
    BeforeAll {
        Import-Module $commonModule -Force
        Import-Module $executionModule -Force
        Import-Module $capabilityModule -Force
        Import-Module $inspectModule -Force
        Import-Module $hwpxModule -Force
        Import-Module $convertModule -Force
        Import-Module $generateModule -Force
    }

    It '문단·표·이미지를 HWPX ZIP/XML에 직접 넣고 COM 팩터리를 호출하지 않는다' {
        $output = Join-Path $TestDrive 'direct.hwpx'
        $plan = [pscustomobject]@{
            version = '1.0'
            title = '직접 HWPX 시험'
            content = @(
                [pscustomobject]@{ type = 'paragraph'; text = '직접 작성 문단' }
                [pscustomobject]@{
                    type = 'table'
                    rows = 2
                    columns = 2
                    cells = @(
                        [pscustomobject]@{ row = 1; column = 1; text = '항목' }
                        [pscustomobject]@{ row = 1; column = 2; text = '내용' }
                        [pscustomobject]@{ row = 2; column = 1; text = '상태' }
                        [pscustomobject]@{ row = 2; column = 2; text = '완료' }
                    )
                }
                [pscustomobject]@{ type = 'image'; path = $imageFixture; widthMm = 20; heightMm = 20 }
            )
        }
        $context = New-HwpExecutionContext
        $capabilities = Get-HwpCapabilitySnapshot -ExecutionContext $context -NativeRegistrationProbe { $false } -PortableBackendProbe { $false } -IsolatedWorkerProbe { $false }
        $sessionCalls = [pscustomobject]@{ Value = 0 }
        $sessionFactory = ({ param($ignored) $sessionCalls.Value++; throw '세션 호출 금지' }.GetNewClosure())

        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -ExecutionContext $context -Capabilities $capabilities -SessionFactory $sessionFactory

        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.WorkFormat | Should Be 'HWPX'
        $result.FinalFormat | Should Be 'HWPX'
        $result.HancomContentWrite | Should Be $false
        $sessionCalls.Value | Should Be 0
        Test-Path -LiteralPath $output | Should Be $true
        $result.After.Text | Should Match '직접 작성 문단'
        @($result.After.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 1
        @($result.After.Controls | Where-Object CtrlId -eq 'pic').Count | Should Be 1
    }

    It '최종 HWP 변환은 별도 작업자 계약으로만 결과를 승격한다' {
        $input = Join-Path $TestDrive 'input.hwpx'
        $output = Join-Path $TestDrive 'output.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skill/hwp-skill/templates/default.hwpx') -Destination $input
        $worker = {
            param($source, $target)
            [IO.File]::WriteAllBytes($target, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1,0,0,0,0))
            [pscustomobject]@{ Status = 'PASS'; ContentWrittenByHancom = $false; WorkerProcess = $true }
        }

        $result = Invoke-HwpFinalHwpxToHwp -InputPath $input -OutputPath $output -WorkerLauncher $worker

        $result.Status | Should Be 'PASS'
        $result.ContentWrittenByHancom | Should Be $false
        Test-Path -LiteralPath $output | Should Be $true
        (Get-HwpFileKind -LiteralPath $output).DetectedKind | Should Be 'HWP-BINARY'
    }
}
