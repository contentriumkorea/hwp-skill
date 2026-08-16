$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$capabilityModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1'
$routerModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpBackendRouter.psm1'

Describe 'HWP 백엔드 라우터' {
    function New-TestRouterInputs {
        param(
            [string]$ExecutionModule,
            [string]$CapabilityModule,
            [string]$RouterModule
        )

        Import-Module $ExecutionModule -Force
        Import-Module $CapabilityModule -Force
        Import-Module $RouterModule -Force

        Get-HwpCapabilitySnapshot `
            -ExecutionContext (New-HwpExecutionContext) `
            -NativeRegistrationProbe { $true } `
            -PortableBackendProbe { $false } `
            -IsolatedWorkerProbe { $false }
    }

    function New-CapabilitiesWithBackends {
        param(
            [bool]$PortableAvailable = $false,
            [bool]$IsolatedAvailable = $false,
            [bool]$InteractiveAvailable = $true
        )

        [pscustomobject][ordered]@{
            schemaVersion = '1.0'
            executionMode = 'silent'
            backends = @(
                [pscustomobject][ordered]@{
                    id = 'hwpx-direct'
                    available = $true
                    formats = @('HWPX-ZIP')
                    operations = @('inspect')
                    requiresGui = $false
                    isolation = 'none'
                    reason = 'HWPX ZIP/XML direct inspection is built in.'
                },
                [pscustomobject][ordered]@{
                    id = 'hwp-portable'
                    available = $PortableAvailable
                    formats = @('HWP-BINARY')
                    operations = @('inspect', 'generate', 'apply', 'batch', 'verify')
                    requiresGui = $false
                    isolation = 'none'
                    reason = 'Portable backend availability depends on the packaged runtime manifest.'
                },
                [pscustomobject][ordered]@{
                    id = 'hancom-isolated'
                    available = $IsolatedAvailable
                    formats = @('HWP-BINARY')
                    operations = @('inspect', 'generate', 'apply', 'batch', 'verify', 'export')
                    requiresGui = $true
                    isolation = 'separate-session'
                    reason = 'Isolated native worker support will be wired in without using local COM fallback.'
                },
                [pscustomobject][ordered]@{
                    id = 'hancom-interactive'
                    available = $InteractiveAvailable
                    formats = @('HWP-BINARY')
                    operations = @('inspect', 'generate', 'apply', 'batch', 'verify', 'export')
                    requiresGui = $true
                    isolation = 'current-session'
                    reason = 'Interactive Hancom automation depends on local COM registration only.'
                }
            )
        }
    }

    It '라우터 모듈이 존재한다' {
        Test-Path $routerModule | Should Be $true
    }

    It 'core 명령은 형식과 무관하게 core 백엔드를 선택한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $route = Resolve-HwpBackend -Command preflight -DetectedKind NONE `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities

        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'core'
        $route.RequiresGui | Should Be $false
        $route.Isolated | Should Be $false
    }

    It 'silent HWPX 검사는 직접 엔진을 선택한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWPX-ZIP `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities

        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hwpx-direct'
        $route.RequiresGui | Should Be $false
    }

    It 'silent HWP 검사는 GUI 대신 명시적으로 차단한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWP-BINARY `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities

        $route.Status | Should Be 'BLOCKED'
        $route.BackendId | Should Be ''
        $route.RequiresGui | Should Be $false
        $route.Isolated | Should Be $false
        $route.Reason | Should Be 'No silent backend supports inspect for HWP-BINARY.'
        @($route.Warnings).Count | Should Be 0
        @($route.Errors) | Should Be @('hwp-portable 백엔드가 준비되지 않았으며 GUI로 자동 전환하지 않습니다.')
    }

    It '격리 작업자가 없으면 로컬 한컴으로 대체하지 않는다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $context = New-HwpExecutionContext -Mode isolated-native
        $route = Resolve-HwpBackend -Command verify -DetectedKind HWP-BINARY `
            -ExecutionContext $context -Capabilities $capabilities

        $route.Status | Should Be 'BLOCKED'
        ($route.Errors -join ' ') | Should Match 'hancom-isolated'
    }

    It '명시적으로 승인된 interactive만 네이티브 엔진을 선택한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $context = New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWP-BINARY `
            -ExecutionContext $context -Capabilities $capabilities

        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hancom-interactive'
        $route.RequiresGui | Should Be $true
    }

    It '승인되지 않은 interactive 컨텍스트는 라우터 경계에서 즉시 차단한다' {
        $capabilities = New-CapabilitiesWithBackends -PortableAvailable $true -InteractiveAvailable $true
        $forgedContext = [pscustomobject][ordered]@{
            SchemaVersion = '1.0'
            Mode = 'interactive'
            AllowInteractiveWindow = $false
        }

        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWP-BINARY `
            -ExecutionContext $forgedContext -Capabilities $capabilities

        $route.Status | Should Be 'BLOCKED'
        $route.BackendId | Should Be ''
        $route.RequiresGui | Should Be $false
        $route.Isolated | Should Be $false
        $route.Reason | Should Be 'Interactive execution requires explicit AllowInteractiveWindow approval.'
        @($route.Warnings).Count | Should Be 0
        @($route.Errors) | Should Be @('interactive 모드는 -AllowInteractiveWindow의 명시적 승인이 필요합니다.')
    }

    It 'silent HWP 라우팅은 portable이 가능하면 interactive보다 먼저 portable을 선택한다' {
        $capabilities = New-CapabilitiesWithBackends -PortableAvailable $true -InteractiveAvailable $true
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWP-BINARY `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities

        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hwp-portable'
        $route.RequiresGui | Should Be $false
        $route.Isolated | Should Be $false
    }

    It 'isolated-native 라우팅은 portable이 가능해도 isolated만 선택한다' {
        $capabilities = New-CapabilitiesWithBackends -PortableAvailable $true -IsolatedAvailable $true -InteractiveAvailable $true
        $route = Resolve-HwpBackend -Command verify -DetectedKind HWP-BINARY `
            -ExecutionContext (New-HwpExecutionContext -Mode isolated-native) -Capabilities $capabilities

        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hancom-isolated'
        $route.RequiresGui | Should Be $true
        $route.Isolated | Should Be $true
    }

    It 'interactive 라우팅은 portable이 없을 때 native를 선택한다' {
        $capabilities = New-CapabilitiesWithBackends -PortableAvailable $false -InteractiveAvailable $true
        $route = Resolve-HwpBackend -Command verify -DetectedKind HWP-BINARY `
            -ExecutionContext (New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow) -Capabilities $capabilities

        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hancom-interactive'
        $route.RequiresGui | Should Be $true
        $route.Isolated | Should Be $false
    }

    It 'silent HWPX generate는 이 단계에서 정확히 차단된다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $route = Resolve-HwpBackend -Command generate -DetectedKind NONE -OutputPath 'result.hwpx' `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities

        $route.Status | Should Be 'BLOCKED'
        $route.BackendId | Should Be ''
        $route.Reason | Should Be 'No silent backend supports generate for requested format hwpx.'
        $route.RequiresGui | Should Be $false
        $route.Isolated | Should Be $false
        @($route.Warnings).Count | Should Be 0
        @($route.Errors) | Should Be @('hwpx-direct 백엔드는 현재 generate를 선언하지 않았으며 GUI로 자동 전환하지 않습니다.')
    }

    It '출력 형식 계산은 hwp와 hwpx만 허용한다' {
        Get-HwpRequestedFormat -OutputPath '' | Should Be 'none'
        Get-HwpRequestedFormat -OutputPath 'result.hwp' | Should Be 'hwp'
        Get-HwpRequestedFormat -OutputPath 'result.hwpx' | Should Be 'hwpx'
        { Get-HwpRequestedFormat -OutputPath 'result.pdf' } | Should Throw '출력 형식은 HWP 또는 HWPX여야 합니다.'
    }

    It 'backend id 조회는 없는 엔진을 null로 돌려준다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule

        (Get-HwpBackendById -Capabilities $capabilities -BackendId 'core').id | Should Be 'core'
        (Get-HwpBackendById -Capabilities $capabilities -BackendId 'missing') | Should Be $null
    }
}
