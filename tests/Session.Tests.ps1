$commonModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'
Import-Module $commonModule -Force
if (Test-Path -LiteralPath $sessionModule) {
    Import-Module $sessionModule -Force
}

function New-FakeHwpObject {
    param([string]$Version = '13, 0, 0, 711')

    $fake = [pscustomobject]@{
        Version = $Version
        QuitCount = 0
        ClearCount = 0
        RegisterModuleResult = $true
        RegisterCalls = [Collections.Generic.List[string]]::new()
    }
    $fake | Add-Member ScriptMethod Clear {
        param($option)
        $this.ClearCount++
        $true
    }
    $fake | Add-Member ScriptMethod Quit {
        $this.QuitCount++
    }
    $fake | Add-Member ScriptMethod RegisterModule {
        param($moduleType, $moduleName)
        $this.RegisterCalls.Add("$moduleType|$moduleName")
        [bool]$this.RegisterModuleResult
    }
    $fake
}

Describe 'Register-HwpSecurityModules' {
    It '등록 정보가 없으면 파일을 열기 전에 BLOCKED로 반환한다' {
        $fake = New-FakeHwpObject
        $session = [pscustomobject]@{ Hwp=$fake; Owned=$true; Closed=$false }

        $result = Register-HwpSecurityModules -Session $session -SecurityModuleReader { @() }

        $result.Status | Should Be 'BLOCKED'
        $fake.RegisterCalls.Count | Should Be 0
        $result.Data.RegistryWritePerformed | Should Be $false
    }

    It '등록 정보 조회가 실패하면 예외 대신 BLOCKED 결과를 반환한다' {
        $fake = New-FakeHwpObject
        $session = [pscustomobject]@{ Hwp=$fake; Owned=$true; Closed=$false }

        $result = Register-HwpSecurityModules -Session $session -SecurityModuleReader { throw 'registry unavailable' }

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '등록 정보를 읽지 못했습니다'
        $fake.RegisterCalls.Count | Should Be 0
    }

    It '레지스트리에 이미 있는 모듈 이름만 한컴 세션에 등록한다' {
        $fake = New-FakeHwpObject
        $session = [pscustomobject]@{ Hwp=$fake; Owned=$true; Closed=$false }

        $result = Register-HwpSecurityModules -Session $session -SecurityModuleReader { @('FilePathCheckerModuleExample') }

        $result.Status | Should Be 'PASS'
        $fake.RegisterCalls[0] | Should Be 'FilePathCheckDLL|FilePathCheckerModuleExample'
        $result.Data.RegisteredModules[0] | Should Be 'FilePathCheckerModuleExample'
    }

    It 'RegisterModule이 거짓을 반환하면 승인 성공으로 간주하지 않는다' {
        $fake = New-FakeHwpObject
        $fake.RegisterModuleResult = $false
        $session = [pscustomobject]@{ Hwp=$fake; Owned=$true; Closed=$false }

        $result = Register-HwpSecurityModules -Session $session -SecurityModuleReader { @('BrokenModule') }

        $result.Status | Should Be 'BLOCKED'
        $result.Errors[0] | Should Match '활성화'
    }
}

Describe 'New-HwpSession' {
    It '첫 ProgID가 실패하면 두 번째 ProgID를 사용한다' {
        $fake = New-FakeHwpObject
        $attempts = [Collections.Generic.List[string]]::new()
        $factory = {
            param($progId)
            $attempts.Add($progId)
            if ($progId -eq 'HWPFrame.HwpObject.2') {
                throw 'class not registered'
            }
            $fake
        }.GetNewClosure()

        $session = New-HwpSession -ComFactory $factory

        $session.ProgId | Should Be 'HWPFrame.HwpObject'
        $session.Version | Should Be '13, 0, 0, 711'
        $attempts.Count | Should Be 2
    }

    It '만든 세션을 소유 상태로 표시한다' {
        $fake = New-FakeHwpObject
        $factory = { param($progId) $fake }.GetNewClosure()

        $session = New-HwpSession -Visible $false -ComFactory $factory

        $session.Owned | Should Be $true
        $session.Visible | Should Be $false
        $session.Closed | Should Be $false
    }

    It '프로세스 소유권을 입증하지 못하면 빌린 세션으로 표시한다' {
        $fake = New-FakeHwpObject
        $factory = { param($progId) $fake }.GetNewClosure()
        $resolver = {
            param($hwp,$beforeIds,$isComObject)
            [pscustomobject]@{ Owned = $false; ProcessId = 309564; Reason = 'existing-process' }
        }

        $session = New-HwpSession -ComFactory $factory -ProcessOwnershipResolver $resolver
        Close-HwpSession -Session $session

        $session.Owned | Should Be $false
        $session.ProcessId | Should Be 309564
        $session.OwnershipReason | Should Be 'existing-process'
        $fake.ClearCount | Should Be 0
        $fake.QuitCount | Should Be 0
        $session.Closed | Should Be $true
    }

    It '첫 생성 주기의 두 ProgID가 모두 실패하면 제한 횟수 안에서 다시 시도한다' {
        $fake = New-FakeHwpObject
        $attempts = [Collections.Generic.List[string]]::new()
        $factory = {
            param($progId)
            $attempts.Add($progId)
            if ($attempts.Count -le 2) {
                throw 'RPC server is stopping'
            }
            $fake
        }.GetNewClosure()

        $session = New-HwpSession -ComFactory $factory -RetryCount 2 -RetryDelayMilliseconds 0

        $session.Hwp | Should Be $fake
        $attempts.Count | Should Be 3
    }
}

Describe 'Close-HwpSession' {
    It '소유한 세션에만 Clear와 Quit을 호출한다' {
        $ownedHwp = New-FakeHwpObject
        $owned = [pscustomobject]@{
            Hwp = $ownedHwp
            Owned = $true
            Closed = $false
            Version = 'test'
            ProgId = 'fake'
        }
        $borrowedHwp = New-FakeHwpObject
        $borrowed = [pscustomobject]@{
            Hwp = $borrowedHwp
            Owned = $false
            Closed = $false
            Version = 'test'
            ProgId = 'fake'
        }

        Close-HwpSession -Session $owned
        Close-HwpSession -Session $borrowed

        $ownedHwp.ClearCount | Should Be 1
        $ownedHwp.QuitCount | Should Be 1
        $borrowedHwp.ClearCount | Should Be 0
        $borrowedHwp.QuitCount | Should Be 0
    }

    It '같은 세션을 두 번 닫아도 Quit을 한 번만 호출한다' {
        $fake = New-FakeHwpObject
        $session = [pscustomobject]@{
            Hwp = $fake
            Owned = $true
            Closed = $false
            Version = 'test'
            ProgId = 'fake'
        }

        Close-HwpSession -Session $session
        Close-HwpSession -Session $session

        $fake.QuitCount | Should Be 1
    }
}

Describe 'Invoke-HwpPreflight' {
    It '등록된 COM 객체가 없으면 BLOCKED를 반환한다' {
        $result = Invoke-HwpPreflight -ComFactory { param($progId) throw 'class not registered' }

        $result.Status | Should Be 'BLOCKED'
        $result.Errors[0] | Should Match '한컴오피스 자동화'
    }

    It '보안 모듈이 없으면 무인 열기 준비 경고를 반환한다' {
        $fake = New-FakeHwpObject
        $factory = { param($progId) $fake }.GetNewClosure()

        $result = Invoke-HwpPreflight -ComFactory $factory -SecurityModuleReader { @() }

        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.Data.UnattendedOpenReady | Should Be $false
        $result.Warnings[0] | Should Match '보안 모듈'
        $fake.QuitCount | Should Be 1
    }

    It '무인 열기가 필수인데 보안 모듈이 없으면 BLOCKED를 반환한다' {
        $fake = New-FakeHwpObject
        $factory = { param($progId) $fake }.GetNewClosure()

        $result = Invoke-HwpPreflight -RequireUnattendedOpen -ComFactory $factory -SecurityModuleReader { @() }

        $result.Status | Should Be 'BLOCKED'
        $result.Data.UnattendedOpenReady | Should Be $false
        $fake.QuitCount | Should Be 1
    }

    It 'COM과 보안 모듈이 준비되면 PASS를 반환한다' {
        $fake = New-FakeHwpObject
        $factory = { param($progId) $fake }.GetNewClosure()

        $result = Invoke-HwpPreflight -ComFactory $factory -SecurityModuleReader { @('FilePathCheckerModule') }

        $result.Status | Should Be 'PASS'
        $result.Data.Version | Should Be '13, 0, 0, 711'
        $result.Data.SecurityModules[0] | Should Be 'FilePathCheckerModule'
    }
}
