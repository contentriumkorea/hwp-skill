$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpInspect.psm1'
$planModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpPlan.psm1'
$editModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpEdit.psm1'
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

    It 'set-section은 명시적 고급 승인 없이 실행하지 않는다' {
        $session = New-FakeTextSession -Text '구역 설정 위치'
        $operation = New-SectionOperation -Anchor '구역 설정 위치' -Orientation landscape

        $result = Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$false

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '승인'
    }

    It 'merge-documents는 명시적 고급 승인 없이 실행하지 않는다' {
        $session = New-FakeTextSession -Text '병합 대상'
        $operation = New-MergeOperation -Paths @('C:\fixture.hwp')

        $result = Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$false

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '승인'
    }
}

Describe 'Invoke-HwpApply 사전 차단' {
    It '계획의 원본 SHA-256이 다르면 한컴 세션을 만들기 전에 차단한다' {
        $path = Join-Path $TestDrive 'source.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') -Destination $path
        $plan = New-ValidPlan -SourcePath $path -SourceSha256 ('0' * 64)
        $factoryCount = [pscustomobject]@{ Value = 0 }
        $factory = { $factoryCount.Value++; throw '호출되면 안 됨' }.GetNewClosure()

        $result = Invoke-HwpApply -LiteralPath $path -Plan $plan -SessionFactory $factory

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'SHA-256'
        $factoryCount.Value | Should Be 0
    }

    It '원본과 같은 출력 경로를 거부한다' {
        $path = Join-Path $TestDrive 'same.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') -Destination $path
        $plan = New-ValidPlan -SourcePath $path -SourceSha256 (Get-HwpSha256 -LiteralPath $path)

        $result = Invoke-HwpApply -LiteralPath $path -Plan $plan -OutputPath $path

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '원본'
    }
}

Describe '이미지 경로 접근 정책' {
    It '등록된 보안 모듈이 없으면 이미지 파일 접근 전에 BLOCKED로 반환한다' {
        $session = New-FakeTextSession -Text '이미지 삽입 위치'
        $image = Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'
        $operation = New-InsertImageOperation -Path $image

        $result = Invoke-HwpInsertImage -Session $session -Operation $operation -SecurityModuleReader { @() }

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '보안 모듈'
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

        $session = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
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

Describe 'HWP 원자적 계획 적용 실제 한컴 통합 시험' -Tags Atomic,Native {
    It '성공한 계획만 최종 경로로 승격하고 원본 SHA-256을 보존한다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwp
        $output = Join-Path $TestDrive 'atomic-success.hwp'
        $plan = New-ValidPlan -SourcePath $fixtureHwp -SourceSha256 $sourceHash

        $result = Invoke-HwpApply -LiteralPath $fixtureHwp -Plan $plan -OutputPath $output

        $result.Status | Should Be 'PASS'
        $result.OutputPath | Should Be ([IO.Path]::GetFullPath($output))
        Test-Path -LiteralPath $result.OutputPath | Should Be $true
        $result.Inspection.Text | Should Match '새 문구'
        (Get-HwpSha256 -LiteralPath $fixtureHwp) | Should Be $sourceHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.partial.hwp').Count | Should Be 0
    }

    It '후조건 실패 시 완료 경로를 만들지 않고 실패 산출물을 분리한다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwp
        $output = Join-Path $TestDrive 'atomic-failure.hwp'
        $plan = New-ValidPlan -SourcePath $fixtureHwp -SourceSha256 $sourceHash
        $plan.operations[0].verify.expected = '존재하지 않는 결과'

        $result = Invoke-HwpApply -LiteralPath $fixtureHwp -Plan $plan -OutputPath $output

        $result.Status | Should Be 'FAILED'
        Test-Path -LiteralPath $result.OutputPath | Should Be $false
        Test-Path -LiteralPath $result.FailedArtifactPath | Should Be $true
        (Get-HwpSha256 -LiteralPath $fixtureHwp) | Should Be $sourceHash
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.partial.hwp').Count | Should Be 0
    }
}

Describe 'HWP 표 구조 편집 실제 한컴 통합 시험' -Tags Native,Structure {
    It '표를 추가하고 지정 셀을 채운 뒤 승인된 행을 추가한다' -Skip:(-not $runNative) {
        $output = Join-Path $TestDrive 'table-edit.hwp'
        $operations = @(
            (New-InsertTableOperation -Anchor '표 삽입 위치' -Rows 2 -Columns 2),
            (New-TableCellOperation -TableIndex 2 -Row 1 -Column 1 -After '첫 셀'),
            (New-AddTableRowOperation -TableIndex 2 -AfterRow 2),
            (New-TableCellOperation -TableIndex 2 -Row 3 -Column 1 -After '추가 행')
        )

        $session = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $session -LiteralPath $fixtureHwp).Status | Should Be 'PASS'
            $results = @(
                foreach ($operation in $operations) {
                    Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$true
                }
            )
            @($results | Where-Object Status -ne 'PASS').Count | Should Be 0
            (Save-HwpMemoryDocument -Session $session -SourcePath $fixtureHwp -OutputPath $output).Status | Should Be 'PASS'
        }
        finally {
            Close-HwpSession -Session $session
        }

        $after = Get-HwpInspection -LiteralPath $output
        $after.Status | Should Be 'PASS'
        @($after.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 2
        $after.Text | Should Match '첫 셀'
        $after.Text | Should Match '추가 행'
    }
}

Describe 'HWP 서식과 문서 구조 편집 실제 한컴 통합 시험' -Tags Native,Structure {
    It '글자·문단 서식과 쪽 나누기를 적용하고 재열어서 확인한다' -Skip:(-not $runNative) {
        $output = Join-Path $TestDrive 'format-and-break.hwp'
        $before = Get-HwpInspection -LiteralPath $fixtureHwp
        $operations = @(
            (New-CharStyleOperation -Anchor 'HWP 스킬 통합 시험' -HeightPt 14 -Bold $true),
            (New-ParaStyleOperation -Anchor 'HWP 스킬 통합 시험' -Align center),
            (New-PageBreakOperation -Anchor '쪽 나누기 위치' -Placement after)
        )

        $session = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $session -LiteralPath $fixtureHwp).Status | Should Be 'PASS'
            $results = @(
                foreach ($operation in $operations) {
                    Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$true
                }
            )
            @($results | Where-Object Status -ne 'PASS').Count | Should Be 0
            (Save-HwpMemoryDocument -Session $session -SourcePath $fixtureHwp -OutputPath $output).Status | Should Be 'PASS'
        }
        finally {
            Close-HwpSession -Session $session
        }

        $reopened = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $reopened -LiteralPath $output).Status | Should Be 'PASS'
            $snapshot = Get-HwpTextStyleSnapshot -Session $reopened -Operation (New-Operation -Anchor 'HWP 스킬 통합 시험')
            $snapshot.Status | Should Be 'PASS'
            $snapshot.Data.HeightPt | Should Be 14
            $snapshot.Data.Bold | Should Be $true
            $snapshot.Data.Align | Should Be 'center'
        }
        finally {
            Close-HwpSession -Session $reopened
        }

        $after = Get-HwpInspection -LiteralPath $output
        $after.PageCount | Should Be ($before.PageCount + 1)
    }

    It '승인된 구역 설정과 머리말·꼬리말·쪽 번호를 적용한다' -Skip:(-not $runNative) {
        $output = Join-Path $TestDrive 'section-and-header.hwp'
        $operations = @(
            (New-SectionOperation -Anchor 'HWP 스킬 통합 시험' -Orientation landscape -LeftMarginMm 16 -RightMarginMm 16),
            (New-HeaderFooterOperation -Anchor 'HWP 스킬 통합 시험' -Kind header -Text '가상 머리말'),
            (New-HeaderFooterOperation -Anchor 'HWP 스킬 통합 시험' -Kind footer -Text '가상 꼬리말'),
            (New-PageNumberOperation -Anchor 'HWP 스킬 통합 시험' -Position bottom-center -StartNumber 1)
        )

        $session = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $session -LiteralPath $fixtureHwp).Status | Should Be 'PASS'
            $results = @(
                foreach ($operation in $operations) {
                    Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$true
                }
            )
            @($results | Where-Object Status -ne 'PASS').Count | Should Be 0
            (Save-HwpMemoryDocument -Session $session -SourcePath $fixtureHwp -OutputPath $output).Status | Should Be 'PASS'
        }
        finally {
            Close-HwpSession -Session $session
        }

        $reopened = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $reopened -LiteralPath $output).Status | Should Be 'PASS'
            $section = Get-HwpSectionSnapshot -Session $reopened -Operation (New-Operation -Anchor 'HWP 스킬 통합 시험')
            $section.Status | Should Be 'PASS'
            $section.Data.Orientation | Should Be 'landscape'
            [Math]::Round($section.Data.LeftMarginMm, 1) | Should Be 16

            $headerFooter = Get-HwpHeaderFooterTextSnapshot -Session $reopened
            $headerFooter.Status | Should Be 'PASS'
            @($headerFooter.Data.Items | Where-Object { $_.Kind -eq 'header' -and $_.Text -eq '가상 머리말' }).Count | Should Be 1
            @($headerFooter.Data.Items | Where-Object { $_.Kind -eq 'footer' -and $_.Text -eq '가상 꼬리말' }).Count | Should Be 1
        }
        finally {
            Close-HwpSession -Session $reopened
        }

        $after = Get-HwpInspection -LiteralPath $output
        @($after.Controls | Where-Object CtrlId -eq 'head').Count | Should Be 1
        @($after.Controls | Where-Object CtrlId -eq 'foot').Count | Should Be 1
        @($after.Controls | Where-Object CtrlId -eq 'pgnp').Count | Should Be 1
    }
}

Describe 'HWP 참조 개체 편집 실제 한컴 통합 시험' -Tags Native,Reference {
    It '캡션·각주·미주·하이퍼링크·책갈피를 넣고 재열어서 확인한다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwp
        $output = Join-Path $TestDrive 'reference-objects.hwp'
        $operations = @(
            (New-CaptionOperation -ControlId tbl -ControlIndex 1 -Text '시험 표 캡션'),
            (New-NoteOperation -Type add-footnote -Anchor '쪽 나누기 위치' -Text '각주 시험 내용'),
            (New-NoteOperation -Type add-endnote -Anchor '이미지 삽입 위치' -Text '미주 시험 내용'),
            (New-HyperlinkOperation -Anchor '기존 문구' -Url 'https://example.com/hwp-test'),
            (New-BookmarkOperation -Anchor 'HWP 스킬 통합 시험' -Name '통합시험_제목')
        )

        $session = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $session -LiteralPath $fixtureHwp).Status | Should Be 'PASS'
            $results = @(
                foreach ($operation in $operations) {
                    Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$true
                }
            )
            @($results | Where-Object Status -ne 'PASS').Count | Should Be 0
            (Save-HwpMemoryDocument -Session $session -SourcePath $fixtureHwp -OutputPath $output).Status | Should Be 'PASS'
        }
        finally {
            Close-HwpSession -Session $session
        }

        $after = Get-HwpInspection -LiteralPath $output
        $after.Status | Should Be 'PASS'
        $after.Text | Should Match '시험 표 캡션'
        $after.Text | Should Match '각주 시험 내용'
        $after.Text | Should Match '미주 시험 내용'
        @($after.Controls | Where-Object CtrlId -eq '%hlk').Count | Should Be 1
        @($after.Controls | Where-Object CtrlId -eq '%bmk').Count | Should Be 1
        @($after.Controls | Where-Object CtrlId -eq 'fn').Count | Should Be 1
        @($after.Controls | Where-Object CtrlId -eq 'en').Count | Should Be 1
        (Get-HwpSha256 -LiteralPath $fixtureHwp) | Should Be $sourceHash
    }

    It '안전한 수동 차례를 만들고 HWP를 메모리 방식으로 병합한다' -Skip:(-not $runNative) {
        $sourceHash = Get-HwpSha256 -LiteralPath $fixtureHwp
        $output = Join-Path $TestDrive 'toc-and-merge.hwp'
        $operations = @(
            (New-TocOperation -Anchor '쪽 나누기 위치' -HeadingAnchors @('HWP 스킬 통합 시험','표 삽입 위치') -Title '차례'),
            (New-MergeOperation -Paths @($fixtureHwp) -PageBreakBetween $true -VerifyText '기존 문구' -VerifyCount 2)
        )

        $session = New-HwpSession -ExecutionContext (New-TestInteractiveExecutionContext)
        try {
            (Open-HwpDocumentFromMemory -Session $session -LiteralPath $fixtureHwp).Status | Should Be 'PASS'
            $results = @(
                foreach ($operation in $operations) {
                    Invoke-HwpEditOperation -Session $session -Operation $operation -ApprovedAdvanced:$true
                }
            )
            @($results | Where-Object Status -ne 'PASS').Count | Should Be 0
            (Save-HwpMemoryDocument -Session $session -SourcePath $fixtureHwp -OutputPath $output).Status | Should Be 'PASS'
        }
        finally {
            Close-HwpSession -Session $session
        }

        $after = Get-HwpInspection -LiteralPath $output
        $after.Status | Should Be 'PASS'
        $after.Text | Should Match '차례'
        $after.Text | Should Match "HWP 스킬 통합 시험\t1"
        ([regex]::Matches($after.Text, [regex]::Escape('기존 문구'))).Count | Should Be 2
        $after.PageCount | Should BeGreaterThan 1
        (Get-HwpSha256 -LiteralPath $fixtureHwp) | Should Be $sourceHash
    }
}
