# 제3자 자료 고지

이 스킬의 Contentrium 작성 코드와 문서는 동봉된 [MIT 라이선스](LICENSE)를 따른다.
아래 공개 자료의 라이선스와 출처는 별도로 유지한다.

## HwpForge 입력 변환 엔진

- 저작권: Copyright (c) 2026 AiScream Team.
- 프로젝트: https://github.com/ai-screams/HwpForge
- 고정 버전: 0.16.11, 소스 커밋 `65889e8d835d229b38e2922a7fc35081fdcee49c`.
- PyPI의 정식 CPython abi3 wheel 5종을 원형 그대로 `vendor/hwpforge`에 포함한다.
  파일별 원본 SHA-256과 플랫폼은 같은 폴더의 `manifest.json`에 기록했다.
- 원본 라이선스 MIT OR Apache-2.0 중 MIT를 선택해 재배포한다.
  [licenses/HwpForge-MIT.txt](licenses/HwpForge-MIT.txt)에 원문을 포함했다.
- Contentrium이 작성한 실행 래퍼·독립 원본 대조·출력 승격 정책은 엔진과 구분한다.
  원 제작사 또는 한컴의 공식 제휴·완전 호환 보증을 의미하지 않는다.

## Hancom HWPX/OWPML 공개 모델

- 프로젝트: Hancom, Inc. 및 hwpx-owpml-model 기여자
- 원본: https://github.com/hancom-io/hwpx-owpml-model
- 고정 커밋: `1453388472c703a4b299a0834f425cdac16644b9`
- 라이선스: Apache License 2.0. 원본 `LICENSE.txt`의 사본은
  [licenses/Apache-2.0.txt](licenses/Apache-2.0.txt)에 포함한다.
- 원본의 저작권 고지 `NOTICE.txt`도
  [licenses/Hancom-NOTICE.txt](licenses/Hancom-NOTICE.txt)에 그대로 포함한다.
- 이 배포의 `references/hwpx-model-catalog.json`은 Contentrium이 원본의 클래스·속성·
  하위 요소·열거값 식별자와 출처 해시를 추출·재구성한 목록이다. 원본 소스 본문이나
  한컴오피스 설치 바이너리/리소스를 포함하지 않는다. 변경된 목록의 추출 범위와 한계는
  `references/format-model.md` 및 목록의 `scope/limitations`에 설명한다.

공식 제휴·보증 또는 한컴 전체 기능/조판 호환성을 의미하지 않는다.
