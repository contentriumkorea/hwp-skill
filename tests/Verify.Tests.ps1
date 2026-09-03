$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilitiesModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$verifyModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpVerify.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $executionModule -Force
Import-Module $capabilitiesModule -Force
Import-Module $helperModule -Force
if (Test-Path -LiteralPath $verifyModule) {
    Import-Module $verifyModule -Force
}

function New-CompareInspection {
    param(
        [string]$Text = '본문',
        [int]$PageCount = 1,
        [string[]]$ControlIds = @('tbl'),
        [hashtable]$Fields = @{}
    )

    $controls = @($ControlIds | ForEach-Object { [pscustomobject]@{ CtrlId = $_ } })
    [pscustomobject]@{
        Text = $Text
        PageCount = $PageCount
        Controls = $controls
        Fields = [pscustomobject]$Fields
    }
}

function New-FakeExportSession {
    $hwp = [pscustomobject]@{ PageCount = 1 }
    $hwp | Add-Member ScriptMethod SetTextFile {
        param($base64, $format, $option)
        1
    }
    $hwp | Add-Member ScriptMethod RegisterModule {
        param($kind, $name)
        $true
    }
    $hwp | Add-Member ScriptMethod SaveAs {
        param($path, $format, $option)
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n%%EOF`n"))
        $true
    }
    $hwp | Add-Member ScriptMethod CreatePageImage {
        param($path, $page, $resolution, $depth, $format)
        Add-Type -AssemblyName System.Drawing
        $bitmap = [Drawing.Bitmap]::new(8, 8)
        try { $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Bmp) }
        finally { $bitmap.Dispose() }
        $true
    }
    $hwp | Add-Member ScriptMethod GetPageText {
        param($page, $option)
        '가상 페이지'
    }
    [pscustomobject]@{
        Hwp = $hwp
        Version = 'fake'
        Owned = $false
        Closed = $false
    }
}

Describe 'Compare-HwpInspection' {
    It '예상하지 않은 표 감소를 FAILED로 반환한다' {
        $before = New-CompareInspection -ControlIds @('tbl')
        $after = New-CompareInspection -ControlIds @()

        $result = Compare-HwpInspection -Before $before -After $after -ExpectedOperations @()

        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'tbl'
    }

    It '계획에 없는 큰 쪽 수 변화를 경고한다' {
        $before = New-CompareInspection -PageCount 1
        $after = New-CompareInspection -PageCount 4

        $result = Compare-HwpInspection -Before $before -After $after -ExpectedOperations @()

        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        ($result.Warnings -join ' ') | Should Match '쪽 수'
    }

    It '원본 필드가 사라지면 FAILED로 반환한다' {
        $before = New-CompareInspection -Fields @{ 담당자 = '홍길동' }
        $after = New-CompareInspection -Fields @{}

        $result = Compare-HwpInspection -Before $before -After $after -ExpectedOperations @()

        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match '담당자'
    }
}

Describe '내보내기 안전 래퍼' {
    $fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'

    It 'silent PDF 내보내기는 세션 팩터리를 호출하지 않는다' {
        $output = Join-Path $TestDrive 'silent-export.pdf'
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

        $result = Export-HwpPdf -LiteralPath $fixtureHwp -OutputPath $output `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities `
            -SessionFactory $factory -SecurityModuleReader { @('FakeModule') }

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'silent'
        $calls.Value | Should Be 0
    }

    It 'silent 페이지 이미지 내보내기는 세션 팩터리를 호출하지 않는다' {
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

        $result = Export-HwpPageImages -LiteralPath $fixtureHwp -ImageDirectory $TestDrive `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities `
            -SessionFactory $factory -SecurityModuleReader { @('FakeModule') }

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'silent'
        $calls.Value | Should Be 0
    }

    It '승인된 가상 세션에서 PDF 시그니처를 검증하고 별도 파일을 만든다' {
        $output = Join-Path $TestDrive 'export.pdf'
        $factory = { New-FakeExportSession }
        $hwpExecutionContext = New-TestInteractiveExecutionContext
        $capabilities = [pscustomobject]@{
            executionMode = 'interactive'
            backends = @(
                [pscustomobject]@{ id = 'hwpx-direct'; available = $true; formats = @('HWPX-ZIP'); operations = @('inspect'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hwp-portable'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-isolated'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'separate-session'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-interactive'; available = $true; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'current-session'; reason = 'test' }
            )
        }

        $result = Export-HwpPdf -LiteralPath $fixtureHwp -OutputPath $output `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities `
            -SessionFactory $factory -SecurityModuleReader { @('FakeModule') }

        $result.Status | Should Be 'PASS'
        Test-Path -LiteralPath $result.Data.PdfPath | Should Be $true
        [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($result.Data.PdfPath), 0, 5) | Should Be '%PDF-'
    }

    It '승인된 가상 세션에서 쪽 수만큼 PNG를 만든다' {
        $factory = { New-FakeExportSession }
        $hwpExecutionContext = New-TestInteractiveExecutionContext
        $capabilities = [pscustomobject]@{
            executionMode = 'interactive'
            backends = @(
                [pscustomobject]@{ id = 'hwpx-direct'; available = $true; formats = @('HWPX-ZIP'); operations = @('inspect'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hwp-portable'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-isolated'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'separate-session'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-interactive'; available = $true; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'current-session'; reason = 'test' }
            )
        }

        $result = Export-HwpPageImages -LiteralPath $fixtureHwp -ImageDirectory $TestDrive `
            -ExecutionContext $hwpExecutionContext -Capabilities $capabilities `
            -SessionFactory $factory -SecurityModuleReader { @('FakeModule') }

        $result.Status | Should Be 'PASS'
        @($result.Data.PageImages).Count | Should Be 1
        Test-Path -LiteralPath $result.Data.PageImages[0] | Should Be $true
        [BitConverter]::ToString([IO.File]::ReadAllBytes($result.Data.PageImages[0]), 0, 8) | Should Be '89-50-4E-47-0D-0A-1A-0A'
    }
}
