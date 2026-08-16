# Task 4 Implementer Report

- Date: 2026-08-16
- Status: PASS_WITH_WARNINGS
- Commit: `d5b3b5320a728783b22b2aeb858f4be37b92488a` (`feat: add silent capability preflight`)

## Changed Files

- `skill/hwp-skill/scripts/Invoke-HwpSkill.ps1`
- `tests/Cli.Tests.ps1`
- `tests/Repository.Tests.ps1`

## Test Commands And Observed Outputs

1. RED confirmation

```powershell
Invoke-Pester -Script .\tests\Cli.Tests.ps1 -PassThru
```

Observed output summary:

- `Passed: 0 Failed: 3`
- `capabilities` failed because `Command` ValidateSet did not include `capabilities`
- default `preflight` returned exit code `2` instead of `0`
- `interactive` without approval did not yet return the expected `FAILED` JSON

2. Focused Task 4 verification

```powershell
Invoke-Pester -Script @('.\tests\Cli.Tests.ps1','.\tests\Repository.Tests.ps1') -PassThru
```

Observed output summary:

- `Passed: 12 Failed: 0`
- `capabilities` returns `PASS` with `data.executionMode = silent`
- default `preflight` returns `PASS` with `data.executionMode = silent`
- `capabilities -ExecutionMode interactive` without `-AllowInteractiveWindow` returns `FAILED` with exit code `1`

3. Static suite

```powershell
.\tests\run-tests.ps1 -Suite Static
```

Observed output summary:

- `Passed: 100 Failed: 1`
- the single failing test is `tests/Batch.Tests.ps1` case `preflight는 실행 컨텍스트 없이도 silent 기본값으로 BLOCKED JSON과 종료 코드 2를 반환한다`
- observed mismatch: expected exit code `2`, actual exit code `0`

4. Diff hygiene

```powershell
git diff --check
```

Observed output summary:

- no whitespace error reported
- Git warned that some working-copy files will be normalized from `LF` to `CRLF` on a future Git write

## Self-Review Against The Brief

- TDD followed: added `tests/Cli.Tests.ps1` first, ran it, observed RED, then implemented the minimal CLI change.
- Only Task 4 implementation files named in the brief were changed for code/tests: `Invoke-HwpSkill.ps1`, `Cli.Tests.ps1`, `Repository.Tests.ps1`.
- Public CLI now exposes:
  - command `capabilities`
  - parameter `-ExecutionMode` with `silent|isolated-native|interactive`
  - parameter `-AllowInteractiveWindow`
- CLI now imports `HwpExecution.psm1`, `HwpCapabilities.psm1`, and `HwpBackendRouter.psm1` before the existing command libraries.
- CLI now creates one execution context and one capability snapshot up front, then reuses them for `capabilities` and `preflight`.
- Default `capabilities` and default `preflight` are silent and COM-free; they return the capability snapshot and do not call interactive Hancom startup.
- `interactive` without explicit approval returns `FAILED` JSON with exit code `1`, matching the Task 4 expectation.
- Existing command behavior outside the Task 4 surface was preserved; no other command branches were rewritten.
- Tests do not launch Hancom and do not open output files.
- Commit message matches the brief exactly: `feat: add silent capability preflight`.

## Concerns

- The static suite still contains one legacy assertion in `tests/Batch.Tests.ps1` that expects the old default `preflight` contract (`BLOCKED` / exit `2`). Task 4 intentionally changes that contract to silent `PASS`, but the brief limited edits to the Task 4 files, so I did not modify `tests/Batch.Tests.ps1`.
- `Invoke-HwpSkill.ps1` could not safely use a local variable literally named `$executionContext` because PowerShell reserves `ExecutionContext` as a built-in read-only variable. I used `$hwpExecutionContext` instead while keeping the required interface behavior unchanged.

---

## Fix Round 1

- Date: 2026-08-16
- Status: PASS

### Fix Summary

- Updated the stale `tests/Batch.Tests.ps1` default `preflight` assertion only, changing it from the old `BLOCKED` / exit `2` contract to the approved silent `PASS` / exit `0` contract with direct evidence checks:
  - `status = PASS`
  - `command = preflight`
  - `data.executionMode = silent`
  - `errors` count is `0`
- Added a direct CLI regression test in `tests/Cli.Tests.ps1` for `preflight -ExecutionMode interactive` without `-AllowInteractiveWindow`, while keeping the existing `capabilities` gate test.

### Changed Files In Fix Round 1

- `tests/Cli.Tests.ps1`
- `tests/Batch.Tests.ps1`
- `.superpowers/sdd/2026-08-16-hwp-multi-engine-foundation/task-4-report.md`

### Exact Commands And Observed Outputs

1. Focused regression verification

```powershell
Invoke-Pester -Script @('./tests/Cli.Tests.ps1','./tests/Batch.Tests.ps1','./tests/Repository.Tests.ps1') -PassThru
```

Observed output:

```text
Describing HWP 공용 CLI 실행 모드
[+] capabilities 기본 실행 모드는 silent다
[+] silent preflight는 한컴 설치를 필수 조건으로 만들지 않는다
[+] interactive는 창 허용 스위치 없이는 실패한다
[+] interactive preflight는 창 허용 스위치 없이는 실패한다
Describing Invoke-HwpBatch 안전 정책
[+] 기본값은 미리보기이며 결과 문서를 만들지 않는다
[+] 드라이브 루트를 입력 폴더로 열거하지 않는다
[+] 입력 폴더 밖의 출력 폴더를 거부한다
[+] 고급 계획은 Apply 런타임 승인 없이는 검사나 적용 전에 차단한다
Describing 통합 CLI JSON 계약
[+] 유효한 계획 검증은 JSON과 종료 코드 0을 반환한다
[+] preflight는 실행 컨텍스트 없이도 silent 기본값으로 PASS JSON과 종료 코드 0을 반환한다
[+] 시험 fixture 생성기는 승인 스위치 없이 BLOCKED와 종료 코드 2를 반환한다
Describing hwp-skill 저장소 구조
[+] 스킬 메타데이터와 공용 진입점을 제공한다
[+] Codex UI에 HWP Skill이라는 영문 표시명을 제공한다
[+] 공개 배포에 필요한 한국어 문서와 라이선스를 제공한다
[+] 복사 가능한 편집 및 새 문서 계획 예제를 제공한다
[+] 편집·검사·기능·새 문서 계획 JSON 스키마가 유효한 JSON이다
[+] 기능 스냅샷 모듈은 로컬 COM이나 Hancom 실행을 직접 만들지 않는다
[+] 공용 CLI는 silent 실행 모드와 기능 조회 명령을 노출한다
[+] 공개 편집 스키마가 위험한 계획 조합을 거부한다
[+] SKILL.md가 간결한 한국어 안전 워크플로를 명시한다
Tests completed in 6.24s
Passed: 20 Failed: 0 Skipped: 0 Pending: 0 Inconclusive: 0
```

2. Full static suite

```powershell
.\tests\run-tests.ps1 -Suite Static
```

Observed output:

```text
Tests completed in 11.74s
Passed: 102 Failed: 0 Skipped: 0 Pending: 0 Inconclusive: 0
```

### Self-Review For Fix Round 1

- Finding 1 addressed by updating only the stale default `preflight` assertion in `tests/Batch.Tests.ps1`; the CLI behavior itself was not changed.
- Finding 2 addressed by adding the missing direct interactive `preflight` CLI regression test in `tests/Cli.Tests.ps1`; the existing interactive `capabilities` gate test remains in place.
- No Task 5-8 work was added.
- The installed skill was not updated.
- Nothing was pushed.

### Concerns For Fix Round 1

- None beyond the already-documented PowerShell local variable naming constraint in `Invoke-HwpSkill.ps1`.
