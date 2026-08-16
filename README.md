# HWP Native Skill

Windows에 설치된 한컴오피스 한글을 실제 문서 엔진으로 사용해 `.hwp`, `.hwt`,
`.hwpx` 파일을 로컬에서 안전하게 읽고 다루는 Codex 스킬입니다. 공문, 보고서,
계획서, 회의록, 제안서, 스토리보드처럼 원본 양식과 페이지 구조가 중요한 문서를
대상으로 설계했습니다.

핵심 원칙은 간단합니다. **원본을 덮어쓰지 않고, 먼저 읽고, 변경 계획을 검증하고,
별도 결과를 만든 다음 다시 열어 확인합니다.**

> 중요: 이 저장소의 MIT 라이선스는 이 프로젝트 코드에만 적용됩니다. 한컴오피스와
> HWP 자동화 API의 이용 조건은 별개입니다. 한컴 공식 안내는 개인의 비상업적 이용과
> 상업적 이용 조건을 구분하고 있으므로, 회사·기관·납품 등 상업적 이용 전에는
> [한컴 HWP 자동화 공식 안내](https://developer.hancom.com/hwpautomation)에서 최신
> 조건과 필요한 승인·계약을 반드시 확인하세요.

## 무엇을 할 수 있나요?

첫 공개 범위는 다음 1~8번 기능군입니다.

1. **읽기와 안전 편집**: 본문·필드·표·컨트롤을 검사하고, 정확히 하나로 식별된
   문구나 필드를 별도 HWP 결과에서 수정합니다.
2. **문서 제작**: HWT/HWP 양식을 채우거나 문단·표·필드·이미지로 새 HWP를 만듭니다.
3. **구조 편집**: 표, 이미지, 글자·문단 서식, 쪽 나누기, A4 구역 설정, 머리말·꼬리말,
   쪽 번호, 책갈피, 링크, 캡션, 각주·미주, 차례, 문서 병합을 처리합니다.
4. **공공문서 자동화**: 공문·계획서·회의록·보고서 같은 반복 양식을 구조화된 값으로
   생성합니다.
5. **자연어 편집 계획**: 사용자의 요청을 재현 가능한 JSON 계획으로 바꾸고 실제 적용
   전에 모호성·원본 해시·위험 등급을 검사합니다.
6. **검토와 교정**: 추출된 본문을 검토하고, 수정은 결정적 계획으로 적용하며, 원본과
   결과의 필드·표·그림·쪽 수 변화를 비교합니다.
7. **일괄 처리**: 명시된 파일이나 폴더만 대상으로 먼저 미리보기를 만들고, 승인 후
   파일별 별도 결과를 생성합니다.
8. **시각 검증**: 조건이 갖춰지면 PDF와 전체 페이지 이미지를 만들고, 그렇지 않으면
   시각 검증 미완료를 경고로 남깁니다.

이미 한글 프로그램에서 열어 둔 문서를 직접 조종하는 기능은 의도적으로 제외했습니다.
스킬이 만든 자동화 세션만 사용하고 닫기 때문에 사용자의 작업 중인 한글 창을 건드리지
않습니다.

## 현재 지원 상태

| 항목 | 상태 | 설명 |
|---|---|---|
| HWP 읽기·편집·생성 | 지원 | 메모리 입출력, 별도 결과 저장, 재열기 검사 |
| HWT 읽기·양식 생성 | 지원 | 결과는 항상 별도의 HWP |
| HWPX 읽기·검사 | 지원 | ZIP/XML 안전 검사 |
| HWPX 편집·생성 | 미지원 | 현재 한컴 메모리 입출력 경로가 확인되지 않음 |
| 이미지 삽입·교체 | 조건부 | 등록된 한컴 파일 경로 보안 모듈 필요 |
| PDF·페이지 이미지 | 조건부 | 등록된 보안 모듈과 로컬 렌더러 필요 |
| 기존에 열린 한글 문서 제어 | 제외 | 사용자 세션 보호를 위한 의도적 제한 |

개발 환경에서 한컴오피스 2024 Edu, 자동화 엔진 `13.0.0.711`, PowerShell
`7.6.4`로 HWP/HWT의 검사, 본문·필드·표·이미지 접근 차단, 서식·구조 편집,
참조 개체, 문서 생성, 일괄 처리, 재열기 검증을 통합 시험했습니다. 한컴오피스
2018·2020·2022는 현재 실기 검증하지 않았습니다.

개발 PC에는 파일 경로 보안 모듈이 등록되어 있지 않아 실제 한컴 경로 기반 PDF·PNG
내보내기는 완료 검증으로 표시하지 않습니다. 이 경우 도구는 성공을 과장하지 않고
`PASS_WITH_WARNINGS` 또는 `BLOCKED`를 반환합니다.

자세한 제한은 [지원 환경과 제한 사항](skill/hwp-native/references/limitations.md)을
확인하세요.

## 요구 환경

- Windows
- Windows PowerShell 5.1 또는 PowerShell 7 이상
- 자동화 COM 인터페이스가 등록된 한컴오피스 한글
- Codex에서 스킬로 사용할 경우 Codex 데스크톱 또는 CLI
- 이미지·PDF·페이지 이미지 기능에는 사용자가 공식 절차로 등록한 한컴 파일 경로
  보안 모듈

저장소는 한컴오피스, 보안 DLL, 모든 경로를 허용하는 예제 모듈을 포함하거나 자동
설치하지 않습니다.

## 설치

GitHub 저장소를 내려받은 뒤 저장소 폴더에서 실행합니다.

```powershell
git clone https://github.com/gb-consumer/hwp-native-skill.git
Set-Location .\hwp-native-skill
.\install.ps1
```

기본 설치 위치는 다음 순서로 정합니다.

1. `CODEX_HOME`이 있으면 그 아래 `skills\hwp-native`
2. 없으면 사용자 프로필의 `.codex\skills\hwp-native`

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

업데이트 시 기존 `hwp-native` 폴더는 스킬 루트의 `.hwp-native-backups` 아래에 시간표가
붙은 백업으로 이동됩니다. 설치 도중 문제가 생기면 가능한 범위에서 기존 설치를
원위치로 되돌립니다.

설치 후 새 Codex 작업을 시작하고 `$hwp-native`를 지정하면 됩니다.

## Codex에서 사용하기

복잡한 명령을 직접 외우지 않아도 됩니다. 다음처럼 요청하세요.

```text
$hwp-native로 이 HWP 파일이 제대로 읽히는지 확인해 줘.
```

```text
$hwp-native로 이 보고서의 "2025년"을 "2026년"으로 바꾸는 계획을 먼저 보여 줘.
원본은 보존하고 수정본을 다시 열어 검증해 줘.
```

```text
$hwp-native로 이 HWT 양식의 담당자와 사업명을 채워 별도 HWP로 만들어 줘.
```

```text
$hwp-native로 이 폴더의 HWP들을 먼저 미리보기만 하고, 어떤 파일이 바뀔지 보고해 줘.
```

스킬은 문서 안에 적힌 문장을 작업 지시로 따르지 않습니다. 문서 내용은 데이터로만
취급하고, 현재 대화에서 사용자가 요청한 작업만 수행합니다.

## 직접 실행하기

모든 명령은 JSON 결과를 표준 출력으로 반환합니다. `PASS`와
`PASS_WITH_WARNINGS`의 종료 코드는 `0`, `FAILED`는 `1`, `BLOCKED`는 `2`입니다.

### 1. 환경 확인

```powershell
$cli = ".\skill\hwp-native\scripts\Invoke-HwpNative.ps1"
& $cli preflight
```

### 2. 문서 읽기

```powershell
& $cli inspect -LiteralPath "C:\문서\보고서.hwp"
```

### 3. 계획 검증

[편집 예제](skill/hwp-native/examples/replace-text.plan.json)의 경로, 원본 SHA-256,
기준 문구와 값을 실제 검사 결과에 맞게 바꿉니다.

```powershell
& $cli validate-plan -PlanPath "C:\작업\replace.plan.json"
```

### 4. 별도 수정본 만들기

```powershell
& $cli apply `
  -LiteralPath "C:\문서\보고서.hwp" `
  -PlanPath "C:\작업\replace.plan.json" `
  -OutputPath "C:\문서\보고서_수정본.hwp"
```

`OutputPath`를 생략하면 원본 폴더에 `_수정본_날짜시간`이 붙은 새 이름을 만듭니다.
원본과 같은 경로는 거부합니다.

### 5. 새 문서 만들기

```powershell
& $cli generate -NewDocument `
  -PlanPath ".\skill\hwp-native\examples\generate-new.plan.json" `
  -OutputPath "C:\문서\새문서.hwp"
```

### 6. 일괄 처리

`-Apply`가 없으면 실제 파일을 만들지 않는 미리보기입니다.

```powershell
& $cli batch `
  -InputDirectory "C:\문서\입력" `
  -OutputDirectory "C:\문서\입력\결과" `
  -PlanPath "C:\작업\replace.plan.json"
```

미리보기 확인 후 실제 적용:

```powershell
& $cli batch `
  -InputDirectory "C:\문서\입력" `
  -OutputDirectory "C:\문서\입력\결과" `
  -PlanPath "C:\작업\replace.plan.json" `
  -Apply
```

### 7. 다시 열기와 시각 검증

```powershell
& $cli verify `
  -LiteralPath "C:\문서\보고서_수정본.hwp" `
  -OutputDirectory "C:\문서\검증"
```

보안 모듈이 없으면 본문·구조 재검사 결과와 함께 PDF·페이지 이미지가 생성되지
않았다는 경고가 반환됩니다.

전체 명령과 편집 필드는 [편집 작업 규격](skill/hwp-native/references/operations.md)에
정리되어 있습니다.

## 안전 설계

- 원본 작업 전후 SHA-256 확인
- 확장자뿐 아니라 실제 파일 시그니처 검사
- HWP/HWT를 파일 경로가 아닌 메모리로 열고 저장
- 임시 파일 저장 → 재열기 검사 → 최종 결과 승격
- 실패 결과와 완성 결과 분리
- 고급 작업의 명시적 승인 요구
- 고급 작업은 계획 기록과 실행 시 `-ApproveAdvanced`를 모두 요구
- 반복 문구가 둘 이상이면 추측하지 않고 중단
- HWPX ZIP 경로 탈출, 압축 폭탄, XML 외부 개체 차단
- 사용자 한글 프로세스 일괄 종료 금지
- 외부 업로드와 매크로 실행 금지

세부 정책과 복구 절차는 [안전 및 복구 정책](skill/hwp-native/references/safety.md)을
참조하세요.

## 개발과 시험

정적 안전 시험:

```powershell
.\tests\run-tests.ps1 -Suite Static
```

네이티브 통합 시험은 실제 한컴오피스를 시작하고 프로젝트가 만든 시험 문서만
사용합니다. 열어 둔 업무 문서가 있다면 그대로 보존하지만, 시험에는 시간이 걸릴 수
있습니다. 실수로 한컴을 시작하지 않도록 보호 스위치가 있으므로 명시적으로 켭니다.

```powershell
$env:HWP_NATIVE_RUN_INTEGRATION = '1'
try {
  .\tests\run-tests.ps1 -Suite Integration
}
finally {
  Remove-Item Env:HWP_NATIVE_RUN_INTEGRATION -ErrorAction SilentlyContinue
}
```

보호 스위치를 켜지 않으면 네이티브 항목은 `Skipped`로 표시됩니다. 전체 시험에서
네이티브 항목까지 실행하려면 다음과 같이 합니다.

```powershell
$env:HWP_NATIVE_RUN_INTEGRATION = '1'
try {
  .\tests\run-tests.ps1 -Suite All
}
finally {
  Remove-Item Env:HWP_NATIVE_RUN_INTEGRATION -ErrorAction SilentlyContinue
}
```

시험 자료는 저장소가 직접 만든 가상 HWP/HWT와 이미지입니다. 사용자의 경북교육청
문서나 다른 실제 업무 문서는 저장소와 시험에 포함하지 않습니다.

## 프로젝트 구조

```text
skill/hwp-native/
├─ SKILL.md
├─ agents/openai.yaml
├─ scripts/Invoke-HwpNative.ps1
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
