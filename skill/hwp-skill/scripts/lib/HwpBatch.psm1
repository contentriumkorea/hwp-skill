Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpExecution.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpCapabilities.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpPlan.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpEdit.psm1') -ErrorAction Stop

function Test-HwpBatchPathWithin {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Candidate
    )

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidatePath = [IO.Path]::GetFullPath($Candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($rootPath, $candidatePath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-HwpBatchBroadRoot {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $resolved = [IO.Path]::GetFullPath($LiteralPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $roots = [Collections.Generic.List[string]]::new()
    $driveRoot = [IO.Path]::GetPathRoot($resolved)
    if (-not [string]::IsNullOrWhiteSpace($driveRoot)) {
        $roots.Add($driveRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    $profileRoot = [Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
        $roots.Add([IO.Path]::GetFullPath($profileRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    try {
        $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
        $roots.Add($repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
    }
    catch { }
    @($roots | Where-Object { [string]::Equals($_, $resolved, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
}

function Resolve-HwpBatchInputs {
    param(
        [AllowNull()][string[]]$InputPaths,
        [AllowEmptyString()][string]$InputDirectory,
        [bool]$Recurse,
        [ValidateRange(1, 10000)][int]$MaximumFiles
    )

    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $items = [Collections.Generic.List[string]]::new()
    $directoryMode = -not [string]::IsNullOrWhiteSpace($InputDirectory)
    $pathMode = $null -ne $InputPaths -and @($InputPaths).Count -gt 0
    if ($directoryMode -eq $pathMode) {
        return New-HwpResult -Status BLOCKED -Command resolve-batch-inputs -Errors @(
            'InputPaths 또는 InputDirectory 중 하나만 지정해야 합니다.'
        )
    }

    $resolvedDirectory = ''
    if ($directoryMode) {
        try {
            $resolvedDirectory = (Resolve-Path -LiteralPath $InputDirectory -ErrorAction Stop).Path
            if (-not (Test-Path -LiteralPath $resolvedDirectory -PathType Container)) {
                throw '입력 경로가 폴더가 아닙니다.'
            }
            if (Test-HwpBatchBroadRoot -LiteralPath $resolvedDirectory) {
                return New-HwpResult -Status BLOCKED -Command resolve-batch-inputs -Data ([pscustomobject]@{
                    InputDirectory = $resolvedDirectory
                    DirectoryMode = $true
                    Paths = @()
                }) -Errors @('드라이브 루트, 사용자 프로필 루트 또는 저장소 루트는 일괄 입력 폴더로 사용할 수 없습니다.')
            }
            $parameters = @{
                LiteralPath = $resolvedDirectory
                File = $true
                ErrorAction = 'Stop'
            }
            if ($Recurse) { $parameters.Recurse = $true }
            $found = @(
                Get-ChildItem @parameters |
                    Where-Object {
                        $_.Extension.ToLowerInvariant() -in '.hwp','.hwt','.hwpx' -and
                        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
                    } |
                    Sort-Object FullName
            )
            if ($found.Count -gt $MaximumFiles) {
                return New-HwpResult -Status BLOCKED -Command resolve-batch-inputs -Errors @(
                    "일괄 입력 파일이 안전 한도 $MaximumFiles 개를 초과했습니다."
                )
            }
            foreach ($file in $found) { $items.Add($file.FullName) }
        }
        catch {
            $errors.Add("일괄 입력 폴더를 열거하지 못했습니다: $($_.Exception.Message)")
        }
    }
    else {
        if (@($InputPaths).Count -gt $MaximumFiles) {
            return New-HwpResult -Status BLOCKED -Command resolve-batch-inputs -Errors @(
                "일괄 입력 파일이 안전 한도 $MaximumFiles 개를 초과했습니다."
            )
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($pathValue in @($InputPaths)) {
            try {
                $resolved = (Resolve-Path -LiteralPath ([string]$pathValue) -ErrorAction Stop).Path
                if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw '입력 경로가 파일이 아닙니다.' }
                if ([IO.Path]::GetExtension($resolved).ToLowerInvariant() -notin '.hwp','.hwt','.hwpx') {
                    throw 'HWP, HWT 또는 HWPX 파일만 일괄 처리할 수 있습니다.'
                }
                if ($seen.Add($resolved)) { $items.Add($resolved) }
                else { $warnings.Add("중복 입력을 한 번만 처리합니다: $resolved") }
            }
            catch {
                $errors.Add("일괄 입력 파일을 확인하지 못했습니다: $pathValue - $($_.Exception.Message)")
            }
        }
    }
    if ($items.Count -eq 0 -and $errors.Count -eq 0) {
        $warnings.Add('처리할 HWP, HWT 또는 HWPX 파일이 없습니다.')
    }
    $data = [pscustomobject]@{
        InputDirectory = $resolvedDirectory
        DirectoryMode = $directoryMode
        Paths = @($items)
    }
    if ($errors.Count -gt 0) {
        return New-HwpResult -Status BLOCKED -Command resolve-batch-inputs -Data $data -Warnings @($warnings) -Errors @($errors)
    }
    $status = if ($warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }
    New-HwpResult -Status $status -Command resolve-batch-inputs -Data $data -Warnings @($warnings)
}

function Copy-HwpBatchPlanForSource {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$SourceSha256
    )

    $copy = ($Plan | ConvertTo-Json -Depth 100) | ConvertFrom-Json -Depth 100
    $copy.source.path = $SourcePath
    $copy.source.sha256 = $SourceSha256
    $copy
}

function New-HwpBatchItemResult {
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')][string]$Status,
        [string]$InputPath,
        [string]$InputSha256 = '',
        [string]$DetectedKind = '',
        [string]$OutputPath = '',
        [AllowNull()][object]$Inspection = $null,
        [AllowNull()][object]$ApplyResult = $null,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    [pscustomobject]@{
        Status = $Status
        InputPath = $InputPath
        InputSha256 = $InputSha256
        DetectedKind = $DetectedKind
        OutputPath = $OutputPath
        Inspection = $Inspection
        ApplyResult = $ApplyResult
        Warnings = @($Warnings)
        Errors = @($Errors)
    }
}

function New-HwpBatchResult {
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')][string]$Status,
        [bool]$DryRun,
        [string]$InputDirectory = '',
        [string]$OutputDirectory = '',
        [object[]]$Items = @(),
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $data = [pscustomobject]@{
        DryRun = $DryRun
        InputDirectory = $InputDirectory
        OutputDirectory = $OutputDirectory
        ItemCount = @($Items).Count
        Items = @($Items)
    }
    $result = New-HwpResult -Status $Status -Command batch -Data $data -Warnings $Warnings -Errors $Errors
    foreach ($property in $data.PSObject.Properties) {
        $result | Add-Member NoteProperty $property.Name $property.Value
    }
    $result
}

function Invoke-HwpBatch {
    [CmdletBinding(DefaultParameterSetName = 'Paths')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Paths')]
        [ValidateNotNullOrEmpty()][string[]]$InputPaths,

        [Parameter(Mandatory, ParameterSetName = 'Directory')]
        [ValidateNotNullOrEmpty()][string]$InputDirectory,

        [Parameter(Mandatory)][ValidateNotNull()][object]$Plan,
        [string]$OutputDirectory = '',
        [switch]$Apply,
        [switch]$ApproveAdvanced,
        [Parameter(ParameterSetName = 'Directory')][switch]$Recurse,
        [ValidateRange(1, 10000)][int]$MaximumFiles = 100,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$Inspector = {
            param($path, $executionContext, $capabilities)
            Get-HwpInspection -LiteralPath $path -ExecutionContext $executionContext -Capabilities $capabilities
        },
        [scriptblock]$ApplyInvoker = {
            param($path,$itemPlan,$output,$approveAdvanced,$executionContext,$capabilities)
            Invoke-HwpApply -LiteralPath $path -Plan $itemPlan -OutputPath $output -ApproveAdvanced:$approveAdvanced `
                -ExecutionContext $executionContext -Capabilities $capabilities
        }
    )

    $dryRun = -not [bool]$Apply
    $baseValidation = Test-HwpEditPlan -Plan $Plan
    if ($baseValidation.Status -ne 'PASS') {
        return New-HwpBatchResult -Status BLOCKED -DryRun:$dryRun -Errors @($baseValidation.Errors)
    }
    if ($Apply) {
        $runtimeApproval = Assert-HwpRuntimeAdvancedApproval -Plan $Plan -ApproveAdvanced:([bool]$ApproveAdvanced)
        if ($runtimeApproval.Status -ne 'PASS') {
            return New-HwpBatchResult -Status BLOCKED -DryRun:$dryRun -Errors @($runtimeApproval.Errors)
        }
    }
    $resolved = if ($PSCmdlet.ParameterSetName -eq 'Directory') {
        Resolve-HwpBatchInputs -InputPaths $null -InputDirectory $InputDirectory -Recurse:([bool]$Recurse) -MaximumFiles $MaximumFiles
    }
    else {
        Resolve-HwpBatchInputs -InputPaths $InputPaths -InputDirectory '' -Recurse:$false -MaximumFiles $MaximumFiles
    }
    if ($resolved.Status -notin 'PASS','PASS_WITH_WARNINGS') {
        return New-HwpBatchResult -Status BLOCKED -DryRun:$dryRun -Warnings @($resolved.Warnings) -Errors @($resolved.Errors)
    }
    $warnings = [Collections.Generic.List[string]]::new()
    foreach ($message in @($resolved.Warnings)) { $warnings.Add([string]$message) }

    $resolvedOutput = ''
    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        try {
            $resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory -ErrorAction Stop).Path
            if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Container)) { throw '출력 경로가 폴더가 아닙니다.' }
            if ($resolved.Data.DirectoryMode) {
                if (-not (Test-HwpBatchPathWithin -Root $resolved.Data.InputDirectory -Candidate $resolvedOutput)) {
                    return New-HwpBatchResult -Status BLOCKED -DryRun:$dryRun -InputDirectory $resolved.Data.InputDirectory `
                        -OutputDirectory $resolvedOutput -Errors @('출력 폴더는 입력 폴더와 같거나 입력 폴더 안에 있어야 합니다.')
                }
            }
            else {
                foreach ($path in @($resolved.Data.Paths)) {
                    $parent = [IO.Path]::GetDirectoryName($path)
                    if (-not (Test-HwpBatchPathWithin -Root $parent -Candidate $resolvedOutput)) {
                        return New-HwpBatchResult -Status BLOCKED -DryRun:$dryRun -OutputDirectory $resolvedOutput `
                            -Errors @("출력 폴더는 각 입력 파일 폴더 안에 있어야 합니다: $path")
                    }
                }
            }
        }
        catch {
            return New-HwpBatchResult -Status BLOCKED -DryRun:$dryRun -Errors @("출력 폴더를 확인하지 못했습니다: $($_.Exception.Message)")
        }
    }
    elseif ($Apply) {
        if ($resolved.Data.DirectoryMode) { $resolvedOutput = $resolved.Data.InputDirectory }
    }

    $items = [Collections.Generic.List[object]]::new()
    foreach ($path in @($resolved.Data.Paths)) {
        try {
            $kind = Get-HwpFileKind -LiteralPath $path
            $sha = Get-HwpSha256 -LiteralPath $path
        }
        catch {
            $items.Add((New-HwpBatchItemResult -Status BLOCKED -InputPath $path -Errors @($_.Exception.Message)))
            continue
        }
        if (-not $kind.ExtensionMatches) {
            $items.Add((New-HwpBatchItemResult -Status BLOCKED -InputPath $path -InputSha256 $sha `
                -DetectedKind $kind.DetectedKind -Errors @('확장자와 실제 파일 형식이 다릅니다.')))
            continue
        }
        $inspection = & $Inspector $path $ExecutionContext $Capabilities
        if ($null -eq $inspection -or $inspection.Status -notin 'PASS','PASS_WITH_WARNINGS') {
            $itemErrors = if ($null -eq $inspection) { @('검사기가 결과를 반환하지 않았습니다.') } else { @($inspection.Errors) }
            $items.Add((New-HwpBatchItemResult -Status BLOCKED -InputPath $path -InputSha256 $sha `
                -DetectedKind $kind.DetectedKind -Inspection $inspection -Errors $itemErrors))
            continue
        }
        $itemPlan = Copy-HwpBatchPlanForSource -Plan $Plan -SourcePath $path -SourceSha256 $sha
        $planValidation = Test-HwpEditPlan -Plan $itemPlan
        if ($planValidation.Status -ne 'PASS') {
            $items.Add((New-HwpBatchItemResult -Status BLOCKED -InputPath $path -InputSha256 $sha `
                -DetectedKind $kind.DetectedKind -Inspection $inspection -Errors @($planValidation.Errors)))
            continue
        }
        if ($dryRun) {
            $itemWarnings = [Collections.Generic.List[string]]::new()
            foreach ($message in @($inspection.Warnings)) { $itemWarnings.Add([string]$message) }
            if ($kind.DetectedKind -eq 'HWPX-ZIP') {
                $itemWarnings.Add('HWPX는 읽기 검사는 가능하지만 현재 네이티브 편집 적용은 지원하지 않습니다.')
            }
            $itemStatus = if ($itemWarnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }
            $items.Add((New-HwpBatchItemResult -Status $itemStatus -InputPath $path -InputSha256 $sha `
                -DetectedKind $kind.DetectedKind -Inspection $inspection -Warnings @($itemWarnings)))
            continue
        }
        if ($kind.DetectedKind -ne 'HWP-BINARY') {
            $items.Add((New-HwpBatchItemResult -Status BLOCKED -InputPath $path -InputSha256 $sha `
                -DetectedKind $kind.DetectedKind -Inspection $inspection -Errors @('현재 일괄 편집 적용은 HWP/HWT 바이너리만 지원합니다.')))
            continue
        }
        $itemOutputDirectory = if ($resolvedOutput.Length -gt 0) { $resolvedOutput } else { [IO.Path]::GetDirectoryName($path) }
        $baseOutput = [IO.Path]::Combine($itemOutputDirectory, ([IO.Path]::GetFileNameWithoutExtension($path) + '.hwp'))
        $outputPath = Get-HwpVersionedPath -LiteralPath $baseOutput
        try {
            $applyResult = & $ApplyInvoker $path $itemPlan $outputPath ([bool]$ApproveAdvanced) $ExecutionContext $Capabilities
        }
        catch {
            $items.Add((New-HwpBatchItemResult -Status FAILED -InputPath $path -InputSha256 $sha `
                -DetectedKind $kind.DetectedKind -OutputPath $outputPath -Inspection $inspection `
                -Errors @("일괄 적용 호출 중 오류가 발생했습니다: $($_.Exception.Message)")))
            continue
        }
        $actualOutput = if ($null -ne $applyResult -and $applyResult.PSObject.Properties.Name -contains 'OutputPath') {
            [string]$applyResult.OutputPath
        }
        else { $outputPath }
        $items.Add((New-HwpBatchItemResult -Status ([string]$applyResult.Status) -InputPath $path `
            -InputSha256 $sha -DetectedKind $kind.DetectedKind -OutputPath $actualOutput `
            -Inspection $inspection -ApplyResult $applyResult -Warnings @($applyResult.Warnings) -Errors @($applyResult.Errors)))
    }

    $failedCount = @($items | Where-Object Status -eq 'FAILED').Count
    $blockedCount = @($items | Where-Object Status -eq 'BLOCKED').Count
    $warningCount = @($items | Where-Object Status -eq 'PASS_WITH_WARNINGS').Count
    $passedCount = @($items | Where-Object { $_.Status -in 'PASS','PASS_WITH_WARNINGS' }).Count
    $status = if ($failedCount -gt 0) { 'FAILED' }
    elseif ($blockedCount -gt 0 -and $passedCount -eq 0) { 'BLOCKED' }
    elseif ($blockedCount -gt 0 -or $warningCount -gt 0 -or $warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' }
    else { 'PASS' }
    if ($blockedCount -gt 0 -and $passedCount -gt 0) {
        $warnings.Add("일부 항목이 차단되었습니다: $blockedCount 개")
    }
    New-HwpBatchResult -Status $status -DryRun:$dryRun -InputDirectory $resolved.Data.InputDirectory `
        -OutputDirectory $resolvedOutput -Items @($items) -Warnings @($warnings)
}

Export-ModuleMember -Function @(
    'Resolve-HwpBatchInputs',
    'Invoke-HwpBatch'
)
