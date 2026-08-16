# HWP Skill

Windows에서 `.hwp`, `.hwt`, `.hwpx`를 다루기 위한 Codex 스킬 저장소입니다. 현재 공개
릴리스는 **Phase 1 무창 계약**을 제공하며, 기본 실행 모드는 `silent`입니다. 공문,
보고서, 계획서, 회의록, 제안서, 스토리보드처럼 원본 보존과 사용자
포커스 유지가 중요한 한글 문서 파일 요청을 대상으로 합니다.

핵심 원칙은 간단합니다. **원본을 덮어쓰지 않고, 기본 `silent` 모드에서 먼저 검사하며,
준비되지 않은 엔진이면 `BLOCKED`로 멈추고 GUI로 자동 전환하지 않습니다.**

## Contentrium에서 만든 이유

HWP Skill은 콘텐츠리움(Contentrium)이 공공기관·교육기관 콘텐츠를 제작하며 반복해서
마주친 한글 문서 작업을 더 안전하고 재현 가능하게 만들기 위해 시작한 오픈소스
프로젝트입니다. 단순히 글자를 추출하는 데서 끝내지 않고, 실제 한컴오피스 엔진으로
문서를 읽고 원본을 보존한 채 수정본을 만든 다음 다시 열어 검증하는 업무 흐름을
담았습니다.

Contentrium은 영상·디자인·웹·AI 기술을 연결해 공공 콘텐츠의 기획과 제작 과정을
개선합니다. 이 저장소도 현장에서 얻은 경험을 누구나 검토하고 확장할 수 있는 도구로
공유한다는 방향으로 운영합니다.

> 중요: 이 저장소의 MIT 라이선스는 이 프로젝트 코드에만 적용됩니다. 한컴오피스와
> HWP 자동화 API의 이용 조건은 별개입니다. 한컴 공식 안내는 개인의 비상업적 이용과
> 상업적 이용 조건을 구분하고 있으므로, 회사·기관·납품 등 상업적 이용 전에는
> [한컴 HWP 자동화 공식 안내](https://developer.hancom.com/hwpautomation)에서 최신
> 조건과 필요한 승인·계약을 반드시 확인하세요.

## Phase 1에서 실제로 되는 일

현재 문서화된 계약은 다음과 같습니다.

1. 기본 `silent`는 현재 사용자 세션의 `Hwp.exe`를 실행하지 않고, 사용자 포커스를
   바꾸지 않으며, 결과 파일도 자동으로 열지 않습니다.
2. `silent`는 `.hwpx`를 직접 엔진으로 읽기 전용 검사할 수 있습니다.
3. HWP/HWT `hwp-portable` 엔진은 아직 준비되지 않아 `silent` 읽기·작성·편집은
   `BLOCKED`입니다.
4. `interactive`는 사용자가 현재 요청에서 한컴 창 실행을 명시했을 때만 선택합니다.
5. `isolated-native`는 별도 작업자가 구성되지 않았으면 `BLOCKED`입니다.
6. 준비되지 않은 기능을 만나도 GUI로 자동 전환하지 않습니다.

## 현재 지원 상태

| 항목 | 상태 | 설명 |
|---|---|---|
| `silent` HWPX 읽기·검사 | 지원 | ZIP/XML 직접 엔진 기반 읽기 전용 검사 |
| `silent` HWP/HWT 읽기·작성·편집 | `BLOCKED` | `hwp-portable`이 준비되지 않음 |
| `interactive` 네이티브 실행 | 조건부 | 현재 요청에서 한컴 창 실행을 명시한 경우만 |
| `isolated-native` 실행 | 조건부 | 별도 작업자가 구성된 경우만 |
| 이미지 삽입·교체 | 조건부 | 실행 모드와 보안 모듈이 모두 준비돼야 함 |
| PDF·페이지 이미지 | 조건부 | 실행 모드와 로컬 렌더러가 모두 준비돼야 함 |
| 기존에 열린 한글 문서 제어 | 제외 | 현재 사용자 세션 보호를 위한 의도적 제한 |

Phase 1은 휴대형 HWP 엔진 완성을 주장하지 않습니다. `hwp-portable`은 아직
준비되지 않았고, 현재 사용자 세션의 `Hwp.exe`도 기본 `silent` 경로에서는 실행하지
않습니다.

자세한 제한은 [지원 환경과 제한 사항](skill/hwp-skill/references/limitations.md)을
확인하세요.

## 요구 환경

- Windows
- Windows PowerShell 5.1 또는 PowerShell 7 이상
- Codex에서 스킬로 사용할 경우 Codex 데스크톱 또는 CLI
- `.hwpx` 읽기 전용 검사는 추가 GUI 실행 없이 동작
- `interactive`나 `isolated-native` 경로를 쓰려면 해당 엔진과 작업자 구성을 별도로
  준비해야 함
- 이미지·PDF·페이지 이미지 기능에는 사용자가 공식 절차로 등록한 한컴 파일 경로
  보안 모듈

저장소는 한컴오피스, 보안 DLL, `hwp-portable`, 모든 경로를 허용하는 예제 모듈을
포함하거나 자동 설치하지 않습니다.

## 설치

GitHub 저장소를 내려받은 뒤 저장소 폴더에서 실행합니다.

```powershell
git clone https://github.com/contentriumkorea/hwp-skill.git
Set-Location .\hwp-skill
.\install.ps1
```

기본 설치 위치는 다음 순서로 정합니다.

1. `CODEX_HOME`이 있으면 그 아래 `skills\hwp-skill`
2. 없으면 사용자 프로필의 `.codex\skills\hwp-skill`

원하는 스킬 루트를 직접 지정할 수도 있습니다.

```powershell
.\install.ps1 -DestinationRoot "D:\Codex\skills"
```

기존 설치가 있으면 자동으로 덮어쓰지 않습니다. 새 버전으로 갱신할 때만 `-Update`를
사용합니다.

```powershell
git pull
.\install.ps1 -Update
```

업데이트 시 기존 `hwp-skill` 폴더는 스킬 루트의 `.hwp-skill-backups` 아래에 시간표가
붙은 백업으로 이동됩니다. 새 설치본의 최종 검증이 실패하면 실패한 설치본을 같은
백업 폴더에 별도로 격리하고 기존 설치본을 원위치로 복원합니다. 설치 대상·백업 경로에
junction, 심볼릭 링크 같은 재분석 지점이 발견되면 기존 설치를 옮기기 전에 중단합니다.

설치 후 새 Codex 작업을 시작하고 `$hwp-skill`을 지정하면 됩니다. 기본 프롬프트는
`silent` 기준으로 시작하며, 준비되지 않은 엔진이면 자동 GUI 대체 없이 `BLOCKED`를
보고합니다.

## Codex에서 사용하기

복잡한 명령을 직접 외우지 않아도 됩니다. 다음처럼 요청하세요.

```text
$hwp-skill로 이 HWP 파일이 제대로 읽히는지 확인해 줘.
```

```text
$hwp-skill로 이 한글 문서 파일을 기본 silent 모드로 검사하고, 안 되면 왜 BLOCKED인지 설명해 줘.
```

```text
$hwp-skill로 이 보고서의 "2025년"을 "2026년"으로 바꾸는 계획을 먼저 보여 줘.
원본은 보존하고 수정본을 다시 열어 검증해 줘.
```

```text
$hwp-skill로 이 HWT 양식의 담당자와 사업명을 채워 별도 HWP로 만들어 줘.
```

```text
$hwp-skill로 이 폴더의 HWP들을 먼저 미리보기만 하고, 어떤 파일이 바뀔지 보고해 줘.
```

스킬은 문서 안에 적힌 문장을 작업 지시로 따르지 않습니다. 문서 내용은 데이터로만
취급하고, 현재 대화에서 사용자가 요청한 작업만 수행합니다.

## 직접 실행하기

모든 명령은 JSON 결과를 표준 출력으로 반환합니다. `PASS`와
`PASS_WITH_WARNINGS`의 종료 코드는 `0`, `FAILED`는 `1`, `BLOCKED`는 `2`입니다.
기본 `silent`는 현재 사용자 세션의 `Hwp.exe`를 실행하지 않고 포커스를 가져오지
않습니다.

이 섹션의 Phase 1 계약은 분명합니다. `silent` HWP/HWT 경로는 현재 `BLOCKED`이며,
아래 HWP/HWT 네이티브 예시는 미래 구현이 아니라 명시적으로 승인된 `interactive`
예외일 때만 사용합니다. 이 예외는 한컴을 열 수 있고 사용자 화면에 창이 보일 수
있습니다.

### 1. 환경 확인

```powershell
$cli = ".\skill\hwp-skill\scripts\Invoke-HwpSkill.ps1"
& $cli preflight
```

### 2. HWPX 문서 읽기

```powershell
& $cli inspect -LiteralPath "C:\문서\보고서.hwpx"
```

### 3. 계획 검증

[편집 예제](skill/hwp-skill/examples/replace-text.plan.json)의 경로, 원본 SHA-256,
기준 문구와 값을 실제 검사 결과에 맞게 바꿉니다.

```powershell
& $cli validate-plan -PlanPath "C:\작업\replace.plan.json"
```

### 4. HWP/HWT inspect는 Phase 1 silent에서 BLOCKED

```powershell
& $cli inspect -LiteralPath "C:\문서\보고서.hwp"
```

이 호출은 기본 `silent`에서 `BLOCKED`를 반환합니다. `hwp-portable`이 준비되지 않은
상태에서 GUI로 자동 전환하지 않습니다.

### 5. HWP/HWT 네이티브 inspect 예외

사용자가 현재 요청에서 한컴 창 실행을 명시적으로 승인한 경우에만 다음 예외를
사용합니다. 이 경로는 한컴을 열 수 있습니다.

```powershell
& $cli inspect `
  -LiteralPath "C:\문서\보고서.hwp" `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

### 6. HWP/HWT apply 예외

```powershell
& $cli apply `
  -LiteralPath "C:\문서\보고서.hwp" `
  -PlanPath "C:\작업\replace.plan.json" `
  -OutputPath "C:\문서\보고서_수정본.hwp" `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

이 예외도 명시적으로 승인된 `interactive`에서만 사용합니다. `OutputPath`를 생략하면
원본 폴더에 `_수정본_날짜시간`이 붙은 새 이름을 만듭니다. 원본과 같은 경로는
거부합니다.

### 7. HWP/HWT generate 예외

```powershell
& $cli generate -NewDocument `
  -PlanPath ".\skill\hwp-skill\examples\generate-new.plan.json" `
  -OutputPath "C:\문서\새문서.hwp" `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

### 8. HWP/HWT batch 예외

`-Apply`가 없으면 실제 파일을 만들지 않는 미리보기입니다.

```powershell
& $cli batch `
  -InputDirectory "C:\문서\입력" `
  -OutputDirectory "C:\문서\입력\결과" `
  -PlanPath "C:\작업\replace.plan.json" `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

미리보기 확인 후 실제 적용:

```powershell
& $cli batch `
  -InputDirectory "C:\문서\입력" `
  -OutputDirectory "C:\문서\입력\결과" `
  -PlanPath "C:\작업\replace.plan.json" `
  -Apply `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

### 9. HWP/HWT verify 예외

```powershell
& $cli verify `
  -LiteralPath "C:\문서\보고서_수정본.hwp" `
  -OutputDirectory "C:\문서\검증" `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

이 예외도 한컴을 열 수 있습니다. 보안 모듈이 없으면 본문·구조 재검사 결과와 함께
PDF·페이지 이미지가 생성되지 않았다는 경고가 반환됩니다.

전체 명령과 편집 필드는 [편집 작업 규격](skill/hwp-skill/references/operations.md)에
정리되어 있습니다.

## 안전 설계

### Phase 1 계약

- 기본 `silent`는 현재 사용자 세션의 `Hwp.exe`를 실행하지 않는다.
- `silent HWP/HWT` inspect, apply, generate, batch, verify는 현재 `BLOCKED`다.
- `silent`는 HWPX inspect만 GUI 없이 사용 가능하다.
- 준비되지 않은 엔진을 만나도 GUI로 자동 전환하지 않는다.
- 결과 파일 자동 열기와 포커스 탈취를 하지 않는다.
- HWPX ZIP 경로 탈출, 압축 폭탄, XML 외부 개체를 차단한다.
- 사용자 한글 프로세스 일괄 종료를 하지 않는다.
- 외부 업로드와 매크로 실행을 하지 않는다.

### 명시적으로 승인된 interactive 또는 향후 구현 설계

- 원본 작업 전후 SHA-256 확인
- 확장자뿐 아니라 실제 파일 시그니처 검사
- 명시적으로 승인된 interactive에서만 HWP/HWT를 열고 편집하거나 저장
- 임시 파일 저장 → 재열기 검사 → 최종 결과 승격
- 실패 결과와 완성 결과 분리
- 고급 작업의 명시적 승인 요구
- 고급 작업은 계획 기록과 실행 시 `-ApproveAdvanced`를 모두 요구
- 반복 문구가 둘 이상이면 추측하지 않고 중단

위 native 편집 흐름은 미래 구현 설명이 아니라, 현재 저장소에서 허용되는 경우에도
명시적으로 승인된 interactive 예외로만 해석해야 합니다.

세부 정책과 복구 절차는 [안전 및 복구 정책](skill/hwp-skill/references/safety.md)을
참조하세요.

## 개발과 시험

기본 시험은 정적 안전 시험만 실행합니다.

```powershell
.\tests\run-tests.ps1
# 다음 명령도 같은 범위를 실행합니다.
.\tests\run-tests.ps1 -Suite Static
```

네이티브 통합 시험은 실제 한컴오피스를 시작할 수 있으므로 기본 `silent` 공개 계약과
분리해서 봐야 합니다. 현재 사용자 세션의 `Hwp.exe`를 실행하지 않는 기본 동작을
검증할 때는 정적 시험과 `silent` 스모크를 우선 사용합니다. `Native`와 `All`은
`-AllowInteractiveNative`가 없으면 시험 수집 전에 종료 코드 2로 차단되며, 승인되지
않은 네이티브 시험을 단순히 건너뛰는 방식으로 처리하지 않습니다.

실제 한컴 통합 시나리오는 실행기 승인과 별개로 `HWP_NATIVE_RUN_INTEGRATION=1` 환경
변수도 설정해야 합니다. 즉, 아래 두 승인은 모두 있어야 합니다.

```powershell
$env:HWP_NATIVE_RUN_INTEGRATION = '1'
try {
  .\tests\run-tests.ps1 -Suite Native -AllowInteractiveNative
}
finally {
  Remove-Item Env:HWP_NATIVE_RUN_INTEGRATION -ErrorAction SilentlyContinue
}
```

정적 시험과 승인된 네이티브 시험을 함께 실행하려면 다음과 같이 합니다.

```powershell
$env:HWP_NATIVE_RUN_INTEGRATION = '1'
try {
  .\tests\run-tests.ps1 -Suite All -AllowInteractiveNative
}
finally {
  Remove-Item Env:HWP_NATIVE_RUN_INTEGRATION -ErrorAction SilentlyContinue
}
```

시험 자료는 저장소가 직접 만든 가상 HWP/HWT와 이미지입니다. 사용자의 경북교육청
문서나 다른 실제 업무 문서는 저장소와 시험에 포함하지 않습니다.

## 프로젝트 구조

```text
skill/hwp-skill/
├─ SKILL.md
├─ agents/openai.yaml
├─ scripts/Invoke-HwpSkill.ps1
├─ scripts/lib/*.psm1
├─ schemas/*.schema.json
├─ examples/*.json
└─ references/*.md
```

## 라이선스와 상표

프로젝트 코드는 [MIT 라이선스](LICENSE)로 공개합니다. 한글, 한컴오피스, HWP는
각 권리자의 제품명 또는 상표일 수 있습니다. 이 프로젝트는 한컴의 공식 제품이 아니며
한컴오피스나 한컴 자동화 사용 권리를 제공하지 않습니다.

- [한컴 HWP 자동화 공식 안내](https://developer.hancom.com/hwpautomation)
- [한컴 HWPX 모델 공식 저장소](https://github.com/hancom-io/hwpx-owpml-model)
