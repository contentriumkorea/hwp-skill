$upgradeCli = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'))
$upgradeShell = (Get-Process -Id $PID).Path
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force

Describe 'Version 2.1 public command integration without native applications' {
    BeforeEach {
        $script:upgradeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($upgradeRoot)
        $script:upgradeSource = Join-Path $upgradeRoot 'input.hwpx'
        $script:upgradePlan = '{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"text":"CELL"}]},{"type":"paragraph","text":"TARGET"},{"type":"paragraph","text":"OTHER"}]}' | ConvertFrom-Json
        $generated = Invoke-HwpGenerate -NewDocument -Plan $upgradePlan -OutputPath $upgradeSource
        $generated.Status | Should Be 'PASS_WITH_WARNINGS'
    }

    It 'edits the inspected run address after a table through the actual CLI' {
        $raw = & $upgradeShell -NoProfile -File $upgradeCli inspect -LiteralPath $upgradeSource
        $LASTEXITCODE | Should Be 0
        $inspection = ($raw -join "`n") | ConvertFrom-Json
        $target = @($inspection.paragraphs | Where-Object text -CEQ TARGET)[0]
        $plan = @{version='2.0';operations=@(@{type='replace-run-text';address=$target.charShapeRuns[0].address;expectedText='TARGET';text='CHANGED'})}
        $path = Join-Path $upgradeRoot 'edit.json'; $output = Join-Path $upgradeRoot 'edited.hwpx'
        [IO.File]::WriteAllText($path,($plan | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $raw = & $upgradeShell -NoProfile -File $upgradeCli edit-hwpx -LiteralPath $upgradeSource -PlanPath $path -OutputPath $output
        $LASTEXITCODE | Should Be 0
        (($raw -join "`n") | ConvertFrom-Json).status | Should Be 'PASS_WITH_WARNINGS'
        $actual = Get-HwpInspection -LiteralPath $output
        $actual.Text | Should Match 'CHANGED'
        $actual.Text | Should Match 'OTHER'
        $actual.Text | Should Not Match 'TARGET'
        (Get-HwpInspection -LiteralPath $upgradeSource).Text | Should Match 'TARGET'
    }

    It 'blocks row and column insertion without runtime advanced approval' {
        $table = (Get-HwpInspection -LiteralPath $upgradeSource).Tables[0]
        foreach ($type in @('insert-table-row','insert-table-column')) {
            $op = @{type=$type;address=$table.address;index=1}
            if ($type -eq 'insert-table-row') { $op.heightMm=5 } else { $op.widthMm=5 }
            $path = Join-Path $upgradeRoot ($type+'.json'); $output=Join-Path $upgradeRoot ($type+'.hwpx')
            [IO.File]::WriteAllText($path,(@{version='2.0';operations=@($op)}|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            $raw = & $upgradeShell -NoProfile -File $upgradeCli edit-hwpx -LiteralPath $upgradeSource -PlanPath $path -OutputPath $output
            $LASTEXITCODE | Should Be 2
            (($raw -join "`n") | ConvertFrom-Json).status | Should Be 'BLOCKED'
            Test-Path $output | Should Be $false
        }
    }

    It 'creates an approximate HTML report through preview with an absent browser' {
        $before=(Get-FileHash $upgradeSource).Hash
        $raw = & $upgradeShell -NoProfile -File $upgradeCli preview -LiteralPath $upgradeSource -OutputDirectory (Join-Path $upgradeRoot 'preview') -BrowserPath (Join-Path $upgradeRoot 'absent-browser')
        $LASTEXITCODE | Should Be 0
        $result=($raw -join "`n")|ConvertFrom-Json
        $result.status | Should Be 'PASS_WITH_WARNINGS'
        $result.data.Fidelity | Should Be 'approximate'
        $result.data.NativeLayoutVerified | Should Be $false
        Test-Path $result.data.HtmlPath | Should Be $true
        Test-Path $result.data.ReportPath | Should Be $true
        $result.data.PdfPath | Should BeNullOrEmpty
        (Get-FileHash $upgradeSource).Hash | Should Be $before
    }

    It 'reports a blocked HWP request with a usable HWPX path and exit code 2' {
        $path=Join-Path $upgradeRoot 'generate.json'; $output=Join-Path $upgradeRoot 'final.hwp'
        [IO.File]::WriteAllText($path,($upgradePlan|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $raw = & $upgradeShell -NoProfile -File $upgradeCli generate -NewDocument -PlanPath $path -OutputPath $output
        $LASTEXITCODE | Should Be 2
        $result=($raw -join "`n")|ConvertFrom-Json
        $result.status | Should Be 'BLOCKED'
        Test-Path $output | Should Be $false
        (Get-HwpInspection -LiteralPath $result.WorkingHwpxPath).Text | Should Match 'TARGET'
    }
}
