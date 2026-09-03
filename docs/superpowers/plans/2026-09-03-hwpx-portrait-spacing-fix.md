# 세로 기본값·줄 간격 회귀 수정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 한컴을 실행하지 않고 새 서류의 세로 방향과 문단 간격을 정확하게 기록한다.

**Architecture:** 기존 HWPX ZIP/XML 작성기, 독립 검사기, 부분 수정기의 잘못된 저장값만 바로잡는다. 새 문서에는 추정 줄 배치 캐시를 넣지 않고 문단 스타일을 기준으로 재배치하도록 한다. 한컴에서 만들어진 기본 템플릿의 방향·호환 분기를 독립 기준으로 삼는다.

**Tech Stack:** PowerShell 5.1/7, .NET ZIP/XML, Pester.

**Spec:** 사용자 보고: 새 서류가 가로로 작성되고 줄 간격이 이상함. 기존 [작성 제어 설계](../specs/2026-09-03-hwpx-authoring-controls-design.md)의 무창·원본 보존 경계를 유지한다. 해당 구현의 방향 enum 해석은 이번 회귀 시험으로 정정한다.

## Global Constraints

- 한컴·Word·탐색기·출력 문서 창을 실행하지 않는다.
- 사용자 기존 문서는 변경하지 않는다. 실제 문제 파일은 이번 요청에 첨부되지 않았다.
- 새 서류는 별도 지시가 없으면 A4 세로·비율 줄 간격 160%·문단 앞뒤 0mm다. 명시된 가로·고정/최소 간격은 보존한다.
- GitHub에는 별도 요청 없이 게시하지 않는다. 로컬 Codex·Claude는 백업 후 교체한다.
- 내부 구조 검증과 실제 한컴 화면 검증을 구분한다.

### Task 1: 저장 방향 수정

**Files:** `tests/HwpxPortraitSpacingRegression.Tests.ps1`, `HwpHwpx.psm1`, `HwpInspect.psm1`, `HwpAuthoringVerify.psm1`, `HwpHwpxScopedEdit.psm1` (모듈은 `skills/hwp-skill/scripts/lib/`). 기존 방향 시험의 잘못된 리터럴도 정정한다.

**Interfaces:** `Invoke-HwpGenerate -NewDocument -Plan -OutputPath`, `Get-HwpInspection`, `Invoke-HwpxScopedEdit`는 변경하지 않는다.

- [x] 템플릿과 기본 생성 결과를 독립 ZIP/XML로 검사하는 실패 시험을 실행한다.

```powershell
$page.GetAttribute('landscape') | Should Be 'WIDELY' # 세로
# 가로는 NARROWLY. width/height는 회전 전 용지 치수다.
Invoke-Pester -Script tests/HwpxPortraitSpacingRegression.Tests.ps1
```

- [x] 네 모듈의 세로/가로 매핑을 일치시키되 기대값은 작성 함수로 계산하지 않는다.
- [x] 기본값·명시적 세로·명시적 가로·혼합 구역·원본 보존 부분 수정 시험을 실행한다.

### Task 2: 문단 단위와 배치 캐시 수정

**Files:** 같은 회귀 시험, `HwpHwpxStyles.psm1`, `HwpHwpx.psm1`, `HwpHwpxScopedEdit.psm1`, `HwpInspect.psm1`, `HwpAuthoringVerify.psm1`, 기존 문단/폭 시험.

**Interfaces:** `paragraphStyle.lineSpacingPercent`, `lineSpacing:{type,valuePt}`, 문단 mm 입력은 유지한다.

- [x] 기본 160%, 명시적 180%, FIXED 14pt, AT_LEAST, 문단 앞뒤·들여쓰기 및 V1 캐시 제거를 실패 시험으로 만든다.

```powershell
$caseLine.GetAttribute('value') | Should Be '1400' # 14pt, HwpUnitChar
$fallbackLine.GetAttribute('value') | Should Be '2800' # 구형 문단 단위
$section.SelectNodes('//*[local-name()="linesegarray"]').Count | Should Be 0
```

- [x] 새 문단에 기본 템플릿과 같은 `hp:switch`/`HwpUnitChar`/`hp:default`를 쓴다. 비율은 동일, 절대 문단 길이는 구형 분기에서 두 배다. 부분 수정도 분기별 단위를 지킨다.
- [x] 모든 생성 버전에서 고정 추정 줄 캐시를 제거한다. 표·본문 폭은 실제 객체/쪽 치수로 시험한다.
- [x] 독립 검증기에 호환 분기 간 단위 불일치 및 잔존 줄 캐시 검출 시험을 추가한다.
- [x] 구형 direct 문단의 부분 수정→재검사를 시험한다. `raw`는 보존하고 물리 mm/pt만 분기 단위로 변환한다. 10mm를 재검사했을 때 20mm로 보이는 회귀를 막는다.

### Task 3: 안내·설치·최종 검증

**Files:** `skills/hwp-skill/SKILL.md`, `references/authoring.md`, 이번 수정 QA 기록.

- [x] 일반 서류 기본값과 기존 양식 보존 안내를 명확히 한다. 고급 혼합 방향 예제는 일반 서류 기본안으로 복사하지 않도록 분리한다.
- [x] PowerShell 7/5.1에서 `tests/run-tests.ps1 -Suite Static`과 동일한 시험 목록을 실행한다. NUnit 로그를 남기기 위해 같은 필터의 `Invoke-Pester -OutputFile ... -OutputFormat NUnitXml -PassThru`를 사용했다. Native 통합 시험은 제외했다.
- [x] 설치 스크립트를 확인한 뒤 두 설치본을 백업·교체하고 SHA256 및 설치본 CLI의 기본 세로·간격 출력을 다시 검사한다.
- [x] 최종 변경 파일·검사 결과·한컴 시각 검증 미실시를 [검증 기록](../reports/2026-09-03-hwpx-portrait-spacing-qa.md)에 남긴다. 기존 문서의 개별 증상은 원본을 받기 전까지 확정하지 않는다.
