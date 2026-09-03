$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$planModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPlan.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $helperModule -Force
if (Test-Path -LiteralPath $planModule) {
    Import-Module $planModule -Force
}

Describe 'Test-HwpEditPlan' {
    It '유효하고 단일 일치인 safe 계획을 허용한다' {
        $plan = New-ValidPlan

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'PASS'
        $result.Data.OperationCount | Should Be 1
    }

    It 'expectedMatches가 1이 아닌 safe 작업을 거부한다' {
        $plan = New-ValidPlan
        $plan.operations[0].expectedMatches = 2

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'expectedMatches'
    }

    It 'advanced 작업은 approvedAdvanced=true가 아니면 거부한다' {
        $plan = New-ValidPlan -Type 'merge-documents' -Risk 'advanced' -ApprovedAdvanced $false

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '승인'
    }

    It '승인된 advanced 작업을 허용한다' {
        $plan = New-ValidPlan -Type 'merge-documents' -Risk 'advanced' -ApprovedAdvanced $true
        $plan.operations[0].target | Add-Member NoteProperty paths @('C:\fixture.hwp')

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'PASS'
        $result.Data.AdvancedOperationCount | Should Be 1
    }

    It '중복 작업 ID를 거부한다' {
        $plan = New-ValidPlan
        $second = New-Operation -Type 'insert-after' -Anchor '기존 문구' -Before '' -After '추가'
        $second.id = $plan.operations[0].id
        $plan.operations = @($plan.operations[0], $second)

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '중복'
    }

    It '빈 기준 문구를 거부한다' {
        $plan = New-ValidPlan
        $plan.operations[0].target.anchor = ''

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '기준 문구'
    }

    It '미지원 작업을 거부한다' {
        $plan = New-ValidPlan -Type 'run-macro'

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '지원하지 않는 작업'
    }

    It '독립 export 명령을 편집 계획 작업으로 허용하지 않는다' {
        $plan = New-ValidPlan -Type 'export'

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '지원하지 않는 작업'
    }

    It '정의된 위험도와 다른 risk 값을 거부한다' {
        $plan = New-ValidPlan -Type 'replace-text' -Risk 'advanced' -ApprovedAdvanced $true

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '위험 등급'
    }

    It '잘못된 SHA-256과 실패 정책을 함께 보고한다' {
        $plan = New-ValidPlan
        $plan.source.sha256 = 'not-a-hash'
        $plan.operations[0].onFailure = 'continue'

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'SHA-256'
        ($result.Errors -join ' ') | Should Match 'onFailure'
    }

    It '작업 목록이 비어 있으면 거부한다' {
        $plan = New-ValidPlan
        $plan.operations = @()

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '하나 이상'
    }
}

Describe 'Import-HwpEditPlan' {
    It 'UTF-8 JSON 계획을 읽고 검증 결과와 계획을 반환한다' {
        $path = Join-Path $TestDrive 'plan.json'
        $plan = New-ValidPlan
        [IO.File]::WriteAllText($path, ($plan | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

        $result = Import-HwpEditPlan -LiteralPath $path

        $result.Status | Should Be 'PASS'
        $result.Data.Plan.version | Should Be '1.0'
    }

    It '구문이 깨진 JSON을 예외 대신 BLOCKED로 반환한다' {
        $path = Join-Path $TestDrive 'broken.json'
        [IO.File]::WriteAllText($path, '{ broken', [Text.UTF8Encoding]::new($false))

        $result = Import-HwpEditPlan -LiteralPath $path

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'JSON'
    }
}

Describe 'Assert-HwpOperationAllowed' {
    It '고급 작업 단독 검사도 명시적 승인 없이는 BLOCKED다' {
        $operation = New-Operation -Type 'delete-range' -Risk 'advanced'

        $result = Assert-HwpOperationAllowed -Operation $operation -ApprovedAdvanced:$false

        $result.Status | Should Be 'BLOCKED'
    }
}

Describe 'Assert-HwpRuntimeAdvancedApproval' {
    It '계획 파일 자체의 승인만으로 고급 작업 실행을 허용하지 않는다' {
        $plan = New-ValidPlan -Type 'merge-documents' -Risk 'advanced' -ApprovedAdvanced $true

        $result = Assert-HwpRuntimeAdvancedApproval -Plan $plan -ApproveAdvanced:$false

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'ApproveAdvanced'
    }

    It '계획 기록과 런타임 승인이 모두 있으면 고급 작업을 허용한다' {
        $plan = New-ValidPlan -Type 'merge-documents' -Risk 'advanced' -ApprovedAdvanced $true

        $result = Assert-HwpRuntimeAdvancedApproval -Plan $plan -ApproveAdvanced:$true

        $result.Status | Should Be 'PASS'
    }
}

Describe '작업별 대상 필드 검증' {
    It 'set-field 계획에 fieldName이 없으면 적용 전에 차단한다' {
        $plan = New-ValidPlan -Type 'set-field'

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'fieldName'
    }

    It '글자 서식 변경 값이 하나도 없으면 적용 전에 차단한다' {
        $plan = New-ValidPlan -Type 'apply-char-style'

        $result = Test-HwpEditPlan -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'heightPt|bold|italic'
    }
}
