Describe 'hwp-native 설치 도구' {
    BeforeEach {
        $script:installer = Join-Path $PSScriptRoot '../install.ps1'
        $script:destinationRoot = Join-Path $TestDrive 'skills'
    }

    It '빈 대상에 hwp-native 스킬만 설치한다' {
        $result = & $installer -DestinationRoot $destinationRoot

        $result.Status | Should Be 'PASS'
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
}
