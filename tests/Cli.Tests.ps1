$cli = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1'
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
}
