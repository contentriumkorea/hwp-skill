[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InputPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot '../lib'
Import-Module (Join-Path $lib 'HwpCommon.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $lib 'HwpExecution.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $lib 'HwpSession.psm1') -Force -ErrorAction Stop

$session = $null
try {
    $resolvedInput = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).Path
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedInput).ToLowerInvariant() -ne '.hwpx') {
        throw '최종 HWP 변환 입력은 HWPX여야 합니다.'
    }
    if ([IO.Path]::GetExtension($resolvedOutput).ToLowerInvariant() -ne '.hwp') {
        throw '최종 HWP 변환 출력은 HWP여야 합니다.'
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        throw "기존 결과를 덮어쓰지 않습니다: $resolvedOutput"
    }
    $outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "최종 HWP 결과 폴더가 없습니다: $outputDirectory"
    }

    # 이 worker에서만 한컴 COM을 사용한다. 본문·표·이미지는 이미 HWPX에 직접 저장돼 있다.
    $workerContext = New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow
    $session = New-HwpSession -ExecutionContext $workerContext -Visible:$false -RetryCount 3 -RetryDelayMilliseconds 300
    $security = Register-HwpSecurityModules -Session $session
    if ($security.Status -notin 'PASS', 'PASS_WITH_WARNINGS') {
        throw (($security.Errors | ForEach-Object { [string]$_ }) -join ' ')
    }
    if (-not [bool]$session.Hwp.Open($resolvedInput, '', 'lock:false;backup:false')) {
        throw 'HWPX를 최종 변환 작업자에서 열지 못했습니다.'
    }
    try { $session.Hwp.XHwpWindows.Item(0).Visible = $false } catch { }
    if (-not [bool]$session.Hwp.SaveAs($resolvedOutput, 'HWP', 'lock:false;backup:false')) {
        throw 'HWPX를 HWP로 최종 저장하지 못했습니다.'
    }
    $kind = Get-HwpFileKind -LiteralPath $resolvedOutput
    if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWP-BINARY') {
        throw '최종 저장 결과가 HWP 바이너리로 확인되지 않았습니다.'
    }
    [pscustomobject]@{
        Status = 'PASS'
        OutputPath = $resolvedOutput
        ByteLength = (Get-Item -LiteralPath $resolvedOutput).Length
        SecurityModules = @($security.Data.RegisteredModules)
        Visible = $false
        ContentWrittenByHancom = $false
    } | ConvertTo-Json -Compress
    exit 0
}
catch {
    [pscustomobject]@{
        Status = 'FAILED'
        Errors = @($_.Exception.Message)
        Visible = $false
        ContentWrittenByHancom = $false
    } | ConvertTo-Json -Compress
    exit 1
}
finally {
    if ($null -ne $session) {
        Close-HwpSession -Session $session
    }
}
