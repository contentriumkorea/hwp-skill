Set-StrictMode -Version Latest

$executionModulePath = Join-Path $PSScriptRoot 'HwpExecution.psm1'
Import-Module $executionModulePath -Force -Global

function Get-HwpBackendCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [bool]$Available,

        [Parameter(Mandatory)]
        [string[]]$Formats,

        [Parameter(Mandatory)]
        [string[]]$Operations,

        [Parameter(Mandatory)]
        [bool]$RequiresGui,

        [Parameter(Mandatory)]
        [ValidateSet('none', 'separate-session', 'current-session')]
        [string]$Isolation,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    [pscustomobject][ordered]@{
        id = $Id
        available = $Available
        formats = @($Formats)
        operations = @($Operations)
        requiresGui = $RequiresGui
        isolation = $Isolation
        reason = $Reason
    }
}

function Get-HwpCapabilitySnapshot {
    [CmdletBinding()]
    param(
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [scriptblock]$NativeRegistrationProbe,
        [scriptblock]$PortableBackendProbe,
        [scriptblock]$IsolatedWorkerProbe
    )

    if (-not (Test-HwpExecutionContext $ExecutionContext)) {
        throw '유효한 HWP 실행 컨텍스트가 필요합니다.'
    }

    if (-not $NativeRegistrationProbe) {
        $NativeRegistrationProbe = {
            if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }

            $null -ne [type]::GetTypeFromProgID('HWPFrame.HwpObject.2', $false) -or
                $null -ne [type]::GetTypeFromProgID('HWPFrame.HwpObject', $false)
        }
    }

    if (-not $PortableBackendProbe) {
        $portableBackendPath = Join-Path $PSScriptRoot '../../runtime/hwp-portable/backend.json'
        $PortableBackendProbe = {
            if (-not (Test-Path -LiteralPath $portableBackendPath -PathType Leaf)) {
                return $false
            }

            try {
                $backend = Get-Content -LiteralPath $portableBackendPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            } catch {
                return $false
            }

            return [string]$backend.id -eq 'hwp-portable'
        }.GetNewClosure()
    }

    if (-not $IsolatedWorkerProbe) {
        $IsolatedWorkerProbe = { $false }
    }

    $backends = @(
        (Get-HwpBackendCapability -Id 'hwpx-direct' -Available $true -Formats @('HWPX-ZIP') -Operations @('inspect', 'generate') -RequiresGui $false -Isolation 'none' -Reason 'HWPX ZIP/XML direct inspection and generation are built in; Hancom is not used for content writing.')
        (Get-HwpBackendCapability -Id 'hwp-portable' -Available ([bool](& $PortableBackendProbe)) -Formats @('HWP-BINARY') -Operations @('inspect', 'generate', 'apply', 'batch', 'verify') -RequiresGui $false -Isolation 'none' -Reason 'Portable backend availability depends on the packaged runtime manifest.')
        (Get-HwpBackendCapability -Id 'hancom-isolated' -Available ([bool](& $IsolatedWorkerProbe)) -Formats @('HWP-BINARY') -Operations @('inspect', 'generate', 'apply', 'batch', 'verify', 'export') -RequiresGui $true -Isolation 'separate-session' -Reason 'Isolated native worker support will be wired in without using local COM fallback.')
        (Get-HwpBackendCapability -Id 'hancom-interactive' -Available ([bool](& $NativeRegistrationProbe)) -Formats @('HWP-BINARY') -Operations @('inspect', 'generate', 'apply', 'batch', 'verify', 'export') -RequiresGui $true -Isolation 'current-session' -Reason 'Interactive Hancom automation depends on local COM registration only.')
    )

    [pscustomobject][ordered]@{
        schemaVersion = '1.0'
        executionMode = [string]$ExecutionContext.Mode
        backends = @($backends)
    }
}

Export-ModuleMember -Function @(
    'Get-HwpBackendCapability',
    'Get-HwpCapabilitySnapshot'
)
