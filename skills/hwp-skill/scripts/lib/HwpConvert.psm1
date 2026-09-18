Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpConversionVerify.psm1') -ErrorAction Stop

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
        $sourceHash = Get-HwpSha256 -LiteralPath $resolvedInput
        $workerResult = & $WorkerLauncher $resolvedInput $resolvedOutput
        if ($null -eq $workerResult) { throw '최종 HWP 변환 작업자가 결과를 반환하지 않았습니다.' }
        if ($workerResult.PSObject.Properties.Name -contains 'Status' -and [string]$workerResult.Status -ne 'PASS') {
            throw (($workerResult.Errors | ForEach-Object { [string]$_ }) -join ' ')
        }
        if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Leaf)) {
            throw 'The converter did not create an HWP output.'
        }
        if ((Get-HwpSha256 -LiteralPath $resolvedInput) -ne $sourceHash) { throw 'Converter changed the HWPX source content.' }
        $verification = Test-HwpConvertedContent -InputPath $resolvedInput -OutputPath $resolvedOutput
        if ($verification.Status -ne 'PASS') { throw ($verification.Errors -join ' ') }
        return [pscustomobject]@{
            Status='PASS'; InputPath=$resolvedInput; OutputPath=$resolvedOutput
            OutputSha256=Get-HwpSha256 -LiteralPath $resolvedOutput
            ByteLength=(Get-Item -LiteralPath $resolvedOutput).Length
            ContentWrittenByHancom=$false; WorkerProcess=$true
            Verification=$verification
        }
    }
    # Hiding a PowerShell process does not isolate the COM server desktop.
    # No current-session Hancom fallback is allowed for final conversion.
    throw [NotSupportedException]::new('No isolated HWP converter is configured. The HWPX work file is preserved; local Hancom will not be started.')
}

Export-ModuleMember -Function @(
    'Invoke-HwpFinalHwpxToHwp'
)
