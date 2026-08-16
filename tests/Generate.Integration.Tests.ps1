$commonModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpCommon.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpInspect.psm1'
$generateModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpGenerate.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
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
    It 'HWT 원본을 보존하고 서로 다른 필드값의 별도 HWP 두 개를 만든다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwt
        $output1 = Join-Path $TestDrive '양식생성-1.hwp'
        $output2 = Join-Path $TestDrive '양식생성-2.hwp'

        $plan1 = New-ValidPlan -SourcePath $fixtureHwt -SourceSha256 $sourceHash
        $plan1.operations = @((New-FieldOperation -Name '담당자' -Before '시험 담당자' -After '김한글'))
        $plan2 = New-ValidPlan -SourcePath $fixtureHwt -SourceSha256 $sourceHash
        $plan2.operations = @((New-FieldOperation -Name '담당자' -Before '시험 담당자' -After '박문서'))

        $result1 = Invoke-HwpGenerate -TemplatePath $fixtureHwt -Plan $plan1 -OutputPath $output1
        $result2 = Invoke-HwpGenerate -TemplatePath $fixtureHwt -Plan $plan2 -OutputPath $output2

        $result1.Status | Should Be 'PASS'
        $result2.Status | Should Be 'PASS'
        $result1.After.Fields.담당자 | Should Be '김한글'
        $result2.After.Fields.담당자 | Should Be '박문서'
        [IO.Path]::GetExtension($result1.OutputPath) | Should Be '.hwp'
        [IO.Path]::GetExtension($result2.OutputPath) | Should Be '.hwp'
        (Get-HwpSha256 -LiteralPath $fixtureHwt) | Should Be $sourceHash
    }

    It '빈 문서 계획으로 제목·본문·표를 가진 재열 수 있는 HWP를 만든다' -Skip:(-not $runNative) {
        $output = Join-Path $TestDrive '새공공문서.hwp'
        $observation = [pscustomobject]@{ SawStaging = $false }
        $inspector = {
            param($path)
            if ($path -notmatch '\.partial\.hwp$') { throw "임시 검증 경로가 아닙니다: $path" }
            if (Test-Path -LiteralPath $output) { throw '재열기 검사 전에 최종 결과가 생성되었습니다.' }
            $observation.SawStaging = $true
            Get-HwpInspection -LiteralPath $path
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

        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -Inspector $inspector

        $result.Status | Should Be 'PASS'
        $result.After.Text | Should Match '가상 공공문서'
        $result.After.Text | Should Match '안전한 빈 문서 생성 시험입니다\.'
        $result.After.Text | Should Match '항목'
        $result.After.Text | Should Match '완료'
        @($result.After.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 1
        $observation.SawStaging | Should Be $true
        Test-Path -LiteralPath $result.OutputPath | Should Be $true
    }
}
