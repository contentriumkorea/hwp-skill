$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'

function Invoke-TestScriptBlockAndCaptureError {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

    try {
        & $ScriptBlock
        $null
    }
    catch {
        $_.Exception.Message
    }
}

Describe 'HWP 실행 컨텍스트' {
    It '기본 모드는 silent이며 대화형 창을 허용하지 않는다' {
        Test-Path -LiteralPath $executionModule | Should Be $true
        Import-Module $executionModule -Force

        $context = New-HwpExecutionContext

        $context.Mode | Should Be 'silent'
        $context.AllowInteractiveWindow | Should Be $false
    }

    It 'silent 컨텍스트에서는 COM 팩터리를 호출하지 않는다' {
        Import-Module $executionModule -Force
        Import-Module $sessionModule -Force
        $calls = [pscustomobject]@{ Value = 0 }
        $factory = {
            param($progId)
            $calls.Value++
            throw 'COM 팩터리를 호출하면 안 됩니다.'
        }.GetNewClosure()

        $errorMessage = Invoke-TestScriptBlockAndCaptureError {
            New-HwpSession -ExecutionContext (New-HwpExecutionContext) -ComFactory $factory
        }

        $errorMessage | Should Match 'interactive'
        $calls.Value | Should Be 0
    }

    It 'interactive 모드만 지정하고 창 허용을 생략하면 거부한다' {
        Import-Module $executionModule -Force

        $errorMessage = Invoke-TestScriptBlockAndCaptureError {
            New-HwpExecutionContext -Mode interactive
        }

        $errorMessage | Should Match 'AllowInteractiveWindow'
    }

    It '실행 컨텍스트를 생략해도 silent 기본값으로 해석하고 COM 팩터리를 호출하지 않는다' {
        Import-Module $executionModule -Force
        Import-Module $sessionModule -Force
        $calls = [pscustomobject]@{ Value = 0 }
        $factory = {
            param($progId)
            $calls.Value++
            throw 'COM 팩터리를 호출하면 안 됩니다.'
        }.GetNewClosure()

        $errorMessage = Invoke-TestScriptBlockAndCaptureError {
            New-HwpSession -ComFactory $factory
        }

        $errorMessage | Should Match 'interactive'
        $calls.Value | Should Be 0
    }
}
