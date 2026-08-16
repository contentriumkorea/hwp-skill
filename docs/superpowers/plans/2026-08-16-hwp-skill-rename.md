# HWP Skill 이름 변경 및 재배포 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 `hwp-native` 스킬을 외부 식별자 `hwp-skill`로 통일하고, 로컬 재설치와 `contentriumkorea/hwp-skill` 공개 배포까지 완료한다.

**Architecture:** 문서 처리 엔진의 내부 PowerShell 함수명과 `HWP_NATIVE_*` 환경 변수는 호환성을 위해 유지한다. 스킬 폴더, YAML 이름, 호출어, 설치 대상, 백업 폴더, 공개 문서와 스키마 URL처럼 사용자가 접하는 식별자만 `hwp-skill`로 변경한다.

**Tech Stack:** PowerShell 7, Pester, Codex Skill YAML, Git, GitHub

## Global Constraints

- 원본 기능과 안전 정책은 바꾸지 않는다.
- 기존 로컬 설치 `C:\Users\JeYun\.codex\skills\hwp-native`는 새 설치 검증 직전에만 제거한다.
- 새 설치 경로는 `C:\Users\JeYun\.codex\skills\hwp-skill`이다.
- 공개 저장소는 `https://github.com/contentriumkorea/hwp-skill`이며 기본 브랜치는 `main`이다.
- README에는 콘텐츠리움의 제작 배경을 한국어로 명시한다.

---

### Task 1: 외부 이름 계약을 테스트로 고정

**Files:**
- Modify: `tests/Repository.Tests.ps1`
- Modify: `tests/Installer.Tests.ps1`

**Interfaces:**
- Consumes: 현재 `hwp-native` 저장소 구조와 설치 결과 객체
- Produces: `hwp-skill` 경로·메타데이터·README·설치 위치를 요구하는 실패 테스트

- [ ] **Step 1: 새 이름과 콘텐츠리움 표기를 요구하는 테스트 작성**
- [ ] **Step 2: 실패 확인**

```powershell
Invoke-Pester -Script .\tests\Repository.Tests.ps1,.\tests\Installer.Tests.ps1
```

예상 결과: `skill/hwp-skill`과 새 설치 경로가 아직 없어 실패한다.

### Task 2: 외부 식별자 변경

**Files:**
- Rename: `skill/hwp-native` → `skill/hwp-skill`
- Modify: `skill/hwp-skill/SKILL.md`
- Modify: `skill/hwp-skill/agents/openai.yaml`
- Modify: `install.ps1`
- Modify: `README.md`
- Modify: `LICENSE`
- Modify: `skill/hwp-skill/schemas/*.json`
- Modify: `tests/*.ps1`
- Modify: `docs/superpowers/specs/*.md`
- Modify: `docs/superpowers/plans/*.md`

**Interfaces:**
- Consumes: Task 1의 이름 계약
- Produces: `$hwp-skill`, `skill/hwp-skill`, `.hwp-skill-backups`, `contentriumkorea/hwp-skill`

- [ ] **Step 1: 폴더를 `skill/hwp-skill`로 이동**
- [ ] **Step 2: 사용자 노출 문자열과 경로를 새 이름으로 변경**
- [ ] **Step 3: README에 콘텐츠리움 소개와 제작 배경 추가**
- [ ] **Step 4: 정적 테스트와 스킬 유효성 검사 통과**

```powershell
& .\tests\run-tests.ps1 -Suite Static
python 'C:\Users\JeYun\.codex\skills\.system\skill-creator\scripts\quick_validate.py' '.\skill\hwp-skill'
```

### Task 3: 재설치와 GitHub 공개 검증

**Files:**
- Delete after verification: `C:\Users\JeYun\.codex\skills\hwp-native`
- Create: `C:\Users\JeYun\.codex\skills\hwp-skill`

**Interfaces:**
- Consumes: 검증된 저장소와 `install.ps1`
- Produces: 로컬 `hwp-skill` 설치본과 공개 `contentriumkorea/hwp-skill` 저장소

- [ ] **Step 1: 임시 Codex 홈에 설치해 새 이름만 생성되는지 확인**
- [ ] **Step 2: 기존 설치본을 제거하고 새 이름으로 설치**
- [ ] **Step 3: 커밋 후 `contentriumkorea/hwp-skill`의 `main`에 푸시**
- [ ] **Step 4: 공개 URL·README·SKILL.md·설치 명령을 새 환경에서 재검증**

```powershell
& .\install.ps1
git push -u origin main
```
