Describe 'hwp-native 저장소 구조' {
    It '스킬 메타데이터와 공용 진입점을 제공한다' {
        Test-Path "$PSScriptRoot/../skill/hwp-native/SKILL.md" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-native/agents/openai.yaml" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-native/scripts/Invoke-HwpNative.ps1" | Should Be $true
    }

    It '공개 배포에 필요한 한국어 문서와 라이선스를 제공한다' {
        foreach ($relativePath in @(
            '../README.md',
            '../LICENSE',
            '../install.ps1',
            '../skill/hwp-native/references/operations.md',
            '../skill/hwp-native/references/safety.md',
            '../skill/hwp-native/references/limitations.md'
        )) {
            Test-Path (Join-Path $PSScriptRoot $relativePath) | Should Be $true
        }

        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw -Encoding UTF8
        $readme | Should Match '한컴오피스'
        $readme | Should Match '상업적 이용'
        $readme | Should Match '보안 모듈'
        $readme | Should Match 'HWPX'
        $readme | Should Match '원본.*덮어쓰'
    }

    It '복사 가능한 편집 및 새 문서 계획 예제를 제공한다' {
        $editExample = Join-Path $PSScriptRoot '../skill/hwp-native/examples/replace-text.plan.json'
        $generateExample = Join-Path $PSScriptRoot '../skill/hwp-native/examples/generate-new.plan.json'
        Test-Path $editExample | Should Be $true
        Test-Path $generateExample | Should Be $true
        { Get-Content -LiteralPath $editExample -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
        { Get-Content -LiteralPath $generateExample -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
    }

    It '편집·검사·새 문서 계획 JSON 스키마가 유효한 JSON이다' {
        foreach ($name in 'edit-plan.schema.json','inspection.schema.json','generate-plan.schema.json') {
            $schemaPath = Join-Path $PSScriptRoot "../skill/hwp-native/schemas/$name"
            Test-Path $schemaPath | Should Be $true
            { Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
        }
    }

    It 'SKILL.md가 간결한 한국어 안전 워크플로를 명시한다' {
        $skillPath = Join-Path $PSScriptRoot '../skill/hwp-native/SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
        (Get-Content -LiteralPath $skillPath -Encoding UTF8).Count | Should BeLessThan 500
        $skill | Should Match '사전 점검'
        $skill | Should Match '검사'
        $skill | Should Match '계획'
        $skill | Should Match '승인'
        $skill | Should Match '다시 열'
        $skill | Should Match '원본'
    }
}
