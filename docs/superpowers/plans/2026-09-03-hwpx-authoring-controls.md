# HWPX 작성 제어 확장 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 승인된 작성 제어를 무창 HWPX 경로의 입력·기록·검사·사용 안내에 연결한다.

**Architecture:** 기존 HWP 휴대형 읽기와 ZIP 패키지 엔진은 유지한다. 쪽·구역과 계획 검증을 별도 모듈로 분리하고, 모든 작성 블록에 유효 영역을 전달한다. 실제 저장 속성의 독립 재검사를 완료 조건으로 사용한다.

**Tech Stack:** Windows PowerShell 5.1/7, .NET XML/ZIP, Pester, JSON Schema.

**Spec:** `docs/superpowers/specs/2026-09-03-hwpx-authoring-controls-design.md`

## Global Constraints

- 모든 작성·편집은 로컬 HWPX ZIP/XML에서 수행한다.
- Windows PowerShell 5.1과 PowerShell 7을 지원한다.
- 기존 HWP 5.x 휴대형 읽기와 보호 문서 거부 동작은 유지한다.
- 이미지 삽입은 BinData 직접 포함으로 처리한다. 보안 모듈 설치를 요구하지 않는다.
- 입력 해시·원본 보존·별도 출력·부분 파일 검증 후 승격을 유지한다.
- 미지원 키나 기능이 있으면 출력 파일을 만들기 전에 정확한 속성 경로와 이유를 반환한다.
- 부분 배포를 전체 완료로 부르지 않는다. A~C 완료 전 설치본을 교체하지 않는다.
- 사용자 원본 문서와 자산은 시험·공개 저장소에 포함하지 않는다.

## 작업 순서와 독립 경계

A(작업 1~3) → B(작업 4~5) → C(작업 6~8). 새 파일의 exported 함수는 아래 인터페이스를
기준으로 사용한다. 계획 결함을 발견하면 근거와 실제 수정 범위를 이 문서에 기록한다.

### Task 1: 쪽 방향 기록·판독 및 부모 영역 수정

**Files:** `HwpHwpxStyles.psm1`, `HwpHwpx.psm1`, `HwpInspect.psm1` (모두 `skills/hwp-skill/scripts/lib/`), `tests/HwpxPageControls.Tests.ps1`.

**Interfaces:** 기존 `Invoke-HwpGenerate -NewDocument -Plan -OutputPath`와 `Get-HwpInspection -LiteralPath` 유지. 검사 page definition의 width/height는 유효 치수, 새 paperWidth/paperHeight는 XML 저장 치수다.

- [x] 기존 작성 명령으로 아래 세 경우를 생성하고 ZIP/XML을 별도로 열어 검사하는 실패 시험을 추가한다.

```powershell
# 생성 함수에서 계산한 값을 기대값으로 재사용하지 않는다.
$page.GetAttribute('landscape') | Should Be 'WIDELY'
[int]$page.GetAttribute('width') | Should Be 59528
[int]$page.GetAttribute('height') | Should Be 84189
# LANDSCAPE의 실제 너비는 약 297mm, 저장 너비는 약 210mm다.
```

- [x] 생략 기본값=명시적 PORTRAIT, 독립 WIDELY 기준 XML 판독, A5 표 폭=118mm
  (용지 148mm, 좌우15mm)의 RED를 확인한다.
- [x] V1 widthMm/heightMm를 화면 치수로 받아 가로일 때 저장용 치수만 반대로 매핑한다.
  기본 XML을 PORTRAIT로 통일한다. 검사기는 landscape 속성을 먼저 읽는다.
- [x] 쪽의 본문 폭을 문단·표로 전달하고 고정 51024 폭을 기본 출력에서 제거한다.
- [x] 위 시험과 `tests/HwpxGenerate.Tests.ps1`, `tests/TableStructure.Tests.ps1`를 실행한 뒤 커밋한다.

### Task 2: 엄격한 계획 검증과 V2 계약

**Files:** 새 `scripts/lib/HwpAuthoringPlan.psm1`, 수정 `HwpGenerate.psm1`, `schemas/generate-plan.schema.json`, 새 `tests/AuthoringPlan.Tests.ps1`.

**Interfaces:** `Test-HwpAuthoringPlan -Plan`은 Status/Errors를 반환한다. `ConvertTo-HwpAuthoringPlan -Plan`은 원본을 변경하지 않고 version/document/sections/content를 가진 정규화 복사본을 반환한다. sections의 각 항목은 document/content를 가진다. content는 전체 블록을 순서대로 평탄화한 검사용 목록이다.

- [x] 미지원 속성, 문자열 Boolean, 비정수 행열, 중복 셀, 여백 초과, 모순 치수의 실패 시험을 추가한다.

```powershell
$plan = '{"version":"1.0","document":{"header":{"text":"기관명"}},"content":[{"type":"paragraph","text":"본문"}]}' | ConvertFrom-Json
(Test-HwpNewDocumentPlan -Plan $plan).Status | Should Be 'BLOCKED'
```

- [x] 현재 런타임의 거짓 PASS를 RED로 기록한다.
- [x] 허용 속성을 계층별로 검사하고 잘못된 자료형은 캐스팅 전에 거부한다. JSON 스키마와 같은 입력 corpus를 시험한다. 5.1에서는 외부 런타임을 설치하지 않는다.
- [x] V2는 content/sections 중 하나를 받는다. paperSize와 paperWidthMm/paperHeightMm는 배타적이다. 알 수 없는 version도 거부한다.
- [x] V1 호환성·원본 계획 불변·오류 시 출력 미생성 시험을 통과시켜 커밋한다.

### Task 3: 다중 구역·용지·다단·쪽 스타일

**Files:** 새 `scripts/lib/HwpPageLayout.psm1`, 수정 `HwpHwpx.psm1`, `HwpHwpxStyles.psm1`, `HwpInspect.psm1`, `HwpGenerate.psm1`, 계획 스키마·검증, 새 `tests/HwpxSections.Tests.ps1`.

**Interfaces:** `Get-HwpPageLayout -Page -Version`은 orientation, width/height(저장), effectiveWidth/effectiveHeight, contentWidth/contentHeight, margins, gutterType을 반환한다. columns는 count/gapMm/widthsMm/separator로 받는다. section document 기본값을 style context에 넘긴다.

- [x] V2 세로→가로→세로의 세 구역, 다른 여백, 2단과 잘못된 단 너비합 시험을 작성해 RED를 확인한다.

```json
{"version":"2.0","document":{"page":{"paperSize":"A4"}},"sections":[{"document":{"page":{"orientation":"PORTRAIT"}},"content":[{"type":"paragraph","text":"세로"}]},{"document":{"page":{"orientation":"LANDSCAPE"}},"content":[{"type":"paragraph","text":"가로"}]}]}
```

- [x] paperSize에는 A3/A4/A5/ISO_B4/ISO_B5/JIS_B4/JIS_B5/LETTER/LEGAL을 제공한다.
  제본은 LEFT_ONLY/LEFT_RIGHT/TOP_ONLY, 쪽 border는 BOTH/EVEN/ODD 적용 범위를 구분한다.
- [x] 구역마다 sectionN.xml을 쓰고 header secCnt·manifest·spine을 함께 갱신한다. 스타일과 이미지 ID는 문서 전체에서 유일하게 배정한다.
- [x] columns가 지정되면 colPr/colSz/colLine에 기록한다. column-break 블록을 별도로 처리한다. 부모 영역은 현재 단 너비를 사용한다.
- [x] 쪽 테두리·배경·여백·첫 쪽 숨김을 계획·작성·검사에 연결한다.
- [x] 검사 결과의 구역 순서·방향·유효 치수·단 설정을 확인하고 5.1/7 시험 후 커밋한다.

### Task 4: 글자·문단·표 제어

**Files:** `HwpHwpxStyles.psm1`, 새 `HwpHwpxBlocks.psm1`, `HwpHwpx.psm1`, `HwpInspect.psm1`, 검증·스키마, 새 `tests/HwpxRichBlocks.Tests.ps1`.

**Interfaces:** paragraph는 text 또는 runs를 받는다. run은 text/textStyle이다. table은 widthMm/columnWidthsMm/rowHeightsMm/repeatHeader/pageBreak/alignment, cell은 rowSpan/colSpan/paragraphs/verticalAlignment와 style을 받는다. cell text와 paragraphs는 배타적이다.

- [x] 부분 서식·밑줄·장평·자간, 고정 줄 간격, 문단 묶기, 병합 셀과 비균등 열 너비의 RED를 확인한다.

```json
{"type":"table","rows":2,"columns":2,"columnWidthsMm":[40,100],"cells":[{"row":1,"column":1,"colSpan":2,"text":"제목"},{"row":2,"column":1,"text":"항목"},{"row":2,"column":2,"text":"내용"}]}
```

- [x] 스타일 리소스 ID를 문서 단위로 관리하고 문자 구간마다 charPrIDRef를 기록한다.
- [x] 문단 탭·목록·명명 스타일·breakSetting을 원문 XML 모델과 대조하여 구현한다.
- [x] 병합 그리드 occupancy로 겹침·범위 초과를 거부하고 covered 칸은 중복 생성하지 않는다. 열합·표폭·현재 영역을 검증한다.
- [x] 네 변 테두리·셀 안쪽 여백·배경·정렬·제목행 반복·쪽 넘김을 독립 검사한다.
- [x] 속성 대조 및 회귀 시험을 통과하여 커밋한다.

### Task 5: 이미지 배치와 기본 개체

**Files:** `HwpHwpxBlocks.psm1`, `HwpHwpx.psm1`, 검사·계획·스키마, 새 `tests/HwpxObjects.Tests.ps1`.

**Interfaces:** image는 placement(treatAsChar/relativeTo/alignment/offsetMm/wrap), crop, rotation, flip, caption, description을 받는다. shape는 LINE/RECTANGLE/ELLIPSE/TEXTBOX와 size/text/style을 받는다.

- [x] 실제 그림 fixture로 원본 비율 보존·오프셋·회전·crop·캡션의 RED 시험을 작성한다.
- [x] BinData 바이트 해시를 보존하면서 XML 속성으로 변환을 표현한다. 원본 비율 없는 기본 40×30mm 강제 변형은 제거한다.
- [x] 공식 개체 모델의 orgSz/curSz/rotationInfo/renderingInfo/pos를 대조하고 기본 도형을 기록한다.
- [x] 실제 이미지 바이트 포함과 요청한 속성·대체 설명을 다시 읽어 확인하고 커밋한다.

### Task 6: 문서 참조와 반복 구성

**Files:** 새 `HwpHwpxReferences.psm1`, 기존 작성·검사·계획·스키마, 새 `tests/HwpxReferences.Tests.ps1`.

**Interfaces:** section document.header/footer/pageNumber, bookmark/hyperlink/footnote/endnote/field/toc 블록. 실제 컨트롤을 기록하고 고유 ID/이름을 검사한다.

- [x] 필드가 일반 텍스트가 아닌 실제 컨트롤인지, 구역별 머리말/홀짝/쪽 번호/각주/책갈피 링크를 기록하는지 RED 시험을 작성한다.
- [x] 한컴 컨트롤 모델을 기준으로 XML을 기록한다. 전역 ID와 구역 시작 번호를 일관되게 관리한다.
- [x] 링크 차례는 제목 책갈피를 사용한다. 실제 쪽 번호 차례는 렌더러가 없으면 사전 거부한다.
- [x] 명칭 중복·끊어진 링크·허용되지 않은 URL·미지원 자동 갱신 옵션을 거부한다.
- [x] 문서 구성 왕복 검사와 CLI 생성 시험을 통과하여 커밋한다.

### Task 7: 원본 보존 HWPX 부분 수정

**Files:** 새 `HwpHwpxEdit.psm1`, CLI/라우터/기능/검사, 새 `tests/HwpxEdit.Tests.ps1`.

**Interfaces:** 기존 편집 계획과 source.sha256을 사용한다. 지원 작업에만 hwpx-direct apply 라우팅을 제공한다. 미지원 작업은 사전에 차단한다.

- [x] 합성 XML 확장 요소·BinData·구역을 넣은 원본에서 문구·속성 수정 및 보존 시험을 작성한다.
- [x] 원본 ZIP 항목을 보존하며 해당 XML 노드만 변경한다. 공유 스타일은 새 ID로 복제한다.
- [x] 표 병합·분할은 명시적 내용 보존 정책에 따르고 모호한 대상을 거부한다.
- [x] 원본 해시·대상 외 노드·변경 없는 파트의 비압축 해시를 대조한다. 실패 결과는 승격하지 않는다.
- [x] 무변경 왕복·수정·실패 복구 시험을 통과하여 커밋한다.

### Task 8: 기능표·행동 시험·통합 검증

**Files:** `SKILL.md`, `references/authoring.md`, `references/feature-support.md`, `references/limitations.md`, `references/operations.md`, `README.md`, examples, 관련 시험.

- [x] 기존 Static/결함 RED 기준선과 독립 에이전트의 실제 요청→CLI→ZIP 행동 시험을 확보한다.
- [x] 기능표를 생성·읽기·수정·구조·시각 검증으로 구분한다. 미구현 기능은 unsupported로 유지한다.
- [x] 하나의 혼합 용지 보고서 예제로 지원 옵션을 안내한다. 내부 개발 계획을 일반 문서 작업에 요구하지 않는다.
- [x] 새 스킬로 동일 행동 시험을 통과시킨다. 전체 Static, PowerShell 5.1, CLI, ZIP 배포·임시 설치 시험을 실행한다.
- [x] 전체 diff 독립 검토와 모든 중대 지적 수정을 마친다. 현재 사용자 한컴을 실행하지 않는다.
- [x] A~C 충족 여부를 명세와 대조한 뒤에만 로컬 설치를 백업 갱신한다. GitHub 반영 전 대상 변경과 검증 결과를 확인한다.

## 진행 기록

- 기준 Static: 157 통과, 1 실패(새 최상위 창 감지). 같은 무창 시험을 분리 재실행하여
  7개 통과를 확인했고, V2 혼합 구역/부분 수정 감시를 더한 8개 시험도 통과했다.
- 실제 구현 파일 분리: 쪽 계산은 기존 `HwpHwpxStyles.psm1`과 새 `HwpAuthoringPlan.psm1`에
  통합했다. 별도 `HwpPageLayout.psm1`을 중복 생성하지 않았다. 표/문단은 기존 작성기에,
  그림/도형은 `HwpHwpxObjects.psm1`에, 참조는 `HwpHwpxReferences.psm1`에 배치했다.
- 부분 수정은 기존 HWP V1 `apply` 의미를 바꾸지 않는 별도 V2 `edit-hwpx`와
  `HwpHwpxScopedEdit.psm1`로 구현했다. 최상위 해시 필드는 `sourceSha256`이다.
  스타일 ID 선택/복제, 방향·크기·여백, 텍스트 전용 셀의 보존형 병합/분할을 제공한다.
- 생성 검증은 생성기·검사기에 의존하지 않는 `HwpAuthoringVerify.psm1`을 추가하고
  최종 결과 승격 전에 필수로 실행한다. 방향/치수/구역/참조/표/그림 바이트 오염 시험 포함.
- 같은 스타일 리소스는 구역 간 재사용한다. 명시적인 단 나누기를 따라 현재 단 폭을
  사용하며 자동 조판에 따른 단 이동은 예측하지 않는다.
- 공식 모델 대조 후 `lineBreak/tab`을 `hp:t` 안에 기록하도록 고쳤고, 검사기는 DOM 순서로
  구분자를 읽는다. 템플릿의 계산되지 않은 줄 캐시/미리보기 이미지는 새 문서에 넣지 않는다.
- 독립 행동 시험: 세 구역, 18pt 제목/11pt 본문, 3열 병합 표, PNG, 링크 차례와 각주를
  실제 CLI로 작성했고 독립 ZIP 검사 31개를 통과했다. 쪽 번호 차례와 변경 추적은 차단했다.
  이후 입력 검증 보완을 포함한 고정 소스 전체 재검사를 수행한 뒤에만 설치한다.
- 공개 GitHub/기본 브랜치에는 아직 반영하지 않았다. 각 작업 중간 커밋 대신 전체 검증을
  마친 기능 브랜치의 단일 구현 커밋으로 묶는다. 통합 방식은 사용자에게 확인한다.
- 마지막 독립 안전 검토의 경로 해석 후 UNC 검사 누락을 수정했다. 문서와 이미지 모두
  정규화한 로컬 경로를 파일 열기 전에 검사하며, 실제 네트워크 접속 없이 회귀 시험했다.
- Windows PowerShell 5.1 새 프로세스의 압축 어셈블리 명시 로드와 기존 편집/일괄 계획의
  JSON 파싱 호환성을 보완했다. 시험·설치 스크립트의 한글 인코딩과 실행기 선택도 정리했다.
- 5.1에는 Test-Json이 없어 편집/표 구조 JSON Schema 전용 시험 3개는 7에서 검사한다.
  새 작성/기능 계약의 표준 스키마 대조는 시험용 PowerShell 7을 사용하며 설치 엔진에는
  PowerShell 7이나 별도 JSON 라이브러리를 필수로 추가하지 않았다.
- 설치본 재생성 시험에서 .NET Framework의 NoCompression이 실제로는 ZIP method 8을
  기록하는 차이를 발견했다. 새 빈 스트림에 저장형 mimetype ZIP을 초기화하고 Update로
  나머지 항목을 추가하여 5.1/7의 생성·부분 수정 모두 method 0을 유지한다. 독립 검증기에도
  첫 로컬 헤더/중앙 디렉터리의 mimetype 비압축 규칙을 필수 승격 조건으로 추가했다.
- 최종 검증: PowerShell 7은 422/422 통과, 5.1은 419 통과/3개 스키마 전용 검사 제외,
  실패 0. Codex·Claude 설치본 각각 41개 파일의 원본 해시 일치와 혼합 보고서 생성·재읽기,
  독립 ZIP 검사 31개를 확인했다. 기존 설치본은 삭제하지 않고 백업했다.
- 인수 근거와 시각 검증 한계는 `docs/superpowers/reports/2026-09-03-hwpx-authoring-controls-qa.md`에 정리했다.
