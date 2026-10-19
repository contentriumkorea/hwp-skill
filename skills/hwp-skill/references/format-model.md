# 공식 HWPX 모델 조회와 확장 편집

한컴 없이 설치된 스킬만으로 저장 형식의 근거를 조회한다. 인터넷·한컴 설치·보안 모듈이
필요 없다. Python은 개발용 목록 재생성에만 필요하며 스킬 사용에는 필요 없다.

```powershell
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" format-model
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" format-model -ModelClass CSectionDefinitionType
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" format-model -ElementName secPr
& "<스킬 경로>/scripts/Invoke-HwpSkill.ps1" format-model -ModelEnum g_ParaLineWrapList
```

선택 인수는 한 번에 하나만 쓴다. 기본 조회는 목록/통계, 클래스·요소 조회는 직접
읽기/쓰기 속성과 하위 요소 등록·참조 열거값, 열거값 조회는 정확한 문자열을 반환한다.
요소 별칭은 관찰된 등록 이름이며 문서 전체에서 유일한 XPath를 뜻하지 않는다.

근거는 [한컴 공식 공개 모델](https://github.com/hancom-io/hwpx-owpml-model/tree/1453388472c703a4b299a0834f425cdac16644b9)의
고정 커밋 `1453388472c703a4b299a0834f425cdac16644b9`다. `OWPML/Class/**/*.cpp`
288개 전체와 `enumdef.h`에서 클래스 316개, 직접 저장 속성 항목 723개, 하위 요소 등록
663개, 열거값 목록 103개를 추출했다. 중복되는 속성명/등록이 포함되므로 기능 개수가
아니다. JSON의 파일별 Git blob·SHA-256으로 원문 출처를 추적한다. 원 프로젝트는
Apache-2.0이며, 이 목록은 사실/식별자 추출물로 한컴 설치본의 바이너리나 원문 코드를
포함하지 않는다.

추출기는 `WriteElement`, `WriteAttribute`, `SetAttribute`, `ReadAttribute`, `InitMap`의
리터럴 호출만 분석한다. 속성 전용 helper의 14개 항목도 포함해 빠뜨리지 않는다.
상속 호출·조건·기본값·소유권·연동·자동 갱신·렌더링 의미는 해결하지 않는다. 비리터럴/
상속 속성 호출 5개도 `unresolvedAttributeCalls`에 남겨 누락을 숨기지 않는다.
**이 목록은 완전한 XSD 검사기나 임의 XML 수정 API가 아니다.** 실제 기능 지원은
`capabilities`와 [지원표](feature-support.md)를 따른다.

## 기존 문서의 확장 편집

공통 계획은 `version:"2.0"`, `operations:[...]`다. 주소는 `inspect`의 해당 문단 또는
개체 `address`를 그대로 쓴다. 원본 해시·정확한 원문을 대조하며 새 파일에만 저장한다.
아래 `address` 자리에는 실제 검사 주소 객체를 넣는다. 내부 계획은 AI가 구성한다.

### 서식을 유지한 문장 범위 교체

```json
{"type":"replace-paragraph-text","address":{},"expectedText":"문단 전체 원문",
 "find":"바꿀 문자열","replacement":"교체 문자열","replaceAll":false}
```

리터럴·대소문자 구분·비중첩 일치다. 여러 run에 걸친 일치를 허용하며 교체 부분은
첫 일치 run의 서식을 이어받는다. 나머지 run/탭/줄바꿈/문단 플래그를 보존한다.
LF는 줄바꿈, 탭 문자는 탭이다. 정규식, 문단 사이 검색, 필드/제어 경계를 넘는 교체는
하지 않는다. 최대 문단 문자열 1 Mi UTF-16, 4,096 run, 10,000 일치이며 누적 예산도 검사한다.

### 기본 개체 편집

```json
{"type":"set-object-format","address":{},"altText":"그림 설명",
 "placement":{"horizontalAlignment":"CENTER","horizontalOffsetMm":0},
 "rotation":90,"flipHorizontal":false,"widthMm":50.8,
 "crop":{"left":0.1,"right":0.1}}
```

대상은 `pic/rect/ellipse/line`이며 `inspect`의 `controls[].address`를 쓴다.
`crop`은 그림에만 쓰고 각 변에서 제외할 0 이상 1 미만 비율이다. 생략 속성은 보존한다.
`placement`는 `treatAsChar`, `horizontalAlignment`, `verticalAlignment`,
`horizontalRelativeTo`, `verticalRelativeTo`, 두 OffsetMm, `textWrap`을 받는다.
최상위 `textWrap`, `flipVertical`, `heightMm`도 가능하다. wrap은 `SQUARE`,
`TOP_AND_BOTTOM`, `BEHIND_TEXT`, `IN_FRONT_OF_TEXT`다. rotation은 0~359 정수다.

크기/변환은 생성기의 기본 좌표계로 입증된 도형에 한정한다. 그룹·특수 행렬·상대 크기·
그림 효과·뒤집힌 원본의 크기 변경·텍스트 상자 크기 변경을 추측하지 않는다. ID·본문·
BinData는 유지한다. 개체 배치·변환은 `-ApproveAdvanced`로 실행한다.

### 구역 설정과 쪽 번호

```json
{"type":"set-section-settings","sectionIndex":0,"settings":{
 "startNumbers":{"pageStartsOn":"BOTH","page":3},
 "visibility":{"hideFirstPageNum":true,"hideFirstHeader":false},
 "grid":{"lineGrid":0,"charGrid":0,"wonggojiFormat":false},
 "textDirection":"HORIZONTAL",
 "pageNumber":{"position":"BOTTOM_CENTER","format":"DIGIT","sideChar":"-"}}}
```

정규 구역 정의 한 개만 수정한다. 페이지 설정·다른 컨트롤·본문을 보존한다.
쪽 번호가 없으면 해당 구역 정의 run에 추가하고, 다른 위치/여러 정의면 차단한다.
startNumbers는 `page/pic/tbl/equation`의 uint32와 pageStartsOn `BOTH/EVEN/ODD`다.
visibility는 첫 header/footer/masterPage/pageNum/emptyLine 숨김 Boolean과
`showLineNumber`, `border/fill`의 `HIDE_FIRST/SHOW_FIRST/SHOW_ALL`이다.
textDirection은 `HORIZONTAL/VERTICAL/VERTICALALL`이다. pageNumber의 위치/번호
형식 허용 목록은 helper의 검증된 부분집합이며 공식 전체 열거값보다 좁다.
줄 번호 표시 플래그·격자 저장은 세부 줄 번호 구성·원고지 완성·실제 조판 검증이 아니다.
이 작업도 `-ApproveAdvanced`가 필요하다. 쪽/구역 정의와 그 내부를 같은 계획에서
겹쳐 수정하지 않고 저장·재검사 후 다음 작업을 진행한다.

모든 경로는 계산된 것처럼 보이는 줄 좌표를 만들지 않고 캐시를 제거한다. 실제 페이지 수,
글꼴 대체, 픽셀 배치는 한컴과 동등하다고 보증하지 않는다.
