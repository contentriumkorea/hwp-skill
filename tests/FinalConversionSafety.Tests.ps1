$finalLib = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib'
Import-Module (Join-Path $finalLib 'HwpGenerate.psm1') -Force
Import-Module (Join-Path $finalLib 'HwpConvert.psm1') -Force
Import-Module (Join-Path $finalLib 'HwpInspect.psm1') -Force

Describe 'Final HWP conversion never trusts signatures or hidden local GUI' {
    It 'blocks an unconfigured converter without starting the old local worker' {
        $source = Join-Path $TestDrive 'source.hwpx'
        Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
        { Invoke-HwpFinalHwpxToHwp -InputPath $source -OutputPath (Join-Path $TestDrive 'blocked.hwp') } | Should Throw 'isolated'
        Test-Path (Join-Path $TestDrive 'blocked.hwp') | Should Be $false
    }

    It 'does not promote unrelated real HWP returned by a converter' {
        $fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'))
        $worker = { param($InputPath,$OutputPath)
            Copy-Item -LiteralPath $fixture -Destination $OutputPath
            [pscustomobject]@{Status='PASS';OutputPath=$OutputPath}
        }.GetNewClosure()
        $plan = '{"version":"2.0","content":[{"type":"paragraph","text":"REQUIRED_UNIQUE_TEXT_20260918"}]}' | ConvertFrom-Json
        $output = Join-Path $TestDrive 'wrong.hwp'
        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -FinalConverter $worker
        $result.Status | Should Be 'FAILED'
        Test-Path $output | Should Be $false
        ($result.Errors -join ' ') | Should Match 'content|본문'
    }

    It 'preserves a usable HWPX when HWP conversion is not configured' {
        $plan = '{"version":"2.0","content":[{"type":"paragraph","text":"KEEP_HWPX_CONTENT"}]}' | ConvertFrom-Json
        $output = Join-Path $TestDrive 'unavailable.hwp'
        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output
        $result.Status | Should Be 'BLOCKED'
        Test-Path $output | Should Be $false
        Test-Path $result.WorkingHwpxPath | Should Be $true
        (Get-HwpInspection -LiteralPath $result.WorkingHwpxPath).Text | Should Match 'KEEP_HWPX_CONTENT'
    }

    It 'rejects a worker that returns PASS without creating an output' {
        $source = Join-Path $TestDrive 'source.hwpx'
        Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
        $failure = ''
        try { HwpConvert\Invoke-HwpFinalHwpxToHwp -InputPath $source -OutputPath (Join-Path $TestDrive 'missing.hwp') -WorkerLauncher { [pscustomobject]@{Status='PASS'} } }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match 'did not create'
    }

    It 'reopens a matching real HWP and reports the final binary inspection' {
        $fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'))
        $baseline = Get-HwpInspection -LiteralPath $fixture
        $plan = [pscustomobject]@{version='2.0';content=@(
            [pscustomobject]@{type='paragraph';text=$baseline.Text.Trim()}
            [pscustomobject]@{type='table';rows=2;columns=2;cells=@()}
        )}
        $worker = { param($InputPath,$OutputPath)
            Copy-Item -LiteralPath $fixture -Destination $OutputPath
            [pscustomobject]@{Status='PASS'}
        }.GetNewClosure()
        $output=Join-Path $TestDrive 'matching.hwp'
        $result=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -FinalConverter $worker
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.After.DetectedKind | Should Be 'HWP-BINARY'
        $result.After.Sha256 | Should Be (Get-FileHash $fixture).Hash.ToLowerInvariant()
        $result.After.Path | Should Be $output
        $result.After.Tables[0].RowCount | Should Be 2
    }

    It 'rejects equal text and table counts when the table grid differs' {
        $fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'))
        $baseline=Get-HwpInspection -LiteralPath $fixture
        $plan=[pscustomobject]@{version='2.0';content=@(
            [pscustomobject]@{type='paragraph';text=$baseline.Text.Trim()}
            [pscustomobject]@{type='table';rows=1;columns=4;cells=@()}
        )}
        $worker={param($InputPath,$OutputPath) Copy-Item -LiteralPath $fixture -Destination $OutputPath; [pscustomobject]@{Status='PASS'}}.GetNewClosure()
        $output=Join-Path $TestDrive 'wrong-grid.hwp'
        $result=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -FinalConverter $worker
        $result.Status | Should Be 'FAILED'
        ($result.Errors -join ' ') | Should Match 'table.*dimensions'
        Test-Path $output | Should Be $false
    }
}
