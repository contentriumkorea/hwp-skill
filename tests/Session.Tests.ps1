$commonModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpSession.psm1'
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
    }
    $fake | Add-Member ScriptMethod Clear {
        param($option)
        $this.ClearCount++
        $true
    }
    $fake | Add-Member ScriptMethod Quit {
        $this.QuitCount++
    }
    $fake
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
