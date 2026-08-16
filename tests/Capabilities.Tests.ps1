$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilityModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$capabilitySchema = Join-Path $PSScriptRoot '../skill/hwp-skill/schemas/capabilities.schema.json'

Describe 'HWP 엔진 기능 스냅샷' {
    It '기능 모듈이 존재한다' {
        Test-Path $capabilityModule | Should Be $true
    }

    It '탐지 과정에서 네이티브 COM 객체를 만들지 않는다' {
        Import-Module $executionModule -Force
        Import-Module $capabilityModule -Force
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
        Import-Module $executionModule -Force
        Import-Module $capabilityModule -Force

        $snapshot = Get-HwpCapabilitySnapshot `
            -ExecutionContext (New-HwpExecutionContext) `
            -NativeRegistrationProbe { $false } `
            -PortableBackendProbe { $false } `
            -IsolatedWorkerProbe { $false }
        $json = $snapshot | ConvertTo-Json -Depth 20

        $json | Test-Json -SchemaFile $capabilitySchema | Should Be $true
    }
}
