# 편집 작업 규격

이 문서는 `edit-plan.schema.json`으로 검증하는 편집 계획의 작업별 필드를 설명한다.
계획을 직접 작성하기 전에 반드시 `inspect` 결과에서 실제 기준 문구, 원본 경로,
SHA-256을 가져온다.

## 공통 구조

```json
{
  "version": "1.0",
  "source": {
    "path": "C:\\문서\\원본.hwp",
    "sha256": "64자리 SHA-256"
  },
  "approvedAdvanced": false,
  "operations": [
    {
      "id": "고유한 작업 ID",
      "type": "replace-text",
      "risk": "safe",
      "target": {
        "anchor": "정확한 기준 문구",
        "beforeContext": "앞 문맥",
        "afterContext": "뒤 문맥"
      },
      "expectedMatches": 1,
      "before": "기존 값",
      "after": "새 값",
      "onFailure": "stop",
      "verify": {
        "kind": "text-contains",
        "expected": "새 값"
      }
    }
  ]
}
```

공통 조건은 다음과 같다.

- `source.path`와 `source.sha256`은 검사한 원본과 정확히 일치해야 한다.
- `id`는 계획 안에서 중복되지 않아야 한다.
- `safe` 작업의 `expectedMatches`는 반드시 `1`이다.
- `onFailure`는 `stop` 또는 `skip`이다. 구조에 영향을 주는 작업은 `stop`을 권장한다.
- `target.anchor`는 빈 문자열일 수 없다. 구조 인덱스로 찾는 작업도 사람이 이해할 수
  있는 식별 문구를 넣는다.
- `before`가 있는 작업은 현재 값이 다르면 적용하지 않는다.
- `verify`는 실행 후 확인할 값을 기록한다. 구현이 작업 자체의 사후검증도 추가로 한다.

## 안전 작업

### `replace-text`

- 용도: 정확한 문구 하나를 바꾼다.
- 핵심 필드: `target.anchor`, 선택형 문맥, `before`, `after`.
- 조건: 기준 문구와 `before`가 일치해야 한다.

### `insert-before`, `insert-after`

- 용도: 기준 문구의 바로 앞 또는 뒤에 `after` 문자열을 넣는다.
- 핵심 필드: `target.anchor`, 선택형 문맥, `after`.
- 줄바꿈도 `after` 안에 명시적으로 포함한다.

### `set-field`

- 용도: 이름이 지정된 필드·누름틀 값을 바꾼다.
- 추가 대상 필드: `target.fieldName`.
- 값: `before`는 예상 기존 값, `after`는 새 값.
- 같은 이름의 필드가 여러 개면 자동으로 하나를 추측하지 않는다.

### `set-table-cell`

- 용도: 기존 표의 특정 셀 내용을 바꾼다.
- 추가 대상 필드: `target.tableIndex`, `target.row`, `target.column`.
- 인덱스는 모두 1부터 시작한다.
- 값: `before`는 예상 기존 셀 값, `after`는 새 셀 값.

### `insert-table`

- 용도: 기준 문구 앞이나 뒤에 빈 표를 넣는다.
- 추가 대상 필드: `target.rows`, `target.columns`, `target.placement`.
- `placement`: `before` 또는 `after`.
- 행과 열은 각각 1~100이다. 셀 입력은 후속 `set-table-cell` 작업으로 한다.

### `insert-image`

- 용도: 기준 문구 앞이나 뒤에 로컬 이미지를 넣는다.
- 추가 대상 필드: `target.imagePath`, 선택형 `widthMm`, `heightMm`, `placement`.
- PNG, JPEG, GIF, BMP의 실제 시그니처를 확인한다.
- 새 HWPX 문서에서는 이미지를 ZIP 패키지의 `BinData`에 직접 삽입하므로 한컴 파일
  경로 보안 모듈이 필요하지 않다. HWP/HWT 원본을 네이티브로 수정하는 별도 경로는
  현재 자동 작업 범위에 포함하지 않는다.

### `replace-image`

- 용도: 기존 그림 컨트롤을 새 로컬 이미지로 교체한다.
- 추가 대상 필드: `target.controlIndex`, `target.imagePath`, 선택형 `widthMm`,
  `heightMm`.
- `controlIndex`는 검사 결과의 그림 컨트롤 순서를 기준으로 1부터 시작한다.
- 원본 그림과 새 그림의 완전한 레이아웃 동일성은 페이지 이미지로 확인해야 한다.

### `apply-char-style`

- 용도: 정확히 선택된 문구의 글자 서식을 바꾼다.
- 추가 대상 필드: 하나 이상의 `target.heightPt`, `target.bold`, `target.italic`.
- 현재 공개 버전은 글꼴명, 글자색, 자간을 직접 변경하지 않는다.

### `apply-para-style`

- 용도: 기준 문구가 속한 문단의 정렬을 바꾼다.
- 추가 대상 필드: `target.align`.
- 값: `left`, `center`, `right`, `justify` 중 하나.

### `insert-page-break`

- 용도: 기준 문구 앞이나 뒤에 쪽 나누기를 넣는다.
- 추가 대상 필드: 선택형 `target.placement` (`before` 또는 `after`).

### `set-header-footer`

- 용도: 해당 구역에 새 머리말 또는 꼬리말을 만든다.
- 추가 대상 필드: `target.kind`, `target.text`, 선택형 `target.pages`.
- `kind`: `header` 또는 `footer`.
- `pages`: `both`, `even`, `odd` 중 하나이며 기본값은 `both`다.
- 기존 머리말·꼬리말이 있으면 중복 생성을 피하기 위해 `BLOCKED`로 멈춘다.

### `set-page-number`

- 용도: 새 쪽 번호 컨트롤을 만든다.
- 추가 대상 필드: 선택형 `target.position`, `target.startNumber`.
- 위치: `top-left`, `top-center`, `top-right`, `bottom-left`, `bottom-center`,
  `bottom-right`.
- 기존 쪽 번호가 있으면 중복 생성을 피하기 위해 멈춘다.

### `add-bookmark`

- 용도: 정확히 선택된 문구에 책갈피를 추가한다.
- 추가 대상 필드: `target.name`.
- 이름은 세미콜론과 줄바꿈 없이 1~120자다.

### `add-hyperlink`

- 용도: 정확히 선택된 표시 문구에 링크를 추가한다.
- 추가 대상 필드: `target.url`.
- `http`와 `https` 절대 URL만 허용한다. 사용자명·비밀번호가 포함된 URL은 거부한다.
- 대화상자를 여는 `Hyperlink` 작업 대신 직접 삽입 방식만 사용한다.

### `add-caption`

- 용도: 표 또는 그림에 캡션을 붙인다.
- 추가 대상 필드: `target.controlId`, `target.controlIndex`, `target.text`.
- `controlId`: 표는 `tbl`, 그림은 `gso`.
- `controlIndex`는 해당 종류의 컨트롤 순서를 기준으로 1부터 시작한다.

### `add-footnote`, `add-endnote`

- 용도: 기준 문구 앞이나 뒤에 각주 또는 미주를 추가한다.
- 추가 대상 필드: `target.text`, 선택형 `target.placement`.
- `placement`: `before` 또는 `after`, 기본값은 `after`다.

### `build-toc`

- 용도: 실제 인쇄 쪽 번호를 읽어 안전한 텍스트 차례를 만든다.
- 추가 대상 필드: `target.headingAnchors`, 선택형 `target.title`,
  `target.placement`, `target.pageBreakBefore`.
- `target.anchor`는 차례 삽입 위치다.
- 쪽 번호가 바뀌지 않도록 삽입 위치는 모든 제목 기준 문구 뒤에 있어야 한다.
- 일부 한컴 2024 빌드에서 네이티브 `MakeContents`가 비정상 종료되어, 현재는 제목과
  실제 인쇄 쪽 번호를 조합한 수동 차례를 만든다. 자동 갱신 필드는 아니다.

## 고급 작업

아래 작업은 `risk`를 `advanced`로 쓰고, 사용자의 명시적 승인 후에만 최상위
`approvedAdvanced`를 `true`로 바꾼다. 이 기록만으로 실행 권한이 생기지는 않으며,
`apply`, 양식 `generate`, 실제 `batch` 명령에도 `-ApproveAdvanced`를 별도로 전달해야
한다.

### `delete-range`

- 용도: 정확히 식별한 문자열 범위를 삭제한다.
- `before`에 삭제될 전체 값을 기록한다.
- 삭제 범위와 주변 문맥을 사용자에게 먼저 보여 준다.

### `add-table-row`

- 용도: 기존 표에 빈 행을 하나 추가한다.
- 추가 대상 필드: `target.tableIndex`, `target.afterRow`.
- 두 값은 1부터 시작한다. 새 행 값은 별도 `set-table-cell` 작업으로 채운다.

### `set-section`

- 용도: 기준 문구가 속한 구역의 용지와 여백을 바꾼다.
- 필수 대상 필드: `target.orientation` (`portrait` 또는 `landscape`).
- 선택형: `target.paperSize`는 현재 `A4`만 허용한다.
- 선택형 여백: `leftMarginMm`, `rightMarginMm`, `topMarginMm`,
  `bottomMarginMm`은 0~100mm다.
- 현재 버전은 단 수, 제본 여백, 머리말·꼬리말 여백을 변경하지 않는다.

### `merge-documents`

- 용도: 현재 결과 문서 끝에 HWP/HWT 문서를 순서대로 병합한다.
- 추가 대상 필드: `target.paths`, 선택형 `target.pageBreakBetween`.
- 입력은 1~50개이며 실제 형식이 HWP 바이너리여야 한다.
- 각 병합 입력도 메모리로 읽고 SHA-256이 바뀌지 않았는지 확인한다.

## 독립 명령

`export`는 편집 계획 작업이 아니라 공용 실행 파일의 독립 명령으로 사용한다.

```powershell
& ./scripts/Invoke-HwpSkill.ps1 export -LiteralPath "C:\문서\결과.hwp" `
  -ExportKind pdf -OutputPath "C:\문서\결과.pdf"
```

PDF 또는 쪽 이미지 내보내기에는 등록된 보안 모듈이 필요하다. 보안 모듈이 없으면
대화상자를 우회하거나 자동 클릭하지 않고 `BLOCKED`로 끝낸다.

## 새 문서 계획

빈 문서 생성 계획은 편집 계획과 구조가 다르다. `generate-plan.schema.json`과
`examples/generate-new.plan.json`을 사용한다.

- `paragraph`: `text`
- `table`: `rows`, `columns`, `cells[{row,column,text}]`
- `field`: `name`, `value`, 선택형 `label`, `memo`, `display`
- `image`: `path`, 선택형 `widthMm`, `heightMm`
- `page-break`: 추가 필드 없음

새 문서는 HWPX 작업본으로 직접 저장한다. 출력 확장자가 HWP이면 HWPX 전체 검증이
끝난 뒤 마지막 단계에서만 숨김 변환한다. 이미지 블록도 경로 기반 한컴 파일 열기
없이 HWPX `BinData`에 직접 저장한다.
