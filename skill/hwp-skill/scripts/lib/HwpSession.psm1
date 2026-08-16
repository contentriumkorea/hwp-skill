Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpExecution.psm1') -ErrorAction Stop

function Test-HwpWindowsPlatform {
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Resolve-HwpSessionProcessOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Hwp,
        [int[]]$BeforeProcessIds = @(),
        [bool]$IsComObject = $true
    )

    if (-not $IsComObject) {
        return [pscustomobject]@{ Owned = $true; ProcessId = 0; Reason = 'non-com-test-double' }
    }
    if (-not (Test-HwpWindowsPlatform)) {
        return [pscustomobject]@{ Owned = $false; ProcessId = 0; Reason = 'non-windows' }
    }

    try {
        $windowHandle = [IntPtr]([int64]$Hwp.XHwpWindows.Item(0).WindowHandle)
        if ($windowHandle -eq [IntPtr]::Zero) { throw '한글 자동화 창 핸들이 비어 있습니다.' }
        if ($null -eq ('HwpNativeWindowOwnership' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HwpNativeWindowOwnership
{
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
        }
        [uint32]$windowProcessId = 0
        $threadId = [HwpNativeWindowOwnership]::GetWindowThreadProcessId($windowHandle, [ref]$windowProcessId)
        if ($threadId -eq 0 -or $windowProcessId -eq 0) { throw '창 핸들의 프로세스를 확인하지 못했습니다.' }
        $process = Get-Process -Id ([int]$windowProcessId) -ErrorAction Stop
        if (-not [string]::Equals($process.ProcessName, 'Hwp', [StringComparison]::OrdinalIgnoreCase)) {
            throw "자동화 창의 프로세스가 Hwp가 아닙니다: $($process.ProcessName)"
        }
        $wasRunning = [int]$windowProcessId -in @($BeforeProcessIds)
        [pscustomobject]@{
            Owned = -not $wasRunning
            ProcessId = [int]$windowProcessId
            Reason = if ($wasRunning) { 'existing-window-process' } else { 'new-window-process' }
        }
    }
    catch {
        [pscustomobject]@{ Owned = $false; ProcessId = 0; Reason = "ownership-unverified: $($_.Exception.Message)" }
    }
}

function Get-HwpSecurityModuleNames {
    [CmdletBinding()]
    param()

    if (-not (Test-HwpWindowsPlatform)) {
        return @()
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        'Software\HNC\HwpAutomation\Modules',
        $false
    )
    if ($null -eq $key) {
        return @()
    }

    try {
        @($key.GetValueNames() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    finally {
        $key.Dispose()
    }
}

function Get-HwpAutomationInfo {
    [CmdletBinding()]
    param(
        [scriptblock]$SecurityModuleReader = { Get-HwpSecurityModuleNames }
    )

    [object[]]$securityModules = @(
        try {
            & $SecurityModuleReader
        }
        catch {
            # 환경 정보 조회는 세션 생성 여부와 별개이므로 빈 목록으로 보고한다.
        }
    )

    [pscustomobject]@{
        IsWindows = [bool](Test-HwpWindowsPlatform)
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        CandidateProgIds = @('HWPFrame.HwpObject.2', 'HWPFrame.HwpObject')
        SecurityModules = @($securityModules)
        UnattendedOpenReady = $securityModules.Count -gt 0
        RegistryWritePerformed = $false
    }
}

function Resolve-HwpExecutionContext {
    [CmdletBinding()]
    param([AllowNull()][object]$ExecutionContext)

    if ($null -eq $ExecutionContext) {
        return New-HwpExecutionContext
    }

    $ExecutionContext
}

function New-HwpSession {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ExecutionContext = $null,
        [bool]$Visible = $false,
        [scriptblock]$ComFactory = { param($progId) New-Object -ComObject $progId },
        [scriptblock]$ProcessIdProvider = {
            @(
                Get-Process -Name Hwp -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Id
            )
        },
        [scriptblock]$ProcessOwnershipResolver = {
            param($hwp,$beforeProcessIds,$isComObject)
            Resolve-HwpSessionProcessOwnership -Hwp $hwp -BeforeProcessIds $beforeProcessIds -IsComObject:$isComObject
        },
        [ValidateRange(1, 10)]
        [int]$RetryCount = 3,
        [ValidateRange(0, 5000)]
        [int]$RetryDelayMilliseconds = 300
    )

    $resolvedExecutionContext = Resolve-HwpExecutionContext -ExecutionContext $ExecutionContext
    Assert-HwpLocalGuiAllowed -ExecutionContext $resolvedExecutionContext

    $lastErrorMessage = '등록된 ProgID를 찾지 못했습니다.'
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        foreach ($progId in 'HWPFrame.HwpObject.2', 'HWPFrame.HwpObject') {
            $hwp = $null
            try {
                [int[]]$beforeProcessIds = @(& $ProcessIdProvider)
                $hwp = & $ComFactory $progId
                if ($null -eq $hwp) {
                    throw "$progId 생성 결과가 비어 있습니다."
                }

                $isComObject = [Runtime.InteropServices.Marshal]::IsComObject($hwp)
                if ($isComObject) {
                    $version = [string]$hwp.Version
                    $null = $hwp.IsActionEnable('InsertText')
                }
                else {
                    $version = try { [string]$hwp.Version } catch { 'unknown' }
                }

                try {
                    $hwp.XHwpWindows.Item(0).Visible = $Visible
                }
                catch {
                    # 창이 만들어지기 전이거나 시험용 객체인 경우에도 세션 자체는 유효할 수 있다.
                }

                $ownership = & $ProcessOwnershipResolver $hwp $beforeProcessIds $isComObject
                if ($null -eq $ownership -or
                    -not ($ownership.PSObject.Properties.Name -contains 'Owned')) {
                    throw '프로세스 소유권 확인기가 유효한 결과를 반환하지 않았습니다.'
                }
                if ($isComObject -and -not [bool]$ownership.Owned) {
                    $reason = if ($ownership.PSObject.Properties.Name -contains 'Reason') { [string]$ownership.Reason } else { 'unknown' }
                    try { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($hwp) } catch { }
                    $hwp = $null
                    throw "새 전용 한글 프로세스 소유권을 확인하지 못했습니다: $reason"
                }

                return [pscustomobject]@{
                    Hwp = $hwp
                    ProgId = $progId
                    Version = $version
                    Owned = [bool]$ownership.Owned
                    ProcessId = if ($ownership.PSObject.Properties.Name -contains 'ProcessId') { [int]$ownership.ProcessId } else { 0 }
                    OwnershipReason = if ($ownership.PSObject.Properties.Name -contains 'Reason') { [string]$ownership.Reason } else { '' }
                    Visible = $Visible
                    Closed = $false
                }
            }
            catch {
                $lastErrorMessage = $_.Exception.Message
                if ($null -ne $hwp -and [Runtime.InteropServices.Marshal]::IsComObject($hwp)) {
                    try { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($hwp) } catch { }
                }
            }
        }

        if ($attempt -lt $RetryCount -and $RetryDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }

    throw "한컴오피스 자동화 객체를 만들 수 없습니다: $lastErrorMessage"
}

function Register-HwpSecurityModules {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [scriptblock]$SecurityModuleReader = { Get-HwpSecurityModuleNames }
    )

    try {
        [object[]]$moduleNames = @(& $SecurityModuleReader)
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command register-security-module -Data ([pscustomobject]@{
            RegisteredModules = @()
            RegistryWritePerformed = $false
        }) -Errors @("한컴 자동화 보안 모듈 등록 정보를 읽지 못했습니다: $($_.Exception.Message)")
    }

    if ($moduleNames.Count -eq 0) {
        return New-HwpResult -Status BLOCKED -Command register-security-module -Data ([pscustomobject]@{
            RegisteredModules = @()
            RegistryWritePerformed = $false
        }) -Errors @('등록된 공식 한컴 자동화 보안 모듈이 없어 파일 접근을 자동 승인할 수 없습니다.')
    }

    $registered = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($moduleName in $moduleNames) {
        if ([string]::IsNullOrWhiteSpace([string]$moduleName)) {
            continue
        }

        try {
            $enabled = [bool]$Session.Hwp.RegisterModule('FilePathCheckDLL', [string]$moduleName)
            if ($enabled) {
                $registered.Add([string]$moduleName)
            }
            else {
                $errors.Add("보안 모듈을 활성화하지 못했습니다: $moduleName")
            }
        }
        catch {
            $errors.Add("보안 모듈 활성화 중 오류가 발생했습니다: $moduleName - $($_.Exception.Message)")
        }
    }

    $data = [pscustomobject]@{
        RegisteredModules = @($registered)
        RegistryWritePerformed = $false
    }
    if ($registered.Count -eq 0) {
        return New-HwpResult -Status BLOCKED -Command register-security-module -Data $data -Errors @($errors)
    }
    if ($errors.Count -gt 0) {
        return New-HwpResult -Status PASS_WITH_WARNINGS -Command register-security-module -Data $data -Warnings @($errors)
    }

    New-HwpResult -Status PASS -Command register-security-module -Data $data
}

function Close-HwpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session
    )

    if ($Session.PSObject.Properties.Name -contains 'Closed' -and $Session.Closed) {
        return
    }

    $owned = $Session.PSObject.Properties.Name -contains 'Owned' -and [bool]$Session.Owned
    $hwp = if ($Session.PSObject.Properties.Name -contains 'Hwp') { $Session.Hwp } else { $null }
    if ($owned -and $null -ne $hwp) {
        try {
            $null = $hwp.Clear(1)
        }
        catch {
            # 문서가 없거나 시험용 객체에 Clear가 없어도 종료는 계속한다.
        }

        try {
            $hwp.Quit()
        }
        catch {
            # 이미 종료된 COM 서버도 정리 대상으로 간주한다.
        }
    }

    if ($Session.PSObject.Properties.Name -contains 'Closed') {
        $Session.Closed = $true
    }

    if ($null -ne $hwp -and [Runtime.InteropServices.Marshal]::IsComObject($hwp)) {
        try {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($hwp)
        }
        catch {
            # COM 해제 실패가 사용자 프로세스 강제 종료로 이어져서는 안 된다.
        }
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

function Invoke-HwpPreflight {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$ExecutionContext = $null,
        [switch]$RequireUnattendedOpen,
        [bool]$Visible = $false,
        [scriptblock]$ComFactory = { param($progId) New-Object -ComObject $progId },
        [scriptblock]$SecurityModuleReader = { Get-HwpSecurityModuleNames }
    )

    $warnings = [Collections.Generic.List[string]]::new()
    [object[]]$securityModules = @(
        try {
            & $SecurityModuleReader
        }
        catch {
            $warnings.Add("한컴 자동화 보안 모듈 등록 정보를 읽지 못했습니다: $($_.Exception.Message)")
        }
    )

    $session = $null
    try {
        $session = New-HwpSession -ExecutionContext (Resolve-HwpExecutionContext -ExecutionContext $ExecutionContext) -Visible $Visible -ComFactory $ComFactory
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command preflight -Data ([pscustomobject]@{
            SecurityModules = @($securityModules)
            UnattendedOpenReady = $false
            RegistryWritePerformed = $false
        }) -Warnings @($warnings) -Errors @($_.Exception.Message)
    }

    try {
        $unattendedOpenReady = $securityModules.Count -gt 0
        $data = [pscustomobject]@{
            ProgId = $session.ProgId
            Version = $session.Version
            Visible = $session.Visible
            Owned = $session.Owned
            ProcessId = $session.ProcessId
            OwnershipReason = $session.OwnershipReason
            SecurityModules = @($securityModules)
            UnattendedOpenReady = $unattendedOpenReady
            RegistryWritePerformed = $false
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        }

        if (-not $unattendedOpenReady) {
            $message = '등록된 한컴 자동화 보안 모듈이 없어 무인 문서 열기는 승인 대화상자 없이 보장할 수 없습니다.'
            if ($RequireUnattendedOpen) {
                return New-HwpResult -Status BLOCKED -Command preflight -Data $data -Warnings @($warnings) -Errors @($message)
            }
            $warnings.Add($message)
            return New-HwpResult -Status PASS_WITH_WARNINGS -Command preflight -Data $data -Warnings @($warnings)
        }

        New-HwpResult -Status PASS -Command preflight -Data $data -Warnings @($warnings)
    }
    finally {
        if ($null -ne $session) {
            Close-HwpSession -Session $session
        }
    }
}

Export-ModuleMember -Function @(
    'Get-HwpAutomationInfo',
    'New-HwpSession',
    'Register-HwpSecurityModules',
    'Close-HwpSession',
    'Invoke-HwpPreflight',
    'Resolve-HwpSessionProcessOwnership'
)
