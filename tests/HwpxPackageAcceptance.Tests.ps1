Describe 'Authoring package is self-contained' {
    It 'includes and executes the V2 engine from a standalone ZIP' {
        $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $zip=Join-Path $TestDrive 'authoring.zip';$expanded=Join-Path $TestDrive 'expanded'
        $null=& (Join-Path $root 'package.ps1') -OutputPath $zip
        [IO.Compression.ZipFile]::ExtractToDirectory($zip,$expanded)
        $skill=Join-Path $expanded 'hwp-skill'
        foreach($name in @('HwpAuthoringPlan','HwpAuthoringVerify','HwpHwpxObjects','HwpHwpxReferences','HwpHwpxScopedEdit')){
            Test-Path -LiteralPath (Join-Path $skill ('scripts/lib/'+$name+'.psm1')) | Should Be $true
        }
        $out=Join-Path $TestDrive 'packaged.hwpx'
        $raw=& pwsh -NoProfile -File (Join-Path $skill 'scripts/Invoke-HwpSkill.ps1') generate -NewDocument -PlanPath (Join-Path $skill 'examples/authoring-v2.plan.json') -OutputPath $out
        $LASTEXITCODE | Should Be 0
        $result=($raw -join "`n")|ConvertFrom-Json
        $result.Status | Should Be PASS_WITH_WARNINGS
        $result.StructuralVerification.Status | Should Be PASS
        $result.HancomContentWrite | Should Be $false
    }
    It 'installs identical authoring files and advertises silent capabilities' {
        $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $destination=Join-Path $TestDrive 'installed'
        $installed=& (Join-Path $root 'install.ps1') -DestinationRoot $destination
        $installed.Status | Should Be PASS
        $source=Join-Path $root 'skills/hwp-skill'
        foreach($relative in @('scripts/lib/HwpAuthoringVerify.psm1','scripts/lib/HwpHwpxScopedEdit.psm1','references/authoring-capabilities.json','references/authoring.md')){
            (Get-FileHash (Join-Path $installed.InstallPath $relative)).Hash | Should Be ((Get-FileHash (Join-Path $source $relative)).Hash)
        }
        $raw=& pwsh -NoProfile -File (Join-Path $installed.InstallPath 'scripts/Invoke-HwpSkill.ps1') capabilities
        $result=($raw -join "`n")|ConvertFrom-Json
        $result.data.authoring.defaultPlanVersion | Should Be '2.0'
        $result.data.authoring.requiresHancomForHwpx | Should Be $false
    }
}
