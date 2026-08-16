$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'

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

        {
            New-HwpSession -ExecutionContext (New-HwpExecutionContext) -ComFactory $factory
        } | Should Throw '현재 사용자 세션의 한컴 실행은 interactive 모드에서만 허용됩니다.'
        $calls.Value | Should Be 0
    }

    It 'interactive 모드만 지정하고 창 허용을 생략하면 거부한다' {
        Import-Module $executionModule -Force

        {
            New-HwpExecutionContext -Mode interactive
        } | Should Throw 'interactive 모드는 -AllowInteractiveWindow의 명시적 승인이 필요합니다.'
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

        {
            New-HwpSession -ComFactory $factory
        } | Should Throw '현재 사용자 세션의 한컴 실행은 interactive 모드에서만 허용됩니다.'
        $calls.Value | Should Be 0
    }
}
