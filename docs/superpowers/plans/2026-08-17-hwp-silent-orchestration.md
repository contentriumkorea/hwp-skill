# HWP Silent Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `hwp-skill` the single, silent orchestrator for HWP/HWT/HWPX work so internal planning, approvals, commands, engine selection, and raw blocked states do not leak into the user's conversation.

**Architecture:** Keep the existing deterministic PowerShell engine and safety gates unchanged, but replace the skill's user-facing contract with one integrated workflow. The skill will choose only a non-foreground backend by default, treat a bare “승인” as insufficient for interactive Hancom, and emit one concise final report. Pester contract tests will guard the wording and the no-fallback boundary.

**Tech Stack:** Agent Skills Markdown, `agents/openai.yaml`, PowerShell, Pester 4, existing HWP capability router and installer.

## Global Constraints

- Preserve original HWP/HWT/HWPX files; never overwrite them automatically.
- Default execution remains `silent`; current-session Hancom GUI is never an automatic fallback.
- A user-visible Hancom window requires an explicit request to open/show the window, not a generic “승인”.
- Local document contents and image assets remain local; do not transmit them to an external service.
- The current Phase 1 engine limitations remain honest; this plan does not claim a portable HWP binary engine that is not packaged.
- Existing installed skills are updated through the repository installer with backup and readback validation.

---

### Task 1: Add the failing orchestration contract tests

**Files:**
- Create: `tests/OrchestrationContract.Tests.ps1`
- Modify: none

**Interfaces:**
- Consumes: `skill/hwp-skill/SKILL.md` and `skill/hwp-skill/agents/openai.yaml` as UTF-8 text.
- Produces: deterministic assertions for single-owner routing, silent defaults, hidden progress, and explicit-window wording.

- [ ] **Step 1: Write the failing tests**

  Assert that the skill contains all of the following contracts:

  ```powershell
  It '일반 한글 작업의 단일 오케스트레이터다' {
      $skill | Should Match '이 스킬이.*단일.*진입점|단일.*오케스트레이터'
      $skill | Should Match 'writing-plans'
      $skill | Should Match '호출하지 않|사용하지 않'
      $skill | Should Match '원시.*명령|raw.*command|명령.*JSON'
  }

  It '승인만으로 interactive를 선택하지 않는다' {
      $skill | Should Match '승인.*interactive.*충분하지 않|interactive.*명시적.*창'
      $skill | Should Match '한컴.*창.*열|화면.*보이'
  }

  It '일반 작업의 사용자 보고는 한 번으로 제한한다' {
      $skill | Should Match '진행.*1회|한 번.*진행|최종.*결과'
      $skill | Should Match '내부.*계획|내부.*상태'
  }

  It '메타데이터도 단일 silent 흐름을 지시한다' {
      $interface | Should Match '단일.*silent|무창.*자동'
      $interface | Should Match '내부.*계획|명령.*표시하지'
  }
  ```

- [ ] **Step 2: Run the focused test and verify it fails for the old contract**

  Run: `Invoke-Pester -Script .\tests\OrchestrationContract.Tests.ps1 -PassThru`

  Expected: FAIL because the current skill exposes a step-by-step “계획 → 승인 → 다시 열기” workflow and the metadata does not prohibit generic planning/command output.

- [ ] **Step 3: Commit the red test**

  ```powershell
  git add tests/OrchestrationContract.Tests.ps1
  git commit -m "test: define silent HWP orchestration contract"
  ```

### Task 2: Replace the skill prompt with the integrated silent workflow

**Files:**
- Modify: `skill/hwp-skill/SKILL.md`
- Modify: `skill/hwp-skill/references/limitations.md`

**Interfaces:**
- Consumes: existing CLI commands, capability router, original-preservation rules, and current backend limitations.
- Produces: a compact Korean skill contract that owns intent parsing, internal planning, execution, verification, and final reporting.

- [ ] **Step 1: Write the single-entry contract**

  Make the first operational section state that every HWP/HWT/HWPX request is handled by `hwp-skill` alone. Explicitly state that `writing-plans`, `documents`, `pdf`, `computer-use`, and generic GUI automation are not invoked for ordinary work.

- [ ] **Step 2: Define the invisible internal pipeline**

  Use this order inside the skill without exposing it as a user-facing transcript: classify request → inspect source and assets → create an internal plan/job folder → choose a non-foreground backend → execute on a new output → reopen/inspect/verify → report only the result.

- [ ] **Step 3: Define the exact interactive predicate**

  Treat only an explicit request such as “한컴 창을 열어 보여줘”, “화면에서 직접 작업해줘”, or “현재 열려 있는 문서를 제어해줘” as an interactive request. A bare “승인”, “진행”, or approval of a previous explanation never authorizes the current-session window.

- [ ] **Step 4: Define one concise blocked/error report**

  Keep engine status, raw command output, internal plan names, and fallback selection internal. If no silent backend can satisfy the requested format, report once with the requested format, the single blocking reason, whether the original was preserved, and the available safe output format. Do not present a multi-option troubleshooting tree unless the user asks for diagnosis.

- [ ] **Step 5: Update limitations to match the contract**

  Explain that a missing security module or unavailable binary backend is an engine capability result, not a reason to open Hancom or ask the user to approve GUI work. Do not imply that the current Phase 1 repository contains a portable HWP binary writer.

### Task 3: Align Codex metadata and repository documentation

**Files:**
- Modify: `skill/hwp-skill/agents/openai.yaml`
- Modify: `README.md`
- Modify: `tests/Repository.Tests.ps1`

**Interfaces:**
- Consumes: the new single-entry skill contract.
- Produces: a trigger/default prompt that causes Codex to select one skill and keep internal mechanics hidden; documentation that does not advertise interactive as the normal recovery path.

- [ ] **Step 1: Update the default prompt**

  Set the default prompt to instruct Codex to use the skill as the sole HWP document workflow, default to silent execution, preserve focus/originals, and keep internal plans/commands/statuses out of the conversation.

- [ ] **Step 2: Update README behavior and examples**

  Retain accurate Phase 1 limitations, but rewrite the normal workflow examples so they show one silent job and one final result. Keep any interactive example explicitly labeled as a user-requested diagnostic exception.

- [ ] **Step 3: Update repository contract tests**

  Replace assertions that require the old exposed “계획/승인/다시 열기” sequence with assertions for the new single-entry, silent, hidden-report contract while retaining metadata, licensing, and limitation checks.

### Task 4: Run the green test cycle and install the verified skill

**Files:**
- Modify: none beyond Tasks 1–3

**Interfaces:**
- Consumes: updated repository and test suite.
- Produces: verified source tree and updated local `C:\Users\JeYun\.codex\skills\hwp-skill` installation with a backup of the previous version.

- [ ] **Step 1: Run the focused contract tests**

  Run: `Invoke-Pester -Script .\tests\OrchestrationContract.Tests.ps1 -PassThru`

  Expected: PASS with zero failures.

- [ ] **Step 2: Run all static tests**

  Run: `.	ests\run-tests.ps1 -Suite Static`

  Expected: exit code 0 and zero failed tests. Native tests remain unexecuted unless separately approved.

- [ ] **Step 3: Validate the skill package**

  Run: `python -X utf8 C:\Users\JeYun\.codex\skills\.system\skill-creator\scripts\quick_validate.py .\skill\hwp-skill`

  Expected: `Skill is valid!`.

- [ ] **Step 4: Update the local installation with rollback protection**

  Run: `.install.ps1 -DestinationRoot 'C:\Users\JeYun\.codex\skills' -Update`

  Expected: `PASS`, a backup path, and an installed `hwp-skill` folder containing the updated `SKILL.md` and `agents/openai.yaml`.

- [ ] **Step 5: Verify installed readback and silent CLI behavior**

  Run the installed validator, `capabilities`, `preflight`, and existing silent activity tests. Confirm the installed hashes match the source and no new Hwp/Word/Explorer process or visible window is created by silent probes.

- [ ] **Step 6: Commit and push the change**

  ```powershell
  git add SKILL.md agents/openai.yaml references/limitations.md README.md tests docs/superpowers/plans/2026-08-17-hwp-silent-orchestration.md
  git commit -m "fix: make HWP skill a silent single-entry orchestrator"
  git push origin codex/hwp-multi-engine-foundation
  ```

## Self-Review Coverage

- The screenshot's exposed approval/command/blocked flow is covered by Tasks 1–3.
- The accidental interactive selection from a bare approval is covered by the explicit predicate in Task 2 and its contract test.
- The current HWP/HWT binary-engine limitation remains documented rather than hidden or falsely advertised as fixed.
- Existing original-preservation, capability-router, and silent-window tests remain part of the final gate.
