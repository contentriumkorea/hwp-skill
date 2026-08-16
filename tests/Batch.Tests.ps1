$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$batchModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpBatch.psm1'
$helperModule = Join-Path $PSScriptRoot 'TestHelpers.psm1'
Import-Module $commonModule -Force
Import-Module $helperModule -Force
if (Test-Path -LiteralPath $batchModule) {
    Import-Module $batchModule -Force
}

function New-FakeBatchInspection {
    param([string]$LiteralPath)

    [pscustomobject]@{
        Status = 'PASS'
        Path = [IO.Path]::GetFullPath($LiteralPath)
        Sha256 = Get-HwpSha256 -LiteralPath $LiteralPath
        DetectedKind = 'HWP-BINARY'
        Text = '가상 본문'
        Fields = [pscustomobject]@{}
        Controls = @()
        PageCount = 1
        Warnings = @()
        Errors = @()
    }
}

Describe 'Invoke-HwpBatch 안전 정책' {
    It '기본값은 미리보기이며 결과 문서를 만들지 않는다' {
        $input = Join-Path $TestDrive 'input.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') -Destination $input
        $plan = New-ValidPlan -SourcePath $input -SourceSha256 (Get-HwpSha256 -LiteralPath $input)
        $applyCount = [pscustomobject]@{ Value = 0 }
        $applyInvoker = { param($path,$itemPlan,$output); $applyCount.Value++; throw '호출되면 안 됨' }.GetNewClosure()
        $inspector = { param($path) New-FakeBatchInspection -LiteralPath $path }

        $result = Invoke-HwpBatch -InputPaths @($input) -Plan $plan -Inspector $inspector -ApplyInvoker $applyInvoker

        $result.Status | Should Be 'PASS'
        $result.DryRun | Should Be $true
        @($result.Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.OutputPath) }).Count | Should Be 0
        $applyCount.Value | Should Be 0
    }

    It '드라이브 루트를 입력 폴더로 열거하지 않는다' {
        $root = [IO.Path]::GetPathRoot($TestDrive)
        $plan = New-ValidPlan

        $result = Invoke-HwpBatch -InputDirectory $root -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '루트'
    }

    It '입력 폴더 밖의 출력 폴더를 거부한다' {
        $inputDirectory = Join-Path $TestDrive 'input-dir'
        $outputDirectory = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $inputDirectory,$outputDirectory | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') `
            -Destination (Join-Path $inputDirectory 'one.hwp')
        $plan = New-ValidPlan

        $result = Invoke-HwpBatch -InputDirectory $inputDirectory -OutputDirectory $outputDirectory -Plan $plan

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '입력 폴더'
    }

    It '고급 계획은 Apply 런타임 승인 없이는 검사나 적용 전에 차단한다' {
        $input = Join-Path $TestDrive 'advanced.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') -Destination $input
        $plan = New-ValidPlan -Type 'merge-documents' -Risk 'advanced' -ApprovedAdvanced $true
        $plan.operations[0].target | Add-Member NoteProperty paths @($input)
        $applyCount = [pscustomobject]@{ Value = 0 }
        $applyInvoker = { param($path,$itemPlan,$output,$approved); $applyCount.Value++ }.GetNewClosure()

        $result = Invoke-HwpBatch -InputPaths @($input) -Plan $plan -Apply -ApplyInvoker $applyInvoker

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'ApproveAdvanced'
        $applyCount.Value | Should Be 0
    }
}

Describe '통합 CLI JSON 계약' {
    It '유효한 계획 검증은 JSON과 종료 코드 0을 반환한다' {
        $cli = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $planPath = Join-Path $TestDrive 'plan.json'
        $plan = New-ValidPlan
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $pwsh = Join-Path $PSHOME 'pwsh.exe'

        $raw = & $pwsh -NoProfile -File $cli validate-plan -PlanPath $planPath
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS'
        $json.command | Should Be 'validate-plan'
    }

    It 'preflight는 실행 컨텍스트 없이도 silent 기본값으로 BLOCKED JSON과 종료 코드 2를 반환한다' {
        $cli = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $pwsh = Join-Path $PSHOME 'pwsh.exe'

        $raw = & $pwsh -NoProfile -File $cli preflight
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 2
        $json.status | Should Be 'BLOCKED'
        $json.command | Should Be 'preflight'
        ($json.errors -join ' ') | Should Match 'interactive'
    }

    It '시험 fixture 생성기는 승인 스위치 없이 BLOCKED와 종료 코드 2를 반환한다' {
        $generator = Join-Path $PSScriptRoot 'fixtures/New-TestFixtures.ps1'
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        $outputDirectory = Join-Path $TestDrive 'fixture-output'

        $raw = & $pwsh -NoProfile -File $generator -OutputDirectory $outputDirectory
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 2
        $json.status | Should Be 'BLOCKED'
        $json.command | Should Be 'create-test-fixtures'
        ($json.errors -join ' ') | Should Match 'AllowInteractiveNative'
        Test-Path -LiteralPath (Join-Path $outputDirectory 'native-fixture.hwp') | Should Be $false
    }
}
