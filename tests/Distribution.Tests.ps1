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
        (@($plugin.PSObject.Properties.Name) -contains 'version') | Should Be $false
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
        $skill | Should Match '(?m)^## 지원 환경\r?$'
        $skill | Should Match 'Windows PowerShell 5\.1'
        $skill | Should Match 'AI 에이전트의 정식 작업 형식'
        $skill | Should Not Match 'Codex의 정식 작업 형식'
    }
}

Describe '독립 HWP Skill ZIP 패키지' {
    BeforeEach {
        $script:packageScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../package.ps1'))
        $script:packagePath = Join-Path $TestDrive ('hwp-skill-' + [guid]::NewGuid().ToString('n') + '.zip')
    }

    It 'ZIP 최상위 hwp-skill 폴더에 필수 파일과 실행 스크립트를 포함한다' {
        $null = & $packageScript -OutputPath $packagePath

        Test-Path -LiteralPath $packagePath -PathType Leaf | Should Be $true
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
        try {
            $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
            ($entryNames -contains 'hwp-skill/SKILL.md') | Should Be $true
            ($entryNames -contains 'hwp-skill/scripts/Invoke-HwpSkill.ps1') | Should Be $true
            @($entryNames | Where-Object { $_ -match '^hwp-skill/' }).Count | Should BeGreaterThan 2
        }
        finally {
            $archive.Dispose()
        }
    }

    It 'Force 없이는 기존 ZIP을 덮어쓰지 않는다' {
        $originalBytes = [byte[]](0x50,0x52,0x45,0x53,0x45,0x52,0x56,0x45)
        [IO.File]::WriteAllBytes($packagePath, $originalBytes)
        $beforeHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
        $errorMessage = ''

        try {
            $null = & $packageScript -OutputPath $packagePath
        }
        catch {
            $errorMessage = $_.Exception.Message
        }

        $errorMessage | Should Match '이미|existing|Force'
        (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash | Should Be $beforeHash
    }
}
