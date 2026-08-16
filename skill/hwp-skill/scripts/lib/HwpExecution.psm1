Set-StrictMode -Version Latest

function New-HwpExecutionContext {
    [CmdletBinding()]
    param(
        [ValidateSet('silent', 'isolated-native', 'interactive')]
        [string]$Mode = 'silent',
        [switch]$AllowInteractiveWindow
    )

    if ($Mode -eq 'interactive' -and -not $AllowInteractiveWindow) {
        throw 'interactive 모드는 -AllowInteractiveWindow의 명시적 승인이 필요합니다.'
    }
    if ($Mode -ne 'interactive' -and $AllowInteractiveWindow) {
        throw '-AllowInteractiveWindow는 interactive 모드에서만 사용할 수 있습니다.'
    }

    [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        Mode = $Mode
        AllowInteractiveWindow = [bool]$AllowInteractiveWindow
    }
}

function Test-HwpExecutionContext {
    param([AllowNull()][object]$ExecutionContext)

    if ($null -eq $ExecutionContext) { return $false }

    $propertyNames = @($ExecutionContext.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'SchemaVersion' -or
        $propertyNames -notcontains 'Mode' -or
        $propertyNames -notcontains 'AllowInteractiveWindow') {
        return $false
    }

    $ExecutionContext.SchemaVersion -is [string] -and
        [string]::Equals([string]$ExecutionContext.SchemaVersion, '1.0', [StringComparison]::Ordinal) -and
        $ExecutionContext.Mode -is [string] -and
        [string]$ExecutionContext.Mode -in 'silent', 'isolated-native', 'interactive' -and
        $ExecutionContext.AllowInteractiveWindow -is [bool]
}

function Assert-HwpLocalGuiAllowed {
    param([Parameter(Mandatory)][object]$ExecutionContext)

    if (-not (Test-HwpExecutionContext $ExecutionContext)) {
        throw '유효한 HWP 실행 컨텍스트가 필요합니다.'
    }
    if ([string]$ExecutionContext.Mode -ne 'interactive' -or
        $ExecutionContext.AllowInteractiveWindow -ne $true) {
        throw '현재 사용자 세션의 한컴 실행은 interactive 모드에서만 허용됩니다.'
    }
}

Export-ModuleMember -Function @(
    'New-HwpExecutionContext',
    'Test-HwpExecutionContext',
    'Assert-HwpLocalGuiAllowed'
)
