$commonModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpSession.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpInspect.psm1'
$planModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpPlan.psm1'
$editModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpEdit.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $sessionModule -Force
Import-Module $inspectModule -Force
Import-Module $planModule -Force
Import-Module $helperModule -Force
if (Test-Path -LiteralPath $editModule) {
    Import-Module $editModule -Force
}

function New-FakeTextSession {
    param([string]$Text)

    $hwp = [pscustomobject]@{ PlainText = $Text }
    $hwp | Add-Member ScriptMethod GetTextFile {
        param($format, $option)
        $this.PlainText
    }
    [pscustomobject]@{ Hwp = $hwp }
}

Describe 'Resolve-HwpTextTarget' {
    It '유일한 리터럴 기준 문구를 첫 번째 후보로 확정한다' {
        $session = New-FakeTextSession -Text '앞 기존 문구 뒤'
        $operation = New-Operation -Anchor '기존 문구'

        $result = Resolve-HwpTextTarget -Session $session -Operation $operation

        $result.Status | Should Be 'PASS'
        $result.Data.CandidateCount | Should Be 1
        $result.Data.AnchorOrdinal | Should Be 1
    }

    It '같은 문구가 둘인데 문맥이 없으면 적용하지 않는다' {
        $session = New-FakeTextSession -Text "중복 문구`r`n중복 문구"
        $operation = New-Operation -Anchor '중복 문구' -ExpectedMatches 1

        $result = Resolve-HwpTextTarget -Session $session -Operation $operation

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '2개'
    }

    It '앞뒤 문맥으로 두 번째 중복 문구만 확정한다' {
        $session = New-FakeTextSession -Text "A 중복 문구 X`r`nB 중복 문구 Y"
        $operation = New-Operation -Anchor '중복 문구'
        $operation | Set-OperationContext -BeforeContext 'B ' -AfterContext ' Y' | Out-Null

        $result = Resolve-HwpTextTarget -Session $session -Operation $operation

        $result.Status | Should Be 'PASS'
        $result.Data.CandidateCount | Should Be 1
        $result.Data.AnchorOrdinal | Should Be 2
    }
}

Describe 'Invoke-HwpEditOperation 정책' {
    It 'delete-range는 명시적 고급 승인 없이 실행하지 않는다' {
        $session = New-FakeTextSession -Text '삭제 대상'
        $operation = New-Operation -Type 'delete-range' -Anchor '삭제 대상' -Before '삭제 대상' -After '' -Risk 'advanced'

        $result = Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$false

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '승인'
    }
}

$fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
$runNative = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and (Test-Path -LiteralPath $fixtureHwp)

Describe 'HWP 메모리 편집 실제 한컴 통합 시험' -Tags Native {
    It '한 곳만 바꾸고 앞뒤 삽입과 필드 입력 후 별도 HWP로 저장한다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwp
        $output = Join-Path $TestDrive 'edited.hwp'
        $operations = @(
            (New-Operation -Type 'replace-text' -Anchor '기존 문구' -Before '기존 문구' -After '새 문구'),
            (New-Operation -Type 'insert-before' -Anchor '새 문구' -Before '' -After '[앞] '),
            (New-Operation -Type 'insert-after' -Anchor '안전하게 변경합니다.' -Before '' -After ' [뒤]'),
            (New-FieldOperation -Name '담당자' -Before '시험 담당자' -After '홍길동'),
            (New-Operation -Type 'delete-range' -Anchor '쪽 나누기 위치' -Before '쪽 나누기 위치' -After '' -Risk 'advanced')
        )

        $session = New-HwpSession
        try {
            $open = Open-HwpDocumentFromMemory -Session $session -LiteralPath $fixtureHwp
            $open.Status | Should Be 'PASS'
            $operationResults = @(
                foreach ($operation in $operations) {
                    Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$true
                }
            )
            @($operationResults | Where-Object Status -ne 'PASS').Count | Should Be 0
            $saved = Save-HwpMemoryDocument -Session $session -SourcePath $fixtureHwp -OutputPath $output
            $saved.Status | Should Be 'PASS'
        }
        finally {
            Close-HwpSession -Session $session
        }

        $after = Get-HwpInspection -LiteralPath $output
        $after.Status | Should Be 'PASS'
        $after.Text | Should Match '\[앞\] 새 문구를 안전하게 변경합니다\. \[뒤\]'
        $after.Text | Should Not Match '기존 문구'
        $after.Text | Should Not Match '쪽 나누기 위치'
        $after.Fields.담당자 | Should Be '홍길동'
        (Get-HwpSha256 -LiteralPath $fixtureHwp) | Should Be $sourceHash
        $output | Should Not Be $fixtureHwp
    }
}
