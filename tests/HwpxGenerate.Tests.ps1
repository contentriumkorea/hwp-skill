$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilityModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1'
$generateModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1'
$hwpxModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpx.psm1'
$convertModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpConvert.psm1'
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
                [pscustomobject]@{ type = 'paragraph'; text = "줄바꿈 문단 첫 줄`n줄바꿈 문단 둘째 줄" }
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
        $result.After.Text | Should Match '줄바꿈 문단 첫 줄'
        $result.After.Text | Should Match '줄바꿈 문단 둘째 줄'
        @($result.After.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 1
        @($result.After.Controls | Where-Object CtrlId -eq 'pic').Count | Should Be 1
    }

    It '글꼴·문단·표 테두리·용지 설정을 HWPX에 직접 기록하고 다시 구조 검사한다' {
        $output = Join-Path $TestDrive 'styled.hwpx'
        $plan = [pscustomobject]@{
            version = '1.0'
            title = '서식 HWPX 시험'
            document = [pscustomobject]@{
                page = [pscustomobject]@{
                    orientation = 'LANDSCAPE'
                    widthMm = 297
                    heightMm = 210
                    margins = [pscustomobject]@{
                        leftMm = 18
                        rightMm = 19
                        topMm = 20
                        bottomMm = 21
                        headerMm = 12
                        footerMm = 13
                        gutterMm = 2
                    }
                }
                textStyle = [pscustomobject]@{
                    fontFamily = 'Noto Sans KR'
                    fontSizePt = 11
                    textColor = '#123456'
                }
                paragraphStyle = [pscustomobject]@{
                    alignment = 'JUSTIFY'
                    lineSpacingPercent = 170
                }
                tableStyle = [pscustomobject]@{
                    borderType = 'DASH'
                    borderWidthMm = 0.3
                    borderColor = '#445566'
                    fillColor = '#F0F1F2'
                    cellPaddingMm = 2
                }
            }
            content = @(
                [pscustomobject]@{
                    type = 'paragraph'
                    text = '서식 있는 제목'
                    textStyle = [pscustomobject]@{
                        fontFamily = 'Pretendard'
                        fontSizePt = 18
                        bold = $true
                        italic = $true
                        textColor = '#112233'
                    }
                    paragraphStyle = [pscustomobject]@{
                        alignment = 'CENTER'
                        lineSpacingPercent = 145
                        marginAfterMm = 3
                    }
                }
                [pscustomobject]@{
                    type = 'table'
                    rows = 1
                    columns = 1
                    cells = @(
                        [pscustomobject]@{
                            row = 1
                            column = 1
                            text = '서식 셀'
                            style = [pscustomobject]@{ cellPaddingMm = 4 }
                        }
                    )
                }
            )
        }
        $context = New-HwpExecutionContext
        $capabilities = Get-HwpCapabilitySnapshot -ExecutionContext $context -NativeRegistrationProbe { $false } -PortableBackendProbe { $false } -IsolatedWorkerProbe { $false }
        $sessionCalls = [pscustomobject]@{ Value = 0 }
        $sessionFactory = ({ param($ignored) $sessionCalls.Value++; throw '세션 호출 금지' }.GetNewClosure())

        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -ExecutionContext $context -Capabilities $capabilities -SessionFactory $sessionFactory

        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $sessionCalls.Value | Should Be 0
        (@($result.After.Resources.Fonts.Name) -contains 'Pretendard') | Should Be $true
        $titleParagraph = @($result.After.Paragraphs | Where-Object Text -eq '서식 있는 제목')[0]
        $titleCharShape = @($result.After.Resources.CharShapes | Where-Object Id -eq $titleParagraph.CharShapeRuns[0].CharShapeId)[0]
        $titleCharShape.ResolvedFontNames.Hangul | Should Be 'Pretendard'
        $titleCharShape.FontSizePt | Should Be 18
        $titleCharShape.Attributes.Bold | Should Be $true
        $titleCharShape.Attributes.Italic | Should Be $true
        $titleCharShape.TextColor | Should Be '#112233'
        $titleParaShape = @($result.After.Resources.ParaShapes | Where-Object Id -eq $titleParagraph.ParaShapeId)[0]
        $titleParaShape.Alignment | Should Be 'CENTER'
        $titleParaShape.LineSpacing.Value | Should Be 145
        $result.After.Sections[0].PageDefinitions[0].Orientation | Should Be 'LANDSCAPE'
        [Math]::Round($result.After.Sections[0].PageDefinitions[0].Width.Millimeter, 1) | Should Be 297
        [Math]::Round($result.After.Sections[0].PageDefinitions[0].Margins.Left.Millimeter, 1) | Should Be 18
        $table = $result.After.Tables[0]
        $tableBorder = @($result.After.Resources.BorderFills | Where-Object Id -eq $table.BorderFillId)[0]
        $tableBorder.Borders.Left.Type | Should Be 'DASH'
        $tableBorder.Borders.Left.WidthMm | Should Be 0.3
        $tableBorder.Borders.Left.Color | Should Be '#445566'
        $tableBorder.Fill.Solid.BackgroundColor | Should Be '#F0F1F2'
        $table.Cells[0].Margins.Left | Should Be 1134
        $table.Cells[0].Margins.Right | Should Be 1134
    }

    It '잘못된 색상과 용지 방향을 작성 전에 거부한다' {
        $plan = [pscustomobject]@{
            version = '1.0'
            document = [pscustomobject]@{
                page = [pscustomobject]@{ orientation = 'SIDEWAYS' }
                textStyle = [pscustomobject]@{ textColor = 'red' }
            }
            content = @([pscustomobject]@{ type = 'paragraph'; text = '거부 시험' })
        }

        $validation = Test-HwpNewDocumentPlan -Plan $plan

        $validation.Status | Should Be 'BLOCKED'
        ($validation.Errors -join ' ') | Should Match 'orientation'
        ($validation.Errors -join ' ') | Should Match 'textColor'
    }

    It '최종 HWP 변환은 별도 작업자 계약으로만 결과를 승격한다' {
        $input = Join-Path $TestDrive 'input.hwpx'
        $output = Join-Path $TestDrive 'output.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $input
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
