Describe 'hwp-skill 저장소 구조' {
    It '스킬 메타데이터와 공용 진입점을 제공한다' {
        Test-Path "$PSScriptRoot/../skill/hwp-skill/SKILL.md" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-skill/agents/openai.yaml" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-native" | Should Be $false
    }

    It 'Codex UI에 HWP Skill이라는 영문 표시명을 제공한다' {
        $interface = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skill/hwp-skill/agents/openai.yaml') -Raw -Encoding UTF8
        $displayNameMatch = [regex]::Match($interface, '(?m)^\s{2}display_name:\s*"([^"]+)"\s*$')

        $displayNameMatch.Success | Should Be $true
        $displayNameMatch.Groups[1].Value | Should Be 'HWP Skill'
    }

    It '공개 배포에 필요한 한국어 문서와 라이선스를 제공한다' {
        foreach ($relativePath in @(
            '../README.md',
            '../LICENSE',
            '../install.ps1',
            '../skill/hwp-skill/references/operations.md',
            '../skill/hwp-skill/references/safety.md',
            '../skill/hwp-skill/references/limitations.md'
        )) {
            Test-Path (Join-Path $PSScriptRoot $relativePath) | Should Be $true
        }

        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $readme | Should Match '한컴오피스'
        $readme | Should Match '상업적 이용'
        $readme | Should Match '보안 모듈'
        $readme | Should Match 'HWPX'
        $readme | Should Match '원본.*덮어쓰'
        $readme | Should Match '콘텐츠리움'
        $readme | Should Match 'https://github.com/contentriumkorea/hwp-skill.git'
    }

    It '복사 가능한 편집 및 새 문서 계획 예제를 제공한다' {
        $editExample = Join-Path $PSScriptRoot '../skill/hwp-skill/examples/replace-text.plan.json'
        $generateExample = Join-Path $PSScriptRoot '../skill/hwp-skill/examples/generate-new.plan.json'
        Test-Path $editExample | Should Be $true
        Test-Path $generateExample | Should Be $true
        { Get-Content -LiteralPath $editExample -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
        { Get-Content -LiteralPath $generateExample -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
    }

    It '편집·검사·기능·새 문서 계획 JSON 스키마가 유효한 JSON이다' {
        foreach ($name in 'capabilities.schema.json','edit-plan.schema.json','inspection.schema.json','generate-plan.schema.json') {
            $schemaPath = Join-Path $PSScriptRoot "../skill/hwp-skill/schemas/$name"
            Test-Path $schemaPath | Should Be $true
            { Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
            (Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8) | Should Match 'https://github.com/contentriumkorea/hwp-skill/'
        }
    }

    It '기능 스냅샷 모듈은 로컬 COM이나 Hancom 실행을 직접 만들지 않는다' {
        $modulePath = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1'
        Test-Path $modulePath | Should Be $true

        $content = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8

        $content | Should Match 'GetTypeFromProgID'
        $content | Should Not Match 'New-Object\s+-ComObject'
        $content | Should Not Match 'Activator\s*::\s*CreateInstance'
        $content | Should Not Match 'New-HwpSession'
        $content | Should Not Match 'Start-Process'
        $content | Should Not Match 'Hwp\.exe'
    }

    It '공용 CLI는 silent 실행 모드와 기능 조회 명령을 노출한다' {
        $cliPath = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        Test-Path $cliPath | Should Be $true

        $content = Get-Content -LiteralPath $cliPath -Raw -Encoding UTF8

        $content | Should Match '\[ValidateSet\(''capabilities'',''preflight'',''inspect'',''validate-plan'',''apply'',''generate'',''batch'',''compare'',''verify'',''export''\)\]'
        $content | Should Match '\[ValidateSet\(''silent'',''isolated-native'',''interactive''\)\]\s*\[string\]\$ExecutionMode\s*=\s*''silent'''
        $content | Should Match '\[switch\]\$AllowInteractiveWindow'
        $content | Should Match "'capabilities'\s*\{"
    }

    It '공개 편집 스키마가 위험한 계획 조합을 거부한다' {
        $schemaPath = Join-Path $PSScriptRoot '../skill/hwp-skill/schemas/edit-plan.schema.json'
        $valid = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skill/hwp-skill/examples/replace-text.plan.json') `
            -Raw -Encoding UTF8 | ConvertFrom-Json

        (($valid | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $true

        $valid.operations[0].target.anchor = ''
        (($valid | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        $valid.operations[0].target.anchor = '기존 사업명'

        $valid.operations[0].expectedMatches = 2
        (($valid | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
        $valid.operations[0].expectedMatches = 1

        $valid.operations[0].type = 'merge-documents'
        $valid.operations[0].risk = 'safe'
        (($valid | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false

        $valid.operations[0].risk = 'advanced'
        $valid.approvedAdvanced = $false
        (($valid | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should Be $false
    }

    It 'SKILL.md가 간결한 한국어 안전 워크플로를 명시한다' {
        $skillPath = Join-Path $PSScriptRoot '../skill/hwp-skill/SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
        (Get-Content -LiteralPath $skillPath -Encoding UTF8).Count | Should BeLessThan 500
        $skill | Should Match '사전 점검'
        $skill | Should Match '검사'
        $skill | Should Match '계획'
        $skill | Should Match '승인'
        $skill | Should Match '다시 열'
        $skill | Should Match '원본'
        $skill | Should Match '(?m)^name:\s+hwp-skill\r?$'

        $interface = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skill/hwp-skill/agents/openai.yaml') -Raw -Encoding UTF8
        $interface | Should Match '\$hwp-skill'
    }

    It '한글 문서 작성 요청과 무창 기본 정책을 메타데이터에 포함한다' {
        $skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skill/hwp-skill/SKILL.md') -Raw -Encoding UTF8
        $skill | Should Match '(?m)^description:\s+Use when'
        $skill | Should Match '한글 문서 파일'
        $skill | Should Match 'HWPX'
        $skill | Should Match 'silent'
        $skill | Should Match '포커스'
        $skill | Should Match 'GUI로 자동 전환하지 않는다'
    }

    It 'README가 현재 단계에서 HWP 휴대형 엔진을 완료로 과장하지 않는다' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $readme | Should Match 'hwp-portable.*준비되지'
        $readme | Should Match '현재 사용자 세션.*Hwp.exe.*실행하지'
    }
}
