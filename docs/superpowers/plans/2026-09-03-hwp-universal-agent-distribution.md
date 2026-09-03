# HWP Skill 범용 AI 도구 배포 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 하나의 `hwp-skill` 원본을 Claude Code, Codex 및 Agent Skills 호환 AI 도구에 설치하고 검증할 수 있게 한다.

**Architecture:** 스킬 원본을 표준 `skills/hwp-skill` 경로로 이동하고 Claude 플러그인·마켓플레이스 메타데이터를 저장소 루트에 둔다. 범용 도구 설치는 `npx skills`에 맡기고, 기존 PowerShell 설치기는 Codex·Claude·공용 Agent Skills 경로를 안전하게 처리하도록 확장한다.

**Tech Stack:** PowerShell 5.1/7, Pester 4, Agent Skills 표준, Claude Code plugin manifests, ZIP

**Spec:** `docs/superpowers/specs/2026-09-03-hwp-universal-agent-distribution-design.md`

## Global Constraints

- 스킬 원본은 `skills/hwp-skill` 한 곳에만 존재한다.
- 기본 PowerShell 설치 대상은 기존과 같은 `Codex`다.
- HWPX 우선, 무창 실행, HWP 마지막 변환, 원본 보존 계약은 변경하지 않는다.
- Claude 플러그인과 마켓플레이스 JSON은 UTF-8 BOM 없이 저장한다.
- 외부 스킬 설치 기능이 없는 웹 채팅은 지원 대상으로 표현하지 않는다.
- 기존 설치는 `-Update` 없이 덮어쓰지 않고 실패 시 대상별로 복원한다.

---

### Task 1: 범용 배포 계약의 실패 시험

**Files:**
- Create: `tests/Distribution.Tests.ps1`
- Modify: `tests/Repository.Tests.ps1`
- Modify: `tests/Installer.Tests.ps1`

**Interfaces:**
- Consumes: 현재 `skill/hwp-skill`, Codex 전용 `install.ps1`
- Produces: 표준 경로·Claude manifest·설치 대상·ZIP 구조를 요구하는 RED 시험

- [ ] **Step 1: 표준 저장소 구조와 Claude 매니페스트 시험 작성**

```powershell
Describe '범용 Agent Skills 배포 구조' {
    It '표준 skills 경로에 단일 원본만 둔다' {
        Test-Path "$PSScriptRoot/../skills/hwp-skill/SKILL.md" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-skill/SKILL.md" | Should Be $false
    }

    It 'Claude plugin과 marketplace manifest를 제공한다' {
        $plugin = Get-Content "$PSScriptRoot/../.claude-plugin/plugin.json" -Raw | ConvertFrom-Json
        $market = Get-Content "$PSScriptRoot/../.claude-plugin/marketplace.json" -Raw | ConvertFrom-Json
        $plugin.name | Should Be 'hwp-skill'
        $market.name | Should Be 'contentrium'
        $market.plugins[0].name | Should Be 'hwp-skill'
    }
}
```

- [ ] **Step 2: 제품별 설치 경로 시험 작성**

```powershell
It 'Claude 대상은 임시 프로필의 .claude skills에 설치한다' {
    $profile = Join-Path $TestDrive 'profile'
    $result = & $installer -Target Claude -ProfileRoot $profile
    $result.Status | Should Be 'PASS'
    $result.InstallPath | Should Be ([IO.Path]::GetFullPath("$profile/.claude/skills/hwp-skill"))
}

It 'All 대상은 Codex Claude Universal 세 경로를 설치한다' {
    $profile = Join-Path $TestDrive 'profile-all'
    $result = & $installer -Target All -ProfileRoot $profile
    $result.Status | Should Be 'PASS'
    @($result.Results).Count | Should Be 3
}
```

- [ ] **Step 3: 새 시험이 기대한 이유로 실패하는지 확인**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Script '.\tests\Distribution.Tests.ps1','.\tests\Installer.Tests.ps1' -PassThru"
```

Expected: `skills/hwp-skill`, `.claude-plugin` 또는 `Target` 매개변수가 없어서 FAIL.

- [ ] **Step 4: RED 시험 커밋**

```powershell
git add tests/Distribution.Tests.ps1 tests/Repository.Tests.ps1 tests/Installer.Tests.ps1
git commit -m "test: define universal skill distribution contract"
```

### Task 2: 표준 원본과 Claude 플러그인 배포

**Files:**
- Move: `skill/hwp-skill` → `skills/hwp-skill`
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Modify: `skills/hwp-skill/SKILL.md`
- Modify: repository test paths under `tests/*.Tests.ps1`
- Modify: `install.ps1`

**Interfaces:**
- Consumes: 기존 스킬 폴더의 모든 스크립트·스키마·참조·예제
- Produces: Agent Skills 표준 원본과 Claude Code plugin `hwp-skill@contentrium`

- [ ] **Step 1: 원본 폴더를 표준 위치로 이동하고 모든 내부 시험 경로 갱신**

```powershell
git mv skill skills
(Get-ChildItem tests -Filter '*.Tests.ps1').FullName
```

모든 `../skill/hwp-skill` 참조를 `../skills/hwp-skill`로 기계적으로 변경한다.

- [ ] **Step 2: Claude 플러그인 매니페스트 작성**

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "hwp-skill",
  "displayName": "HWP Skill",
  "description": "Windows에서 HWP, HWT, HWPX 문서를 안전하게 읽고 작성하는 스킬",
  "author": { "name": "contentrium", "url": "https://github.com/contentriumkorea" },
  "homepage": "https://github.com/contentriumkorea/hwp-skill",
  "repository": "https://github.com/contentriumkorea/hwp-skill",
  "license": "MIT",
  "keywords": ["hwp", "hwt", "hwpx", "hancom", "korean-document"]
}
```

- [ ] **Step 3: Claude 마켓플레이스 작성**

```json
{
  "name": "contentrium",
  "owner": { "name": "contentrium", "url": "https://github.com/contentriumkorea" },
  "description": "contentrium 공개 Agent Skills",
  "plugins": [{
    "name": "hwp-skill",
    "source": "./",
    "description": "HWP, HWT, HWPX 문서 작업 스킬",
    "homepage": "https://github.com/contentriumkorea/hwp-skill",
    "repository": "https://github.com/contentriumkorea/hwp-skill",
    "license": "MIT",
    "keywords": ["hwp", "hwt", "hwpx", "hancom"]
  }]
}
```

- [ ] **Step 4: 스킬 메타데이터와 본문을 제품 중립화**

`description`은 `Use when AI 도구가`로 시작하고 본문의 `지원 환경`에 Windows와
PowerShell 요구사항을 기록한다. frontmatter는 공통 필드인 `name`과 `description`만
사용한다. 본문의 `Codex의 정식 작업 형식`은
`AI 에이전트의 정식 작업 형식`으로 바꾸되 실행 정책은 그대로 둔다.

- [ ] **Step 5: 저장소·Claude 검증 시험 통과 확인**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Script '.\tests\Distribution.Tests.ps1','.\tests\Repository.Tests.ps1' -PassThru"
claude plugin validate .
npx -y skills@latest add . --list
```

Expected: Pester PASS, Claude `Validation passed`, `hwp-skill` 1개 발견.

- [ ] **Step 6: 표준 배포 커밋**

```powershell
git add .claude-plugin skills tests install.ps1
git commit -m "feat: package hwp skill for Claude and agent standards"
```

### Task 3: 다중 대상 PowerShell 설치기

**Files:**
- Modify: `install.ps1`
- Modify: `tests/Installer.Tests.ps1`

**Interfaces:**
- Consumes: `-Target Codex|Claude|Universal|All`, `-ProfileRoot`, `-DestinationRoot`, `-Update`
- Produces: 단일 대상의 기존 결과 계약 또는 `All`의 집계 결과와 `Results[]`

- [ ] **Step 1: 설치 대상별 실패 시험을 단독 실행해 RED 확인**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Script '.\tests\Installer.Tests.ps1' -PassThru"
```

Expected: 새 `Claude`, `Universal`, `All` 시험이 매개변수 또는 경로 불일치로 FAIL.

- [ ] **Step 2: 대상 경로 계산 함수 구현**

```powershell
function Resolve-HwpSkillDestinationRoots {
    param(
        [ValidateSet('Codex','Claude','Universal','All')][string]$Target,
        [string]$ProfileRoot,
        [string]$DestinationRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($DestinationRoot)) {
        if ($Target -eq 'All') {
            throw '-DestinationRoot는 -Target All과 함께 사용할 수 없습니다.'
        }
        return ,([pscustomobject]@{
            Target = $Target
            Root = [IO.Path]::GetFullPath($DestinationRoot)
        })
    }

    $profileWasSpecified = -not [string]::IsNullOrWhiteSpace($ProfileRoot)
    if (-not $profileWasSpecified) {
        $ProfileRoot = [Environment]::GetFolderPath('UserProfile')
    }
    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        throw '사용자 프로필 경로를 확인하지 못했습니다.'
    }

    $targets = if ($Target -eq 'All') { @('Codex','Claude','Universal') } else { @($Target) }
    $seen = @{}
    $resolved = foreach ($name in $targets) {
        $root = switch ($name) {
            'Codex' {
                if (-not $profileWasSpecified -and -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
                    Join-Path $env:CODEX_HOME 'skills'
                } else {
                    Join-Path (Join-Path $ProfileRoot '.codex') 'skills'
                }
            }
            'Claude' {
                if (-not $profileWasSpecified -and -not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
                    Join-Path $env:CLAUDE_CONFIG_DIR 'skills'
                } else {
                    Join-Path (Join-Path $ProfileRoot '.claude') 'skills'
                }
            }
            'Universal' { Join-Path (Join-Path $ProfileRoot '.agents') 'skills' }
        }
        $fullRoot = [IO.Path]::GetFullPath($root)
        $key = $fullRoot.ToUpperInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [pscustomobject]@{ Target = $name; Root = $fullRoot }
        }
    }
    return @($resolved)
}
```

`Codex`는 `CODEX_HOME`, `Claude`는 `CLAUDE_CONFIG_DIR`, `Universal`은 `.agents`를
우선 규칙대로 계산하고 `All`에서는 정규화한 경로를 중복 제거한다.

- [ ] **Step 3: 기존 설치 본문을 단일 대상 함수로 감싸고 All 집계 구현**

```powershell
function Invoke-HwpSkillSingleInstall {
    param([string]$TargetName, [string]$DestinationRoot, [switch]$Update,
          [scriptblock]$InstallValidator)

    $rootPath = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $installPath = [IO.Path]::GetFullPath((Join-Path $rootPath 'hwp-skill'))
    $backupRoot = [IO.Path]::GetFullPath((Join-Path $rootPath '.hwp-skill-backups'))

    # 현재 install.ps1에서 rootPath 계산 다음부터 마지막 결과 생성까지의
    # staging, backup, 두 차례 validator, 실패 격리, rollback 코드를 이 함수로
    # 이동한다. 반환 객체의 Target만 TargetName으로 채우고 나머지 필드는 유지한다.
}
```

함수 본문 이동 뒤 최상위 호출부는 다음 집계 코드를 사용한다.

```powershell
$destinations = @(Resolve-HwpSkillDestinationRoots -Target $Target `
    -ProfileRoot $ProfileRoot -DestinationRoot $DestinationRoot)
$results = @($destinations | ForEach-Object {
    Invoke-HwpSkillSingleInstall -TargetName $_.Target -DestinationRoot $_.Root `
        -Update:$Update -InstallValidator $InstallValidator
})
if ($results.Count -eq 1) { return $results[0] }

$aggregateStatus = if (@($results | Where-Object Status -eq 'FAILED').Count -gt 0) {
    'FAILED'
} elseif (@($results | Where-Object Status -eq 'BLOCKED').Count -gt 0) {
    'BLOCKED'
} else {
    'PASS'
}
[pscustomobject]@{
    Status = $aggregateStatus
    InstallPath = ''
    BackupPath = ''
    RollbackStatus = 'NOT_REQUIRED'
    FailedInstallPath = ''
    Warnings = @($results.Warnings)
    Errors = @($results.Errors)
    Results = $results
}
```

- [ ] **Step 4: 설치기 시험 통과 확인**

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Script '.\tests\Installer.Tests.ps1' -PassThru"
```

Expected: 기존 6개와 신규 대상·집계 시험 모두 PASS.

- [ ] **Step 5: 설치기 커밋**

```powershell
git add install.ps1 tests/Installer.Tests.ps1
git commit -m "feat: install hwp skill across agent runtimes"
```

### Task 4: 독립 ZIP 패키지

**Files:**
- Create: `package.ps1`
- Modify: `tests/Distribution.Tests.ps1`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `package.ps1 -OutputPath <zip> [-Force]`
- Produces: 최상위 `hwp-skill/` 폴더 한 개를 가진 독립 설치 ZIP

- [ ] **Step 1: ZIP 동작 실패 시험 작성 및 RED 확인**

```powershell
It '독립 ZIP에 스킬 필수 파일과 스크립트를 포함한다' {
    $zip = Join-Path $TestDrive 'hwp-skill.zip'
    & "$PSScriptRoot/../package.ps1" -OutputPath $zip
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        @($archive.Entries.FullName) | Should Contain 'hwp-skill/SKILL.md'
        @($archive.Entries.FullName) | Should Contain 'hwp-skill/scripts/Invoke-HwpSkill.ps1'
    } finally { $archive.Dispose() }
}
```

Run:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Script '.\tests\Distribution.Tests.ps1' -PassThru"
```

Expected: `package.ps1` 부재로 FAIL.

- [ ] **Step 2: 안전한 패키지 작성 구현**

```powershell
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist/hwp-skill.zip'),
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'skills/hwp-skill'))
$output = [IO.Path]::GetFullPath($OutputPath)

if (-not (Test-Path (Join-Path $source 'SKILL.md') -PathType Leaf)) {
    throw 'skills/hwp-skill/SKILL.md를 찾지 못했습니다.'
}
$linked = @(Get-Item -LiteralPath $source -Force) + @(Get-ChildItem -LiteralPath $source -Recurse -Force)
if (@($linked | Where-Object {
    ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}).Count -gt 0) {
    throw '스킬 원본에 reparse point, junction 또는 심볼릭 링크가 있습니다.'
}
if ((Test-Path -LiteralPath $output) -and -not $Force) {
    throw "출력 파일이 이미 있습니다: $output"
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('hwp-skill-package-' + [guid]::NewGuid().ToString('n'))
try {
    $skillStage = Join-Path $stage 'hwp-skill'
    $null = New-Item -ItemType Directory -Path $stage
    Copy-Item -LiteralPath $source -Destination $skillStage -Recurse
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    Compress-Archive -LiteralPath $skillStage -DestinationPath $output
    Get-Item -LiteralPath $output
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
```

- [ ] **Step 3: ZIP 시험 통과와 기본 출력 제외 확인**

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Script '.\tests\Distribution.Tests.ps1' -PassThru"
git status --short
```

Expected: PASS이며 `dist/` 결과물은 Git 상태에 나타나지 않는다.

- [ ] **Step 4: 패키지 커밋**

```powershell
git add package.ps1 tests/Distribution.Tests.ps1 .gitignore
git commit -m "feat: build standalone hwp skill package"
```

### Task 5: 한국어 설치 문서와 최종 검증

**Files:**
- Modify: `README.md`
- Modify: `tests/Repository.Tests.ps1`

**Interfaces:**
- Consumes: GitHub 저장소 URL과 세 가지 설치 방식
- Produces: 범용, Claude 전용, PowerShell 수동 설치를 구분한 한국어 안내

- [ ] **Step 1: README 계약 시험을 먼저 실패시킴**

README 시험은 `npx skills@latest`, `claude plugin marketplace add`,
`-Target Claude`, `-Target Universal`, `package.ps1`을 요구한다.

- [ ] **Step 2: README 설치 섹션 재작성**

첫 번째 방법은 70개 이상 호환 도구용 `npx skills`, 두 번째는 Claude 공식 플러그인,
세 번째는 Node.js가 없는 Windows의 `install.ps1`로 설명한다. 웹 채팅의 외부 스킬
미지원 경계를 명시한다.

- [ ] **Step 3: 전체 정적 회귀 시험 실행**

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File '.\tests\run-tests.ps1' -Suite Static
```

Expected: `Failed: 0`이고 기존 146개보다 시험 수가 증가한다.

- [ ] **Step 4: 실제 배포 도구 검증**

```powershell
claude plugin validate .
npx -y skills@latest add . --list
.\package.ps1 -OutputPath "$env:TEMP\hwp-skill.zip" -Force
```

Expected: Claude validation PASS, `hwp-skill` 1개 발견, ZIP 생성 PASS.

- [ ] **Step 5: 문서 및 최종 검증 커밋**

```powershell
git add README.md tests/Repository.Tests.ps1
git commit -m "docs: explain universal AI tool installation"
```

### Task 6: 로컬 설치와 GitHub 배포

**Files:**
- No repository file changes

**Interfaces:**
- Consumes: 검증된 브랜치 커밋
- Produces: 갱신된 로컬 Codex·Claude 스킬과 원격 `main`

- [ ] **Step 1: 임시 프로필 설치 행렬 검증**

```powershell
$profile = Join-Path $env:TEMP ('hwp-skill-profile-' + [guid]::NewGuid().ToString('n'))
.\install.ps1 -Target All -ProfileRoot $profile
```

Expected: 세 대상 `PASS`, 각 `hwp-skill/SKILL.md` 존재.

- [ ] **Step 2: 로컬 Codex와 Claude 설치 갱신**

```powershell
.\install.ps1 -Target Codex -Update
.\install.ps1 -Target Claude -Update
```

대상이 처음 설치되는 경우 `-Update`는 신규 설치도 허용한다.

- [ ] **Step 3: 설치본과 원본의 전체 파일 해시 비교**

각 설치본의 상대 경로와 SHA-256 집합이 `skills/hwp-skill`과 동일해야 한다.

- [ ] **Step 4: 브랜치를 main에 fast-forward 병합하고 푸시**

```powershell
git checkout main
git merge --ff-only feat/universal-agent-install
git push origin main
```

- [ ] **Step 5: 원격 커밋과 Claude GitHub 설치 확인**

```powershell
git ls-remote origin refs/heads/main
claude plugin marketplace add contentriumkorea/hwp-skill
claude plugin install hwp-skill@contentrium
```

원격 SHA가 로컬 `main`과 같고 Claude가 플러그인을 설치 목록에 표시해야 한다.
