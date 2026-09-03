# HWP Skill 범용 AI 도구 배포 설계

## 목표

`hwp-skill`의 실행 기능은 그대로 유지하면서, 하나의 표준 스킬 원본을 Claude Code,
Codex 및 Agent Skills 호환 AI 도구에 설치할 수 있게 한다. 사용자는 특정 도구의 내부
폴더 구조를 몰라도 GitHub 저장소에서 설치할 수 있어야 하며, 기존 Codex 설치 명령은
계속 동작해야 한다.

## 현재 실패와 원인

- 현재 스킬 원본은 `skill/hwp-skill`에 있고 설치기는 Codex의 사용자 스킬 경로만
  계산한다.
- 저장소 루트에 Claude Code용 `.claude-plugin/plugin.json`과
  `.claude-plugin/marketplace.json`이 없다.
- Claude Code 2.1.197에서 `claude plugin validate .`를 실행하면
  `No manifest found in directory`로 실패한다.
- `SKILL.md`의 설명과 본문 일부가 Codex만 실행 주체로 지칭하여 다른 에이전트의 자동
  발견 문구로 적합하지 않다.

## 지원 범위

### 직접 지원

1. Agent Skills 공개 규격을 따르는 모든 도구
2. `npx skills`가 지원하는 AI 에이전트 전체
3. Claude Code 및 Claude Code Desktop의 플러그인 마켓플레이스
4. Codex, Claude Code와 공용 `.agents/skills` 경로를 위한 Windows PowerShell 설치
5. 원하는 스킬 루트를 직접 지정하는 사용자 정의 설치

### 지원의 의미

- 스킬 설치 기능을 제공하는 도구에는 스킬 전체 폴더가 배치되어 자동 또는 명시적으로
  호출될 수 있다.
- 외부 스킬 설치 기능 자체가 없는 일반 웹 채팅에는 설치 가능하다고 주장하지 않는다.
- 문서 엔진의 플랫폼 요구사항은 설치 호환성과 구분한다. 현재 HWP/HWT 휴대형 읽기와
  HWPX 생성의 공식 지원 환경은 Windows와 PowerShell이다.

## 배포 구조

스킬 원본은 하나만 둔다.

```text
hwp-skill/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json
├── skills/
│   └── hwp-skill/
│       ├── SKILL.md
│       ├── agents/openai.yaml
│       ├── scripts/
│       ├── references/
│       ├── schemas/
│       └── examples/
├── install.ps1
├── package.ps1
└── README.md
```

기존 `skill/hwp-skill`은 `skills/hwp-skill`로 이동한다. 복제본이나 심볼릭 링크를 두지
않아 제품별 복사본이 서로 달라지는 문제를 막는다. `agents/openai.yaml`은 Codex 전용
확장 메타데이터로서 표준 스킬 폴더 안에 그대로 유지하며, 다른 도구는 이를 무시할 수
있다.

## 설치 경로

### 범용 설치

주 설치 명령은 다음과 같다.

```powershell
npx skills@latest add contentriumkorea/hwp-skill --skill hwp-skill --global --agent '*' --copy --yes
```

`npx skills`가 각 도구의 현재 설치 경로를 관리하므로 저장소가 제품 경로 수십 개를
중복 관리하지 않는다. `--copy`를 사용하여 Windows의 심볼릭 링크 권한과 재분석 지점
문제를 피한다.

### Claude Code 플러그인

```text
claude plugin marketplace add https://github.com/contentriumkorea/hwp-skill.git
claude plugin install hwp-skill@contentrium
```

마켓플레이스 이름은 `contentrium`, 플러그인 이름과 스킬 이름은 `hwp-skill`, 표시
이름은 `HWP Skill`로 고정한다. 명시적 플러그인 버전은 두지 않고 Git 커밋 SHA를
업데이트 식별자로 사용한다. 플러그인 소스는 같은 Git 저장소의 루트를 가리키는 `./`로
지정해, 마켓플레이스를 받은 뒤 별도의 SSH 복제를 시도하지 않도록 한다.

### PowerShell 설치기

`install.ps1`은 다음 인터페이스를 제공한다.

```powershell
.\install.ps1 [-Target Codex|Claude|Universal|All] [-ProfileRoot PATH]
               [-DestinationRoot PATH] [-Update]
```

- 기본 `Target`은 기존과 같은 `Codex`다.
- `Codex`: `CODEX_HOME\skills` 또는 `<profile>\.codex\skills`
- `Claude`: `CLAUDE_CONFIG_DIR\skills` 또는 `<profile>\.claude\skills`
- `Universal`: `<profile>\.agents\skills`
- `All`: 위 세 경로에서 중복을 제거하여 모두 설치
- `DestinationRoot`: 자동 경로 계산을 대체하는 단일 사용자 지정 스킬 루트
- `ProfileRoot`: 시험과 이동식 환경을 위한 사용자 프로필 대체 경로

단일 대상의 반환 계약은 기존 `Status`, `InstallPath`, `BackupPath` 등을 유지한다.
`All`은 동일 계약에 `Results` 배열을 추가하며, 하나라도 실패하면 전체 상태를
`FAILED` 또는 `BLOCKED`로 올린다. 기존 설치는 `-Update` 없이 덮어쓰지 않고, 대상별
백업·검증·복원 정책을 그대로 적용한다.

## 독립 패키지

`package.ps1`은 `skills/hwp-skill`만 포함하는 `hwp-skill.zip`을 만든다. 출력 경로를
지정할 수 있고, 기존 파일은 명시적 `-Force` 없이는 덮어쓰지 않는다. ZIP 내부 최상위
폴더는 `hwp-skill`이며 `SKILL.md`, 스크립트, 참조, 스키마, 예제를 모두 포함한다.

## 스킬 내용의 제품 중립화

- frontmatter의 `description`은 `Use when AI 도구가 ...`로 시작한다.
- 공통 frontmatter는 `name`과 `description`만 사용하고, 본문의 `지원 환경`에 Windows와
  PowerShell 요구사항을 기록한다.
- 실행 계약의 주어를 `Codex`에서 `AI 에이전트`로 바꾼다.
- Codex 전용 호출 표기는 `agents/openai.yaml`에만 둔다.
- HWPX 우선, 무창 실행, HWP 마지막 변환, 원본 보존 정책은 변경하지 않는다.

## 오류 처리

- 잘못된 대상 이름은 PowerShell 매개변수 검증에서 거부한다.
- 사용자 프로필을 계산할 수 없으면 파일을 쓰기 전에 `BLOCKED`를 반환한다.
- `All` 대상 중 하나가 실패해도 나머지 결과와 실패 경로를 모두 반환한다.
- Claude 매니페스트와 마켓플레이스 JSON은 UTF-8 BOM 없이 저장한다.
- ZIP 원본 또는 설치 원본에 심볼릭 링크·junction·reparse point가 있으면 중단한다.

## 검증

1. 변경 전 `claude plugin validate .`가 매니페스트 부재로 실패하는 것을 RED로 보존한다.
2. 새 저장소 구조와 제품 중립 메타데이터를 Pester에서 검사한다.
3. 임시 프로필에 Codex, Claude, Universal, All 설치를 실제 수행한다.
4. 업데이트 실패 시 대상별 기존 설치 복원을 검증한다.
5. 패키지 ZIP을 풀어 필수 파일과 상대 경로를 검증한다.
6. `claude plugin validate .`과 `npx skills@latest add . --list`를 실제 실행한다.
7. 기존 Static 전체 시험 146개 이상의 회귀 시험을 통과시킨다.
8. 로컬 Codex와 Claude 사용자 스킬을 갱신한 뒤 저장소 원본과 파일 해시를 비교한다.
9. GitHub에 푸시한 커밋을 다시 조회하여 원격 반영을 확인한다.

## 비목표

- 일반 Claude.ai, ChatGPT 웹 채팅처럼 로컬 외부 스킬 설치 기능이 없는 서비스 지원
- 각 AI 도구의 계정 로그인이나 유료 구독 자동화
- HWP 처리 엔진을 macOS 또는 Linux 네이티브 프로그램으로 다시 구현
- 한컴오피스를 보이게 실행하거나 기존 문서를 직접 제어하는 기능 추가
