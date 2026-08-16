$modulePath = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCommon.psm1'
if (Test-Path -LiteralPath $modulePath) {
    Import-Module $modulePath -Force
}

function Test-Throws {
    param([scriptblock]$ScriptBlock)

    try {
        & $ScriptBlock
        $false
    }
    catch {
        $true
    }
}

Describe 'Get-HwpFileKind' {
    It 'OLE 문서가 HWPX 확장자를 쓰면 불일치로 보고한다' {
        $path = Join-Path $TestDrive 'wrong.hwpx'
        [IO.File]::WriteAllBytes($path, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))

        $actual = Get-HwpFileKind -LiteralPath $path

        $actual.DetectedKind | Should Be 'HWP-BINARY'
        $actual.ExtensionMatches | Should Be $false
    }

    It 'PK ZIP 시그니처와 HWPX 확장자를 일치로 보고한다' {
        $path = Join-Path $TestDrive 'valid.hwpx'
        [IO.File]::WriteAllBytes($path, [byte[]](0x50,0x4B,0x03,0x04))

        $actual = Get-HwpFileKind -LiteralPath $path

        $actual.DetectedKind | Should Be 'HWPX-ZIP'
        $actual.ExtensionMatches | Should Be $true
    }

    It 'OLE 시그니처와 HWT 확장자를 일치로 보고한다' {
        $path = Join-Path $TestDrive 'template.hwt'
        [IO.File]::WriteAllBytes($path, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))

        (Get-HwpFileKind -LiteralPath $path).ExtensionMatches | Should Be $true
    }

    It '알 수 없는 시그니처를 UNKNOWN으로 보고한다' {
        $path = Join-Path $TestDrive 'unknown.hwp'
        [IO.File]::WriteAllBytes($path, [byte[]](0x01,0x02,0x03,0x04))

        $actual = Get-HwpFileKind -LiteralPath $path

        $actual.DetectedKind | Should Be 'UNKNOWN'
        $actual.ExtensionMatches | Should Be $false
    }
}

Describe '공통 파일 안전 함수' {
    It '같은 폴더에 _수정본_yyyyMMdd_HHmmss 이름을 만든다' {
        $source = Join-Path $TestDrive '보고서.hwp'
        Set-Content -LiteralPath $source -Value 'x'

        $actual = Get-HwpVersionedPath -LiteralPath $source -Now ([datetime]'2026-08-16T14:30:00')

        [IO.Path]::GetFileName($actual) | Should Be '보고서_수정본_20260816_143000.hwp'
        $actual | Should Not Be $source
    }

    It '같은 시각의 결과가 이미 있으면 순번을 붙인다' {
        $source = Join-Path $TestDrive '보고서.hwp'
        Set-Content -LiteralPath $source -Value 'x'
        $existing = Join-Path $TestDrive '보고서_수정본_20260816_143000.hwp'
        Set-Content -LiteralPath $existing -Value '기존 결과'

        $actual = Get-HwpVersionedPath -LiteralPath $source -Now ([datetime]'2026-08-16T14:30:00')

        [IO.Path]::GetFileName($actual) | Should Be '보고서_수정본_20260816_143000_01.hwp'
    }

    It 'SHA-256을 소문자 64자리로 반환한다' {
        $path = Join-Path $TestDrive 'hash.hwp'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes('abc'))

        Get-HwpSha256 -LiteralPath $path | Should Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }

    It '지원하지 않는 확장자를 거부한다' {
        $path = Join-Path $TestDrive 'document.txt'
        Set-Content -LiteralPath $path -Value 'x'

        Test-Throws { Resolve-HwpLiteralPath -LiteralPath $path } | Should Be $true
    }

    It '정해진 완료 상태만 결과로 만든다' {
        $result = New-HwpResult -Status PASS -Command inspect -Data @{ value = 1 }

        $result.Status | Should Be 'PASS'
        $result.Command | Should Be 'inspect'
        $result.Warnings.Count | Should Be 0
        Test-Throws { New-HwpResult -Status UNKNOWN -Command inspect } | Should Be $true
    }
}

Describe '공개 JSON 스키마' {
    It '편집 계획 스키마의 핵심 필드를 필수로 고정한다' {
        $path = Join-Path $PSScriptRoot '../skill/hwp-skill/schemas/edit-plan.schema.json'
        $schema = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json

        foreach ($name in 'version','source','approvedAdvanced','operations') {
            ($schema.required -contains $name) | Should Be $true
        }
    }

    It '검사 결과 스키마의 핵심 필드를 필수로 고정한다' {
        $path = Join-Path $PSScriptRoot '../skill/hwp-skill/schemas/inspection.schema.json'
        $schema = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json

        foreach ($name in 'status','path','sha256','detectedKind','text','fields','controls','pageCount','warnings') {
            ($schema.required -contains $name) | Should Be $true
        }
    }
}
