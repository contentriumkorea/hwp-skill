# HWP Skill

Windows에서 `.hwp`, `.hwt`, `.hwpx`를 다루기 위한 Codex 스킬 저장소입니다. 현재 공개
릴리스는 **Phase 1 무창 계약**과 한글 문서 작업의 단일 오케스트레이션 흐름을 제공하며,
기본 실행 모드는 `silent`입니다. 공문,
보고서, 계획서, 회의록, 제안서, 스토리보드처럼 원본 보존과 사용자
포커스 유지가 중요한 한글 문서 파일 요청을 대상으로 합니다.

핵심 원칙은 간단합니다. **원본을 덮어쓰지 않고, 내부 계획·명령·엔진 상태를 사용자
대화에 노출하지 않으며, 기본 `silent` 모드에서 처리하고 준비되지 않은 엔진이면 GUI로
자동 전환하지 않습니다.**

## Contentrium에서 만든 이유

HWP Skill은 콘텐츠리움(Contentrium)이 공공기관·교육기관 콘텐츠를 제작하며 반복해서
마주친 한글 문서 작업을 더 안전하고 재현 가능하게 만들기 위해 시작한 오픈소스
프로젝트입니다. 기존 HWP 5.x는 한컴 없이 읽고 표의 행·열·병합·셀 문단까지 논리
구조로 복원합니다. 새 본문·표·이미지는 HWPX 직접 엔진으로 만들고 검사하며, HWP
납품이 필요한 경우에만 마지막 숨김 변환을 사용하는 업무 흐름을 담았습니다.

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
2. `silent`는 `.hwpx`를 직접 엔진으로 읽고 새 문서를 작성할 수 있습니다. 문단·표·필드는
   ZIP/XML에 직접 기록하고, 이미지는 BinData에 넣어 보안모듈 경고 없이 연결합니다.
3. 보호되지 않은 HWP 5.x `.hwp`와 `.hwt`는 내장 `hwp-portable`이 Windows 기본 OLE
   복합파일 API로 읽습니다. 표의 행·열, 병합 범위, 셀 주소와 셀별 문단도 함께
   복원하며 한컴오피스, 한컴 COM 등록, 보안 모듈을 사용하지 않습니다.
4. 최종 확장자가 HWP일 때만 별도 숨김 작업자가 완성된 HWPX를 HWP 바이너리로
   변환합니다. 변환 전까지는 한컴오피스를 실행하지 않습니다.
5. HWPX 직접 작성은 한컴 설치 없이도 동작합니다. HWP 최종 변환은 HWP 호환
   변환 엔진이 필요하며, 사용할 수 없으면 HWPX를 가짜 HWP로 이름만 바꾸지 않고
   안전하게 중단합니다.
6. HWP/HWT 기존 양식 편집은 직접 HWPX 가져오기·편집기가 준비될 때까지 자동
   한컴 실행을 막고 HWPX 양식을 요구합니다.
7. 준비되지 않은 기능을 만나도 GUI로 자동 전환하지 않습니다.

## 현재 지원 상태

| 항목 | 상태 | 설명 |
|---|---|---|
| `silent` HWP/HWT 읽기·검사 | 지원 | HWP 5.x 본문과 표 행·열·병합·셀 문단 직접 판독, 한컴 불필요 |
| `silent` HWPX 읽기·검사 | 지원 | ZIP/XML 직접 엔진 기반 |
| `silent` 새 문서 HWPX 작성 | 지원 | 문단·표·필드·이미지 직접 패키징 |
| `silent` 새 문서 HWP 작성 | 조건부 | HWPX 작성 후 마지막 숨김 변환 |
| HWP/HWT 기존 양식 편집 | 현재 차단 | 한컴을 작업 중 실행하지 않도록 HWPX 양식 요구 |
| 이미지 삽입 | 지원 | HWPX BinData 직접 삽입, 보안모듈 불필요 |
| `interactive` 네이티브 실행 | 예외 | 사용자가 창 표시를 명시한 경우만 |
| PDF·페이지 이미지 | 조건부 | 실행 모드와 로컬 렌더러가 모두 준비돼야 함 |
| 기존에 열린 한글 문서 제어 | 제외 | 현재 사용자 세션 보호를 위한 의도적 제한 |

Phase 1은 HWP 바이너리를 직접 작성한다고 주장하지 않습니다. 기존 HWP 5.x 읽기는
내장 엔진으로 가능하지만, HWP 결과가 필요할 때는 HWPX를 먼저 완성·검사한 다음 마지막
변환만 별도 작업자에 맡깁니다. 한컴오피스가 없는 컴퓨터에서도 HWP/HWT 읽기와 HWPX
작성은 가능하며, 새 HWP 납품 파일이 꼭 필요하면 별도 HWP 변환 엔진이 필요합니다.

자세한 제한은 [지원 환경과 제한 사항](skill/hwp-skill/references/limitations.md)을
확인하세요.

## 요구 환경

- Windows
- Windows PowerShell 5.1 또는 PowerShell 7 이상
- Codex에서 스킬로 사용할 경우 Codex 데스크톱 또는 CLI
- HWP 5.x 읽기는 Windows 기본 OLE 복합파일 API만 사용하며 한컴 설치가 필요하지 않음
- HWPX 직접 작성·검사는 추가 GUI 실행 없이 동작
- HWP 최종 변환을 요청하면 한컴 호환 변환 엔진과 숨김 작업자 구성이 필요함
- 새 HWPX 문서의 이미지 삽입에는 한컴 파일 경로 보안 모듈이 필요하지 않음
- HWP/HWT 원본의 네이티브 편집·PDF·페이지 이미지 기능에는 사용자가 공식 절차로
  등록한 한컴 파일 경로 보안 모듈이 필요할 수 있음

저장소에는 읽기 전용 `hwp-portable` 소스가 포함됩니다. 한컴오피스, 보안 DLL, 모든
경로를 허용하는 예제 모듈은 포함하거나 자동 설치하지 않습니다. 휴대형 읽기는 암호,
배포용 문서, DRM 등 보호 제한을 우회하지 않으며 HWP 3.x와 페이지 렌더링은 지원하지
않습니다.

> HWP 바이너리 판독 기능은 (주)한글과컴퓨터의
> [한글 문서 파일 형식 5.0 공개 문서](https://cdn.hancom.com/link/docs/%ED%95%9C%EA%B8%80%EB%AC%B8%EC%84%9C%ED%8C%8C%EC%9D%BC%ED%98%95%EC%8B%9D_5.0_revision1.3.pdf)를
> 참고하여 개발하였습니다. OLE 복합파일 컨테이너는 Microsoft의
> [MS-CFB 공개 규격](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b)을 따릅니다.

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
`silent` 단일 작업으로 시작하며, 내부 계획·명령·엔진 상태를 대화에 표시하지 않습니다.
준비되지 않은 엔진이면 자동 GUI 대체 없이 원본 보존과 제한 사유를 한 번에 보고합니다.

## Codex에서 사용하기

복잡한 명령을 직접 외우지 않아도 됩니다. 다음처럼 요청하세요.

```text
$hwp-skill로 이 HWPX 파일이 제대로 읽히는지 확인해 줘.
```

```text
$hwp-skill로 이 한글 문서 파일을 조용히 확인하고, 원본은 보존한 뒤 결과만 간단히 알려 줘.
```

```text
$hwp-skill로 이 보고서의 "2025년"을 "2026년"으로 바꿔 줘.
내부 계획과 명령은 표시하지 말고 원본은 보존하며 수정본을 검증해 줘.
```

```text
$hwp-skill로 이 HWPX 양식의 담당자와 사업명을 채워 별도 HWP로 만들어 줘.
작업은 HWPX로 끝낸 뒤 마지막에만 HWP로 변환해 줘.
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

이 섹션의 계약은 분명합니다. Codex 작업은 항상 HWPX에서 진행합니다. 새 HWP 결과가
필요하면 HWPX를 완성하고 검증한 뒤 마지막에만 숨김 변환합니다. HWP/HWT 기존 양식의
네이티브 편집은 HWPX 양식으로 준비되지 않은 경우 현재 자동 경로에서 차단합니다.
사용자가 한컴 창을 열어 화면에 보이게 작업하라고 명시한 경우에만 아래 interactive
예외를 사용할 수 있습니다.

### 1. 환경 확인

```powershell
$cli = ".\skill\hwp-skill\scripts\Invoke-HwpSkill.ps1"
& $cli preflight
```

### 2. HWP/HWT/HWPX 문서 읽기

```powershell
& $cli inspect -LiteralPath "C:\문서\보고서.hwp"
& $cli inspect -LiteralPath "C:\문서\보고서.hwpx"
```

HWP/HWT는 보호되지 않은 HWP 5.x 본문과 표·그림·수식 개체를 직접 읽습니다. 표는
`tables[]`에 행·열 수, 셀 주소, 행·열 병합, 셀 크기·여백, 테두리 채우기 참조,
셀별 문단과 전체 그리드로 반환합니다. 한컴은 실행하지 않으며 페이지 수와 최종
레이아웃은 검증하지 않았다는 경고를 함께 반환합니다.

표 셀의 `rowAddress`와 `columnAddress`는 0부터 시작합니다. `rowSpan`과
`columnSpan`은 병합 범위이며, `grid`의 병합된 칸은 원본 셀을 `mergedInto`로
가리킵니다. 셀이 겹치거나 주소 범위를 벗어나면 임의로 추측하지 않고 구조 경고에
기록합니다. `borderFillId`는 문서 내부 서식 참조값이며 화면 픽셀 렌더링 결과는
아닙니다.

### 3. 계획 검증

[편집 예제](skill/hwp-skill/examples/replace-text.plan.json)의 경로, 원본 SHA-256,
기준 문구와 값을 실제 검사 결과에 맞게 바꿉니다.

```powershell
& $cli validate-plan -PlanPath "C:\작업\replace.plan.json"
```

### 4. HWPX 새 문서 작성

```powershell
& $cli generate -NewDocument `
  -PlanPath ".\skill\hwp-skill\examples\generate-new.plan.json" `
  -OutputPath "C:\문서\새문서.hwpx"
```

이 경로는 한컴 창을 열지 않고 HWPX ZIP/XML에 직접 작성합니다. 문단·표·필드·이미지가
모두 HWPX 작업본에 들어간 뒤 구조 검사를 통과해야 결과를 승격합니다.

### 5. HWP 최종 결과 만들기

출력 확장자만 HWP로 지정합니다. 내부 작업은 HWPX로 고정되고, 최종 검증이 끝난 뒤
숨김 변환 작업자가 한 번만 HWP를 만듭니다.

```powershell
& $cli generate -NewDocument `
  -PlanPath ".\skill\hwp-skill\examples\generate-new.plan.json" `
  -OutputPath "C:\문서\새문서.hwp"
```

변환 엔진을 사용할 수 없으면 HWPX 중간 결과를 보존하고 HWP를 만들지 않습니다. HWPX
확장자만 HWP로 바꾸는 방식은 사용하지 않습니다.

### 6. HWP/HWT 기존 양식 편집

HWP/HWT 원본을 직접 열어 내용을 채우는 자동 경로는 현재 차단합니다. 한컴 창을
보이게 열어 작업하라는 명시적 요청이 있거나, 먼저 HWPX 양식으로 변환해 준비된 경우에
한해 별도 경로를 검토합니다.

### 7. 명시적 interactive 예외

사용자가 현재 요청에서 한컴 창을 열어 화면에 보이게 작업하라고 명시한 경우에만 다음
예외를 사용합니다. 단순한 `승인`이나 `진행`은 이 예외가 아닙니다.

```powershell
& $cli apply `
  -LiteralPath "C:\문서\보고서.hwp" `
  -PlanPath "C:\작업\replace.plan.json" `
  -OutputPath "C:\문서\보고서_수정본.hwp" `
  -ExecutionMode interactive `
  -AllowInteractiveWindow
```

이 예외는 HWP/HWT 원본을 직접 수정할 때만 사용합니다. `OutputPath`를 생략하면
원본 폴더에 `_수정본_날짜시간`이 붙은 새 이름을 만듭니다. 원본과 같은 경로는
거부합니다.

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
- `silent`는 보호되지 않은 HWP 5.x HWP/HWT를 OLE 구조에서 직접 읽고 표의 행·열,
  병합 범위와 셀별 문단을 전체 그리드로 복원한다.
- `silent`는 HWPX 읽기·작성·표·이미지·구조 검사를 GUI 없이 수행하며 동일한 표 구조
  계약을 반환한다.
- 새 HWP 결과도 HWPX 작업본을 먼저 완성한 뒤 마지막 숨김 변환으로 만든다.
- HWP/HWT 기존 양식의 네이티브 편집은 HWPX 양식이 준비되지 않으면 자동 실행하지 않는다.
- 준비되지 않은 엔진을 만나도 GUI로 자동 전환하지 않는다.
- 결과 파일 자동 열기와 포커스 탈취를 하지 않는다.
- HWPX ZIP 경로 탈출, 압축 폭탄, XML 외부 개체를 차단한다.
- HWP는 하나의 읽기 세션으로 잠그고, 레코드·개체·텍스트·압축 해제 크기에 문서 전체
  누적 한도를 적용하며 보호 문서를 우회하지 않는다.
- 사용자 한글 프로세스 일괄 종료를 하지 않는다.
- 외부 업로드와 매크로 실행을 하지 않는다.

### 명시적으로 승인된 interactive 또는 향후 구현 설계

- 원본 작업 전후 SHA-256 확인
- 확장자뿐 아니라 실제 파일 시그니처 검사
- 명시적으로 승인된 interactive에서만 HWP/HWT 원본을 열고 편집하거나 저장
- 임시 파일 저장 → 재열기 검사 → 최종 결과 승격
- 실패 결과와 완성 결과 분리
- 고급 작업의 명시적 승인 요구
- 고급 작업은 계획 기록과 실행 시 `-ApproveAdvanced`를 모두 요구
- 반복 문구가 둘 이상이면 추측하지 않고 중단

위 native 편집 흐름은 HWPX 직접 작업의 기본 경로가 아니라, 사용자가 창 표시를
명시한 경우에만 허용되는 예외입니다.

세부 정책과 복구 절차는 [안전 및 복구 정책](skill/hwp-skill/references/safety.md)을
참조하세요.

## 개발과 시험

기본 시험은 정적 안전 시험만 실행합니다.

```powershell
.\tests\run-tests.ps1
# 다음 명령도 같은 범위를 실행합니다.
.\tests\run-tests.ps1 -Suite Static
```

최종 HWP 변환 통합 시험은 실제 한컴오피스를 시작할 수 있으므로 기본 `silent` 공개
계약과 분리해서 봐야 합니다. HWPX 직접 작업과 현재 사용자 세션의 `Hwp.exe`를
실행하지 않는 기본 동작을 검증할 때는 정적 시험과 `silent` 스모크를 우선 사용합니다. `Native`와 `All`은
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
├─ scripts/workers/Convert-HwpxToHwp.ps1
├─ scripts/lib/*.psm1
├─ templates/default.hwpx
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
