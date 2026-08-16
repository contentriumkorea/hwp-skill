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

    $null -ne $ExecutionContext -and
        $ExecutionContext.PSObject.Properties.Name -contains 'Mode' -and
        $ExecutionContext.PSObject.Properties.Name -contains 'AllowInteractiveWindow' -and
        [string]$ExecutionContext.Mode -in 'silent', 'isolated-native', 'interactive'
}

function Assert-HwpLocalGuiAllowed {
    param([Parameter(Mandatory)][object]$ExecutionContext)

    if (-not (Test-HwpExecutionContext $ExecutionContext)) {
        throw '유효한 HWP 실행 컨텍스트가 필요합니다.'
    }
    if ([string]$ExecutionContext.Mode -ne 'interactive' -or
        -not [bool]$ExecutionContext.AllowInteractiveWindow) {
        throw '현재 사용자 세션의 한컴 실행은 interactive 모드에서만 허용됩니다.'
    }
}

Export-ModuleMember -Function @(
    'New-HwpExecutionContext',
    'Test-HwpExecutionContext',
    'Assert-HwpLocalGuiAllowed'
)
