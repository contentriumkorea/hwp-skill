Describe 'hwp-skill 저장소 구조' {
    It '내부 SDD 구현 보고서를 공개 Git 이력에 추적하지 않는다' {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $tracked = @(& git -C $repositoryRoot ls-files)
        $trackedReports = @($tracked | Where-Object { $_ -match '^\.superpowers/sdd/.+-report\.md$' })

        @($trackedReports).Count | Should Be 0
    }

    It '스킬 메타데이터와 공용 진입점을 제공한다' {
        Test-Path "$PSScriptRoot/../skills/hwp-skill/SKILL.md" | Should Be $true
        Test-Path "$PSScriptRoot/../skills/hwp-skill/agents/openai.yaml" | Should Be $true
        Test-Path "$PSScriptRoot/../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1" | Should Be $true
        Test-Path "$PSScriptRoot/../skills/hwp-skill/scripts/lib/HwpPortable.psm1" | Should Be $true
        Test-Path "$PSScriptRoot/../skills/hwp-skill/scripts/lib/HwpCompoundFile.cs" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-native" | Should Be $false
    }

    It 'Codex UI에 HWP Skill이라는 영문 표시명을 제공한다' {
        $interface = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/agents/openai.yaml') -Raw -Encoding UTF8
        $displayNameMatch = [regex]::Match($interface, '(?m)^\s{2}display_name:\s*"([^"]+)"\s*$')

        $displayNameMatch.Success | Should Be $true
        $displayNameMatch.Groups[1].Value | Should Be 'HWP Skill'
    }

    It '공개 배포에 필요한 한국어 문서와 라이선스를 제공한다' {
        foreach ($relativePath in @(
            '../README.md',
            '../USAGE.md',
            '../LICENSE',
            '../install.ps1',
            '../skills/hwp-skill/references/operations.md',
            '../skills/hwp-skill/references/safety.md',
            '../skills/hwp-skill/references/limitations.md'
        )) {
            Test-Path (Join-Path $PSScriptRoot $relativePath) | Should Be $true
        }

        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $usage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../USAGE.md') -Raw -Encoding UTF8
        $publicDocs = $readme + "`n" + $usage
        $readme | Should Match 'assets/readme-cover\.svg'
        $readme | Should Match 'assets/document-workflow\.svg'
        $readme | Should Match 'releases/latest/download/hwp-skill\.zip'
        $readme | Should Match 'USAGE\.md'
        $publicDocs | Should Match '한컴오피스'
        $publicDocs | Should Match '상업적 이용'
        $publicDocs | Should Match '보안 모듈'
        $readme | Should Match 'HWPX'
        $publicDocs | Should Match '원본.*덮어쓰'
        $publicDocs | Should Match '콘텐츠리움'
        $publicDocs | Should Match 'https://github.com/contentriumkorea/hwp-skill\.git'
    }

    It '복사 가능한 편집 및 새 문서 계획 예제를 제공한다' {
        $editExample = Join-Path $PSScriptRoot '../skills/hwp-skill/examples/replace-text.plan.json'
        $generateExample = Join-Path $PSScriptRoot '../skills/hwp-skill/examples/generate-new.plan.json'
        Test-Path $editExample | Should Be $true
        Test-Path $generateExample | Should Be $true
        { Get-Content -LiteralPath $editExample -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
        { Get-Content -LiteralPath $generateExample -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
    }

    It '편집·검사·기능·새 문서 계획 JSON 스키마가 유효한 JSON이다' {
        foreach ($name in 'capabilities.schema.json','edit-plan.schema.json','inspection.schema.json','generate-plan.schema.json') {
            $schemaPath = Join-Path $PSScriptRoot "../skills/hwp-skill/schemas/$name"
            Test-Path $schemaPath | Should Be $true
            { Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
            (Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8) | Should Match 'https://github.com/contentriumkorea/hwp-skill/'
        }
    }

    It '기능 스냅샷 모듈은 로컬 COM이나 Hancom 실행을 직접 만들지 않는다' {
        $modulePath = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1'
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
        $cliPath = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        Test-Path $cliPath | Should Be $true

        $content = Get-Content -LiteralPath $cliPath -Raw -Encoding UTF8

        $content | Should Match '\[ValidateSet\(''capabilities'',''format-model'',''preflight'',''inspect'',''validate-plan'',''validate-generate-plan'',''edit-hwpx'',''preview'',''apply'',''generate'',''batch'',''compare'',''verify'',''export''\)\]'
        $content | Should Match '\[ValidateSet\(''silent'',''isolated-native'',''interactive''\)\]\s*\[string\]\$ExecutionMode\s*=\s*''silent'''
        $content | Should Match '\[switch\]\$AllowInteractiveWindow'
        $content | Should Match "'capabilities'\s*\{"
    }

    It '공개 편집 스키마가 위험한 계획 조합을 거부한다' -Skip:($null -eq (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        $schemaPath = Join-Path $PSScriptRoot '../skills/hwp-skill/schemas/edit-plan.schema.json'
        $valid = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/examples/replace-text.plan.json') `
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

    It 'SKILL.md가 단일 silent 오케스트레이션과 한국어 안전 경계를 명시한다' {
        $skillPath = Join-Path $PSScriptRoot '../skills/hwp-skill/SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
        (Get-Content -LiteralPath $skillPath -Encoding UTF8).Count | Should BeLessThan 500
        $skill | Should Match '단일.*(?:진입점|오케스트레이터)'
        $skill | Should Match '내부.*(?:계획|상태)'
        $skill | Should Match '원본'
        $skill | Should Match 'silent'
        $skill | Should Match '진행 안내는 최대 1회'
        $skill | Should Match '원본'
        $skill | Should Match '(?m)^name:\s+hwp-skill\r?$'

        $interface = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/agents/openai.yaml') -Raw -Encoding UTF8
        $interface | Should Match '\$hwp-skill'
        $interface | Should Match '단일 silent'
        $interface | Should Match '내부 계획·명령·엔진 상태'
    }

    It '한글 문서 작성 요청과 무창 기본 정책을 메타데이터에 포함한다' {
        $skill = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/SKILL.md') -Raw -Encoding UTF8
        $skill | Should Match '(?m)^description:\s+Use when'
        $skill | Should Match '한글 문서 파일'
        $skill | Should Match 'HWPX'
        $skill | Should Match 'silent'
        $skill | Should Match '포커스'
        $skill | Should Match 'GUI로 자동 전환하지 않는다'
    }

    It 'README와 상세 안내가 HWP 읽기와 네이티브 편집의 경계를 정확히 설명한다' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $usage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../USAGE.md') -Raw -Encoding UTF8
        $readme | Should Match '보호되지 않은 HWP 5\.x.*한컴 없이'
        $readme | Should Match '기존 HWP/HWT 양식 편집.*현재 자동 경로에서 차단'
        $usage | Should Match 'hwp-portable.*관리 코드'
        $usage | Should Match 'HWP 5\.x[\s\S]*?한컴오피스, 한컴 COM 등록, 보안 모듈을 사용하지 않습니다'
        $usage | Should Match 'HWP/HWT 원본을 직접 열어 내용을 채우는 자동 경로는 현재 차단'
        $usage | Should Match '한글 문서 파일 형식 5\.0 공개 문서'
        $usage | Should Match '현재 사용자 세션.*Hwp\.exe.*실행하지'
    }

    It 'README와 상세 안내는 HWPX 작업과 HWP 마지막 변환을 기본 경로로 설명한다' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $usage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../USAGE.md') -Raw -Encoding UTF8
        $readme | Should Match 'HWPX의 확장자만 바꿔 HWP로 제공하지 않습니다'
        $readme | Should Match '별도 격리 변환기.*기본 배포에는 없습니다'
        $usage | Should Match 'HWPX 작업본을 완성하고 별도 격리 엔진이 있을 때만 마지막 숨김 변환'
        $usage | Should Match 'HWP/HWT 원본을 직접 열어 내용을 채우는 자동 경로는 현재 차단'
        $usage | Should Match 'interactive[\s\S]*한컴 창'
        $usage | Should Match '\-ExecutionMode interactive'
        $usage | Should Match '\-AllowInteractiveWindow'
        $usage | Should Match '한컴을 열 수 있'
    }

    It '상세 안내는 현재 Phase 1 계약과 향후 interactive 설계를 구분한다' {
        $usage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../USAGE.md') -Raw -Encoding UTF8
        $usage | Should Match 'Phase 1 계약'
        $usage | Should Match '미래 구현|향후 구현|future'
        $usage | Should Match '명시적으로 승인된 interactive'
        $usage | Should Match 'HWP/HWT.*네이티브 편집.*자동 실행하지 않는다'
        $usage | Should Match 'HWPX.*숨김 변환'
    }

    It '상세 안내는 현재 시험 실행기 승인 계약과 공개 release 용어를 사용한다' {
        $usage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../USAGE.md') -Raw -Encoding UTF8

        $usage | Should Not Match 'Task 8'
        $usage | Should Not Match '\-Suite Integration'
        $usage | Should Match 'run-tests\.ps1 -Suite Native -AllowInteractiveNative'
        $usage | Should Match 'run-tests\.ps1 -Suite All -AllowInteractiveNative'
        $usage | Should Match 'HWP_NATIVE_RUN_INTEGRATION'
        $usage | Should Match '종료 코드 2'
    }

    It 'README와 상세 안내는 Claude Codex 및 Agent Skills 도구의 설치 경로를 제공한다' {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $usage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../USAGE.md') -Raw -Encoding UTF8

        $readme | Should Match 'npx\s+skills@latest\s+add\s+contentriumkorea/hwp-skill'
        $readme | Should Match "--agent\s+'\*'"
        $readme | Should Match 'releases/latest/download/hwp-skill\.zip'
        $usage | Should Match 'claude\s+plugin\s+marketplace\s+add\s+https://github\.com/contentriumkorea/hwp-skill\.git'
        $usage | Should Match 'claude\s+plugin\s+install\s+hwp-skill@contentrium'
        $usage | Should Match '/hwp-skill:hwp-skill'
        $usage | Should Match '\.\\install\.ps1\s+-Target\s+Claude'
        $usage | Should Match '\.\\install\.ps1\s+-Target\s+Universal'
        $usage | Should Match '\.\\install\.ps1\s+-Target\s+All'
        $usage | Should Match '\.\\package\.ps1'
        $usage | Should Match '외부 스킬 설치 기능.*없는.*웹 채팅'
        $usage | Should Not Match '(?<!s)skill/hwp-skill'
        $usage | Should Not Match '(?<!s)skill\\hwp-skill'
    }
}
