$cli = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'

Describe 'HWP 공용 CLI 실행 모드' {
    It 'capabilities 기본 실행 모드는 silent다' {
        $raw = & $pwsh -NoProfile -File $cli capabilities
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS'
        $json.command | Should Be 'capabilities'
        $json.data.executionMode | Should Be 'silent'
    }

    It 'silent preflight는 한컴 설치를 필수 조건으로 만들지 않는다' {
        $raw = & $pwsh -NoProfile -File $cli preflight
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS'
        $json.command | Should Be 'preflight'
        $json.data.executionMode | Should Be 'silent'
    }

    It 'interactive는 창 허용 스위치 없이는 실패한다' {
        $raw = & $pwsh -NoProfile -File $cli capabilities -ExecutionMode interactive
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 1
        $json.status | Should Be 'FAILED'
        ($json.errors -join ' ') | Should Match 'AllowInteractiveWindow'
    }

    It 'interactive preflight는 창 허용 스위치 없이는 실패한다' {
        $raw = & $pwsh -NoProfile -File $cli preflight -ExecutionMode interactive
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 1
        $json.status | Should Be 'FAILED'
        $json.command | Should Be 'preflight'
        ($json.errors -join ' ') | Should Match 'AllowInteractiveWindow'
    }

    It 'silent inspect는 HWP 바이너리를 한컴 프로세스 없이 읽는다' {
        $fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $beforeProcessIds = @(Get-Process -Name Hwp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

        $raw = & $pwsh -NoProfile -File $cli inspect -LiteralPath $fixtureHwp
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json
        $afterProcessIds = @(Get-Process -Name Hwp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS_WITH_WARNINGS'
        $json.detectedKind | Should Be 'HWP-BINARY'
        $json.text | Should Match 'HWP 네이티브 통합 시험'
        @($afterProcessIds) -join ',' | Should Be (@($beforeProcessIds) -join ',')
    }

    It 'Windows PowerShell 5.1에서도 HWP 바이너리를 한컴 없이 읽는다' `
        -Skip:(-not (Test-Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) {
        $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $beforeProcessIds = @(Get-Process -Name Hwp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

        $raw = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $cli inspect -LiteralPath $fixtureHwp
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json
        $afterProcessIds = @(Get-Process -Name Hwp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS_WITH_WARNINGS'
        $json.text | Should Match 'HWP 네이티브 통합 시험'
        @($afterProcessIds) -join ',' | Should Be (@($beforeProcessIds) -join ',')
    }

    It 'Windows PowerShell 5.1에서도 서식 계획으로 HWPX를 직접 작성한다' `
        -Skip:(-not (Test-Path "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) {
        $windowsPowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $planPath = Join-Path $PSScriptRoot '../skills/hwp-skill/examples/generate-new.plan.json'
        $outputPath = Join-Path $TestDrive 'styled-ps51.hwpx'

        $raw = & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $cli generate `
            -NewDocument -PlanPath $planPath -OutputPath $outputPath
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS_WITH_WARNINGS'
        $json.data.After.sections[0].pageDefinitions[0].orientation | Should Be 'PORTRAIT'
        (@($json.data.After.resources.fonts.name) -contains '함초롬돋움') | Should Be $true
        Test-Path -LiteralPath $outputPath | Should Be $true
    }

    It 'silent HWPX 생성은 직접 엔진으로 작성한다' {
        $planPath = Join-Path $TestDrive 'generate.plan.json'
        $outputPath = Join-Path $TestDrive 'generated.hwpx'
        $plan = [pscustomobject]@{
            version = '1.0'
            content = @([pscustomobject]@{ type = 'paragraph'; text = 'HWPX 생성 차단' })
        }
        [IO.File]::WriteAllText($planPath, ($plan | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

        $raw = & $pwsh -NoProfile -File $cli generate -NewDocument -PlanPath $planPath -OutputPath $outputPath
        $exitCode = $LASTEXITCODE
        $json = ($raw -join "`n") | ConvertFrom-Json

        $exitCode | Should Be 0
        $json.status | Should Be 'PASS_WITH_WARNINGS'
        $json.data.After.detectedKind | Should Be 'HWPX-ZIP'
        Test-Path -LiteralPath $outputPath | Should Be $true
    }
}
