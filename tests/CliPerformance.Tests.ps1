$cli = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
$library = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib'
$pwsh = (Get-Process -Id $PID).Path

Describe 'CLI selective loading and compact results' {
    It 'capabilities does not load the editing and generation engines' {
        $wrapper = Join-Path $TestDrive 'modules.ps1'
        $script = @'
param($Cli)
$raw = & $Cli capabilities
$code = $LASTEXITCODE
[pscustomobject]@{ exitCode=$code; result=(($raw -join "`n") | ConvertFrom-Json); modules=@(Get-Module -All | Select-Object -ExpandProperty Name) } | ConvertTo-Json -Depth 50
'@
        [IO.File]::WriteAllText($wrapper,$script,[Text.UTF8Encoding]::new($false))
        $result = ((& $pwsh -NoProfile -File $wrapper $cli) -join "`n") | ConvertFrom-Json
        $result.exitCode | Should Be 0
        $result.result.status | Should Be 'PASS'
        foreach ($name in 'HwpGenerate','HwpEdit','HwpBatch','HwpInspect','HwpHwpx') {
            ($name -in $result.modules) | Should Be $false
        }
    }

    It 'compact inspection retains content, addresses, tables and fidelity warnings without changing full output' {
        $path = Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx'
        $full = ((& $pwsh -NoProfile -File $cli inspect -LiteralPath $path) -join "`n") | ConvertFrom-Json
        $raw = (& $pwsh -NoProfile -File $cli inspect -LiteralPath $path -ResultDetail compact) -join "`n"
        $code = $LASTEXITCODE
        $code | Should Be 0
        $compact = $raw | ConvertFrom-Json
        $compact.resultDetail | Should Be 'compact'
        $compact.sha256 | Should Be $full.sha256
        $compact.text | Should Be $full.text
        foreach ($name in 'paragraphs','tables','sections','layout','warnings','errors') {
            ($compact.$name | ConvertTo-Json -Depth 100 -Compress) | Should Be ($full.$name | ConvertTo-Json -Depth 100 -Compress)
        }
        ($compact.PSObject.Properties.Name -contains 'resources') | Should Be $false
        $compact.resourceSummary.fonts | Should Be @($full.resources.fonts).Count
        ($full.PSObject.Properties.Name -contains 'resources') | Should Be $true
        ($raw.Length -lt (($full | ConvertTo-Json -Depth 100).Length / 2)) | Should Be $true
    }

    It 'compact generation keeps verification and warnings but avoids duplicated inspections' {
        $path = Join-Path $TestDrive 'compact.hwpx'
        $plan = Join-Path $PSScriptRoot '../skills/hwp-skill/examples/generate-new.plan.json'
        $raw = (& $pwsh -NoProfile -File $cli generate -NewDocument -PlanPath $plan -OutputPath $path -ResultDetail compact) -join "`n"
        $code = $LASTEXITCODE
        $code | Should Be 0
        $result = $raw | ConvertFrom-Json
        $result.status | Should Be 'PASS_WITH_WARNINGS'
        $result.data.OutputPath | Should Be $path
        $result.data.AfterSummary.sha256 | Should Be ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())
        $result.StructuralVerification.Status | Should Be 'PASS'
        $result.data.AfterSummary.layout.exactRenderingVerified | Should Be $false
        @($result.warnings).Count | Should BeGreaterThan 0
        ($result.PSObject.Properties.Name -contains 'After') | Should Be $false
        ($result.data.PSObject.Properties.Name -contains 'After') | Should Be $false

        $inspection = ((& $pwsh -NoProfile -File $cli inspect -LiteralPath $path -ResultDetail compact) -join "`n") | ConvertFrom-Json
        $run = @($inspection.paragraphs | ForEach-Object { $_.charShapeRuns } | Where-Object { $_.text.Length -gt 0 })[0]
        $editPlan = @{version='2.0';operations=@(@{type='replace-run-text';address=$run.address;expectedText=$run.text;text='Compact address edit'})}
        $planPath = Join-Path $TestDrive 'compact-edit.json'
        [IO.File]::WriteAllText($planPath,($editPlan|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
        $edited = Join-Path $TestDrive 'compact-edited.hwpx'
        $editRaw = (& $pwsh -NoProfile -File $cli edit-hwpx -LiteralPath $path -PlanPath $planPath -OutputPath $edited) -join "`n"
        $LASTEXITCODE | Should Be 0
        ($editRaw | ConvertFrom-Json).status | Should Be 'PASS_WITH_WARNINGS'
        $check = ((& $pwsh -NoProfile -File $cli inspect -LiteralPath $edited -ResultDetail compact) -join "`n") | ConvertFrom-Json
        $check.text | Should Match 'Compact address edit'
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should Be $result.data.AfterSummary.sha256
    }

    It 'compact mode preserves a failed command and its exit code' {
        $raw = (& $pwsh -NoProfile -File $cli inspect -LiteralPath (Join-Path $TestDrive 'missing.hwpx') -ResultDetail compact) -join "`n"
        $code = $LASTEXITCODE
        $code | Should Be 1
        $result = $raw | ConvertFrom-Json
        $result.status | Should Be 'FAILED'
        @($result.errors).Count | Should BeGreaterThan 0
    }

    It 'compact mode retains blocked HWP recovery paths instead of reporting completion' {
        $path = Join-Path $TestDrive 'blocked.hwp'
        $plan = Join-Path $PSScriptRoot '../skills/hwp-skill/examples/generate-new.plan.json'
        $raw = (& $pwsh -NoProfile -File $cli generate -NewDocument -PlanPath $plan -OutputPath $path -ResultDetail compact) -join "`n"
        $code = $LASTEXITCODE
        $code | Should Be 2
        $result = $raw | ConvertFrom-Json
        $result.status | Should Be 'BLOCKED'
        $result.data.WorkingHwpxPath | Should Not BeNullOrEmpty
        Test-Path -LiteralPath $result.data.WorkingHwpxPath | Should Be $true
        Test-Path -LiteralPath $path | Should Be $false
        @($result.errors).Count | Should BeGreaterThan 0
    }

    It 'response projection never mutates inspection or hides operation errors' {
        Import-Module (Join-Path $library 'HwpCliResponse.psm1') -Force
        $inspection = [pscustomobject]@{status='PASS_WITH_WARNINGS';text='한글';resources=[pscustomobject]@{fonts=@(1,2)};layout=[pscustomobject]@{exactRenderingVerified=$false};warnings=@('layout unverified');errors=@()}
        $before = $inspection | ConvertTo-Json -Depth 100 -Compress
        $view = ConvertTo-HwpCliResponse -Result $inspection -Command inspect
        ($inspection | ConvertTo-Json -Depth 100 -Compress) | Should Be $before
        $view.resourceSummary.fonts | Should Be 2
        $result=[pscustomobject]@{status='FAILED';command='generate';warnings=@('warning');errors=@('error');data=[pscustomobject]@{After=$inspection;OperationResults=@([pscustomobject]@{status='FAILED';errors=@('inner failure')});FailedArtifactPath='recover.hwpx'};After=$inspection}
        $before = $result | ConvertTo-Json -Depth 100 -Compress
        $view = ConvertTo-HwpCliResponse -Result $result -Command generate
        ($result | ConvertTo-Json -Depth 100 -Compress) | Should Be $before
        $view.data.OperationResults[0].errors[0] | Should Be 'inner failure'
        $view.data.FailedArtifactPath | Should Be 'recover.hwpx'
        $view.errors[0] | Should Be 'error'
        $view.warnings[0] | Should Be 'warning'
        $view.data.AfterSummary.warnings[0] | Should Be 'layout unverified'
    }
}
