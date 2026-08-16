Describe 'hwp-native 설치 도구' {
    BeforeEach {
        $script:installer = Join-Path $PSScriptRoot '../install.ps1'
        $script:destinationRoot = Join-Path $TestDrive ('skills-' + [guid]::NewGuid().ToString('n'))
    }

    It '빈 대상에 hwp-native 스킬만 설치한다' {
        $result = & $installer -DestinationRoot $destinationRoot

        $result.Status | Should Be 'PASS'
        @($result.Warnings).Count | Should Be 0
        Test-Path (Join-Path $destinationRoot 'hwp-native/SKILL.md') | Should Be $true
        @(Get-ChildItem -LiteralPath $destinationRoot -Directory).Count | Should Be 1
    }

    It '기존 설치는 Update 없이는 덮어쓰지 않는다' {
        $null = & $installer -DestinationRoot $destinationRoot
        $marker = Join-Path $destinationRoot 'hwp-native/user-marker.txt'
        Set-Content -LiteralPath $marker -Value '보존' -Encoding UTF8

        $result = & $installer -DestinationRoot $destinationRoot

        $result.Status | Should Be 'BLOCKED'
        (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() | Should Be '보존'
    }

    It 'Update 시 기존 설치를 백업하고 새 버전으로 교체한다' {
        $null = & $installer -DestinationRoot $destinationRoot
        $marker = Join-Path $destinationRoot 'hwp-native/user-marker.txt'
        Set-Content -LiteralPath $marker -Value '백업 확인' -Encoding UTF8

        $result = & $installer -DestinationRoot $destinationRoot -Update

        $result.Status | Should Be 'PASS'
        Test-Path (Join-Path $destinationRoot 'hwp-native/SKILL.md') | Should Be $true
        Test-Path $marker | Should Be $false
        Test-Path (Join-Path $result.BackupPath 'user-marker.txt') | Should Be $true
        (Split-Path -Leaf (Split-Path -Parent $result.BackupPath)) | Should Be '.hwp-native-backups'
    }

    It '드라이브 루트 자체를 설치 대상으로 사용하지 않는다' {
        $root = [IO.Path]::GetPathRoot($TestDrive)

        $result = & $installer -DestinationRoot $root

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '루트'
    }

    It '업데이트 후 검증 실패 시 새 설치본을 격리하고 기존 설치를 복원한다' {
        $null = & $installer -DestinationRoot $destinationRoot
        $marker = Join-Path $destinationRoot 'hwp-native/user-marker.txt'
        Set-Content -LiteralPath $marker -Value '복원 대상' -Encoding UTF8
        $validationCalls = [pscustomobject]@{ Value = 0 }
        $validator = {
            param($path)
            $validationCalls.Value++
            if ($validationCalls.Value -ge 2) { throw '의도한 설치 후 검증 실패' }
            $true
        }.GetNewClosure()

        $result = & $installer -DestinationRoot $destinationRoot -Update -InstallValidator $validator

        $result.Status | Should Be 'FAILED'
        $result.RollbackStatus | Should Be 'PASS'
        (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() | Should Be '복원 대상'
        Test-Path -LiteralPath $result.FailedInstallPath | Should Be $true
    }

    It '백업 폴더가 junction이면 업데이트 전에 차단한다' {
        $null = & $installer -DestinationRoot $destinationRoot
        $marker = Join-Path $destinationRoot 'hwp-native/user-marker.txt'
        Set-Content -LiteralPath $marker -Value 'junction 보존' -Encoding UTF8
        $outside = Join-Path $TestDrive 'outside-backup'
        $backupLink = Join-Path $destinationRoot '.hwp-native-backups'
        New-Item -ItemType Directory -Path $outside | Out-Null
        New-Item -ItemType Junction -Path $backupLink -Target $outside | Out-Null

        $result = & $installer -DestinationRoot $destinationRoot -Update

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match 'reparse|junction|링크'
        (Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim() | Should Be 'junction 보존'
        @(Get-ChildItem -LiteralPath $outside -Force).Count | Should Be 0
        [IO.Directory]::Delete($backupLink)
    }
}
