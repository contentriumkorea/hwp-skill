$monitorModule = Join-Path $PSScriptRoot 'WindowActivityMonitor.psm1'
$cli = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'

Import-Module $monitorModule -Force

function New-SilentGeneratePlan {
    [pscustomobject]@{
        version = '1.0'
        content = @(
            [pscustomobject]@{ type = 'paragraph'; text = 'silent generate should stay blocked' }
        )
    }
}

function New-SyntheticHwpxFixture {
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $entries = [ordered]@{
                'mimetype' = 'application/hwp+zip'
                'Contents/section0.xml' = @'
<?xml version="1.0" encoding="UTF-8"?>
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
        xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
  <hp:p id="1"><hp:run><hp:t>Silent HWPX inspection fixture</hp:t></hp:run></hp:p>
</hs:sec>
'@
            }

            foreach ($name in $entries.Keys) {
                $compression = if ($name -eq 'mimetype') {
                    [IO.Compression.CompressionLevel]::NoCompression
                }
                else {
                    [IO.Compression.CompressionLevel]::Optimal
                }
                $entry = $archive.CreateEntry($name, $compression)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try {
                    $writer.Write([string]$entries[$name])
                }
                finally {
                    $writer.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    $Path
}

function Invoke-SilentCliJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $monitor = New-HwpSilentActivityMonitor
    $monitor.Start()
    try {
        $raw = & $pwsh -NoProfile -File $cli @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $monitor.Stop()
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Json = ($raw -join "`n") | ConvertFrom-Json
        NewProcessIds = @($monitor.NewProcessIds)
        NewHwpProcessIds = @($monitor.NewHwpProcessIds)
        NewWinwordProcessIds = @($monitor.NewWinwordProcessIds)
        NewExplorerProcessIds = @($monitor.NewExplorerProcessIds)
        NewVisibleWindowHandles = @($monitor.NewVisibleWindowHandles)
        NewVisibleWindowProcessIds = @($monitor.NewVisibleWindowProcessIds)
        ForegroundCapturedByHwp = $monitor.ForegroundCapturedByHwp
        ForegroundChanged = $monitor.ForegroundChanged
    }
}

function Assert-NoHwpActivity {
    param([Parameter(Mandatory)][object]$Observation)

    @($Observation.NewProcessIds).Count | Should Be 0
    @($Observation.NewHwpProcessIds).Count | Should Be 0
    @($Observation.NewWinwordProcessIds).Count | Should Be 0
    @($Observation.NewExplorerProcessIds).Count | Should Be 0
    @($Observation.NewVisibleWindowHandles).Count | Should Be 0
    @($Observation.NewVisibleWindowProcessIds).Count | Should Be 0
    $Observation.ForegroundCapturedByHwp | Should Be $false
    $Observation.ForegroundChanged | Should Be $false
}

Describe 'HWP silent acceptance gate' {
    It '감시기는 HWP, Word, Explorer, 모든 새 최상위 창과 포그라운드 변경을 노출한다' {
        $monitor = New-HwpSilentActivityMonitor
        $propertyNames = @($monitor.PSObject.Properties.Name)
        try {
            foreach ($propertyName in @(
                'NewHwpProcessIds',
                'NewWinwordProcessIds',
                'NewExplorerProcessIds',
                'NewVisibleWindowHandles',
                'NewVisibleWindowProcessIds',
                'ForegroundChanged'
            )) {
                ($propertyNames -contains $propertyName) | Should Be $true
            }
        }
        finally {
            $monitor.Dispose()
        }
    }

    It 'capabilities와 preflight가 포커스와 HWP 프로세스를 바꾸지 않는다' {
        $capabilities = Invoke-SilentCliJson -Arguments @('capabilities')
        $preflight = Invoke-SilentCliJson -Arguments @('preflight')

        $capabilities.ExitCode | Should Be 0
        $capabilities.Json.status | Should Be 'PASS'
        $capabilities.Json.data.executionMode | Should Be 'silent'
        Assert-NoHwpActivity -Observation $capabilities

        $preflight.ExitCode | Should Be 0
        $preflight.Json.status | Should Be 'PASS'
        $preflight.Json.data.executionMode | Should Be 'silent'
        Assert-NoHwpActivity -Observation $preflight
    }

    It 'silent HWP 차단 inspect도 결과 파일을 자동으로 열지 않는다' {
        $fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'

        $result = Invoke-SilentCliJson -Arguments @('inspect', '-LiteralPath', $fixtureHwp)

        $result.ExitCode | Should Be 2
        $result.Json.status | Should Be 'BLOCKED'
        $result.Json.detectedKind | Should Be 'HWP-BINARY'
        Assert-NoHwpActivity -Observation $result
    }

    It 'synthetic HWPX inspect는 silent로 완료되고 HWP 활동이 없다' {
        $fixtureHwpx = New-SyntheticHwpxFixture -Path (Join-Path $TestDrive 'synthetic.hwpx')

        $result = Invoke-SilentCliJson -Arguments @('inspect', '-LiteralPath', $fixtureHwpx)

        $result.ExitCode | Should Be 0
        $result.Json.status | Should Be 'PASS_WITH_WARNINGS'
        $result.Json.detectedKind | Should Be 'HWPX-ZIP'
        Assert-NoHwpActivity -Observation $result
    }

    It 'unsupported silent generate는 차단되고 창이나 포커스를 만들지 않는다' {
        $planPath = Join-Path $TestDrive 'generate.plan.json'
        $outputPath = Join-Path $TestDrive 'generated.hwpx'
        [IO.File]::WriteAllText($planPath, ((New-SilentGeneratePlan) | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

        $result = Invoke-SilentCliJson -Arguments @('generate', '-NewDocument', '-PlanPath', $planPath, '-OutputPath', $outputPath)

        $result.ExitCode | Should Be 2
        $result.Json.status | Should Be 'BLOCKED'
        Assert-NoHwpActivity -Observation $result
        Test-Path -LiteralPath $outputPath | Should Be $false
    }
}

Describe 'test runner safety gate' {
    It '기본 실행 계약은 Static 기본값과 Native 분리를 선언한다' {
        $content = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run-tests.ps1') -Raw -Encoding UTF8

        $content | Should Match '\[ValidateSet\(''Static'',''Native'',''All''\)\]'
        $content | Should Match '\[string\]\$Suite = ''Static'''
        $content | Should Match '\[switch\]\$AllowInteractiveNative'
        $content | Should Match '''Static''\s*\{\s*\$staticTests\s*\}'
        $content | Should Match '''Native''\s*\{\s*\$nativeTests\s*\}'
        $content | Should Match 'Name -Like ''\*\.Integration\.Tests\.ps1'''
        $content | Should Match 'Name -NotLike ''\*\.Integration\.Tests\.ps1'''
    }

    It 'Native와 All은 명시적 승인 없이 시험 전에 종료 코드 2로 차단한다' {
        $suiteRoot = Join-Path $TestDrive 'runner-native'
        New-Item -ItemType Directory -Path $suiteRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run-tests.ps1') -Destination (Join-Path $suiteRoot 'run-tests.ps1')
        [IO.File]::WriteAllText((Join-Path $suiteRoot 'NativeProbe.Integration.Tests.ps1'), @'
Describe ''Native probe'' {
    It ''must not run'' {
        $true | Should Be $false
    }
}
'@, [Text.UTF8Encoding]::new($false))

        $nativeRaw = & $pwsh -NoProfile -File (Join-Path $suiteRoot 'run-tests.ps1') -Suite Native 2>&1
        $nativeExitCode = $LASTEXITCODE
        $allRaw = & $pwsh -NoProfile -File (Join-Path $suiteRoot 'run-tests.ps1') -Suite All 2>&1
        $allExitCode = $LASTEXITCODE

        $nativeExitCode | Should Be 2
        $allExitCode | Should Be 2
        ($nativeRaw | Out-String) | Should Match 'AllowInteractiveNative'
        ($allRaw | Out-String) | Should Match 'AllowInteractiveNative'
    }
}
