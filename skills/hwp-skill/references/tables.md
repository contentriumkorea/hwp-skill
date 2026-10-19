# 표와 셀 통합 제어

사용자는 자연어로 요청하고 AI는 `hwp-skill` 하나로 읽기·계획·작성·부분 수정·재검사를
처리한다. 아래 명령과 JSON은 AI의 내부 작업 규격이다. 사용자에게 계획 작성을 요구하지 않는다.
모든 작업은 HWPX ZIP/XML을 직접 처리하며 한컴 창·COM·파일 접근 보안 모듈을 사용하지 않는다.

## 요청별 처리

| 요청 | 처리 |
|---|---|
| 표 새로 만들기 | V2 `generate -NewDocument`, 실제 table/cell 노드 생성 |
| 셀 안 여러 문단·빈 줄·부분 글자 서식 | 새 표는 `cells[].paragraphs[].runs`, 기존 셀은 `set-cell-content` |
| 셀 안 특정 글자만 바꾸기·서식 바꾸기 | 검사된 내부 run 주소로 `replace-run-text` / `set-run-format` |
| 셀 전체 글꼴·글자 크기·굵기·색·자간·장평 | `set-cell-format.textStyle` |
| 문단 가로 정렬·줄 간격·들여쓰기 | 셀 전체는 `set-cell-format.paragraphStyle`, 한 문단은 `set-paragraph-format` |
| 셀 세로 정렬·안쪽 여백·선·배경 | `set-cell-format.verticalAlignment/style` |
| 표 전체 서식·행 높이·열 너비·반복 제목행 | `set-table-format` |
| 셀 병합·기존 병합 해제 | `merge-cells` / `split-cell` |
| 셀 안 그림·표 삽입 | `insert-cell-image` / `insert-cell-table`, 기존 개체를 보존해 추가 |
| 합계·수량×단가·연쇄 계산 | `calculate-table`, 셀 참조 기반 decimal 계산과 결과 재검사 |
| 행열 삽입·삭제 | `insert-table-row/column` / `delete-table-row/column`, 병합 범위 조정 포함 |
| 결과 확인 | 출력에서 `inspect`, 필요하면 근사 `preview`; 요청한 값과 셀 그리드 비교 |

일반적인 새 서류는 A4 세로·본문 11pt·줄 간격 160%·문단 위아래 0을 기본으로 한다.
내용 사이 추가 공간은 셀 안에서도 독립 빈 문단과 그 글자 크기로 조절한다. 사용자가
요청한 다른 서식과 기존 문서의 설정은 유지한다. 표를 그림이나 공백 문자로 흉내 내지 않는다.

## 새 표

실행 가능한 기본 예제는 [table-rich.plan.json](../examples/table-rich.plan.json)이다.
작성 계획의 셀은 **1부터**, 검사와 부분 수정은 **0부터**다. 병합된 칸은 기준 셀만
명시하고 나머지 칸을 중복 생성하지 않는다. `text`와 `paragraphs`는 함께 지정하지 않는다.
`paragraphs`의 각 문단은 `text` 또는 `runs` 하나만 사용한다.

표/셀의 글자·문단 서식은 [작성 규격](authoring.md)의 상속 규칙을 따른다. 빈 문단은
`{type:"paragraph",text:"",textStyle:{fontSizePt:6}}`이며, 문단 내부 `\n`과 다르다.
문단 안 `\n`은 줄바꿈, `\t`는 탭 문자로 저장한다.

## 기존 셀 내용과 서식

먼저 `inspect`의 `tables[].cells[].address`와 `text`를 가져온다. 병합 셀은 `rowAddress` /
`columnAddress`의 기준 셀을 고른다. `grid`의 `mergedInto` 칸을 별도 셀로 해석하지 않는다.
아래 `<검사 주소>`는 실제 주소 객체로 대체한다.

```json
{
  "version":"2.0",
  "operations":[{
    "type":"set-cell-content",
    "address":"<검사 주소>",
    "expectedText":"원래 첫 문단\n원래 둘째 문단",
    "paragraphs":[
      {"type":"paragraph","runs":[
        {"text":"담당자: ","textStyle":{"bold":true}},
        {"text":"홍길동","textStyle":{"bold":false,"fontFamily":"맑은 고딕","fontSizePt":11}}
      ]},
      {"type":"paragraph","text":"","textStyle":{"fontSizePt":6}},
      {"type":"paragraph","text":"추가 설명","paragraphStyle":{"alignment":"LEFT"}}
    ]
  }]
}
```

`expectedText`는 검사 결과의 기존 셀 `text`를 그대로 사용한다. 비교할 때 CRLF/CR/LF를
LF로 정규화하므로 Windows 검사 결과도 별도 변환 없이 받는다. 기존 셀의 그림·필드·중첩 표·
알 수 없는 문단 메타데이터가 제거될 수 있으면 전체 내용 교체를 차단하고 지원되는
내부 run만 부분 수정한다. 명시하지 않은 새 문단/run의 서식은 기존 셀 첫 문단/run을
상속한다. 새 문단 ID는 문서 전체에서 고유하다.

`set-cell-format`은 주소와 아래 속성 중 하나 이상을 지정한다.

```json
{
  "type":"set-cell-format",
  "address":"<검사 주소>",
  "verticalAlignment":"CENTER",
  "style":{
    "fillColor":"#EDF3F8",
    "borderType":"SOLID","borderWidthMm":0.2,"borderColor":"#315B77",
    "cellMargins":{"leftMm":2,"rightMm":2,"topMm":1,"bottomMm":1},
    "borders":{"bottom":{"type":"DOUBLE","widthMm":0.3,"color":"#315B77"}}
  },
  "textStyle":{"fontFamily":"맑은 고딕","fontSizePt":11,"bold":false},
  "paragraphStyle":{"alignment":"CENTER","lineSpacingPercent":160,"marginBeforeMm":0,"marginAfterMm":0}
}
```

글자 서식은 글꼴·크기·굵게·기울임·색·밑줄·취소선·윗첨자/아랫첨자·자간·장평을
지원한다. 윗첨자와 아랫첨자는 동시에 켜지 않는다. 글꼴 이름 등록은 글꼴 파일의 설치나
포함이 아니며 실제 화면에는 해당 글꼴이 필요하다. 셀 전체 서식은 그 셀의 모든 일반
문단/run에 적용하며 셀의 이름·기하·요청하지 않은 속성은 유지한다. 그림/필드 컨트롤이
있는 셀의 전체 글자 서식 변경은 차단하고 일반 run의 검사 주소로 수정한다.

`style.cellPaddingMm`는 네 변 공통 여백이고 `cellMargins`가 지정된 변을 덮어쓴다.
여백이 저장된 셀 크기를 모두 차지하면 거부한다. 테두리 두께와 종류는 새 표의 규격과
같다. 기존 공유 글자·문단·테두리 리소스를 복제하므로 다른 셀이나 본문은 바뀌지 않는다.
동일한 원본 서식과 변경 조합은 새 리소스를 재사용한다.

## 표 전체와 행열

`set-table-format`은 표 `address`와 아래 속성 중 하나 이상을 받는다.

- `columnWidthsMm`: 현재 열 개수와 같은 길이의 양수 배열.
- `rowHeightsMm`: 현재 행 개수와 같은 길이의 양수 배열.
- `alignment`: `LEFT/CENTER/RIGHT`, 기존 위치 노드의 가로 정렬.
- `repeatHeader`: Boolean, 켜면 첫 행을 제목 셀로 지정.
- `headerRows`: 0~전체 행 수. 위에서부터 여러 제목 행을 지정하며 `repeatHeader`와 함께 쓰지
  않는다. 세로 병합을 자르는 제목 경계는 거부한다.
- `textDirection`: `HORIZONTAL`, `VERTICAL`, `VERTICALALL`.
- `lineWrap`: `BREAK`, `SQUEEZE`, `KEEP`. 쓰기 방향/줄 처리의 저장 속성이며 실제 조판은 별도다.
- `pageBreak`: `CELL/TABLE/NONE`.
- `verticalAlignment/style/textStyle/paragraphStyle`: 위 셀 서식을 표의 모든 기준 셀에 적용.

크기는 절대 크기의 완전한 표에서 수정한다. 병합 셀의 너비/높이는 해당 행열 크기의
합으로 갱신한다. 행 높이는 저장 기하 정보이며 내용에 따른 실제 최소 높이·페이지
분할을 고정하는 렌더링 보증이 아니다. 합계가 본문 폭에 맞는지 작성자가 확인한다.

행열 삽입·삭제는 병합된 완전한 직사각형 그리드도 지원한다. 삽입 경계를 가로지르는
병합은 늘리고, 삭제되는 행열에 걸친 병합은 줄인다. 병합 기준 셀이 속한 첫 행열을
삭제해도 남은 병합 영역으로 문단·그림·중첩 표를 옮겨 보존한다. 새로 생긴 빈 칸만
빈 셀로 만든다. 통째로 없어질 셀에 그림·필드·미지 개체가 있으면 텍스트 확인만으로
삭제하지 않는다.

삭제 `expectedTexts`는 삭제 행이면 왼쪽부터, 삭제 열이면 위부터 각 **그리드 위치**의
문자열 배열이다. 같은 병합 기준 셀에 속한 위치는 그 기준 셀의 텍스트를 반복한다.
마지막 행/열은 삭제하지 않는다. 원래 행열 크기를 모르면 인위적으로 균등 분배하지
않는다. 이 경우 작업에 기존 `columnWidthsMm` / `rowHeightsMm` 배열을 함께 지정해야 하며
모든 기존 병합 크기의 합과 일치하는지 검증한다. 일반 본문 표뿐 아니라 검사 주소로
고른 중첩 표에도 적용한다. 삽입/삭제·병합/해제·표 전체 설정·중첩 표 삽입은
`-ApproveAdvanced`로 실행한다.
사용자의 요청에 대상과 변경값이 이미 명확하면 AI가 내부 실행 플래그를 적용하며 같은
요청에 대한 동의를 반복해서 묻지 않는다.

한 계획에 표 전체 교체와 그 내부 변경을 겹쳐 넣지 않는다. 표 구조/전체 설정 → 재검사 →
셀 내용 → 재검사 → 필요한 부분 서식처럼 AI가 여러 번 처리하고 마지막 결과만 전달한다.
최대 4,096칸, 한 축 256칸의 완전한 표와 셀 간격 0을 지원한다. 셀 전체 내용 교체는 셀당
1~1,024문단, 문단당 1~1,024 run 및 계획 전체 16,384문단/run·텍스트 16MiB 이내다.

## 셀 안 그림과 중첩 표

새 문서는 기본 표를 먼저 생성한 뒤, 같은 스킬이 `inspect` → `edit-hwpx`를 이어서
수행한다. 기존 문서에도 똑같이 사용한다. 작성 JSON에 미지원 속성을 넣거나 별도 스킬을
호출하는 대신, 각 출력의 새 주소로 순차 삽입한다. 기본 견적표 예제는
[table-objects.plan.json](../examples/table-objects.plan.json)이다.

`insert-cell-image`는 셀 주소, 기존 `expectedText`, `placement:"append"|"prepend"`,
로컬 `path`, 선택 `widthMm/heightMm/altText`를 받는다. 이미지는 실제 BinData와 manifest
참조를 만들어 셀의 독립 문단 안 인라인 개체로 넣는다. 기존 문단·그림·표를 지우지 않는다.
치수 생략 시 비율을 유지하고 최대 40mm 또는 셀 안쪽 폭을 사용한다. 명시한 폭이 셀을
넘으면 임의 축소하지 않고 거부한다. PNG/JPEG/GIF/BMP의 시그니처·디코딩·실제 치수를
검사한다. 그림당 32MiB, 계획 전체 새 그림 128MiB·디코딩 1억 픽셀 이내다.

`insert-cell-table`은 같은 주소/텍스트/placement와 `table` 정의를 받는다.

```json
{
  "type":"insert-cell-table",
  "address":"<검사 주소>","expectedText":"기존 셀 내용","placement":"append",
  "table":{
    "rows":2,"columns":2,
    "textStyle":{"fontFamily":"맑은 고딕","fontSizePt":10},
    "style":{"borderType":"SOLID","borderWidthMm":0.2,"borderColor":"#315B77","cellPaddingMm":0.5},
    "cells":[
      {"row":1,"column":1,"text":"구분"},
      {"row":1,"column":2,"text":"내용"},
      {"row":2,"column":1,"colSpan":2,"paragraphs":[
        {"type":"paragraph","runs":[{"text":"중요: ","textStyle":{"bold":true}},{"text":"실제 표 안의 표입니다."}]}
      ]}
    ]
  }
}
```

셀 주소는 새 표 정의 안에서 1부터 시작한다. `table`은 `rows/columns/cells`가 필수이고
`widthMm/columnWidthsMm/rowHeightsMm/style/textStyle/paragraphStyle/repeatHeader/alignment/pageBreak`를
선택한다. 셀에는 `rowSpan/colSpan/verticalAlignment/style/textStyle/paragraphStyle`과
`text`, `paragraphs`, `content` 중 하나를 둔다. `content`에는 `type:"paragraph"`,
`type:"image"`, `type:"table"` 블록을 넣어 추가 중첩과 그림을 배치한다. image는 위와 같은
로컬 경로/치수, table은 다시 `table` 객체를 받는다. 중첩 8단계·계획 전체 16,384칸 이내다.
새 리소스·개체·문단 ID는 충돌하지 않게 배정하고, 상위 셀 안쪽 폭을 넘는 표를 거부한다.
행 높이는 여전히 초기/최소 기하 정보다.

## 셀 계산과 합계

`calculate-table`은 표 주소와 `calculations`를 받는다. **대상 row/column은 0부터**, 식의
`A1/B2` 참조는 일반 표 계산 표기처럼 1부터다. 숫자·셀 참조·괄호·단항 부호·사칙연산과
`SUM/AVERAGE/MIN/MAX/COUNT/ROUND`만 허용한다. 코드·스크립트·외부 링크를 평가하지 않는다.

```json
{
  "type":"calculate-table","address":"<검사한 표 주소>",
  "calculations":[
    {"row":1,"column":3,"expectedText":"0","expression":"B2*C2"},
    {"row":2,"column":3,"expectedText":"0","expression":"B3*C3"},
    {"row":3,"column":3,"expectedText":"0","expression":"SUM(D2:D3)",
     "format":{"decimalPlaces":0,"groupSeparator":true},"textStyle":{"bold":true}}
  ]
}
```

입력 셀은 빈칸 또는 부호·소수점·정상 천 단위 쉼표가 있는 숫자여야 한다. `원` 같은
단위 문자를 숫자로 추측하지 않는다. 범위 집계는 빈칸과 병합의 덮인 칸을 건너뛰고,
숫자가 아닌 본문을 참조하면 오류로 중단한다. 범위의 병합 기준 셀은 한 번만 센다.
목록 안 계산 셀의 상호 참조는 순서와 무관하게 해석하되 순환 참조를 거부한다.
0 나누기·decimal 범위 초과·잘못된 참조·보호된 대상도 결과 파일을 쓰기 전에 거부한다.

`format`은 `decimalPlaces`(0~8), `groupSeparator`(Boolean), `prefix/suffix`(각 64자 이내)를
선택한다. 반올림은 decimal의 `AwayFromZero` 방식이며 식 안 `ROUND`와 표시 반올림을
구분한다. 계획 전체 최대 1,024개 계산 셀·65,536개 참조다. 재열기 후 값은
`data.CalculationResults`로 보고하며 원래 공유 서식과 다른 셀은 유지한다.

이 값은 **스킬이 계산해 기록한 결과**다. 한글 자체 자동 갱신 필드가 아니므로 데이터나
행열을 수정하면 AI가 원래 계산 계획의 참조를 확인하고 다시 실행한다. 한 작업의 계산
계획은 내부 작업 자료로 보존하며, 사용자에게 수식이나 JSON 재입력을 요구하지 않는다.
다른 곳에서 가져온 문서에 계산 계획이 없으면 의도한 참조/합계 범위를 확인한다.

## 남은 경계

한글 자체 자동 갱신 수식 필드, 내용 기반 자동 크기, 날짜/다중키 정렬, 보호 해제는 지원하지
않는다. 이를 임의 생략하거나 한컴을 실행해 대체하지 않는다. 구조 검사와 근사 미리보기는
한컴의 실제 글꼴·줄바꿈·쪽 배치 검증과 구분한다.

## 표 행 데이터 정렬

`sort-table-rows`는 표 주소와 `startRow/endRow/column`(0부터, 끝 행 포함),
`dataType:"NUMBER"/"TEXT"`, `direction:"ASC"/"DESC"`를 받는다. 범위 밖 행과 같은 키의
행 순서는 유지한다. `TEXT`는 대소문자를 구분하는 ordinal 순서로 한국어 사전/날짜 정렬과
다르다. `NUMBER`는 단위 없는 decimal과 정상 천 단위 쉼표만 허용한다.

키가 아닌 셀의 그림·중첩 표는 행과 함께 이동하며 자산 바이트를 보존한다. 세로 병합,
제목 행을 포함한 범위, 필드/책갈피/각주·미주가 있는 표, 개체를 포함한 키 셀은 차단한다.
`-ApproveAdvanced`로 실행하고 정렬 뒤 계산의 의도한 참조 범위를 다시 확인한다.
기존 저장 합계나 외부 참조를 자동 재배치/재계산하지 않는다.

## 셀 대각선

`set-cell-diagonal`은 셀의 `tc` 주소와 `direction`을 받는다.
`SLASH`(`/`), `BACK_SLASH`(`\`), `CROSS`(두 선), `NONE`(대각선 숨김) 중 하나다.
보이는 선에는 `line:{type:"SOLID",widthMm:0.12,color:"#000000"}`처럼 세 속성을 모두
지정한다. 선 모양은 탭 채움선의 지원 값 중 `NONE`을 제외한 값, 색은 `#RRGGBB`다.
폭은 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.6, 0.7, 1, 1.5, 2, 3, 4, 5mm 중
정확한 값만 허용한다. `NONE`에는 `line`을 넣지 않으며 기존 선 리소스의 값은 보존한다.

공유 `borderFill`을 복제해 선택 셀만 새 정의를 참조하게 한다. 사방 테두리·배경과 셀
내용은 보존한다. 기존 대각선이 단일 직선(`CENTER`)/없음(`NONE`)이고 꺾임·반대 모드가
없는 경우만 편집한다. 복잡한 대각선이나 모호한 원본 플래그는 해석하지 않고 차단한다.
새 표도 기본 작성 후 같은 엔진으로 적용한다. `-ApproveAdvanced`를 사용하고 결과의
테두리 참조와 대각선 속성을 다시 읽는다. 선 위 글자를 자동으로 둘로 나누지는 않는다.
