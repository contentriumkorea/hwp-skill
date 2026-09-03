$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$executionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilitiesModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$editModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpEdit.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $executionModule -Force
Import-Module $capabilitiesModule -Force
Import-Module $helperModule -Force
Import-Module $editModule -Force

function New-FakeAtomicApplySession {
    param([Parameter(Mandatory)][byte[]]$DocumentBytes)

    $hwp = [pscustomobject]@{
        FieldValue = '시험 담당자'
        DocumentBase64 = [Convert]::ToBase64String($DocumentBytes)
    }
    $hwp | Add-Member ScriptMethod SetTextFile { param($data, $format, $option) 1 }
    $hwp | Add-Member ScriptMethod GetFieldList { param($number, $option) '담당자' }
    $hwp | Add-Member ScriptMethod GetFieldText { param($name) $this.FieldValue }
    $hwp | Add-Member ScriptMethod PutFieldText {
        param($name, $value)
        $this.FieldValue = [string]$value
        $true
    }
    $hwp | Add-Member ScriptMethod GetTextFile {
        param($format, $option)
        if ($format -eq 'HWP') { return $this.DocumentBase64 }
        '가짜 재열기 본문'
    }

    [pscustomobject]@{
        Hwp = $hwp
        Owned = $false
        Closed = $false
    }
}

Describe 'Invoke-HwpApply 저장 후 재검사 컨텍스트' {
    It '승인 컨텍스트와 기능 스냅샷을 save, reopen, promote 전체에 보존한다' {
        $sourcePath = Join-Path $TestDrive 'source.hwp'
        $outputPath = Join-Path $TestDrive 'promoted.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') -Destination $sourcePath
        $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
        $sourceHash = Get-HwpSha256 -LiteralPath $sourcePath
        $approvedContext = New-TestInteractiveExecutionContext
        $capabilities = [pscustomobject]@{
            schemaVersion = '1.0'
            executionMode = 'interactive'
            backends = @(
                [pscustomobject]@{ id = 'hwpx-direct'; available = $true; formats = @('HWPX-ZIP'); operations = @('inspect'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hwp-portable'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify'); requiresGui = $false; isolation = 'none'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-isolated'; available = $false; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'separate-session'; reason = 'test' },
                [pscustomobject]@{ id = 'hancom-interactive'; available = $true; formats = @('HWP-BINARY'); operations = @('inspect','generate','apply','batch','verify','export'); requiresGui = $true; isolation = 'current-session'; reason = 'test' }
            )
        }
        $plan = New-ValidPlan -SourcePath $sourcePath -SourceSha256 $sourceHash
        $plan.operations = @((New-FieldOperation -Name '담당자' -Before '시험 담당자' -After '홍길동'))
        $observation = [pscustomobject]@{
            SessionContextPreserved = $false
            InspectionContextPreserved = $false
            CapabilitiesPreserved = $false
            SawStagingBeforePromotion = $false
        }
        $session = New-FakeAtomicApplySession -DocumentBytes $sourceBytes
        $sessionFactory = ({
            param($executionContext)
            $observation.SessionContextPreserved = [object]::ReferenceEquals($executionContext, $approvedContext)
            $session
        }.GetNewClosure())
        $inspector = ({
            param($path, $executionContext, $snapshot)
            $observation.InspectionContextPreserved = [object]::ReferenceEquals($executionContext, $approvedContext)
            $observation.CapabilitiesPreserved = [object]::ReferenceEquals($snapshot, $capabilities)
            $observation.SawStagingBeforePromotion =
                $path -match '\.partial\.hwp$' -and
                (Test-Path -LiteralPath $path -PathType Leaf) -and
                -not (Test-Path -LiteralPath $outputPath)
            [pscustomobject]@{
                Status = 'PASS'
                Text = '가짜 재열기 본문'
                Fields = [pscustomobject]@{ 담당자 = '홍길동' }
                Controls = @()
                Warnings = @()
                Errors = @()
                Path = $path
            }
        }.GetNewClosure())

        $result = Invoke-HwpApply -LiteralPath $sourcePath -Plan $plan -OutputPath $outputPath `
            -ExecutionContext $approvedContext -Capabilities $capabilities `
            -SessionFactory $sessionFactory -Inspector $inspector

        $result.Status | Should Be 'PASS'
        $observation.SessionContextPreserved | Should Be $true
        $observation.InspectionContextPreserved | Should Be $true
        $observation.CapabilitiesPreserved | Should Be $true
        $observation.SawStagingBeforePromotion | Should Be $true
        Test-Path -LiteralPath $outputPath -PathType Leaf | Should Be $true
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.partial.hwp').Count | Should Be 0
        (Get-HwpSha256 -LiteralPath $sourcePath) | Should Be $sourceHash
    }
}
