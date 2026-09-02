Set-StrictMode -Version Latest

$executionModulePath = Join-Path $PSScriptRoot 'HwpExecution.psm1'
Import-Module $executionModulePath -Force -Global

$script:RouteOrder = @(
    'core',
    'hwpx-direct',
    'hwp-portable',
    'hancom-isolated',
    'hancom-interactive'
)

function Get-HwpRequestedFormat {
    param([AllowEmptyString()][string]$OutputPath)

    if ([string]::IsNullOrWhiteSpace($OutputPath)) { return 'none' }

    switch ([IO.Path]::GetExtension($OutputPath).ToLowerInvariant()) {
        '.hwp' { return 'hwp' }
        '.hwpx' { return 'hwpx' }
        default { throw '출력 형식은 HWP 또는 HWPX여야 합니다.' }
    }
}

function Get-HwpCoreBackend {
    [pscustomobject][ordered]@{
        id = 'core'
        available = $true
        formats = @('NONE', 'HWP-BINARY', 'HWPX-ZIP')
        operations = @('capabilities', 'preflight', 'validate-plan', 'compare')
        requiresGui = $false
        isolation = 'none'
        reason = 'Core commands are handled without a document backend.'
    }
}

function Get-HwpBackendById {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Capabilities,
        [Parameter(Mandatory)][string]$BackendId
    )

    if ($BackendId -eq 'core') {
        return Get-HwpCoreBackend
    }

    $matches = @($Capabilities.backends | Where-Object id -eq $BackendId)
    if ($matches.Count -eq 0) {
        return $null
    }

    $matches[0]
}

function New-HwpBlockedRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string[]]$Errors = @()
    )

    [pscustomobject][ordered]@{
        Status = 'BLOCKED'
        BackendId = ''
        RequiresGui = $false
        Isolated = $false
        Reason = $Reason
        Warnings = @()
        Errors = @($Errors)
    }
}

function New-HwpPassRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Backend
    )

    [pscustomobject][ordered]@{
        Status = 'PASS'
        BackendId = [string]$Backend.id
        RequiresGui = [bool]$Backend.requiresGui
        Isolated = [string]$Backend.isolation -eq 'separate-session'
        Reason = [string]$Backend.reason
        Warnings = @()
        Errors = @()
    }
}

function Test-HwpBackendCandidate {
    param(
        [Parameter(Mandatory)][object]$Backend,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$DetectedKind,
        [Parameter(Mandatory)][string]$RequestedFormat,
        [Parameter(Mandatory)][object]$ExecutionContext
    )

    if (-not [bool]$Backend.available) { return $false }
    if ($Backend.operations -notcontains $Command) { return $false }

    if ([string]$Backend.id -eq 'core') {
        return $true
    }

    switch ([string]$ExecutionContext.Mode) {
        'silent' {
            if ([bool]$Backend.requiresGui) { return $false }
        }
        'isolated-native' {
            if ([string]$Backend.id -ne 'hancom-isolated') { return $false }
        }
        'interactive' {
            if ([string]$Backend.id -eq 'hancom-isolated') { return $false }
            if ([string]$Backend.id -eq 'hwp-portable') { return $false }
            if ([string]$Backend.id -eq 'hancom-interactive' -and $ExecutionContext.AllowInteractiveWindow -ne $true) {
                return $false
            }
        }
        default {
            return $false
        }
    }

    if ($RequestedFormat -eq 'hwpx') {
        return [string]$Backend.id -eq 'hwpx-direct'
    }

    if ($DetectedKind -eq 'NONE') {
        if ($RequestedFormat -eq 'hwp') {
            return $Backend.formats -contains 'HWP-BINARY'
        }

        return $false
    }

    return $Backend.formats -contains $DetectedKind
}

function Resolve-HwpBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$DetectedKind = 'NONE',
        [ValidateSet('none', 'hwp', 'hwpx')]
        [string]$RequestedFormat = 'none',
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [Parameter(Mandatory)][object]$Capabilities
    )

    if (-not (Test-HwpExecutionContext $ExecutionContext)) {
        throw '유효한 HWP 실행 컨텍스트가 필요합니다.'
    }

    if ([string]$ExecutionContext.Mode -eq 'interactive' -and $ExecutionContext.AllowInteractiveWindow -ne $true) {
        return New-HwpBlockedRoute `
            -Reason 'Interactive execution requires explicit AllowInteractiveWindow approval.' `
            -Errors @('interactive 모드는 -AllowInteractiveWindow의 명시적 승인이 필요합니다.')
    }

    foreach ($backendId in $script:RouteOrder) {
        $backend = Get-HwpBackendById -Capabilities $Capabilities -BackendId $backendId
        if ($null -eq $backend) {
            continue
        }

        if (Test-HwpBackendCandidate `
                -Backend $backend `
                -Command $Command `
                -DetectedKind $DetectedKind `
                -RequestedFormat $RequestedFormat `
                -ExecutionContext $ExecutionContext) {
            return New-HwpPassRoute -Backend $backend
        }
    }

    switch ([string]$ExecutionContext.Mode) {
        'silent' {
            if ($Command -eq 'inspect' -and $DetectedKind -eq 'HWP-BINARY') {
                return New-HwpBlockedRoute `
                    -Reason 'No silent backend supports inspect for HWP-BINARY.' `
                    -Errors @('hwp-portable 백엔드가 준비되지 않았으며 GUI로 자동 전환하지 않습니다.')
            }
            if ($Command -eq 'generate' -and $RequestedFormat -eq 'hwpx') {
                return New-HwpBlockedRoute `
                    -Reason 'No silent backend supports generate for requested format hwpx.' `
                    -Errors @('hwpx-direct 백엔드는 현재 generate를 선언하지 않았으며 GUI로 자동 전환하지 않습니다.')
            }

            return New-HwpBlockedRoute `
                -Reason "No silent backend supports $Command for $DetectedKind." `
                -Errors @("요청한 작업을 처리할 silent 백엔드가 없으며 GUI로 자동 전환하지 않습니다.")
        }
        'isolated-native' {
            return New-HwpBlockedRoute `
                -Reason "No isolated-native backend supports $Command for $DetectedKind." `
                -Errors @('hancom-isolated 백엔드가 준비되지 않았으며 현재 세션 COM으로 대체하지 않습니다.')
        }
        'interactive' {
            return New-HwpBlockedRoute `
                -Reason "No interactive backend supports $Command for $DetectedKind." `
                -Errors @('interactive 승인이 없는 백엔드로 자동 전환하지 않습니다.')
        }
    }
}

Export-ModuleMember -Function @(
    'Resolve-HwpBackend',
    'Get-HwpBackendById',
    'Get-HwpRequestedFormat'
)
