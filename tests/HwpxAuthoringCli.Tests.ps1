Describe 'Public authoring validation and scoped editing commands' {
    It 'loads scoped editing in a fresh Windows PowerShell 5.1 process' {
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $source=Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx'
        $plan=Join-Path $TestDrive 'fresh-ps51.json'
        [IO.File]::WriteAllText($plan,'{"version":"2.0","operations":[{"type":"set-page","sectionIndex":0,"orientation":"PORTRAIT"}]}')
        $out=Join-Path $TestDrive 'fresh-ps51.hwpx'
        $raw=& powershell -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $out -ApproveAdvanced
        $LASTEXITCODE | Should Be 0
        $result=($raw -join "`n")|ConvertFrom-Json
        $result.status | Should Be PASS_WITH_WARNINGS
        Test-Path -LiteralPath $out | Should Be $true
    }
    It 'requires advanced approval before attempting structural table edits' {
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $source=Join-Path $TestDrive 'table-source.hwpx'
        Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
        foreach($type in @('merge-cells','split-cell')){
            $plan=Join-Path $TestDrive ($type+'.json')
            [IO.File]::WriteAllText($plan,('{"version":"2.0","operations":[{"type":"'+$type+'","sectionIndex":0,"tableIndex":0,"row":0,"column":0}]}'))
            $out=Join-Path $TestDrive ($type+'.hwpx')
            $raw=& pwsh -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $out
            $result=($raw -join "`n")|ConvertFrom-Json
            $result.Status | Should Be BLOCKED
            ($result.Errors -join ' ') | Should Match 'ApproveAdvanced'
            Test-Path -LiteralPath $out | Should Be $false
        }
    }
    It 'validates new plans and requires separate page change approval' {
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $source=Join-Path $TestDrive 'source.hwpx'
        Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
        $plan=Join-Path $TestDrive 'edit.json'
        [IO.File]::WriteAllText($plan,'{"version":"2.0","operations":[{"type":"set-page","sectionIndex":0,"orientation":"PORTRAIT"}]}')
        $out=Join-Path $TestDrive 'changed.hwpx'
        $raw=& pwsh -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $out
        ($raw -join "`n"|ConvertFrom-Json).status | Should Be BLOCKED
        Test-Path $out | Should Be $false
        $raw=& pwsh -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $out -ApproveAdvanced
        ($raw -join "`n"|ConvertFrom-Json).status | Should Be PASS_WITH_WARNINGS
        $generate=Join-Path $TestDrive 'generate.json'
        [IO.File]::WriteAllText($generate,'{"version":"2.0","content":[{"type":"paragraph","text":"test"}]}')
        $raw=& pwsh -NoProfile -File $cli validate-generate-plan -PlanPath $generate
        ($raw -join "`n"|ConvertFrom-Json).status | Should Be PASS
    }
}
