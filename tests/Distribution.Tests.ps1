Describe '범용 Agent Skills 배포 구조' {
    BeforeAll {
        $script:repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $script:skillRoot = Join-Path $repositoryRoot 'skills/hwp-skill'
        $script:pluginManifestPath = Join-Path $repositoryRoot '.claude-plugin/plugin.json'
        $script:marketplaceManifestPath = Join-Path $repositoryRoot '.claude-plugin/marketplace.json'
    }

    It '표준 skills 경로에 단일 원본만 둔다' {
        Test-Path (Join-Path $skillRoot 'SKILL.md') -PathType Leaf | Should Be $true
        Test-Path (Join-Path $repositoryRoot 'skill/hwp-skill/SKILL.md') -PathType Leaf | Should Be $false
    }

    It 'Claude plugin과 marketplace manifest를 제공한다' {
        $plugin = Get-Content -LiteralPath $pluginManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $marketplace = Get-Content -LiteralPath $marketplaceManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $plugin.name | Should Be 'hwp-skill'
        $plugin.displayName | Should Be 'HWP Skill'
        $plugin.PSObject.Properties.Name | Should Not Contain 'version'
        $marketplace.name | Should Be 'contentrium'
        @($marketplace.plugins).Count | Should Be 1
        $marketplace.plugins[0].name | Should Be 'hwp-skill'
        $marketplace.plugins[0].source.source | Should Be 'github'
        $marketplace.plugins[0].source.repo | Should Be 'contentriumkorea/hwp-skill'
    }

    It 'Claude JSON manifest를 UTF-8 BOM 없이 저장한다' {
        foreach ($path in $pluginManifestPath,$marketplaceManifestPath) {
            $bytes = [IO.File]::ReadAllBytes($path)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
        }
    }

    It 'Agent Skills 메타데이터가 제품 중립 호출과 실행 환경을 설명한다' {
        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw -Encoding UTF8

        $skill | Should Match '(?m)^name:\s+hwp-skill\r?$'
        $skill | Should Match '(?m)^description:\s+Use when AI 도구가'
        $skill | Should Match '(?m)^compatibility:\s+.+'
        $skill | Should Match 'AI 에이전트의 정식 작업 형식'
        $skill | Should Not Match 'Codex의 정식 작업 형식'
    }
}
