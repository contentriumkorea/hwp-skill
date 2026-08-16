Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop

$script:SafeOperations = @(
    'replace-text',
    'insert-before',
    'insert-after',
    'set-field',
    'set-table-cell',
    'insert-table',
    'insert-image',
    'replace-image',
    'apply-char-style',
    'apply-para-style',
    'insert-page-break',
    'set-header-footer',
    'set-page-number',
    'add-bookmark',
    'add-hyperlink',
    'add-caption',
    'add-footnote',
    'add-endnote',
    'build-toc'
)
$script:AdvancedOperations = @(
    'delete-range',
    'add-table-row',
    'set-section',
    'merge-documents'
)

function Test-HwpObjectProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
}

function Get-HwpOperationClassification {
    param([AllowNull()][string]$Type)

    if ($Type -in $script:SafeOperations) {
        return 'safe'
    }
    if ($Type -in $script:AdvancedOperations) {
        return 'advanced'
    }
    ''
}

function Assert-HwpOperationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Operation,

        [bool]$ApprovedAdvanced = $false
    )

    $type = if (Test-HwpObjectProperty -InputObject $Operation -Name 'type') {
        [string]$Operation.type
    }
    else {
        ''
    }
    $declaredRisk = if (Test-HwpObjectProperty -InputObject $Operation -Name 'risk') {
        [string]$Operation.risk
    }
    else {
        ''
    }
    $classification = Get-HwpOperationClassification -Type $type
    $operationId = if (Test-HwpObjectProperty -InputObject $Operation -Name 'id') {
        [string]$Operation.id
    }
    else {
        ''
    }
    $data = [pscustomobject]@{
        OperationId = $operationId
        Type = $type
        DeclaredRisk = $declaredRisk
        RequiredRisk = $classification
        ApprovedAdvanced = $ApprovedAdvanced
    }

    if ([string]::IsNullOrWhiteSpace($classification)) {
        return New-HwpResult -Status BLOCKED -Command assert-operation -Data $data -Errors @(
            "지원하지 않는 작업 유형입니다: $type"
        )
    }
    if ($declaredRisk -ne $classification) {
        return New-HwpResult -Status BLOCKED -Command assert-operation -Data $data -Errors @(
            "작업의 위험 등급이 정의와 다릅니다: $type 작업은 $classification 이어야 합니다."
        )
    }
    if ($classification -eq 'advanced' -and -not $ApprovedAdvanced) {
        return New-HwpResult -Status BLOCKED -Command assert-operation -Data $data -Errors @(
            "고급 작업에는 approvedAdvanced=true의 명시적 승인이 필요합니다: $type"
        )
    }

    New-HwpResult -Status PASS -Command assert-operation -Data $data
}

function Test-HwpEditPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Plan
    )

    $errors = [Collections.Generic.List[string]]::new()
    $topLevelNames = @('version', 'source', 'approvedAdvanced', 'operations')
    foreach ($requiredName in $topLevelNames) {
        if (-not (Test-HwpObjectProperty -InputObject $Plan -Name $requiredName)) {
            $errors.Add("편집 계획에 필수 속성이 없습니다: $requiredName")
        }
    }
    foreach ($propertyName in @($Plan.PSObject.Properties.Name)) {
        if ($propertyName -notin $topLevelNames) {
            $errors.Add("편집 계획에 허용되지 않은 속성이 있습니다: $propertyName")
        }
    }

    $version = if (Test-HwpObjectProperty -InputObject $Plan -Name 'version') { [string]$Plan.version } else { '' }
    if ($version -ne '1.0') {
        $errors.Add('편집 계획 version은 1.0이어야 합니다.')
    }

    $source = if (Test-HwpObjectProperty -InputObject $Plan -Name 'source') { $Plan.source } else { $null }
    if ($null -eq $source) {
        $errors.Add('편집 계획 source가 비어 있습니다.')
    }
    else {
        $sourcePath = if (Test-HwpObjectProperty -InputObject $source -Name 'path') { [string]$source.path } else { '' }
        $sourceHash = if (Test-HwpObjectProperty -InputObject $source -Name 'sha256') { [string]$source.sha256 } else { '' }
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            $errors.Add('source.path가 비어 있습니다.')
        }
        if ($sourceHash -notmatch '^[a-fA-F0-9]{64}$') {
            $errors.Add('source.sha256은 64자리 SHA-256이어야 합니다.')
        }
        foreach ($propertyName in @($source.PSObject.Properties.Name)) {
            if ($propertyName -notin 'path', 'sha256') {
                $errors.Add("source에 허용되지 않은 속성이 있습니다: $propertyName")
            }
        }
    }

    $approvedAdvanced = $false
    if (Test-HwpObjectProperty -InputObject $Plan -Name 'approvedAdvanced') {
        if ($Plan.approvedAdvanced -isnot [bool]) {
            $errors.Add('approvedAdvanced는 true 또는 false여야 합니다.')
        }
        else {
            $approvedAdvanced = [bool]$Plan.approvedAdvanced
        }
    }

    $operations = @()
    if (Test-HwpObjectProperty -InputObject $Plan -Name 'operations') {
        $operations = @($Plan.operations)
    }
    if ($operations.Count -eq 0 -or ($operations.Count -eq 1 -and $null -eq $operations[0])) {
        $errors.Add('operations에는 하나 이상의 작업이 필요합니다.')
        $operations = @()
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $safeCount = 0
    $advancedCount = 0
    for ($index = 0; $index -lt $operations.Count; $index++) {
        $operation = $operations[$index]
        $prefix = "operations[$index]"
        if ($null -eq $operation) {
            $errors.Add("$prefix 작업이 비어 있습니다.")
            continue
        }

        $requiredNames = @('id', 'type', 'risk', 'target', 'expectedMatches', 'onFailure', 'verify')
        foreach ($requiredName in $requiredNames) {
            if (-not (Test-HwpObjectProperty -InputObject $operation -Name $requiredName)) {
                $errors.Add("$prefix 에 필수 속성이 없습니다: $requiredName")
            }
        }
        $allowedNames = @('id', 'type', 'risk', 'target', 'expectedMatches', 'before', 'after', 'onFailure', 'verify')
        foreach ($propertyName in @($operation.PSObject.Properties.Name)) {
            if ($propertyName -notin $allowedNames) {
                $errors.Add("$prefix 에 허용되지 않은 속성이 있습니다: $propertyName")
            }
        }

        $id = if (Test-HwpObjectProperty -InputObject $operation -Name 'id') { [string]$operation.id } else { '' }
        if ([string]::IsNullOrWhiteSpace($id)) {
            $errors.Add("$prefix 작업 ID가 비어 있습니다.")
        }
        elseif (-not $ids.Add($id)) {
            $errors.Add("중복 작업 ID가 있습니다: $id")
        }

        $type = if (Test-HwpObjectProperty -InputObject $operation -Name 'type') { [string]$operation.type } else { '' }
        $classification = Get-HwpOperationClassification -Type $type
        if ([string]::IsNullOrWhiteSpace($classification)) {
            $errors.Add("지원하지 않는 작업 유형입니다: $type")
        }
        elseif ($classification -eq 'safe') {
            $safeCount++
        }
        else {
            $advancedCount++
        }

        $risk = if (Test-HwpObjectProperty -InputObject $operation -Name 'risk') { [string]$operation.risk } else { '' }
        if ($risk -notin 'safe', 'advanced') {
            $errors.Add("$prefix risk는 safe 또는 advanced여야 합니다.")
        }
        elseif (-not [string]::IsNullOrWhiteSpace($classification) -and $risk -ne $classification) {
            $errors.Add("$prefix 위험 등급이 정의와 다릅니다: $type 작업은 $classification 이어야 합니다.")
        }

        $target = if (Test-HwpObjectProperty -InputObject $operation -Name 'target') { $operation.target } else { $null }
        $anchor = if ($null -ne $target -and (Test-HwpObjectProperty -InputObject $target -Name 'anchor')) {
            [string]$target.anchor
        }
        else {
            ''
        }
        if ([string]::IsNullOrWhiteSpace($anchor)) {
            $errors.Add("$prefix target.anchor 기준 문구가 비어 있습니다.")
        }

        $requiredTargetNames = switch ($type) {
            'set-field' { @('fieldName'); break }
            'set-table-cell' { @('tableIndex','row','column'); break }
            'add-table-row' { @('tableIndex','afterRow'); break }
            'insert-table' { @('rows','columns'); break }
            'insert-image' { @('imagePath'); break }
            'replace-image' { @('controlIndex','imagePath'); break }
            'apply-para-style' { @('align'); break }
            'set-section' { @('orientation'); break }
            'set-header-footer' { @('kind','text'); break }
            'add-bookmark' { @('name'); break }
            'add-hyperlink' { @('url'); break }
            'add-caption' { @('controlId','controlIndex','text'); break }
            'add-footnote' { @('text'); break }
            'add-endnote' { @('text'); break }
            'build-toc' { @('headingAnchors'); break }
            'merge-documents' { @('paths'); break }
            default { @(); break }
        }
        foreach ($requiredTargetName in $requiredTargetNames) {
            if ($null -eq $target -or -not (Test-HwpObjectProperty -InputObject $target -Name $requiredTargetName)) {
                $errors.Add("$prefix target에 필수 속성이 없습니다: $requiredTargetName")
            }
        }
        if ($type -eq 'apply-char-style' -and $null -ne $target -and
            -not (Test-HwpObjectProperty -InputObject $target -Name 'heightPt') -and
            -not (Test-HwpObjectProperty -InputObject $target -Name 'bold') -and
            -not (Test-HwpObjectProperty -InputObject $target -Name 'italic')) {
            $errors.Add("$prefix apply-char-style에는 heightPt, bold 또는 italic 중 하나가 필요합니다.")
        }
        foreach ($requiredTextName in @('fieldName','imagePath','align','orientation','kind','text','name','url','controlId')) {
            if ($requiredTextName -in $requiredTargetNames -and
                (Test-HwpObjectProperty -InputObject $target -Name $requiredTextName) -and
                [string]::IsNullOrWhiteSpace([string]$target.$requiredTextName)) {
                $errors.Add("$prefix target.$requiredTextName 값이 비어 있습니다.")
            }
        }
        foreach ($requiredListName in @('headingAnchors','paths')) {
            if ($requiredListName -in $requiredTargetNames -and
                (Test-HwpObjectProperty -InputObject $target -Name $requiredListName) -and
                @($target.$requiredListName).Count -eq 0) {
                $errors.Add("$prefix target.$requiredListName 목록이 비어 있습니다.")
            }
        }

        $expectedMatches = $null
        if (Test-HwpObjectProperty -InputObject $operation -Name 'expectedMatches') {
            $expectedMatches = $operation.expectedMatches
        }
        $isInteger = $expectedMatches -is [byte] -or $expectedMatches -is [sbyte] -or
            $expectedMatches -is [int16] -or $expectedMatches -is [uint16] -or
            $expectedMatches -is [int32] -or $expectedMatches -is [uint32] -or
            $expectedMatches -is [int64] -or $expectedMatches -is [uint64]
        if (-not $isInteger -or [decimal]$expectedMatches -lt 0) {
            $errors.Add("$prefix expectedMatches는 0 이상의 정수여야 합니다.")
        }
        elseif ($classification -eq 'safe' -and [long]$expectedMatches -ne 1) {
            $errors.Add("$prefix safe 작업의 expectedMatches는 정확히 1이어야 합니다.")
        }

        $onFailure = if (Test-HwpObjectProperty -InputObject $operation -Name 'onFailure') {
            [string]$operation.onFailure
        }
        else {
            ''
        }
        if ($onFailure -notin 'stop', 'skip') {
            $errors.Add("$prefix onFailure는 stop 또는 skip이어야 합니다.")
        }

        $verify = if (Test-HwpObjectProperty -InputObject $operation -Name 'verify') { $operation.verify } else { $null }
        if ($null -eq $verify -or -not (Test-HwpObjectProperty -InputObject $verify -Name 'kind') -or
            [string]::IsNullOrWhiteSpace([string]$verify.kind)) {
            $errors.Add("$prefix verify.kind가 비어 있습니다.")
        }
        if ($null -eq $verify -or -not (Test-HwpObjectProperty -InputObject $verify -Name 'expected')) {
            $errors.Add("$prefix verify.expected가 없습니다.")
        }

        if (-not [string]::IsNullOrWhiteSpace($classification)) {
            $allowed = Assert-HwpOperationAllowed -Operation $operation -ApprovedAdvanced:$approvedAdvanced
            foreach ($message in @($allowed.Errors)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$message)) {
                    $errors.Add([string]$message)
                }
            }
        }
    }

    $data = [pscustomobject]@{
        Version = $version
        OperationCount = $operations.Count
        SafeOperationCount = $safeCount
        AdvancedOperationCount = $advancedCount
        ApprovedAdvanced = $approvedAdvanced
        SupportedSafeOperations = @($script:SafeOperations)
        SupportedAdvancedOperations = @($script:AdvancedOperations)
    }
    if ($errors.Count -gt 0) {
        return New-HwpResult -Status BLOCKED -Command validate-plan -Data $data -Errors @($errors)
    }

    New-HwpResult -Status PASS -Command validate-plan -Data $data
}

function Assert-HwpRuntimeAdvancedApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Plan,
        [bool]$ApproveAdvanced = $false
    )

    $advancedOperations = @(
        @($Plan.operations) | Where-Object {
            (Get-HwpOperationClassification -Type ([string]$_.type)) -eq 'advanced'
        }
    )
    $data = [pscustomobject]@{
        AdvancedOperationCount = $advancedOperations.Count
        PlanRecordedApproval = [bool]$Plan.approvedAdvanced
        RuntimeApproval = $ApproveAdvanced
    }
    if ($advancedOperations.Count -eq 0) {
        return New-HwpResult -Status PASS -Command runtime-advanced-approval -Data $data
    }
    if (-not [bool]$Plan.approvedAdvanced) {
        return New-HwpResult -Status BLOCKED -Command runtime-advanced-approval -Data $data -Errors @(
            '고급 작업 계획에는 approvedAdvanced=true의 승인 기록이 필요합니다.'
        )
    }
    if (-not $ApproveAdvanced) {
        return New-HwpResult -Status BLOCKED -Command runtime-advanced-approval -Data $data -Errors @(
            '고급 작업을 실제 실행하려면 계획 기록과 별도로 -ApproveAdvanced 런타임 승인이 필요합니다.'
        )
    }

    New-HwpResult -Status PASS -Command runtime-advanced-approval -Data $data
}

function Import-HwpEditPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [ValidateRange(1, 104857600)]
        [long]$MaximumBytes = 10485760
    )

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw '편집 계획 경로가 파일이 아닙니다.'
        }
        if ([IO.Path]::GetExtension($resolvedPath) -ne '.json') {
            return New-HwpResult -Status BLOCKED -Command import-plan -Errors @(
                '편집 계획은 .json 파일이어야 합니다.'
            )
        }
        $fileLength = (Get-Item -LiteralPath $resolvedPath).Length
        if ($fileLength -gt $MaximumBytes) {
            return New-HwpResult -Status BLOCKED -Command import-plan -Errors @(
                "편집 계획 파일이 안전 한도 $MaximumBytes 바이트를 초과했습니다."
            )
        }
        $json = [IO.File]::ReadAllText($resolvedPath, [Text.UTF8Encoding]::new($false, $true))
        $plan = $json | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command import-plan -Errors @(
            "편집 계획 JSON을 읽을 수 없습니다: $($_.Exception.Message)"
        )
    }

    $validation = Test-HwpEditPlan -Plan $plan
    $data = [pscustomobject]@{
        Path = $resolvedPath
        Plan = $plan
        Validation = $validation.Data
    }
    if ($validation.Status -ne 'PASS') {
        return New-HwpResult -Status BLOCKED -Command import-plan -Data $data `
            -Warnings @($validation.Warnings) -Errors @($validation.Errors)
    }

    New-HwpResult -Status PASS -Command import-plan -Data $data
}

Export-ModuleMember -Function @(
    'Import-HwpEditPlan',
    'Test-HwpEditPlan',
    'Assert-HwpOperationAllowed',
    'Assert-HwpRuntimeAdvancedApproval'
)
