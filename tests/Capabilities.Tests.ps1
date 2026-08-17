$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilityModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$capabilitySchema = Join-Path $PSScriptRoot '../skill/hwp-skill/schemas/capabilities.schema.json'

Describe 'HWP 엔진 기능 스냅샷' {
    BeforeAll {
        Import-Module $executionModule -Force
        Import-Module $capabilityModule -Force
    }

    function ConvertTo-SnapshotJson {
        param([Parameter(Mandatory)][object]$InputObject)
        $InputObject | ConvertTo-Json -Depth 20
    }

    function New-DeterministicCapabilitySnapshot {
        Get-HwpCapabilitySnapshot `
            -ExecutionContext (New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow) `
            -NativeRegistrationProbe { $true } `
            -PortableBackendProbe { $true } `
            -IsolatedWorkerProbe { $false }
    }

    It '기능 모듈이 존재한다' {
        Test-Path $capabilityModule | Should Be $true
    }

    It '결정적 프로브로 공개 백엔드 계약을 정확히 노출한다' {
        $snapshot = New-DeterministicCapabilitySnapshot
        $expectedBackends = @(
            [pscustomobject][ordered]@{
                id = 'hwpx-direct'
                available = $true
                formats = @('HWPX-ZIP')
                operations = @('inspect', 'generate')
                requiresGui = $false
                isolation = 'none'
                reason = 'HWPX ZIP/XML direct inspection and generation are built in; Hancom is not used for content writing.'
            },
            [pscustomobject][ordered]@{
                id = 'hwp-portable'
                available = $true
                formats = @('HWP-BINARY')
                operations = @('inspect', 'generate', 'apply', 'batch', 'verify')
                requiresGui = $false
                isolation = 'none'
                reason = 'Portable backend availability depends on the packaged runtime manifest.'
            },
            [pscustomobject][ordered]@{
                id = 'hancom-isolated'
                available = $false
                formats = @('HWP-BINARY')
                operations = @('inspect', 'generate', 'apply', 'batch', 'verify', 'export')
                requiresGui = $true
                isolation = 'separate-session'
                reason = 'Isolated native worker support will be wired in without using local COM fallback.'
            },
            [pscustomobject][ordered]@{
                id = 'hancom-interactive'
                available = $true
                formats = @('HWP-BINARY')
                operations = @('inspect', 'generate', 'apply', 'batch', 'verify', 'export')
                requiresGui = $true
                isolation = 'current-session'
                reason = 'Interactive Hancom automation depends on local COM registration only.'
            }
        )

        $snapshot.schemaVersion | Should Be '1.0'
        $snapshot.executionMode | Should Be 'interactive'
        (ConvertTo-SnapshotJson $snapshot.backends) | Should Be (ConvertTo-SnapshotJson $expectedBackends)
    }

    It '기본 프로브 경로도 세션이나 GUI 실행 없이 완료된다' {
        $sessionCalls = 0
        $launchCalls = 0

        function global:New-HwpSession {
            $script:sessionCalls++
            throw 'New-HwpSession must not be called by capability snapshot.'
        }

        function global:Start-Process {
            $script:launchCalls++
            throw 'Start-Process must not be called by capability snapshot.'
        }

        try {
            $snapshot = Get-HwpCapabilitySnapshot -ExecutionContext (New-HwpExecutionContext)

            $snapshot.schemaVersion | Should Be '1.0'
            $snapshot.executionMode | Should Be 'silent'
            $snapshot.backends.Count | Should Be 4
            $sessionCalls | Should Be 0
            $launchCalls | Should Be 0
        }
        finally {
            Remove-Item function:global:New-HwpSession -ErrorAction SilentlyContinue
            Remove-Item function:global:Start-Process -ErrorAction SilentlyContinue
        }
    }

    It '주입 프로브를 사용한 탐지 과정에서 네이티브 COM 객체를 만들지 않는다' {
        $nativeCalls = [pscustomobject]@{ Value = 0 }

        $snapshot = Get-HwpCapabilitySnapshot `
            -ExecutionContext (New-HwpExecutionContext) `
            -NativeRegistrationProbe ({ $nativeCalls.Value++; $true }.GetNewClosure()) `
            -PortableBackendProbe { $false } `
            -IsolatedWorkerProbe { $false }

        $nativeCalls.Value | Should Be 1
        ($snapshot.Backends | Where-Object Id -eq 'hwpx-direct').Available | Should Be $true
        ($snapshot.Backends | Where-Object Id -eq 'hwp-portable').Available | Should Be $false
        ($snapshot.Backends | Where-Object Id -eq 'hancom-isolated').Available | Should Be $false
        ($snapshot.Backends | Where-Object Id -eq 'hancom-interactive').Available | Should Be $true
    }

    It '기본 기능 스냅샷이 공개 JSON 스키마를 통과한다' {
        $snapshot = New-DeterministicCapabilitySnapshot
        $json = ConvertTo-SnapshotJson $snapshot

        $json | Test-Json -SchemaFile $capabilitySchema | Should Be $true
    }

    It '공개 JSON 스키마는 지원하지 않는 executionMode를 거부한다' {
        $invalid = New-DeterministicCapabilitySnapshot
        $invalid.executionMode = 'desktop'

        (ConvertTo-SnapshotJson $invalid) | Test-Json -SchemaFile $capabilitySchema -ErrorAction SilentlyContinue |
            Should Be $false
    }

    It '공개 JSON 스키마는 지원하지 않는 backend id를 거부한다' {
        $invalid = New-DeterministicCapabilitySnapshot
        $invalid.backends[1].id = 'portable-beta'

        (ConvertTo-SnapshotJson $invalid) | Test-Json -SchemaFile $capabilitySchema -ErrorAction SilentlyContinue |
            Should Be $false
    }

    It '공개 JSON 스키마는 backend별 format과 operation 계약 불일치를 거부한다' {
        $invalid = New-DeterministicCapabilitySnapshot
        $invalid.backends[0].formats = @('HWP-BINARY')
        $invalid.backends[3].operations = @('inspect')

        (ConvertTo-SnapshotJson $invalid) | Test-Json -SchemaFile $capabilitySchema -ErrorAction SilentlyContinue |
            Should Be $false
    }

    It '공개 JSON 스키마는 backend별 GUI 격리와 reason 계약 불일치를 거부한다' {
        $invalid = New-DeterministicCapabilitySnapshot
        $invalid.backends[1].requiresGui = $true
        $invalid.backends[1].isolation = 'current-session'
        $invalid.backends[0].reason = 'Different reason'

        (ConvertTo-SnapshotJson $invalid) | Test-Json -SchemaFile $capabilitySchema -ErrorAction SilentlyContinue |
            Should Be $false
    }
}
