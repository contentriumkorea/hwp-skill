Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop

function Get-HwpWorkerPowerShellPath {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
    }
    $candidate = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    throw '최종 HWP 변환 작업자를 실행할 PowerShell을 찾지 못했습니다.'
}

function Invoke-HwpFinalHwpxToHwp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InputPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
        [scriptblock]$WorkerLauncher
    )

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
    $directory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "최종 HWP 결과 폴더가 없습니다: $directory"
    }

    if ($null -ne $WorkerLauncher) {
        $workerResult = & $WorkerLauncher $resolvedInput $resolvedOutput
        if ($null -eq $workerResult) { throw '최종 HWP 변환 작업자가 결과를 반환하지 않았습니다.' }
        if ($workerResult.PSObject.Properties.Name -contains 'Status' -and [string]$workerResult.Status -ne 'PASS') {
            throw (($workerResult.Errors | ForEach-Object { [string]$_ }) -join ' ')
        }
        return $workerResult
    }

    $workerPath = Join-Path $PSScriptRoot '../workers/Convert-HwpxToHwp.ps1'
    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
        throw "최종 HWP 변환 작업자가 없습니다: $workerPath"
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-HwpWorkerPowerShellPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($startInfo.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', $workerPath, '-InputPath', $resolvedInput, '-OutputPath', $resolvedOutput)) {
            $null = $startInfo.ArgumentList.Add([string]$argument)
        }
    }
    else {
        $quote = { param([string]$value) '\"{0}\"' -f ($value -replace '\"', '\\\"') }
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File {0} -InputPath {1} -OutputPath {2}' -f (& $quote $workerPath), (& $quote $resolvedInput), (& $quote $resolvedOutput)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw '최종 HWP 변환 작업자를 시작하지 못했습니다.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            try { $process.Kill($true) } catch { }
            throw '최종 HWP 변환이 제한 시간 180초를 초과했습니다.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $details = (($stderr, $stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' '
            throw "최종 HWP 변환 작업자가 실패했습니다: $details"
        }
        if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Leaf)) {
            throw '최종 HWP 변환 작업자가 HWP 결과를 만들지 못했습니다.'
        }
        $kind = Get-HwpFileKind -LiteralPath $resolvedOutput
        if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWP-BINARY') {
            throw '최종 변환 결과의 HWP 바이너리 형식 검증에 실패했습니다.'
        }
        [pscustomobject]@{
            Status = 'PASS'
            InputPath = $resolvedInput
            OutputPath = $resolvedOutput
            OutputSha256 = Get-HwpSha256 -LiteralPath $resolvedOutput
            ByteLength = (Get-Item -LiteralPath $resolvedOutput).Length
            WorkerProcess = $true
            HancomUsedOnlyForFinalConversion = $true
            ContentWrittenByHancom = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Invoke-HwpFinalHwpxToHwp'
)
