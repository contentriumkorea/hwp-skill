# HWP 다중 엔진 무창 기반 구축 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 모든 공개 명령이 기본 `silent` 모드에서 현재 사용자 화면의 한컴 COM·GUI를 실행하지 않도록 강제하고, 파일 형식과 환경에 따라 후속 직접 엔진을 선택할 수 있는 기능 라우터를 구축한다.

**Architecture:** PowerShell 공용 실행기 앞에 불변 실행 컨텍스트, 기능 스냅샷과 백엔드 라우터를 둔다. HWPX 검사는 기존 직접 XML 경로를 유지하고, HWP/HWT 네이티브 경로는 사용자가 현재 요청에서 `interactive`와 창 허용을 함께 명시한 경우에만 도달할 수 있게 한다. 휴대형 HWP 엔진과 격리 작업자는 이 단계에서 `available=false`로 정확히 보고하며 GUI로 자동 대체하지 않는다.

**Tech Stack:** Windows PowerShell 5.1+, PowerShell 7+, Pester 4 호환 문법, .NET `System.IO.Compression`, Win32 `user32.dll` 읽기 전용 창 계측, JSON Schema Draft 7

## Global Constraints

- 기본 실행 모드는 정확히 `silent`다.
- `silent`에서는 현재 사용자 세션에 `Hwp.exe`, Word, 파일 탐색기 또는 결과 파일 연결 프로그램을 시작하지 않는다.
- COM 객체를 만든 뒤 `Visible=false`로 숨기는 방식은 `silent` 구현으로 인정하지 않는다.
- `silent` 실패를 `interactive`로 자동 승격하지 않는다.
- `interactive`는 `-ExecutionMode interactive`와 `-AllowInteractiveWindow`가 동시에 있어야 한다.
- `isolated-native`는 현재 사용자 세션의 COM을 절대 사용하지 않는다.
- 원본 파일을 덮어쓰지 않고 작업 전후 SHA-256을 유지한다.
- 암호, DRM, 배포용 문서 제한과 전자서명을 우회하지 않는다.
- 사용자 동의 없이 문서를 외부 서버로 전송하지 않는다.
- 새 기능과 행동 변경은 실패하는 Pester 시험을 먼저 확인한다.
- 상태값은 `PASS`, `PASS_WITH_WARNINGS`, `BLOCKED`, `FAILED`만 사용한다.
- 이 계획은 HWPX 조판기, 휴대형 HWP 구현과 렌더러를 구현하지 않는다. 해당 엔진의 기능 슬롯과 안전한 미지원 상태만 만든다.

---

## File Structure

### 새 파일

- `skill/hwp-skill/scripts/lib/HwpExecution.psm1`: 실행 모드와 현재 화면 GUI 허용 계약
- `skill/hwp-skill/scripts/lib/HwpCapabilities.psm1`: COM을 생성하지 않는 엔진 기능 탐지
- `skill/hwp-skill/scripts/lib/HwpBackendRouter.psm1`: 명령·형식·실행 모드별 엔진 선택
- `skill/hwp-skill/schemas/capabilities.schema.json`: 기능 스냅샷 공개 규격
- `tests/Execution.Tests.ps1`: 실행 컨텍스트와 세션 강제 경계
- `tests/Capabilities.Tests.ps1`: 기능 탐지와 JSON 계약
- `tests/BackendRouter.Tests.ps1`: 기능 기반 라우팅 표
- `tests/SilentExecution.Tests.ps1`: 포커스·창·프로세스 무변경 수용 시험

### 수정 파일

- `skill/hwp-skill/scripts/Invoke-HwpSkill.ps1`: `capabilities`, 실행 모드와 중앙 라우팅
- `skill/hwp-skill/scripts/lib/HwpSession.psm1`: 로컬 COM 생성에 실행 컨텍스트 강제
- `skill/hwp-skill/scripts/lib/HwpInspect.psm1`: HWPX 직접 검사와 HWP 경로 라우팅
- `skill/hwp-skill/scripts/lib/HwpEdit.psm1`: 적용 전 백엔드 게이트
- `skill/hwp-skill/scripts/lib/HwpGenerate.psm1`: 생성 전 백엔드 게이트
- `skill/hwp-skill/scripts/lib/HwpBatch.psm1`: 파일별 실행 컨텍스트 전달
- `skill/hwp-skill/scripts/lib/HwpVerify.psm1`: 검증·내보내기 전 백엔드 게이트
- `tests/TestHelpers.psm1`: 승인된 시험용 대화형 컨텍스트 생성기
- `tests/Session.Tests.ps1`: 새 세션 계약
- `tests/Inspect.Integration.Tests.ps1`: 명시적 시험 컨텍스트
- `tests/Edit.Integration.Tests.ps1`: 명시적 시험 컨텍스트
- `tests/Generate.Integration.Tests.ps1`: 명시적 시험 컨텍스트
- `tests/Batch.Integration.Tests.ps1`: 명시적 시험 컨텍스트
- `tests/Verify.Integration.Tests.ps1`: 명시적 시험 컨텍스트
- `tests/run-tests.ps1`: 정적 시험 기본값과 네이티브 시험 승인 게이트
- `tests/Repository.Tests.ps1`: 새 모듈·스키마·스킬 트리거 계약
- `skill/hwp-skill/SKILL.md`: 기본 무창 정책과 명시적 대화형 예외
- `skill/hwp-skill/references/limitations.md`: 단계별 실제 지원 범위
- `skill/hwp-skill/references/safety.md`: 포커스·GUI·자동 대체 금지
- `README.md`: 무창 기본 동작과 기능 매트릭스

## Public Interfaces

```powershell
New-HwpExecutionContext `
  [-Mode <silent|isolated-native|interactive>] `
  [-AllowInteractiveWindow]

Get-HwpCapabilitySnapshot `
  [-ExecutionContext <object>] `
  [-NativeRegistrationProbe <scriptblock>] `
  [-PortableBackendProbe <scriptblock>] `
  [-IsolatedWorkerProbe <scriptblock>]

Resolve-HwpBackend `
  -Command <string> `
  -DetectedKind <UNKNOWN|HWP-BINARY|HWPX-ZIP|NONE> `
  [-RequestedFormat <none|hwp|hwpx>] `
  -ExecutionContext <object> `
  -Capabilities <object>

New-HwpSession -ExecutionContext <object> [...existing parameters]
```

`Resolve-HwpBackend` 성공 데이터:

```json
{
  "backendId": "hwpx-direct",
  "reason": "HWPX inspect is supported without GUI",
  "requiresGui": false,
  "isolated": false
}
```

---

### Task 1: 실행 컨텍스트와 로컬 GUI 강제 경계

**Files:**
- Create: `skill/hwp-skill/scripts/lib/HwpExecution.psm1`
- Create: `tests/Execution.Tests.ps1`
- Modify: `skill/hwp-skill/scripts/lib/HwpSession.psm1:106-186`
- Modify: `tests/TestHelpers.psm1`
- Modify: `tests/Session.Tests.ps1:80-235`
- Modify: `tests/fixtures/New-TestFixtures.ps1`

**Interfaces:**
- Produces: `New-HwpExecutionContext`, `Test-HwpExecutionContext`, `Assert-HwpLocalGuiAllowed`
- Produces: `New-HwpSession -ExecutionContext <object>`
- Consumes: 기존 `New-HwpResult`

- [ ] **Step 1: 기본 컨텍스트가 GUI를 허용하지 않는 실패 시험 작성**

```powershell
$executionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpSession.psm1'

Describe 'HWP 실행 컨텍스트' {
    It '기본 모드는 silent이며 대화형 창을 허용하지 않는다' {
        Test-Path -LiteralPath $executionModule | Should Be $true
        Import-Module $executionModule -Force
        $context = New-HwpExecutionContext
        $context.Mode | Should Be 'silent'
        $context.AllowInteractiveWindow | Should Be $false
    }

    It 'silent 컨텍스트에서는 COM 팩터리를 호출하지 않는다' {
        Import-Module $sessionModule -Force
        $calls = [pscustomobject]@{ Value = 0 }
        $factory = ({
            param($progId)
            $calls.Value++
            throw 'COM 팩터리를 호출하면 안 됩니다.'
        }.GetNewClosure())

        { New-HwpSession -ExecutionContext (New-HwpExecutionContext) -ComFactory $factory } |
            Should Throw '*interactive*'
        $calls.Value | Should Be 0
    }

    It 'interactive 모드만 지정하고 창 허용을 생략하면 거부한다' {
        { New-HwpExecutionContext -Mode interactive } | Should Throw '*AllowInteractiveWindow*'
    }
}
```

- [ ] **Step 2: 시험을 실행해 RED 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\Execution.Tests.ps1 `
    -TestName '기본 모드는 silent이며 대화형 창을 허용하지 않는다' -PassThru
```

Expected: `HwpExecution.psm1`이 없어 첫 시험이 FAIL하고, 현재 `New-HwpSession`에는
`ExecutionContext`가 없어 무창 계약이 존재하지 않음이 확인된다.

- [ ] **Step 3: 최소 실행 컨텍스트 구현**

`HwpExecution.psm1`에 다음 공개 계약을 구현한다.

```powershell
Set-StrictMode -Version Latest

function New-HwpExecutionContext {
    [CmdletBinding()]
    param(
        [ValidateSet('silent','isolated-native','interactive')]
        [string]$Mode = 'silent',
        [switch]$AllowInteractiveWindow
    )

    if ($Mode -eq 'interactive' -and -not $AllowInteractiveWindow) {
        throw 'interactive 모드는 -AllowInteractiveWindow의 명시적 승인이 필요합니다.'
    }
    if ($Mode -ne 'interactive' -and $AllowInteractiveWindow) {
        throw '-AllowInteractiveWindow는 interactive 모드에서만 사용할 수 있습니다.'
    }

    [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        Mode = $Mode
        AllowInteractiveWindow = [bool]$AllowInteractiveWindow
    }
}

function Test-HwpExecutionContext {
    param([AllowNull()][object]$ExecutionContext)
    $null -ne $ExecutionContext -and
        $ExecutionContext.PSObject.Properties.Name -contains 'Mode' -and
        $ExecutionContext.PSObject.Properties.Name -contains 'AllowInteractiveWindow' -and
        [string]$ExecutionContext.Mode -in 'silent','isolated-native','interactive'
}

function Assert-HwpLocalGuiAllowed {
    param([Parameter(Mandatory)][object]$ExecutionContext)
    if (-not (Test-HwpExecutionContext $ExecutionContext)) {
        throw '유효한 HWP 실행 컨텍스트가 필요합니다.'
    }
    if ([string]$ExecutionContext.Mode -ne 'interactive' -or
        -not [bool]$ExecutionContext.AllowInteractiveWindow) {
        throw '현재 사용자 세션의 한컴 실행은 interactive 모드에서만 허용됩니다.'
    }
}

Export-ModuleMember -Function @(
    'New-HwpExecutionContext',
    'Test-HwpExecutionContext',
    'Assert-HwpLocalGuiAllowed'
)
```

`New-HwpSession`의 첫 실행문에서 `Assert-HwpLocalGuiAllowed`를 호출한 뒤에만
프로세스 목록 조회와 COM 팩터리 호출을 수행한다. `HwpSession.psm1`은
`HwpExecution.psm1`을 가져오며, `Invoke-HwpPreflight`도 `ExecutionContext`를 받아
같은 컨텍스트를 `New-HwpSession`에 전달한다.

```powershell
function New-HwpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ExecutionContext,
        [bool]$Visible = $false,
        [scriptblock]$ComFactory = { param($progId) New-Object -ComObject $progId },
        [scriptblock]$ProcessOwnershipResolver = {
            param($hwp,$beforeProcessIds,$isComObject)
            Resolve-HwpSessionProcessOwnership -Hwp $hwp `
                -BeforeProcessIds $beforeProcessIds -IsComObject:$isComObject
        },
        [ValidateRange(1, 10)][int]$RetryCount = 3,
        [ValidateRange(0, 5000)][int]$RetryDelayMilliseconds = 300
    )

    Assert-HwpLocalGuiAllowed -ExecutionContext $ExecutionContext
    # 기존 프로세스 소유권 확인과 COM 생성 코드는 이 줄 뒤에 그대로 둔다.
}
```

- [ ] **Step 4: 네이티브 의도를 가진 기존 세션 시험을 명시적으로 변경**

`tests/TestHelpers.psm1`에 다음 함수를 추가하고 내보낸다.

```powershell
function New-TestInteractiveExecutionContext {
    New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow
}
```

`TestHelpers.psm1`과 `New-TestFixtures.ps1`은 `HwpExecution.psm1`을 명시적으로
가져온다. 시험 문서 생성기는 사용자에게 보이는 네이티브 작업이므로
`-AllowInteractiveNative` 스위치를 새로 받고, 스위치가 없으면 COM 생성 전에
종료 코드 `2`로 차단한다. 승인된 경우에만 다음 컨텍스트를 사용한다.

```powershell
$executionContext = New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow
$session = New-HwpSession -ExecutionContext $executionContext -Visible ([bool]$Visible)
```

`Session.Tests.ps1`에서 COM 시험 더블을 만드는 호출은 다음 형식으로 바꾼다.

```powershell
$session = New-HwpSession `
    -ExecutionContext (New-TestInteractiveExecutionContext) `
    -ComFactory $factory
```

- [ ] **Step 5: RED 시험과 기존 세션 시험 통과 확인**

Run:

```powershell
Invoke-Pester -Script @(
  '.\tests\Execution.Tests.ps1',
  '.\tests\Session.Tests.ps1'
) -PassThru
```

Expected: 두 파일 모두 PASS, `silent` 시험의 COM 팩터리 호출 횟수 `0`.

- [ ] **Step 6: 커밋**

```powershell
git add skill/hwp-skill/scripts/lib/HwpExecution.psm1 `
  skill/hwp-skill/scripts/lib/HwpSession.psm1 `
  tests/Execution.Tests.ps1 tests/TestHelpers.psm1 tests/Session.Tests.ps1 `
  tests/fixtures/New-TestFixtures.ps1
git commit -m "feat: require explicit context for local HWP GUI"
```

---

### Task 2: COM을 생성하지 않는 기능 스냅샷

**Files:**
- Create: `skill/hwp-skill/scripts/lib/HwpCapabilities.psm1`
- Create: `skill/hwp-skill/schemas/capabilities.schema.json`
- Create: `tests/Capabilities.Tests.ps1`
- Modify: `tests/Repository.Tests.ps1:52-96`

**Interfaces:**
- Consumes: `New-HwpExecutionContext`
- Produces: `Get-HwpCapabilitySnapshot`, `Get-HwpBackendCapability`
- Produces: capability schema version `1.0`

- [ ] **Step 1: 기능 스냅샷 실패 시험 작성**

```powershell
Describe 'HWP 엔진 기능 스냅샷' {
    $executionModule = "$PSScriptRoot/../skill/hwp-skill/scripts/lib/HwpExecution.psm1"
    $capabilityModule = "$PSScriptRoot/../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1"

    It '기능 모듈이 존재한다' {
        Test-Path $capabilityModule | Should Be $true
    }

    It '탐지 과정에서 네이티브 COM 객체를 만들지 않는다' {
        Import-Module $executionModule -Force
        Import-Module $capabilityModule -Force
        $nativeCalls = [pscustomobject]@{ Value = 0 }
        $snapshot = Get-HwpCapabilitySnapshot `
            -ExecutionContext (New-HwpExecutionContext) `
            -NativeRegistrationProbe ({ $nativeCalls.Value++; $true }.GetNewClosure()) `
            -PortableBackendProbe { $false } `
            -IsolatedWorkerProbe { $false }

        $nativeCalls.Value | Should Be 1
        ($snapshot.Backends | Where-Object Id -eq 'hwpx-direct').Available | Should Be $true
        ($snapshot.Backends | Where-Object Id -eq 'hwp-portable').Available | Should Be $false
        ($snapshot.Backends | Where-Object Id -eq 'hancom-isolated').Available | Should Be $false
        ($snapshot.Backends | Where-Object Id -eq 'hancom-interactive').Available | Should Be $true
    }

    It '기본 기능 스냅샷이 공개 JSON 스키마를 통과한다' {
        Import-Module $executionModule -Force
        Import-Module $capabilityModule -Force
        $snapshot = Get-HwpCapabilitySnapshot -ExecutionContext (New-HwpExecutionContext) `
            -NativeRegistrationProbe { $false } -PortableBackendProbe { $false } `
            -IsolatedWorkerProbe { $false }
        $json = $snapshot | ConvertTo-Json -Depth 20
        $json | Test-Json -SchemaFile "$PSScriptRoot/../skill/hwp-skill/schemas/capabilities.schema.json" |
            Should Be $true
    }
}
```

- [ ] **Step 2: 시험을 실행해 모듈 부재 RED 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\Capabilities.Tests.ps1 `
    -TestName '기능 모듈이 존재한다' -PassThru
```

Expected: 모듈과 함수가 없어 FAIL.

- [ ] **Step 3: 기능 객체와 안전한 탐지 구현**

백엔드 객체는 다음 정확한 속성을 갖는다.

```powershell
[pscustomobject][ordered]@{
    id = 'hwpx-direct'
    available = $true
    formats = @('HWPX-ZIP')
    operations = @('inspect')
    requiresGui = $false
    isolation = 'none'
    reason = 'HWPX ZIP/XML direct inspection is built in.'
}
```

네 백엔드의 초기 기능 값은 다음 표와 정확히 일치시킨다.

| `id` | `available` | `formats` | `operations` | `requiresGui` | `isolation` |
|---|---|---|---|---:|---|
| `hwpx-direct` | `true` | `HWPX-ZIP` | `inspect` | `false` | `none` |
| `hwp-portable` | portable probe | `HWP-BINARY` | `inspect,generate,apply,batch,verify` | `false` | `none` |
| `hancom-isolated` | isolated probe | `HWP-BINARY` | `inspect,generate,apply,batch,verify,export` | `true` | `separate-session` |
| `hancom-interactive` | native registration probe | `HWP-BINARY` | `inspect,generate,apply,batch,verify,export` | `true` | `current-session` |

최상위 기능 스냅샷도 JSON 스키마와 같은 소문자 속성을 사용한다.

```powershell
[pscustomobject][ordered]@{
    schemaVersion = '1.0'
    executionMode = [string]$ExecutionContext.Mode
    backends = @($backends)
}
```

기본 네이티브 등록 탐지는 COM 인스턴스를 만들지 않고 등록 형식만 확인한다.

```powershell
$nativeProbe = {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    $null -ne [type]::GetTypeFromProgID('HWPFrame.HwpObject.2', $false) -or
        $null -ne [type]::GetTypeFromProgID('HWPFrame.HwpObject', $false)
}
```

휴대형 엔진 기본 프로브는
`skill/hwp-skill/runtime/hwp-portable/backend.json`이 존재하고 내부 `id`가 정확히
`hwp-portable`일 때만 참을 반환한다. 격리 작업자 기본 프로브는 이 구현 단계에서
항상 거짓을 반환하며 Task 3이 로컬 COM으로 대체하지 않는지 검증한다.

- [ ] **Step 4: `capabilities.schema.json` 작성**

스키마는 최상위 `schemaVersion`, `executionMode`, `backends`를 필수로 하고,
각 백엔드에 `id`, `available`, `formats`, `operations`, `requiresGui`, `isolation`,
`reason`을 강제한다. `additionalProperties`는 모든 객체에서 `false`로 둔다. `$id`는
정확히
`https://github.com/contentriumkorea/hwp-skill/blob/main/skill/hwp-skill/schemas/capabilities.schema.json`으로 설정한다.

- [ ] **Step 5: 기능·저장소 시험 통과 확인**

Run:

```powershell
Invoke-Pester -Script @(
  '.\tests\Capabilities.Tests.ps1',
  '.\tests\Repository.Tests.ps1'
) -PassThru
```

Expected: PASS, 기능 탐지 중 `Hwp.exe` 생성 코드 없음.

- [ ] **Step 6: 커밋**

```powershell
git add skill/hwp-skill/scripts/lib/HwpCapabilities.psm1 `
  skill/hwp-skill/schemas/capabilities.schema.json `
  tests/Capabilities.Tests.ps1 tests/Repository.Tests.ps1
git commit -m "feat: report HWP backend capabilities without COM"
```

---

### Task 3: 기능 기반 백엔드 라우터

**Files:**
- Create: `skill/hwp-skill/scripts/lib/HwpBackendRouter.psm1`
- Create: `tests/BackendRouter.Tests.ps1`

**Interfaces:**
- Consumes: capability objects from `Get-HwpCapabilitySnapshot`
- Consumes: execution context from `New-HwpExecutionContext`
- Produces: `Resolve-HwpBackend -RequestedFormat`, `Get-HwpBackendById`, `Get-HwpRequestedFormat`

- [ ] **Step 1: 라우팅 표 실패 시험 작성**

```powershell
Describe 'HWP 백엔드 라우터' {
    $executionModule = "$PSScriptRoot/../skill/hwp-skill/scripts/lib/HwpExecution.psm1"
    $capabilityModule = "$PSScriptRoot/../skill/hwp-skill/scripts/lib/HwpCapabilities.psm1"
    $routerModule = "$PSScriptRoot/../skill/hwp-skill/scripts/lib/HwpBackendRouter.psm1"

    function New-TestRouterInputs {
        param(
            [string]$ExecutionModule,
            [string]$CapabilityModule,
            [string]$RouterModule
        )
        Import-Module $ExecutionModule -Force
        Import-Module $CapabilityModule -Force
        Import-Module $RouterModule -Force
        Get-HwpCapabilitySnapshot `
            -ExecutionContext (New-HwpExecutionContext) `
            -NativeRegistrationProbe { $true } `
            -PortableBackendProbe { $false } `
            -IsolatedWorkerProbe { $false }
    }

    It '라우터 모듈이 존재한다' {
        Test-Path $routerModule | Should Be $true
    }

    It 'silent HWPX 검사는 직접 엔진을 선택한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWPX-ZIP `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities
        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hwpx-direct'
        $route.RequiresGui | Should Be $false
    }

    It 'silent HWP 검사는 GUI 대신 명시적으로 차단한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWP-BINARY `
            -ExecutionContext (New-HwpExecutionContext) -Capabilities $capabilities
        $route.Status | Should Be 'BLOCKED'
        $route.BackendId | Should Be ''
        ($route.Errors -join ' ') | Should Match 'hwp-portable'
    }

    It '격리 작업자가 없으면 로컬 한컴으로 대체하지 않는다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $context = New-HwpExecutionContext -Mode isolated-native
        $route = Resolve-HwpBackend -Command verify -DetectedKind HWP-BINARY `
            -ExecutionContext $context -Capabilities $capabilities
        $route.Status | Should Be 'BLOCKED'
        ($route.Errors -join ' ') | Should Match 'hancom-isolated'
    }

    It '명시적으로 승인된 interactive만 네이티브 엔진을 선택한다' {
        $capabilities = New-TestRouterInputs $executionModule $capabilityModule $routerModule
        $context = New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow
        $route = Resolve-HwpBackend -Command inspect -DetectedKind HWP-BINARY `
            -ExecutionContext $context -Capabilities $capabilities
        $route.Status | Should Be 'PASS'
        $route.BackendId | Should Be 'hancom-interactive'
        $route.RequiresGui | Should Be $true
    }
}
```

- [ ] **Step 2: 시험을 실행해 라우터 부재 RED 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\BackendRouter.Tests.ps1 `
    -TestName '라우터 모듈이 존재한다' -PassThru
```

Expected: `Resolve-HwpBackend` 미정의로 FAIL.

- [ ] **Step 3: 결정적 라우팅 구현**

라우팅 우선순위를 다음 배열 순서로 코드에 고정한다.

```powershell
$routeOrder = @(
    'core',
    'hwpx-direct',
    'hwp-portable',
    'hancom-isolated',
    'hancom-interactive'
)
```

`capabilities`, `preflight`, `validate-plan`, `compare`는 `core`다. HWPX의
`inspect`만 이 단계의 `hwpx-direct`가 지원한다. `silent`는 `RequiresGui=$true`인
백엔드를 후보에서 제외한다. `isolated-native`는 `hancom-isolated`만 허용한다.
`interactive`는 명시적으로 승인된 컨텍스트에서만 `hancom-interactive`를 허용한다.
`generate`처럼 입력 파일이 없는 명령은 `DetectedKind=NONE`과 출력 경로에서 계산한
`RequestedFormat`을 함께 사용한다. `RequestedFormat=hwp`는 `hwp-portable` 또는 승인된
네이티브 엔진, `RequestedFormat=hwpx`는 `hwpx-direct`의 `generate` 기능이 선언된
경우에만 선택한다. 이 단계의 `hwpx-direct`에는 `generate`가 없으므로 silent HWPX
생성은 정확히 `BLOCKED`다.

출력 형식 계산 함수는 `.hwp`와 `.hwpx`만 허용한다.

```powershell
function Get-HwpRequestedFormat {
    param([AllowEmptyString()][string]$OutputPath)
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { return 'none' }
    switch ([IO.Path]::GetExtension($OutputPath).ToLowerInvariant()) {
        '.hwp' { return 'hwp' }
        '.hwpx' { return 'hwpx' }
        default { throw '출력 형식은 HWP 또는 HWPX여야 합니다.' }
    }
}
```

- [ ] **Step 4: 오류에 필요한 엔진과 자동 대체 금지 이유 기록**

차단 결과의 공개 모양을 다음과 같이 고정한다.

```powershell
[pscustomobject][ordered]@{
    Status = 'BLOCKED'
    BackendId = ''
    RequiresGui = $false
    Isolated = $false
    Reason = 'No silent backend supports inspect for HWP-BINARY.'
    Warnings = @()
    Errors = @('hwp-portable 백엔드가 준비되지 않았으며 GUI로 자동 전환하지 않습니다.')
}
```

- [ ] **Step 5: 라우팅 시험 통과 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\BackendRouter.Tests.ps1 -PassThru
```

Expected: 4개 라우팅 계약 모두 PASS.

- [ ] **Step 6: 커밋**

```powershell
git add skill/hwp-skill/scripts/lib/HwpBackendRouter.psm1 tests/BackendRouter.Tests.ps1
git commit -m "feat: route HWP operations by capability and mode"
```

---

### Task 4: 안전한 `capabilities`와 `preflight` CLI

**Files:**
- Modify: `skill/hwp-skill/scripts/Invoke-HwpSkill.ps1:1-159`
- Create: `tests/Cli.Tests.ps1`
- Modify: `tests/Repository.Tests.ps1:1-96`

**Interfaces:**
- Consumes: `New-HwpExecutionContext`, `Get-HwpCapabilitySnapshot`, `Resolve-HwpBackend`
- Produces: CLI command `capabilities`
- Produces: CLI parameters `-ExecutionMode`, `-AllowInteractiveWindow`

- [ ] **Step 1: 기본 CLI가 COM 없이 기능 정보를 반환하는 실패 시험 작성**

```powershell
Describe 'HWP 공용 CLI 실행 모드' {
    BeforeEach { $script:cli = Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/Invoke-HwpSkill.ps1' }

    It 'capabilities 기본 실행 모드는 silent다' {
        $json = & $cli capabilities | ConvertFrom-Json
        $LASTEXITCODE | Should Be 0
        $json.status | Should Be 'PASS'
        $json.data.executionMode | Should Be 'silent'
    }

    It 'silent preflight는 한컴 설치를 필수 조건으로 만들지 않는다' {
        $json = & $cli preflight | ConvertFrom-Json
        $LASTEXITCODE | Should Be 0
        $json.status | Should Be 'PASS'
        $json.data.executionMode | Should Be 'silent'
    }

    It 'interactive는 창 허용 스위치 없이는 실패한다' {
        $json = & $cli capabilities -ExecutionMode interactive | ConvertFrom-Json
        $LASTEXITCODE | Should Be 1
        $json.status | Should Be 'FAILED'
        ($json.errors -join ' ') | Should Match 'AllowInteractiveWindow'
    }
}
```

- [ ] **Step 2: 시험을 실행해 명령 부재 RED 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\Cli.Tests.ps1 -PassThru
```

Expected: `capabilities`가 ValidateSet에 없어 FAIL.

- [ ] **Step 3: CLI 매개변수와 모듈 가져오기 추가**

```powershell
[ValidateSet('capabilities','preflight','inspect','validate-plan','apply','generate','batch','compare','verify','export')]
[string]$Command,

[ValidateSet('silent','isolated-native','interactive')]
[string]$ExecutionMode = 'silent',

[switch]$AllowInteractiveWindow
```

기존 라이브러리보다 먼저 `HwpExecution.psm1`, `HwpCapabilities.psm1`,
`HwpBackendRouter.psm1`을 가져오고 다음 컨텍스트를 한 번만 만든다.

```powershell
$executionContext = New-HwpExecutionContext -Mode $ExecutionMode `
    -AllowInteractiveWindow:([bool]$AllowInteractiveWindow)
$capabilities = Get-HwpCapabilitySnapshot -ExecutionContext $executionContext
```

- [ ] **Step 4: `capabilities`와 `preflight` 분기 구현**

```powershell
'capabilities' {
    New-HwpResult -Status PASS -Command capabilities -Data $capabilities
    break
}
'preflight' {
    if ($ExecutionMode -eq 'interactive') {
        Invoke-HwpPreflight -ExecutionContext $executionContext `
            -RequireUnattendedOpen:([bool]$RequireUnattendedOpen)
    }
    else {
        New-HwpResult -Status PASS -Command preflight -Data $capabilities
    }
    break
}
```

- [ ] **Step 5: CLI와 저장소 시험 통과 확인**

Run:

```powershell
Invoke-Pester -Script @('.\tests\Cli.Tests.ps1','.\tests\Repository.Tests.ps1') -PassThru
```

Expected: PASS, 기본 `preflight`가 한컴 객체를 만들지 않음.

- [ ] **Step 6: 커밋**

```powershell
git add skill/hwp-skill/scripts/Invoke-HwpSkill.ps1 tests/Cli.Tests.ps1 tests/Repository.Tests.ps1
git commit -m "feat: add silent capability preflight"
```

---

### Task 5: 파일 검사 경로 라우팅

**Files:**
- Modify: `skill/hwp-skill/scripts/lib/HwpInspect.psm1:591-689`
- Modify: `skill/hwp-skill/scripts/Invoke-HwpSkill.ps1:63-159`
- Modify: `tests/Inspect.Integration.Tests.ps1:1-351`
- Modify: `tests/Inspect.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-HwpBackend`
- Produces: `Get-HwpInspection -ExecutionContext -Capabilities`

- [ ] **Step 1: HWPX 직접 검사와 HWP 차단 실패 시험 작성**

```powershell
It 'silent HWPX 검사는 세션 팩터리를 호출하지 않는다' {
    $calls = [pscustomobject]@{ Value = 0 }
    $factory = ({ $calls.Value++; throw '세션 호출 금지' }.GetNewClosure())
    $result = Get-HwpInspection -LiteralPath $fixtureHwpx `
        -ExecutionContext (New-HwpExecutionContext) `
        -Capabilities $silentCapabilities -SessionFactory $factory
    $result.Status | Should Match '^PASS'
    $calls.Value | Should Be 0
}

It 'silent HWP 검사는 세션 대신 BLOCKED를 반환한다' {
    $calls = [pscustomobject]@{ Value = 0 }
    $factory = ({ $calls.Value++; throw '세션 호출 금지' }.GetNewClosure())
    $result = Get-HwpInspection -LiteralPath $fixtureHwp `
        -ExecutionContext (New-HwpExecutionContext) `
        -Capabilities $silentCapabilities -SessionFactory $factory
    $result.Status | Should Be 'BLOCKED'
    $calls.Value | Should Be 0
    ($result.Errors -join ' ') | Should Match 'hwp-portable'
}
```

같은 `Describe`의 준비 구문에서 기존 `New-SyntheticHwpx`로 `$fixtureHwpx`를 만들고,
저장소 합성 HWP를 `$fixtureHwp`로 지정하며, 다음 기능 스냅샷을 만든다.

```powershell
$fixtureHwpx = New-SyntheticHwpx -LiteralPath (Join-Path $TestDrive 'silent.hwpx')
$fixtureHwp = Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
$silentCapabilities = Get-HwpCapabilitySnapshot `
    -ExecutionContext (New-HwpExecutionContext) `
    -NativeRegistrationProbe { $true } `
    -PortableBackendProbe { $false } `
    -IsolatedWorkerProbe { $false }
```

- [ ] **Step 2: 시험을 실행해 HWP가 세션 팩터리를 호출하는 RED 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\Inspect.Integration.Tests.ps1 -PassThru
```

Expected: silent HWP 시험이 세션 팩터리 호출로 FAIL.

- [ ] **Step 3: `Get-HwpInspection` 앞에 라우터 적용**

HWPX 직접 분기는 그대로 유지한다. HWP 바이너리 분기 직전에 다음 계약을 적용한다.

```powershell
$route = Resolve-HwpBackend -Command inspect -DetectedKind $detectedKind `
    -ExecutionContext $ExecutionContext -Capabilities $Capabilities
if ($route.Status -ne 'PASS') {
    return New-HwpInspectionRecord -Status $route.Status -Path $resolvedPath `
        -Sha256 $sha256 -DetectedKind $detectedKind `
        -Warnings @($route.Warnings) -Errors @($route.Errors)
}
if ($route.BackendId -ne 'hancom-interactive') {
    return New-HwpInspectionRecord -Status BLOCKED -Path $resolvedPath `
        -Sha256 $sha256 -DetectedKind $detectedKind `
        -Errors @("백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)")
}
```

네이티브 세션 팩터리에는 `$ExecutionContext`를 전달한다. 시험 더블도
`param($executionContext)`를 받도록 통일한다.

- [ ] **Step 4: CLI `inspect`가 공통 컨텍스트와 기능 스냅샷 전달**

```powershell
Get-HwpInspection -LiteralPath $LiteralPath `
    -ExecutionContext $executionContext -Capabilities $capabilities
```

- [ ] **Step 5: 검사 시험 통과 확인**

Run:

```powershell
Invoke-Pester -Script @(
  '.\tests\Inspect.Tests.ps1',
  '.\tests\Inspect.Integration.Tests.ps1',
  '.\tests\Cli.Tests.ps1'
) -PassThru
```

Expected: HWPX 직접 검사 PASS, silent HWP는 `BLOCKED`, 팩터리 호출 `0`, 명시적
interactive 시험 더블은 기존 결과 유지.

- [ ] **Step 6: 커밋**

```powershell
git add skill/hwp-skill/scripts/lib/HwpInspect.psm1 `
  skill/hwp-skill/scripts/Invoke-HwpSkill.ps1 `
  tests/Inspect.Tests.ps1 tests/Inspect.Integration.Tests.ps1 tests/Cli.Tests.ps1
git commit -m "feat: inspect HWP files through the backend router"
```

---

### Task 6: 편집·생성·일괄·검증의 GUI 자동 대체 차단

**Files:**
- Modify: `skill/hwp-skill/scripts/lib/HwpEdit.psm1:2564-2818`
- Modify: `skill/hwp-skill/scripts/lib/HwpGenerate.psm1:455-676`
- Modify: `skill/hwp-skill/scripts/lib/HwpBatch.psm1:201-359`
- Modify: `skill/hwp-skill/scripts/lib/HwpVerify.psm1:278-564`
- Modify: `skill/hwp-skill/scripts/Invoke-HwpSkill.ps1`
- Modify: `tests/Edit.Integration.Tests.ps1`
- Modify: `tests/Generate.Integration.Tests.ps1`
- Modify: `tests/Batch.Integration.Tests.ps1`
- Modify: `tests/Verify.Integration.Tests.ps1`
- Modify: `tests/Verify.Tests.ps1`

**Interfaces:**
- Consumes: `ExecutionContext`, `Capabilities`, `Resolve-HwpBackend`
- Produces: 모든 공개 문서 작업의 기본 무창 차단 계약

- [ ] **Step 1: 기본 모드에서 세션 팩터리를 호출하지 않는 실패 시험 작성**

각 공개 함수에 같은 패턴의 한 가지 대표 시험을 둔다.

```powershell
It 'silent 생성은 네이티브 세션을 호출하지 않는다' {
    $calls = [pscustomobject]@{ Value = 0 }
    $factory = ({ param($context) $calls.Value++; throw '세션 호출 금지' }.GetNewClosure())
    $result = Invoke-HwpGenerate -NewDocument -Plan $validPlan -OutputPath $output `
        -ExecutionContext (New-HwpExecutionContext) `
        -Capabilities $silentCapabilities -SessionFactory $factory
    $result.Status | Should Be 'BLOCKED'
    $calls.Value | Should Be 0
}
```

동일 계약을 `Invoke-HwpApply`, `Invoke-HwpBatch -Apply`, `Invoke-HwpVerify`,
`Export-HwpPdf`, `Export-HwpPageImages`에 적용한다.

- [ ] **Step 2: 시험을 실행해 현재 기본 세션 호출 RED 확인**

Run:

```powershell
Invoke-Pester -Script @(
  '.\tests\Edit.Integration.Tests.ps1',
  '.\tests\Generate.Integration.Tests.ps1',
  '.\tests\Batch.Integration.Tests.ps1',
  '.\tests\Verify.Integration.Tests.ps1',
  '.\tests\Verify.Tests.ps1'
) -PassThru
```

Expected: 새 silent 시험이 세션 팩터리 호출 또는 실행 컨텍스트 매개변수 부재로 FAIL.

- [ ] **Step 3: 각 공개 함수에 동일한 초기 라우팅 게이트 추가**

각 공개 함수는 기본 컨텍스트를 `New-HwpExecutionContext`로 만들고, 기능 스냅샷을
같은 컨텍스트로 만든다. 새 문서 생성은 다음과 같이 출력 형식을 계산하고, 입력
문서 작업은 `requestedFormat='none'`을 사용한다.

```powershell
$requestedFormat = if ($commandName -eq 'generate') {
    Get-HwpRequestedFormat -OutputPath $OutputPath
} else {
    'none'
}
```

```powershell
$route = Resolve-HwpBackend -Command $commandName -DetectedKind $detectedKind `
    -RequestedFormat $requestedFormat `
    -ExecutionContext $ExecutionContext -Capabilities $Capabilities
if ($route.Status -ne 'PASS') {
    return New-HwpResult -Status $route.Status -Command $commandName `
        -Warnings @($route.Warnings) -Errors @($route.Errors)
}
```

이 단계에서 `hwpx-direct`는 `inspect`만 선언하므로 HWPX 생성·편집도 정확히
`BLOCKED`다. `hancom-interactive` 경로에서만 승인된 컨텍스트를 세션 팩터리에
전달한다.

- [ ] **Step 4: 일괄 처리는 파일별 차단을 결과 항목으로 유지**

미리보기와 실제 적용 모두 `ExecutionContext`와 `Capabilities`를
`Get-HwpInspection` 및 `Invoke-HwpApply`에 전달한다. 한 파일의 미지원 상태 때문에
다른 파일을 GUI로 전환하지 않고, 해당 항목만 `BLOCKED`로 기록한다.

- [ ] **Step 5: 명시적 interactive 시험 더블의 기존 기능 보존**

기존 네이티브 통합 시험 호출에는 다음 컨텍스트를 전달한다.

```powershell
-ExecutionContext (New-TestInteractiveExecutionContext)
```

실제 `Hwp.exe`를 사용하지 않는 시험 더블 경로만 현재 세션에서 실행한다.

- [ ] **Step 6: 관련 시험 통과 확인**

Run:

```powershell
& .\tests\run-tests.ps1 -Suite Static
```

Expected: PASS, 새 silent 시험의 모든 세션 팩터리 호출 횟수 `0`.

- [ ] **Step 7: 커밋**

```powershell
git add skill/hwp-skill/scripts/lib/HwpEdit.psm1 `
  skill/hwp-skill/scripts/lib/HwpGenerate.psm1 `
  skill/hwp-skill/scripts/lib/HwpBatch.psm1 `
  skill/hwp-skill/scripts/lib/HwpVerify.psm1 `
  skill/hwp-skill/scripts/Invoke-HwpSkill.ps1 tests
git commit -m "feat: block implicit GUI fallback for every HWP command"
```

---

### Task 7: 포커스·창·프로세스 무변경 수용 시험

**Files:**
- Create: `tests/WindowActivityMonitor.psm1`
- Create: `tests/SilentExecution.Tests.ps1`
- Modify: `tests/run-tests.ps1:1-24`

**Interfaces:**
- Consumes: public CLI only
- Produces: automated `silent` acceptance gate

- [ ] **Step 1: 실행 중 일시적인 HWP 창까지 포착하는 감시기 작성**

```powershell
if ($null -eq ('HwpSilentActivityMonitor' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class HwpSilentActivityMonitor : IDisposable
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    private readonly HashSet<int> baselineProcessIds;
    private readonly HashSet<long> baselineWindowHandles;
    private readonly long baselineForegroundHandle;
    private readonly ConcurrentDictionary<int, byte> newProcessIds = new ConcurrentDictionary<int, byte>();
    private readonly ConcurrentDictionary<long, byte> newWindowHandles = new ConcurrentDictionary<long, byte>();
    private Thread worker;
    private volatile bool running;
    private volatile bool foregroundCapturedByHwp;

    public HwpSilentActivityMonitor()
    {
        baselineProcessIds = GetHwpProcessIds();
        baselineWindowHandles = GetVisibleHwpWindowHandles(baselineProcessIds);
        baselineForegroundHandle = GetForegroundWindow().ToInt64();
    }

    public int[] NewProcessIds { get { return newProcessIds.Keys.OrderBy(x => x).ToArray(); } }
    public long[] NewVisibleWindowHandles { get { return newWindowHandles.Keys.OrderBy(x => x).ToArray(); } }
    public bool ForegroundCapturedByHwp { get { return foregroundCapturedByHwp; } }

    public void Start()
    {
        if (running) throw new InvalidOperationException("Monitor already started.");
        running = true;
        worker = new Thread(Watch) { IsBackground = true, Name = "hwp-silent-window-monitor" };
        worker.Start();
    }

    public void Stop()
    {
        running = false;
        if (worker != null) worker.Join(2000);
        Snapshot();
    }

    private void Watch()
    {
        while (running)
        {
            Snapshot();
            Thread.Sleep(5);
        }
    }

    private void Snapshot()
    {
        HashSet<int> processIds = GetHwpProcessIds();
        foreach (int id in processIds)
            if (!baselineProcessIds.Contains(id)) newProcessIds.TryAdd(id, 0);

        HashSet<long> windowHandles = GetVisibleHwpWindowHandles(processIds);
        foreach (long handle in windowHandles)
            if (!baselineWindowHandles.Contains(handle)) newWindowHandles.TryAdd(handle, 0);

        long foreground = GetForegroundWindow().ToInt64();
        if (foreground != baselineForegroundHandle && windowHandles.Contains(foreground))
            foregroundCapturedByHwp = true;
    }

    private static HashSet<int> GetHwpProcessIds()
    {
        return new HashSet<int>(Process.GetProcessesByName("Hwp").Select(p => p.Id));
    }

    private static HashSet<long> GetVisibleHwpWindowHandles(HashSet<int> hwpProcessIds)
    {
        var result = new HashSet<long>();
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            if (hwpProcessIds.Contains((int)processId)) result.Add(hWnd.ToInt64());
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public void Dispose() { Stop(); }
}
'@
}
```

- [ ] **Step 2: 공개 무창 명령 수용 시험 작성**

```powershell
It 'capabilities와 preflight가 포커스와 HWP 프로세스를 바꾸지 않는다' {
    $monitor = [HwpSilentActivityMonitor]::new()
    $monitor.Start()
    try {
        $capabilities = & $cli capabilities | ConvertFrom-Json
        $preflight = & $cli preflight | ConvertFrom-Json
    }
    finally {
        $monitor.Stop()
    }
    $capabilities.status | Should Be 'PASS'
    $preflight.status | Should Be 'PASS'
    @($monitor.NewProcessIds).Count | Should Be 0
    @($monitor.NewVisibleWindowHandles).Count | Should Be 0
    $monitor.ForegroundCapturedByHwp | Should Be $false
}

It 'silent HWP 차단도 결과 파일을 자동으로 열지 않는다' {
    $monitor = [HwpSilentActivityMonitor]::new()
    $monitor.Start()
    try {
        $result = & $cli inspect -LiteralPath $fixtureHwp | ConvertFrom-Json
    }
    finally {
        $monitor.Stop()
    }
    $result.status | Should Be 'BLOCKED'
    @($monitor.NewProcessIds).Count | Should Be 0
    @($monitor.NewVisibleWindowHandles).Count | Should Be 0
    $monitor.ForegroundCapturedByHwp | Should Be $false
}
```

같은 감시기로 합성 HWPX `inspect`와 지원되지 않는 silent `generate`도 실행한다.
모든 명령에서 새 HWP 프로세스, 새 보이는 HWP 창과 HWP 포그라운드 획득이 `0`이어야
한다. 감시 간격은 5ms로 고정한다.

- [ ] **Step 3: 수용 시험을 실행해 통과 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\SilentExecution.Tests.ps1 -PassThru
```

Expected: PASS, 실행 중 일시적인 새 HWP 프로세스·창·포그라운드 획득도 없음.

- [ ] **Step 4: 시험 실행기 기본값을 정적으로 변경**

```powershell
param(
    [ValidateSet('Static','Native','All')]
    [string]$Suite = 'Static',
    [switch]$AllowInteractiveNative
)

if ($Suite -in 'Native','All' -and -not $AllowInteractiveNative) {
    Write-Error '네이티브 시험은 -AllowInteractiveNative의 명시적 승인이 필요합니다.'
    exit 2
}
```

`Static`은 `*.Integration.Tests.ps1`을 제외한다. `Native`는 해당 파일만 선택한다.
`All`은 두 묶음을 모두 선택하되 명시적 승인을 요구한다.

- [ ] **Step 5: 기본 시험과 승인 게이트 확인**

Run:

```powershell
& .\tests\run-tests.ps1
& .\tests\run-tests.ps1 -Suite Native
```

Expected: 첫 명령 PASS, 두 번째 명령은 시험 실행 전에 종료 코드 `2`.

- [ ] **Step 6: 커밋**

```powershell
git add tests/WindowActivityMonitor.psm1 tests/SilentExecution.Tests.ps1 tests/run-tests.ps1
git commit -m "test: enforce no-window execution by default"
```

---

### Task 8: 스킬 트리거와 공개 문서 정합성

**Files:**
- Modify: `skill/hwp-skill/SKILL.md:1-178`
- Modify: `skill/hwp-skill/agents/openai.yaml`
- Modify: `skill/hwp-skill/references/limitations.md`
- Modify: `skill/hwp-skill/references/safety.md`
- Modify: `README.md`
- Modify: `tests/Repository.Tests.ps1`

**Interfaces:**
- Consumes: 실제 Phase 1 기능 매트릭스
- Produces: 자연어 트리거와 무창 사용 계약

- [ ] **Step 1: 스킬 검색과 문서 정합성 실패 시험 작성**

```powershell
It '한글 문서 작성 요청과 무창 기본 정책을 메타데이터에 포함한다' {
    $skill = Get-Content "$PSScriptRoot/../skill/hwp-skill/SKILL.md" -Raw -Encoding UTF8
    $skill | Should Match '(?m)^description:\s+Use when'
    $skill | Should Match '한글 문서 파일'
    $skill | Should Match 'HWPX'
    $skill | Should Match 'silent'
    $skill | Should Match '포커스'
    $skill | Should Match 'GUI로 자동 전환하지 않는다'
}

It 'README가 현재 단계에서 HWP 휴대형 엔진을 완료로 과장하지 않는다' {
    $readme = Get-Content "$PSScriptRoot/../README.md" -Raw -Encoding UTF8
    $readme | Should Match 'hwp-portable.*준비되지'
    $readme | Should Match '현재 사용자 세션.*Hwp.exe.*실행하지'
}
```

- [ ] **Step 2: 시험을 실행해 기존 COM 중심 설명 RED 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\Repository.Tests.ps1 -PassThru
```

Expected: 새 메타데이터와 무창 설명이 없어 FAIL.

- [ ] **Step 3: SKILL frontmatter를 트리거 중심으로 교체**

```yaml
---
name: hwp-skill
description: Use when Codex가 HWP, HWT, HWPX 또는 "한글 문서 파일"을 읽기, 작성, 디자인, 표·이미지 삽입, 수정, 비교, 일괄 처리하거나 검증해야 할 때 사용합니다. "한글 문서로 작성해줘", "HWP로 만들어줘", "한글파일을 읽어줘" 같은 요청과 원본 보존이 중요한 공문, 보고서, 계획서, 회의록, 제안서, 스토리보드 작업에 사용합니다.
---
```

- [ ] **Step 4: 본문과 공개 문서에 Phase 1 실제 상태 기록**

다음 사실을 동일한 용어로 기록한다.

- 기본 `silent`는 현재 사용자 세션의 `Hwp.exe`를 실행하지 않는다.
- HWPX 읽기 검사는 직접 엔진으로 동작한다.
- HWP/HWT 휴대형 엔진은 이 단계에서 준비되지 않아 `silent` 읽기·작성·편집이
  `BLOCKED`다.
- `interactive`는 사용자가 현재 요청에서 한컴 창 실행을 명시한 경우에만 쓴다.
- `isolated-native`는 작업자가 구성되지 않았으면 `BLOCKED`다.
- 자동 GUI 대체와 결과 파일 자동 열기는 금지한다.

- [ ] **Step 5: `agents/openai.yaml` 재생성 및 검증**

표시명은 정확히 `HWP Skill`을 유지하고 기본 프롬프트에는 `$hwp-skill`과
`silent`를 포함한다. skill-creator의 `generate_openai_yaml.py`에 다음 인터페이스
값을 전달한다.

```text
display_name=HWP Skill
short_description=창을 띄우지 않고 HWP·HWPX 문서를 안전하게 처리합니다
default_prompt=$hwp-skill을 사용해 기본 silent 모드로 한글 문서를 처리하고 원본과 사용자 포커스를 보존해 주세요.
```

실행 명령은 다음과 같다.

```powershell
$codexRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
} else {
    [IO.Path]::GetFullPath($env:CODEX_HOME)
}
$generator = Join-Path $codexRoot 'skills\.system\skill-creator\scripts\generate_openai_yaml.py'
python $generator .\skill\hwp-skill `
  --interface 'display_name=HWP Skill' `
  --interface 'short_description=창을 띄우지 않고 HWP·HWPX 문서를 안전하게 처리합니다' `
  --interface 'default_prompt=$hwp-skill을 사용해 기본 silent 모드로 한글 문서를 처리하고 원본과 사용자 포커스를 보존해 주세요.'
```

- [ ] **Step 6: 문서 시험 통과 확인**

Run:

```powershell
Invoke-Pester -Script .\tests\Repository.Tests.ps1 -PassThru
```

Expected: PASS, SKILL.md 500줄 미만, 표시명 `HWP Skill` 유지.

- [ ] **Step 7: 커밋**

```powershell
git add skill/hwp-skill/SKILL.md skill/hwp-skill/agents/openai.yaml `
  skill/hwp-skill/references/limitations.md `
  skill/hwp-skill/references/safety.md README.md tests/Repository.Tests.ps1
git commit -m "docs: make silent HWP behavior discoverable"
```

---

## Final Verification

- [ ] **Step 1: 전체 정적 시험 실행**

Run:

```powershell
& .\tests\run-tests.ps1 -Suite Static
```

Expected: exit `0`, failed test count `0`.

- [ ] **Step 2: 공개 CLI 무창 스모크 실행**

Run:

```powershell
& .\skill\hwp-skill\scripts\Invoke-HwpSkill.ps1 capabilities
& .\skill\hwp-skill\scripts\Invoke-HwpSkill.ps1 preflight
& .\skill\hwp-skill\scripts\Invoke-HwpSkill.ps1 inspect `
  -LiteralPath .\tests\fixtures\source\native-fixture.hwp
```

Expected: 첫 두 명령 `PASS`, HWP 검사는 `BLOCKED`, 세 명령 모두 현재 세션의
HWP 프로세스 집합과 포그라운드 창을 변경하지 않음.

- [ ] **Step 3: 스킬 폴더 구조 검증**

Run:

```powershell
$skillCreator = Join-Path $env:CODEX_HOME 'skills\.system\skill-creator\scripts\quick_validate.py'
python $skillCreator .\skill\hwp-skill
```

Expected: validation success. `CODEX_HOME`이 비어 있으면 현재 사용자 프로필 아래
`.codex\skills\.system\skill-creator\scripts\quick_validate.py`를 절대 경로로
확정한 뒤 같은 명령을 실행한다.

- [ ] **Step 4: 임시 폴더 설치와 읽기 되돌림 확인**

Run:

```powershell
$installRoot = Join-Path $env:TEMP ('hwp-skill-foundation-' + [guid]::NewGuid().ToString('n'))
$result = & .\install.ps1 -DestinationRoot $installRoot
$result.Status
& (Join-Path $result.InstallPath 'scripts\Invoke-HwpSkill.ps1') capabilities
```

Expected: 설치 `PASS`, 설치본 `capabilities` `PASS`, 사용자 기존 설치는 변경되지 않음.

- [ ] **Step 5: 작업 트리와 커밋 계열 검사**

Run:

```powershell
git diff --check
git status --short
git log --oneline --decorate -10
```

Expected: `git diff --check` 출력 없음, 의도하지 않은 파일 없음, Tasks 1-8의 독립
커밋이 순서대로 존재함.

---

## Self-Review Coverage

- 설계 4장 접근법: Tasks 2-3에서 다중 엔진 선택으로 반영
- 설계 6장 전체 구조: Tasks 1-6에서 실행 컨텍스트·기능·라우터로 반영
- 설계 9장 기능 라우팅: Tasks 3, 5, 6에서 결정적 표로 반영
- 설계 10장 완전 무창: Tasks 1, 4, 7에서 강제 및 계측
- 설계 13장 명령과 보고서: Task 4에서 `capabilities`와 실행 모드 반영
- 설계 14장 오류 처리: Tasks 3, 5, 6에서 `BLOCKED` 및 자동 전환 금지
- 설계 15장 시험 우선: 모든 Task가 RED→GREEN 순서 사용
- 설계 16장 단계 A: Tasks 1-8과 Final Verification 전체가 완료 조건
- HWPX 조판, 휴대형 HWP, 렌더링과 최종 공개는 로드맵의 별도 구현 묶음이며 이
  기반의 인터페이스를 소비한다.
