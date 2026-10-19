# 무창 HWPX 작성·수정 규격

일반 사용자는 JSON을 작성하거나 모듈을 설치할 필요가 없다. AI가 요청을 아래 계획으로
변환하고, 패키지에 포함된 명령으로 검사·작성·재검사한다. 지원 여부는
[기능표](feature-support.md)를 먼저 확인한다. 한컴 창을 열어 부족한 기능을 우회하지 않는다.

## 새 문서

새 계획은 `version: "2.0"`을 사용한다. `content`(한 구역) 또는 `sections`(여러 구역) 중
하나만 지정한다. 기존 `1.0` 계획의 허용 속성은 그대로 유지하며 자동으로 업그레이드하지 않는다.
알 수 없는 속성, 문자열 Boolean, 소수 행·열, 유효 영역이 없는 여백은 작성 전에 거부한다.

```powershell
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" validate-generate-plan -PlanPath "계획.json"
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" generate -NewDocument `
  -PlanPath "계획.json" -OutputPath "별도 결과.hwpx"
```

용지·줄 간격을 별도로 지정하지 않은 일반 서류는 다음 기본 계획에서 시작한다.
제목과 본문은 공통 160%·문단 앞뒤 0mm를 쓰고, 그 사이에는 글자 크기 6pt인 빈 문단을
둔다. 빈 문단도 실제 편집 가능한 문단이므로 한글에서 엔터/백스페이스로 추가·삭제하거나
빈 줄의 글자 크기만 바꿀 수 있다. A4 세로와 본문 11pt는 유지된다.

```json
{
  "version": "2.0",
  "document": {
    "page": {"paperSize": "A4", "orientation": "PORTRAIT"},
    "textStyle": {"fontSizePt": 11},
    "paragraphStyle": {"lineSpacingPercent": 160, "marginBeforeMm": 0, "marginAfterMm": 0}
  },
  "content": [
    {"type": "paragraph", "text": "업무 보고서", "textStyle": {"fontSizePt": 18, "bold": true}},
    {"type": "paragraph", "text": "", "textStyle": {"fontSizePt": 6}},
    {"type": "paragraph", "text": "업무 보고서 본문"}
  ]
}
```

일반 서류의 공간 구성은 **내용 문단 → 필요한 빈 문단 → 다음 내용 문단**이다.
좁은 간격은 빈 문단 6pt, 조금 넓은 간격은 9pt처럼 빈 문단의 글자 크기로 조절한다.
이 수치는 예시이며 본문 글자를 여백용으로 줄이거나 키우지 않는다. 제목·소제목의
크기 차이는 정보 위계를 위한 서식이다. 문단 위·아래 값이나 FIXED/AT_LEAST 줄 간격으로
추가 여백을 만들지 않고, 제목·본문·이름 있는 스타일도 공통 160%/앞뒤 0을 상속한다.
빈 문단은 `text:""`인 독립 paragraph 블록이다. 공백 문자나 `\n\n`을 넣는 방식과 다르다.
`text` 안의 `\n`은 문단 내부 줄바꿈(`hp:lineBreak`)이므로 독립된 엔터 문단으로 쓰지 않는다.
표 셀마다 빈 줄을 일괄 삽입하지 않고 내용 구분에 필요한 위치에만 둔다. 쪽 넘김은
빈 줄을 여러 개 쌓는 대신 `page-break`로 지정한다. 정확한 빈 줄의 물리 높이는 렌더링
검증과 구분한다.

사용자가 가로·특정 줄 간격을 요청한 경우 해당 값을 적용한다. 기존 양식 수정은
원본의 방향·문단 설정을 유지하며 자동으로 빈 문단 방식으로 재작성하지 않는다.
[구역별 보고서 계획](../examples/authoring-v2.plan.json)은
세로/가로 혼합, 다단 등 고급 기능 예제이며 일반 서류의 기본 서식이 아니다.
작업 중 한컴·Word·Explorer를 열거나 결과 파일을 자동으로 표시하지 않는다.
명령의 전체 JSON에는 상세 검사 정보가 포함된다. AI는 이를 내부 변수/로그에 보관하고
`status/errors/StructuralVerification`만 먼저 확인한다. 전체 JSON이나 XML을 사용자 대화에
붙이지 않는다. 세부 사항이 필요할 때만 해당 구역·표·문단을 선택해서 읽는다.

## 쪽과 구역

문서 기본 설정 `document`를 각 `sections[].document`가 필요한 속성만 덮어쓴다.
여백은 항목별로 상속한다. 용지 프리셋과 사용자 용지는 서로 대체하는 설정이다.

| 속성 | 값과 의미 |
|---|---|
| `page.orientation` | `PORTRAIT`, `LANDSCAPE`; 생략하면 세로 |
| `page.paperSize` | `A3`, `A4`, `A5`, `ISO_B4`, `ISO_B5`, `JIS_B4`, `JIS_B5`, `LETTER`, `LEGAL` |
| `page.paperWidthMm`, `paperHeightMm` | 프리셋 대신 쌍으로 지정하는 회전 전 용지 치수; 너비 ≤ 높이 |
| `page.margins` | `leftMm`, `rightMm`, `topMm`, `bottomMm`, `headerMm`, `footerMm`, `gutterMm` |
| `page.gutterType` | `LEFT_ONLY`, `LEFT_RIGHT`, `TOP_ONLY` |
| `page.border` | 표와 같은 테두리/배경 스타일 |
| `page.borderApplyTo` | `BOTH`, `ODD`, `EVEN` |
| `page.borderVisibility`, `fillVisibility` | `SHOW_ALL`, `HIDE_FIRST`, `SHOW_FIRST` |
| `columns` | `count`, `gapMm`, 선택적 `widthsMm` 및 `separator` |

`columns`는 `page` 안이 아니라 `document` 바로 아래에 둔다. 구분선은
`{type:"SOLID",widthMm:0.12,color:"#000000"}` 형식이다. 사용자 단 너비의 합과 단 간격은
본문 폭과 일치해야 한다. 비균등 다단에서 자동 표 폭은 첫 단부터 시작하여 명시적
`column-break`가 가리키는 현재 단에 맞춘다. `page-break`는 첫 단으로 돌아간다.
내용 넘침에 의한 자동 단 이동은 렌더러 없이 예측하지 않는다. 폭이 다른 단에서
정확한 배치가 필요하면 단 나누기를 명시하고 실제 렌더링 확인은 별도로 구분한다.

기본 여백(mm)은 좌우 15, 위아래 10, 머리말·꼬리말 15, 제본 0이다. 본문 폭은 유효 용지
폭에서 좌우·제본 여백을 뺀 값이다. 본문 높이는 위아래와 머리말·꼬리말 영역도 뺀다.
머리말·꼬리말이 비어 있어도 이 공간을 확보한다.
[한컴 공식 여백 설명](https://help.hancom.com/hoffice130/ko-KR/Hwp/format/setting_paper/setting_paper(margins).htm).
`TOP_ONLY` 제본은 높이에서 뺀다. 고정 180mm 표 폭을
사용하지 않는다. 명시적인 표/인라인 그림 폭이 영역을 초과하면 임의로 줄이지 않는다.

V1의 `widthMm/heightMm`는 화면상 치수다. V2의 `paperWidthMm/paperHeightMm`는 회전 전
치수다. 실제 HWPX `pagePr`에는 회전 전 치수를 쓰고 `landscape`로 방향을 표현한다.
저장값은 **세로 `WIDELY`, 가로 `NARROWLY`**다. 영단어의 뜻으로 반대로 판단하지 않는다.
배포된 한컴 기본 템플릿은 `WIDELY`, 너비 59528, 높이 84186인 세로 A4다.
검사 결과 `paperWidth/paperHeight`와 `width/height`를 구분한다.

`page-break`는 쪽 나누기, `column-break`는 단 나누기, `sections`의 새 항목은 구역 나누기다.
이들을 같은 기능으로 대체하지 않는다.

## 글자·문단·표

문단은 `{type:"paragraph",text:"본문"}` 또는 `runs:[{text,textStyle?}]` 중 하나다.
글자 기본값은 문서 → 구역 → 블록 → 셀/문단 → run 순으로 상속하고 명시적 `false`도 보존한다.

줄 간격 160%는 `lineSpacingPercent:160`이며 1.6이나 160pt가 아니다.
명시적으로 요청된 고정/최소 간격은 `valuePt`로 입력한다. 일반 서류의 여백 구성에는
앞의 빈 문단 방식을 사용한다. 작성기가 HwpUnitChar 호환 분기를 생성하여
14pt를 최신 분기 1400·구형 분기 2800으로 기록한다. 문단의 mm 길이도 구형 분기에서
두 배이며 비율 간격은 두 분기에서 동일하다. 이 보정은 문단 속성에만 적용한다.
새 문서에 추정 `linesegarray`를 넣지 않는다. 실제 페이지 수·글자 줄바꿈은 렌더링 미검증이다.
검사 결과의 `raw` 및 `lineSpacing.value`는 파일에 저장된 원시 값이다. 문단의 mm/pt는
호환 분기를 반영하여 읽으며, 고정/최소 줄 간격의 물리값은 `lineSpacing.measurement`에
있다. 비율 줄 간격은 `value`가 백분율이고 `measurement`는 비어 있다.

- `textStyle`: `fontFamily`, `fontSizePt`, `bold`, `italic`, `textColor`, `underline`
  (`NONE/BOTTOM/CENTER/TOP`), `strikeout`, `superscript`, `subscript`,
  `letterSpacingPercent`, `widthPercent`. 윗첨자·아랫첨자는 동시에 쓰지 않는다.
- `paragraphStyle`: `alignment`, `lineSpacingPercent` 또는
  `lineSpacing:{type:"FIXED"|"AT_LEAST",valuePt}`, 앞뒤 `marginBeforeMm/marginAfterMm`,
  `leftMarginMm/rightMarginMm`, `indentMm`, `keepWithNext`, `keepLines`, `widowOrphan`,
  `pageBreakBefore`.
- 탭: `tabs:[{positionMm,alignment,leader}]`. 목록:
  `list:{type:"NUMBER"|"BULLET"|"OUTLINE",level?,start?,character?}`. 번호 목록은 같은
  목록 서식을 공유할 때 같은 번호 리소스를 사용한다. 실제 번호 표시 갱신은 렌더링 미검증이다.
- 이름 있는 문단 스타일: `document.styles:[{name,textStyle?,paragraphStyle?}]`를 정의하고
  일반/셀 문단에 `styleName`을 지정한다. 한 설정 안에서 이름은 중복하지 않는다.
  같은 정의는 구역 간 공유한다. 구역마다 같은 이름의 실효 서식이 달라지면 저장 이름에
  내부 ID를 붙여 충돌을 방지한다. 지정한 문단은 해당 구역의 서식을 참조한다.

표는 `rows/columns/cells`가 필요하다. **작성 계획의 셀 주소는 1부터, 검사 결과는 0부터**다.
생략한 셀은 빈 셀로 생성한다. 병합 칸에 별도 셀을 중복 지정하지 않는다.

- 표: `widthMm`, `columnWidthsMm`, `rowHeightsMm`, `repeatHeader`,
  `pageBreak`(`CELL/TABLE/NONE`), `alignment`, `caption`.
- 셀: `row`, `column`, `rowSpan`, `colSpan`, `text` 또는 `paragraphs`,
  `verticalAlignment`(`TOP/CENTER/BOTTOM`), `textStyle`, `paragraphStyle`, `style`.
- 셀의 `paragraphs`는 paragraph 블록 배열이며 각 문단에 runs를 쓸 수 있다.
- 표/셀 스타일: `borderType`, `borderWidthMm`, `borderColor`, `fillColor`, `cellPaddingMm`,
  `cellMargins:{leftMm,rightMm,topMm,bottomMm}`, `borders:{left,right,top,bottom}`.
  변별 테두리는 `{type,widthMm,color}`다.

V2 테두리 두께(mm)는 한컴 규격의 `0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5,
0.6, 0.7, 1, 1.5, 2, 3, 4, 5` 중 하나다. 쪽 테두리에는 셀 여백을 넣지 않는다.
번호 목록의 `character`, 글머리표의 `start`는 지원하지 않으며 사전 거부한다.

행 높이는 문서에 기록하는 초기/최소 기하 정보이며 내용에 따른 실제 행 높이와 페이지 분할을
고정한다고 주장하지 않는다. 좁은 셀의 긴 글은 렌더러 없이 잘림이 없다고 보증하지 않는다.

## 이미지와 기본 도형

이미지 블록은 `{type:"image",path:"로컬 절대 경로"}`다. 이미지 바이트는 BinData에
그대로 포함한다. PNG/JPEG/GIF/BMP는 실제 치수를 읽어 너비나 높이 중 생략한 값을 비율에
맞춘다. 둘 다 생략하면 너비 40mm를 기준으로 한다. TIFF 등 치수 판독이 없는 형식은 두
치수를 모두 지정한다. 이 작업은 한컴 보안 모듈을 사용하지 않는다.

- `widthMm/heightMm`, `rotation`(0~359 정수), `flipHorizontal/flipVertical`, `altText`, `caption`.
- `crop:{left,right,top,bottom}`는 각 변에서 제외할 비율(0 이상, 1 미만)이다. 남는 영역이
  0이 되면 거부한다. 원본 이미지 바이트는 자르거나 다시 인코딩하지 않는다.
- `placement`: `treatAsChar`, `horizontalAlignment`, `verticalAlignment`,
  `horizontalRelativeTo`, `verticalRelativeTo`, `horizontalOffsetMm`, `verticalOffsetMm`,
  `textWrap`(`SQUARE/TOP_AND_BOTTOM/BEHIND_TEXT/IN_FRONT_OF_TEXT`).

도형은 `type:"shape"`, `shape:"line"|"rectangle"|"ellipse"|"text-box"`와
`widthMm/heightMm`를 지정한다. `text`, `textStyle`, `paragraphStyle`, `style`, `placement`,
`rotation`, `altText`, `caption`을 쓸 수 있다. 복잡한 그룹·효과·차트·OLE를 이 기본 도형으로
임의 재구성하지 않는다.
기본 도형 `style`은 균일한 `borderType/borderWidthMm/borderColor/fillColor`만 지원한다.
표 전용 변별 테두리·셀 여백을 도형에 넣으면 거부한다.

## 머리말·번호·필드·참조

- `document.header/footer`: `{text,applyPageType:"BOTH"|"ODD"|"EVEN"}`.
- `document.pageNumber`: `{position:"BOTTOM_CENTER",formatType:"DIGIT",start:1,sideChar:""}`.
- `document.hideFirstHeader/hideFirstFooter/hideFirstPageNumber`: 첫 쪽 숨김 Boolean.
- `field`: `name/value/label?`. V2는 실제 편집 가능한 CLICK_HERE 필드를 만든다. V1의 기존
  필드 블록은 평문 호환 동작을 유지한다. V2에서 `memo/display`는 지원하지 않는다.
- `bookmark`: `name/text?`. `hyperlink`: `text/target`. HTTP(S) 또는 존재하는 `#책갈피`만
  허용한다. 링크는 만들기만 하며 방문하거나 실행하지 않는다.
- `footnote/endnote`: `text/number?`. 실제 컨트롤을 생성하지만 자동 번호 갱신은
  렌더러에서 확인해야 한다.
- `toc`: `entries:[{text,target:"#책갈피"}],title?`. AI가 제목을 책갈피와 연결하여
  링크 차례를 만든다. 인쇄 쪽 번호를 추정하지 않는다. 실제 쪽 번호 차례는 미지원이다.

## 기존 HWPX 부분 수정

탭·채움선, 머리말/꼬리말 삽입·교체, 각주/미주 설정은 [참조·탭 편집](reference-editing.md)을
따른다. 구역 정의가 겹치는 변경은 AI가 내부적으로 여러 번 저장·검사하고 최종 파일을 전달한다.

확장 편집의 정확한 입력은 [공식 모델 조회와 확장 편집](format-model.md)을 따른다.
`replace-paragraph-text`는 서식을 유지한 여러 run 리터럴 교체, `set-object-format`은
기본 그림/도형 편집, `set-section-settings`는 정규 구역의 시작 번호·격자·표시·쪽 번호다.
공식 속성 목록에 있다는 이유만으로 미지원 XML 기능을 임의 삽입하지 않는다.

`edit-hwpx`는 ZIP을 전체 문서 모델로 재생성하지 않는다. 지정한 노드만 바꾸고 미지의
XML 요소·속성과 변경하지 않은 파트의 비압축 바이트를 보존한다. 좌표는 모두 0부터다.
사용자가 지정한 변경과 원본 검사 결과로만 계획을 만든다.

```powershell
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" edit-hwpx -LiteralPath "원본.hwpx" `
  -PlanPath "부분수정.json" -OutputPath "별도 결과.hwpx"
```

쪽 방향처럼 구조를 바꾸는 작업은 대상·변경값에 대한 사용자 요청을 확인하고
`-ApproveAdvanced`를 함께 지정한다. 지원하지 않는 대상은 GUI로 우회하지 않는다.
검사 결과의 `paragraphs[].charShapeRuns[].address`를 복사한 텍스트 변경 예:

```json
{"version":"2.0","operations":[{"type":"replace-run-text","address":{"version":"1.0","sourceSha256":"<검사한 원본의 SHA-256>","part":"Contents/section0.xml","path":[1,0],"kind":"run"},"expectedText":"기존 문구","text":"새 문구"}]}
```

계획 최상위 `sourceSha256`에 검사한 원본 해시를 넣으면 오래된 원본을 잘못 수정하지 않는다.
모든 주소와 `expectedText/expectedTexts`는 수정 전 원본 기준이다.

주소는 해당 파일의 해시, XML 파트, 요소 자식 기준 경로와 종류를 함께 담는다.
`path`나 문단 번호를 추정하지 말고 검사 결과의 `address`를 그대로 사용한다.
일반 본문뿐 아니라 표 셀과 머리말·꼬리말 내부 문단/run에도 적용한다. 출력 파일을 다시
수정할 때는 재검사하여 새 해시가 들어간 주소를 받아야 한다. 주소와 옛 인덱스 선택자는
한 작업에 섞지 않는다. 옛 `paragraphIndex`는 구역 바로 아래 문단 순서이며 검사 결과의
전체 `paragraphs[].index`와 다르므로 새 계획에서는 사용하지 않는다.

| 작업 | 지정 속성 |
|---|---|
| `set-page` | `sectionIndex`, `orientation?`, 쌍인 `paperWidthMm/paperHeightMm?`, `margins?` |
| `set-columns` | `sectionIndex`, `count`(1~16), `gapMm`, 선택 `widthsMm`(모든 열) |
| `set-page-border` | `sectionIndex`, `applyTo:"BOTH"/"EVEN"/"ODD"`, `style`, 선택 `offsetMm:{left?,right?,top?,bottom?}` |
| `set-paragraph-content` | 문단 `address`, `expectedText`, 하나의 `paragraph:{text 또는 runs,textStyle?,paragraphStyle?}` |
| `set-paragraph-breaks` | 문단 `address`, `pageBreak?`, `columnBreak?`(Boolean) |
| `insert-paragraphs` | 기준 문단 `address`, `placement:"before"/"after"`, `paragraphs` 배열 |
| `delete-paragraph` | 텍스트 전용 문단 `address`, `expectedText` |
| `replace-run-text` | run의 `address`, `expectedText`, `text` |
| `set-run-style` | 문단/run 주소와 검사한 기존 `charPrIDRef` |
| `set-paragraph-style` | 문단 주소와 검사한 기존 `paraPrIDRef` |
| `set-run-format` | 문단/run 주소와 `textStyle` |
| `set-paragraph-format` | 문단 주소와 `paragraphStyle` |
| `merge-cells` | `sectionIndex/tableIndex/row/column`, `rowSpan/columnSpan`, `contentOrder:"row-major"`, `expectedTexts` |
| `split-cell` | `sectionIndex/tableIndex/row/column`, 병합 기준 셀의 `expectedText` |
| `set-table-cell` | 셀(`tc`)의 `address`, `expectedText`, `text` |
| `replace-image` | 그림(`pic`)의 `address`, 새 로컬 이미지 `path`, 원래 이미지 바이트의 `expectedSha256` |
| `insert-table-row` | 표(`tbl`)의 `address`, 0부터 시작하는 삽입 `index`, `heightMm` |
| `insert-table-column` | 표(`tbl`)의 `address`, 0부터 시작하는 삽입 `index`, `widthMm` |
| `set-cell-content` | 셀(`tc`)의 `address`, 기존 셀의 LF 구분 `expectedText`, paragraph 블록 배열 `paragraphs` |
| `set-cell-format` | 셀 주소와 `verticalAlignment?`, `textDirection?`, `lineWrap?`, `style?`, `textStyle?`, `paragraphStyle?` |
| `set-table-format` | 표 주소와 `columnWidthsMm?`, `rowHeightsMm?`, `alignment?`, `repeatHeader?` 또는 `headerRows?`, `pageBreak?`, 공통 셀 서식 |
| `delete-table-row`, `delete-table-column` | 표 주소, 삭제 `index`, 삭제 행/열의 순서대로 `expectedTexts` |
| `insert-cell-image` | 셀 주소, `expectedText`, `placement:"append"/"prepend"`, `path`, 선택 치수와 `altText` |
| `insert-cell-table` | 셀 주소, `expectedText`, `placement`, `table` 정의 |
| `calculate-table` | 표 주소, `calculations[{row,column,expectedText,expression,format?,textStyle?,paragraphStyle?}]` |
| `sort-table-rows` | 표 주소, `startRow/endRow/column`, `dataType:"TEXT"/"NUMBER"`, `direction:"ASC"/"DESC"` |
| `move-paragraph` | 문단 `address`, 같은 부모의 `targetAddress`, `placement:"before"/"after"`, 정확한 `expectedText` |
| `apply-named-style` | 문단 주소, 검사된 PARA `styleId`, 선택 원문 가드·복제 서식/이름 |
| `set-cell-diagonal` | 셀 주소, `direction:"SLASH"/"BACK_SLASH"/"CROSS"/"NONE"`, 보이는 선의 `line` |

새 표·셀 제어의 구체적인 요청 해석과 계획은 [표 통합 제어](tables.md)를 따른다.
문단 이동·명명 스타일의 정확한 적용/복제 경계는 [추가 부분 편집](remaining-editing.md)을 따른다.
표 전체 수정과 같은 표 내부 수정은 검사·수정 단계를 나누고 매번 출력에서 주소를 다시 얻는다.

`set-paragraph-content`는 텍스트 전용 문단의 부분 서식·탭·문단 내 줄바꿈을 구성한다.
책갈피·필드·그림·쪽 정의나 미지 메타데이터를 포함하면 전체 교체하지 않는다.
`set-paragraph-breaks`는 기존 텍스트/컨트롤을 유지하며 나누기 플래그만 수정한다.
`set-columns`의 명시 폭+간격은 본문 폭을 채워야 한다. 폭 생략은 균등 열이며 중간 단
전환/비정규 열 정의는 추측하지 않는다. `set-page-border`는 선택한 종류의 쪽 정의만
공유 리소스를 복제해 수정한다. 다단/쪽 테두리/나누기/정렬은 `-ApproveAdvanced`가 필요하다.
같은 구역의 용지 변경과 다단 설정은 새 본문 폭을 다시 검사하도록 별도 단계로 실행한다.

`insert-paragraphs`는 문단 앞/뒤에 새 문단을 넣고, 원래 쪽 정의·표·그림은 보존한다.
독립 빈 줄은 `text:""`와 `textStyle.fontSizePt`로 넣는다. 문단 스타일과 직접 텍스트 run의
글자 스타일을 상속하며, 직접 텍스트 run이 없는 기준 문단에서는 기존 charPr 0을 사용한다.
`delete-paragraph`는 정확한 원문을 확인한 텍스트 전용 문단만 삭제하며, 컨트롤·미지
메타데이터가 있거나 구역/텍스트 목록의 마지막 문단이면 차단한다. 삽입/삭제는 부모
구조를 보존 복제하므로 같은 부모 내부의 다른 수정은 재검사 후 별도 단계로 처리한다.
둘 다 `-ApproveAdvanced`가 필요하며 저장된 줄 좌표는 다시 계산하지 않고 무효화한다.

표 병합/해제도 `sectionIndex/tableIndex` 대신 표의 `address`를 받을 수 있다.
`set-table-cell`은 일반 문단/run 하나인 셀만 전체 교체한다. 서식이 섞인 셀은 내부 run
주소로 부분 수정한다. 병합된 직사각형 표와 주소로 고른 중첩 표도 행·열 추가/삭제를
지원한다. 삽입 경계를 가로지르는 병합은 확장하고, 삭제 경계의 병합은 축소하며 기준
셀의 내용은 남은 영역으로 보존한다. 새 빈 칸만 생성한다. 원래 행열 치수가 모호하면
`columnWidthsMm/rowHeightsMm` 배열로 원래 치수를 명시해야 한다. 표가 넓어지므로
요청 치수와 본문 폭을 확인하고 `-ApproveAdvanced`로 실행한다.
이미지는 공유되지 않은 PNG/JPEG/GIF/BMP 리소스만 동일 형식으로 교체하며 원래 배치·크기·
자르기 XML을 보존한다. 이미지 디코딩과 실제 조판 결과는 별도 미리보기로 확인한다.

format 작업은 기존 공유 서식을 새 ID로 복제해 대상만 바꾼다. 기존 서식의 다른 사용자는
변하지 않는다. `textStyle`은 글꼴명·크기·굵게·기울임·색·밑줄·취소선·윗첨자/아랫첨자·
자간·장평을 지원한다. 글꼴명은 언어별 리소스에 등록하며 글꼴 파일을 설치·포함하지 않는다.
`paragraphStyle`은 정렬·비율 또는 명시적 고정/최소 줄 간격·좌우/앞뒤 여백·들여쓰기·
keepWithNext/keepLines/widowOrphan/pageBreakBefore를 지원한다. 일반 작성의 기본 간격은
여전히 160%·문단 위아래 0이며, 추가 공간은 편집 가능한 빈 문단으로 처리한다.
기존 목록 정의 수정은 아직 지원하지 않는다. 탭 위치는 `set-paragraph-tabs`를 사용한다. 셀 내용을 새로 구성할
때의 탭 문자·문단 내 줄바꿈과 독립 빈 문단은 지원한다.

병합은 아직 병합되지 않은 직사각형 셀들의 문단을 행 우선 순서로 기준 셀에 모으며,
기준 셀의 셀 서식을 유지한다. `expectedTexts`는 그 순서의 문자열 배열이다. 셀 문단 사이의
구분자는 LF(`\n`)다. 분할은 기존 병합을 해제하며 문단은 기준 셀에 남기고 새 셀은 빈칸으로
만든다. 새로운 행/열 추가가 아니다. 이때 `-ApproveAdvanced`가 필요하다.

한 계획에서 같은 표의 구조 변경은 한 번만 허용한다. 최대 4,096칸의 완전한 표,
셀 간격 0을 지원한다. 셀 전체 삭제로 그림·필드·미지 개체가 소실될 수 있으면 차단한다.
행열 일부만 삭제되는 병합 셀은 포함 그림·중첩 표와 함께 보존한다. 보호 셀·알 수 없는
행 구조와 해결되지 않은 기하 정보는 차단한다. 텍스트 병합/해제는 여전히 알려진 텍스트
셀을 대상으로 한다.
텍스트/글자 서식 대상이 여러 텍스트 요소나 컨트롤을 가로지르면 차단한다.
검사 없이 문단/run 번호나 주소를 추정하지 않는다.

## 근사 미리보기와 최종 HWP 변환

[preview](preview.md)는 로컬 HTML과 선택적인 headless PDF를 생성한다. 표·이미지·문단
배치를 빠르게 점검하는 용도이며 한컴 실제 조판 검증이 아니다.

기본 배포에는 격리 HWP 변환기가 없다. HWP를 요청하면 검증한 HWPX를
`WorkingHwpxPath`에 보존하고 `BLOCKED`로 끝낸다. 라이브러리의 `FinalConverter`/
`WorkerLauncher`는 관리자가 격리 환경을 명시적으로 통합하는 경계이며 JSON 계획이나
기본 CLI에서 임의 명령을 실행하도록 노출하지 않는다. 통합 시 실제 HWP를 재판독하여
본문, 표의 셀/병합, 포함 이미지 바이트를 비교한다. 현재는 그림별 바이너리 참조 대응을
검증하지 못하므로 이미지가 있는 HWP의 변환 승격은 차단한다. HWPX의 이미지 작성·교체는
그대로 지원한다. 이 검사도 실제 글꼴·페이지 조판의 동일성을 보장하지 않는다.
현재 사용자 세션의 COM 창을 숨기는 방법으로 대체하지 않는다.

## 검증 수준

생성 파일을 다시 열어 문구·표·그림과 작성 계약을 검사하고, 원본 편집은 원본 해시와 변경
대상 밖의 보존을 검사한다. 실패 파일은 최종 결과로 승격하지 않는다.

V2 작성기는 계산하지 않은 `linesegarray`를 저장하지 않는다. 글꼴 이름을 쓰는 것과 글꼴의
실제 설치/포함은 별개다. `PASS_WITH_WARNINGS`는 구조 검사를 통과했다는 뜻이지, 실제 줄바꿈,
페이지 수, 인쇄 결과, 글꼴 대체, 복잡한 개체의 픽셀 렌더링이 검증되었다는 뜻이 아니다.
계산하지 않은 템플릿 미리보기 이미지도 새 문서에 복사하지 않는다.
생성 응답의 `StructuralVerification`은 독립 검사 수와 결과를 제공한다.
`capabilities`의 `data.authoring`은 기능표와 같은 지원 경계를 기계 판독용으로 제공한다.

형식 근거: [한컴 공식 HWPX 모델](https://github.com/hancom-io/hwpx-owpml-model),
[용지 방향에 관한 한컴 설명](https://forum.developer.hancom.com/t/pagepr-width-height/1693).
