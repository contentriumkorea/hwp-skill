# 기존 HWPX의 탭·머리말·꼬리말·각주·미주 편집

세 명령은 같은 스킬의 `edit-hwpx`에서 실행한다. 한컴/COM/보안 모듈 없이 원본을 보존하고
새 HWPX에 저장한다. 인수 이름은 대소문자까지 정확히 쓴다. 내부 JSON은 AI가 만들며
사용자에게 별도 스킬 호출이나 계획 작성 작업을 넘기지 않는다.

## 실행과 검증

1. `inspect`로 원본 해시·구역·문단/컨트롤 주소·현재 값을 확인한다. CLI `inspect` 결과는
   최상위 `paragraphs/resources/sections/controls`에 있으며 `.data` 아래가 아니다.
2. `version:"2.0"`과 `operations`로 계획을 구성한다. 일반 문단 탭은 `address`, 구역
   제어는 0부터 시작하는 `sectionIndex`를 쓴다. 원본은 덮어쓰지 않는다.
3. 머리말·꼬리말·각주 설정은 명시된 사용자 요청 범위에서 `-ApproveAdvanced`로 실행한다.
   구역 정의를 통째로 복제하는 작업끼리 같은 계획에서 겹치면, AI가 내부적으로 저장→
   재검사→다음 편집을 진행한다. 사용자가 같은 내용을 재승인하도록 요구하지 않는다.
4. 출력에서 아래 읽기 필드와 저장 속성·기존 본문·그림/각주 보존을 확인한다. 중간 파일은
   내부 작업용이며 최종 결과만 전달한다. 파일이나 미리보기를 자동으로 열지 않는다.

## 문단 탭과 채움선

```json
{"type":"set-paragraph-tabs","address":{},"tabs":[
 {"positionMm":25.4,"alignment":"LEFT","leader":"DOT"},
 {"positionMm":50.8,"alignment":"DECIMAL","leader":"NONE"}],
 "autoTabLeft":false,"autoTabRight":false}
```

`address`는 선택 문단의 검사 주소로 대체한다. `tabs`는 0~64개이며 빈 배열은 명시 탭을
비운다. 위치는 0~2000mm이고 HWPUNIT 반올림 후에도 증가 순서여야 한다. 중복/역순은
추측 정렬하지 않는다. alignment는 `LEFT/RIGHT/CENTER/DECIMAL/VERTBAR`, 기본 LEFT다.
leader 기본 NONE, 지원값은 `NONE/SOLID/DOT/DASH/DASH_DOT/DASH_DOT_DOT/LONG_DASH/CIRCLE/
DOUBLE_SLIM/SLIM_THICK/THICK_SLIM/SLIM_THICK_SLIM/WAVE/DOUBLEWAVE/THICK3D/THICKREV3D/3D/REV3D`다.
두 자동 탭 Boolean은 생략하면 기존값을 보존한다.

공유 문단과 탭 서식은 복제한다. 다른 문단에 적용되던 정의를 직접 바꾸지 않는다.
문자열의 탭 자체는 유지하므로 새 탭 문자가 필요하면 문단 내용 편집의 `\t`를 함께
사용한다. 같은 문단의 내용/서식 교체와 충돌하면 검사·편집 단계를 나눈다.

읽기: `paragraphs[].paraShapeId`→`resources.paraShapes[].id/tabDefinitionId`→
`resources.tabProperties[].id`로 연결한다. 탭 자원의 `autoTabLeft/autoTabRight`,
`stops[].positionRaw/unit/positionMm/alignment/leader`를 확인한다. CHAR 단위 또는 단위가
생략된 기존 탭은 mm로 추측하지 않아 `positionMm`이 null이며 원시 값은 보존한다.

## 머리말·꼬리말 삽입 또는 교체

```json
{"type":"set-header-footer","sectionIndex":0,"kind":"header","applyTo":"BOTH",
 "expectedText":"","paragraphs":[
  {"runs":[{"text":"콘텐츠리움","textStyle":{"bold":true}}],
   "paragraphStyle":{"alignment":"RIGHT"}}]}
```

kind는 `header/footer`, applyTo는 `BOTH/EVEN/ODD`다. 정의가 없으면 expectedText는
정확히 빈 문자열이어야 한다. 기존 정의는 그 안의 문단 텍스트를 순서대로 LF로 이어
expectedText에 넣는다. 탭·줄바꿈도 원문 그대로 확인한다. 내용은 일반 문단/여러 run,
탭/줄바꿈과 글자/문단 서식을 지원한다. 빈 머리말은 `paragraphs:[{"text":""}]`로 만든다.

`controls[]`에서 header/footer 컨트롤의 `address`를 확인하고, 같은 part와 그 주소의
path 아래에 있는 `paragraphs[]`를 검사 순서대로 모아 원문을 구한다. 다른 구역/본문의
같은 문구를 섞지 않는다. 정의/리스트의 ID·크기·다른 컨트롤은 유지한다.

정규 구역 정의 run 밖의 머리말, 중복 정책, 같은 종류에 BOTH와 EVEN/ODD가 섞인 경우는
차단한다. 홀수/짝수 정의를 각각 만들 수 있지만 기존 BOTH 정의를 자동 삭제/전환하지
않는다. 원본 머리말의 표·그림·필드·미지 메타데이터를 텍스트로 재작성하지 않는다.
첫 쪽 숨김은 별도 `set-section-settings.visibility.hideFirstHeader/hideFirstFooter`로
사용자 요청에 맞춰 설정하며, 머리말을 넣는다는 이유로 기존 표시 정책을 자동 변경하지 않는다.

## 각주·미주 구역 설정

```json
{"type":"set-note-settings","sectionIndex":0,"kind":"footnote","settings":{
 "numbering":{"type":"ON_PAGE","newNum":1},
 "placement":{"place":"EACH_COLUMN","beneathText":false},
 "noteSpacing":{"betweenNotesMm":2.54,"belowLineMm":1.27,"aboveLineMm":2.54},
 "autoNumFormat":{"type":"DIGIT","prefixChar":"","suffixChar":")","supscript":true},
 "noteLine":{"type":"SOLID","widthMm":0.12,"color":"#000000","lengthMm":25.4}}}
```

생략한 설정은 보존한다. 필요한 하위 그룹만 넣으며 빈 그룹은 쓰지 않는다.

- kind: `footnote/endnote`. 각주는 `CONTINUOUS/ON_SECTION/ON_PAGE`, 미주는
  `CONTINUOUS/ON_SECTION`으로 다시 시작한다. newNum은 1~uint32 최댓값의 정수다.
- 각주 배치는 `EACH_COLUMN/MERGED_COLUMN/RIGHT_MOST_COLUMN`, 미주는
  `END_OF_DOCUMENT/END_OF_SECTION`이다. beneathText Boolean은 각주에서만 쓴다.
- 간격과 고정 구분선 길이는 0~2000mm다. 전체 폭 sentinel은 의미가 입증되지 않아
  새로 지정하지 않으며 기존 길이는 생략 시 그대로 둔다.
- 번호는 DIGIT·원문자 숫자·로마자·라틴·한글·한자 등의 검증된 형식을 쓴다.
  IMAGE/USER_CHAR/SYMBOL처럼 추가 데이터 의미가 미검증인 형식은 지정하지 않는다.
  접두/접미사는 각각 최대 256 UTF-16 글자, supscript는 Boolean이다.
- 구분선 유형은 위 leader 목록과 같고, 폭은
  `0.1/0.12/0.15/0.2/0.25/0.3/0.4/0.5/0.6/0.7/1/1.5/2/3/4/5`mm,
  색은 `#RRGGBB`다.

읽기: `sections[].noteDefinitions[]`의 kind와 properties에서 번호·간격·배치·구분선의
저장 속성을 확인한다. 이 명령은 각주/미주 본문·개체·기존 번호 필드·참조를 삭제하거나
임의로 다시 쓰지 않는다. 저장 규칙 변경과 조판된 실제 번호/참조 갱신을 구분한다.

세 경로 모두 영향 구역의 저장된 줄 배치 캐시를 무효화한다. 구조·원문·포함 자산 검증이
실제 페이지 수·줄바꿈·인쇄 결과와 같다는 뜻은 아니다. 복잡하거나 보호된 원본을
GUI로 우회하지 않는다.
