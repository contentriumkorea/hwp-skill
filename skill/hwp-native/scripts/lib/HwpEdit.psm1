Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpPlan.psm1') -ErrorAction Stop

function Test-HwpEditProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
}

function Get-HwpOperationId {
    param([object]$Operation)

    if (Test-HwpEditProperty -InputObject $Operation -Name 'id') {
        return [string]$Operation.id
    }
    ''
}

function Get-HwpOperationAnchor {
    param([object]$Operation)

    if ((Test-HwpEditProperty -InputObject $Operation -Name 'target') -and
        (Test-HwpEditProperty -InputObject $Operation.target -Name 'anchor')) {
        return [string]$Operation.target.anchor
    }
    ''
}

function Resolve-HwpTextTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Operation
    )

    $operationId = Get-HwpOperationId -Operation $Operation
    $anchor = Get-HwpOperationAnchor -Operation $Operation
    if ([string]::IsNullOrEmpty($anchor)) {
        return New-HwpResult -Status BLOCKED -Command resolve-text-target -Errors @(
            "작업 $operationId 의 기준 문구가 비어 있습니다."
        )
    }

    try {
        $text = [string]$Session.Hwp.GetTextFile('UNICODE', '')
    }
    catch {
        return New-HwpResult -Status FAILED -Command resolve-text-target -Errors @(
            "본문을 읽지 못했습니다: $($_.Exception.Message)"
        )
    }

    $beforeContext = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'beforeContext') {
        [string]$Operation.target.beforeContext
    }
    else {
        ''
    }
    $afterContext = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'afterContext') {
        [string]$Operation.target.afterContext
    }
    else {
        ''
    }
    $expectedMatches = if (Test-HwpEditProperty -InputObject $Operation -Name 'expectedMatches') {
        [int]$Operation.expectedMatches
    }
    else {
        1
    }

    $allMatches = [Collections.Generic.List[int]]::new()
    $candidates = [Collections.Generic.List[object]]::new()
    $searchIndex = 0
    while ($searchIndex -le $text.Length - $anchor.Length) {
        $matchIndex = $text.IndexOf($anchor, $searchIndex, [StringComparison]::Ordinal)
        if ($matchIndex -lt 0) {
            break
        }
        $allMatches.Add($matchIndex)

        $beforeMatches = $beforeContext.Length -eq 0 -or
            ($matchIndex -ge $beforeContext.Length -and
                [string]::Equals(
                    $text.Substring($matchIndex - $beforeContext.Length, $beforeContext.Length),
                    $beforeContext,
                    [StringComparison]::Ordinal
                ))
        $afterStart = $matchIndex + $anchor.Length
        $afterMatches = $afterContext.Length -eq 0 -or
            ($afterStart + $afterContext.Length -le $text.Length -and
                [string]::Equals(
                    $text.Substring($afterStart, $afterContext.Length),
                    $afterContext,
                    [StringComparison]::Ordinal
                ))
        if ($beforeMatches -and $afterMatches) {
            $candidates.Add([pscustomobject]@{
                StartIndex = $matchIndex
                AnchorOrdinal = $allMatches.Count
            })
        }

        $searchIndex = $matchIndex + [Math]::Max(1, $anchor.Length)
    }

    $data = [pscustomobject]@{
        OperationId = $operationId
        Anchor = $anchor
        AnchorCount = $allMatches.Count
        CandidateCount = $candidates.Count
        ExpectedMatches = $expectedMatches
        BeforeContext = $beforeContext
        AfterContext = $afterContext
        StartIndex = if ($candidates.Count -eq 1) { $candidates[0].StartIndex } else { -1 }
        AnchorOrdinal = if ($candidates.Count -eq 1) { $candidates[0].AnchorOrdinal } else { 0 }
        OriginalText = $text
    }
    if ($candidates.Count -ne $expectedMatches) {
        return New-HwpResult -Status BLOCKED -Command resolve-text-target -Data $data -Errors @(
            "기준 문구 후보가 예상 $expectedMatches 개와 다르게 $($candidates.Count)개입니다: $anchor"
        )
    }
    if ($candidates.Count -ne 1) {
        return New-HwpResult -Status BLOCKED -Command resolve-text-target -Data $data -Errors @(
            '현재 편집기는 한 작업당 유일한 후보 1개만 적용합니다.'
        )
    }

    New-HwpResult -Status PASS -Command resolve-text-target -Data $data
}

function Select-HwpResolvedTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Operation,

        [AllowNull()]
        [object]$Resolution = $null
    )

    if ($null -eq $Resolution) {
        $Resolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    }
    if ($Resolution.Status -ne 'PASS') {
        return $Resolution
    }

    try {
        if (-not $Session.Hwp.HAction.Run('MoveDocBegin')) {
            throw '문서 처음으로 이동하지 못했습니다.'
        }
        $find = $Session.Hwp.HParameterSet.HFindReplace
        $null = $Session.Hwp.HAction.GetDefault('RepeatFind', $find.HSet)
        $find.FindString = [string]$Resolution.Data.Anchor
        $find.Direction = 0
        $find.FindType = 1
        $find.IgnoreMessage = 1
        $find.MatchCase = 1
        $find.UseWildCards = 0
        $find.WholeWordOnly = 0

        for ($ordinal = 1; $ordinal -le [int]$Resolution.Data.AnchorOrdinal; $ordinal++) {
            if (-not $Session.Hwp.HAction.Execute('RepeatFind', $find.HSet)) {
                return New-HwpResult -Status BLOCKED -Command select-text-target -Data $Resolution.Data -Errors @(
                    "한컴오피스에서 기준 문구의 $ordinal 번째 항목을 찾지 못했습니다."
                )
            }
        }

        $selectedText = [string]$Session.Hwp.GetTextFile('UNICODE', 'saveblock')
        if (-not [string]::Equals($selectedText, [string]$Resolution.Data.Anchor, [StringComparison]::Ordinal)) {
            return New-HwpResult -Status BLOCKED -Command select-text-target -Data $Resolution.Data -Errors @(
                "선택된 문구가 계획과 다릅니다: '$selectedText'"
            )
        }

        $startPosition = $Session.Hwp.CreateSet('ListParaPos')
        $endPosition = $Session.Hwp.CreateSet('ListParaPos')
        if (-not $Session.Hwp.GetSelectedPosBySet($startPosition, $endPosition)) {
            throw '선택 영역의 시작과 끝 위치를 가져오지 못했습니다.'
        }

        New-HwpResult -Status PASS -Command select-text-target -Data ([pscustomobject]@{
            Resolution = $Resolution.Data
            SelectedText = $selectedText
            StartPosition = $startPosition
            EndPosition = $endPosition
        })
    }
    catch {
        New-HwpResult -Status FAILED -Command select-text-target -Data $Resolution.Data -Errors @(
            "기준 문구 선택 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
}

function Invoke-HwpInsertRawText {
    param(
        [Parameter(Mandatory)][object]$Session,
        [AllowEmptyString()][string]$Text
    )

    if ($Text.Length -eq 0) {
        return $true
    }
    $insert = $Session.Hwp.HParameterSet.HInsertText
    $null = $Session.Hwp.HAction.GetDefault('InsertText', $insert.HSet)
    $insert.Text = $Text
    [bool]$Session.Hwp.HAction.Execute('InsertText', $insert.HSet)
}

function Test-HwpExactTextMutation {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$ExpectedText,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object]$Data
    )

    $actualText = [string]$Session.Hwp.GetTextFile('UNICODE', '')
    if (-not [string]::Equals($actualText, $ExpectedText, [StringComparison]::Ordinal)) {
        return New-HwpResult -Status FAILED -Command $Command -Data $Data -Errors @(
            '편집 후 전체 본문 사후검증이 계획된 결과와 다릅니다.'
        )
    }
    New-HwpResult -Status PASS -Command $Command -Data $Data
}

function Invoke-HwpReplaceText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $resolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    if ($resolution.Status -ne 'PASS') {
        return $resolution
    }
    $before = if (Test-HwpEditProperty -InputObject $Operation -Name 'before') { [string]$Operation.before } else { '' }
    if ($before.Length -gt 0 -and $before -ne [string]$resolution.Data.Anchor) {
        return New-HwpResult -Status BLOCKED -Command replace-text -Data $resolution.Data -Errors @(
            'replace-text의 before 값이 선택 기준 문구와 다릅니다.'
        )
    }
    $after = if (Test-HwpEditProperty -InputObject $Operation -Name 'after') { [string]$Operation.after } else { '' }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation -Resolution $resolution
    if ($selection.Status -ne 'PASS') {
        return $selection
    }

    try {
        if ($after.Length -eq 0) {
            if (-not $Session.Hwp.HAction.Run('Delete')) {
                throw '선택 문구를 삭제하지 못했습니다.'
            }
        }
        elseif (-not (Invoke-HwpInsertRawText -Session $Session -Text $after)) {
            throw '대체 문구를 넣지 못했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command replace-text -Data $resolution.Data -Errors @($_.Exception.Message)
    }

    $original = [string]$resolution.Data.OriginalText
    $start = [int]$resolution.Data.StartIndex
    $expected = $original.Substring(0, $start) + $after + $original.Substring($start + $resolution.Data.Anchor.Length)
    $data = [pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'replace-text'
        Applied = $true
        SelectedBefore = $resolution.Data.Anchor
        WrittenText = $after
        CandidateCount = $resolution.Data.CandidateCount
    }
    Test-HwpExactTextMutation -Session $Session -ExpectedText $expected -Command replace-text -Data $data
}

function Invoke-HwpInsertRelative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $type = [string]$Operation.type
    if ($type -notin 'insert-before', 'insert-after') {
        return New-HwpResult -Status BLOCKED -Command insert-relative -Errors @(
            "상대 삽입으로 처리할 수 없는 작업입니다: $type"
        )
    }
    $insertText = if (Test-HwpEditProperty -InputObject $Operation -Name 'after') { [string]$Operation.after } else { '' }
    if ($insertText.Length -eq 0) {
        return New-HwpResult -Status BLOCKED -Command insert-relative -Errors @('삽입할 after 문구가 비어 있습니다.')
    }

    $resolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    if ($resolution.Status -ne 'PASS') {
        return $resolution
    }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation -Resolution $resolution
    if ($selection.Status -ne 'PASS') {
        return $selection
    }

    try {
        $position = if ($type -eq 'insert-before') { $selection.Data.StartPosition } else { $selection.Data.EndPosition }
        if (-not $Session.Hwp.SetPosBySet($position)) {
            throw '선택 경계로 커서를 이동하지 못했습니다.'
        }
        if (-not (Invoke-HwpInsertRawText -Session $Session -Text $insertText)) {
            throw '상대 위치에 문구를 넣지 못했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command insert-relative -Data $resolution.Data -Errors @($_.Exception.Message)
    }

    $original = [string]$resolution.Data.OriginalText
    $start = [int]$resolution.Data.StartIndex
    $anchor = [string]$resolution.Data.Anchor
    if ($type -eq 'insert-before') {
        $expected = $original.Substring(0, $start) + $insertText + $original.Substring($start)
    }
    else {
        $end = $start + $anchor.Length
        $expected = $original.Substring(0, $end) + $insertText + $original.Substring($end)
    }
    $data = [pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = $type
        Applied = $true
        Anchor = $anchor
        WrittenText = $insertText
        CandidateCount = $resolution.Data.CandidateCount
    }
    Test-HwpExactTextMutation -Session $Session -ExpectedText $expected -Command insert-relative -Data $data
}

function Invoke-HwpDeleteRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [bool]$ApprovedAdvanced = $false
    )

    $allowed = Assert-HwpOperationAllowed -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced
    if ($allowed.Status -ne 'PASS') {
        return $allowed
    }
    $resolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    if ($resolution.Status -ne 'PASS') {
        return $resolution
    }
    $before = if (Test-HwpEditProperty -InputObject $Operation -Name 'before') { [string]$Operation.before } else { '' }
    if ($before.Length -gt 0 -and $before -ne [string]$resolution.Data.Anchor) {
        return New-HwpResult -Status BLOCKED -Command delete-range -Data $resolution.Data -Errors @(
            'delete-range의 before 값이 선택 기준 문구와 다릅니다.'
        )
    }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation -Resolution $resolution
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    if (-not $Session.Hwp.HAction.Run('Delete')) {
        return New-HwpResult -Status FAILED -Command delete-range -Data $resolution.Data -Errors @(
            '선택한 범위를 삭제하지 못했습니다.'
        )
    }

    $original = [string]$resolution.Data.OriginalText
    $start = [int]$resolution.Data.StartIndex
    $expected = $original.Remove($start, $resolution.Data.Anchor.Length)
    $data = [pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'delete-range'
        Applied = $true
        DeletedText = $resolution.Data.Anchor
        CandidateCount = $resolution.Data.CandidateCount
    }
    Test-HwpExactTextMutation -Session $Session -ExpectedText $expected -Command delete-range -Data $data
}

function Invoke-HwpSetField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $fieldName = if ((Test-HwpEditProperty -InputObject $Operation -Name 'target') -and
        (Test-HwpEditProperty -InputObject $Operation.target -Name 'fieldName')) {
        [string]$Operation.target.fieldName
    }
    else {
        Get-HwpOperationAnchor -Operation $Operation
    }
    if ([string]::IsNullOrWhiteSpace($fieldName)) {
        return New-HwpResult -Status BLOCKED -Command set-field -Errors @('필드 이름이 비어 있습니다.')
    }

    $rawList = [string]$Session.Hwp.GetFieldList(0, 0)
    $fieldNames = if ([string]::IsNullOrEmpty($rawList)) { @() } else { @($rawList -split [char]2) }
    $fieldCount = @($fieldNames | Where-Object { $_ -eq $fieldName }).Count
    $expectedMatches = if (Test-HwpEditProperty -InputObject $Operation -Name 'expectedMatches') {
        [int]$Operation.expectedMatches
    }
    else {
        1
    }
    if ($fieldCount -ne $expectedMatches -or $fieldCount -ne 1) {
        return New-HwpResult -Status BLOCKED -Command set-field -Data ([pscustomobject]@{
            FieldName = $fieldName
            FieldCount = $fieldCount
            ExpectedMatches = $expectedMatches
        }) -Errors @("필드 '$fieldName' 개수가 예상과 다릅니다: $fieldCount")
    }

    $currentValue = [string]$Session.Hwp.GetFieldText($fieldName)
    if (Test-HwpEditProperty -InputObject $Operation -Name 'before') {
        $expectedBefore = [string]$Operation.before
        if (-not [string]::Equals($currentValue, $expectedBefore, [StringComparison]::Ordinal)) {
            return New-HwpResult -Status BLOCKED -Command set-field -Errors @(
                "필드 '$fieldName' 현재 값이 계획의 before와 다릅니다."
            )
        }
    }
    $newValue = if (Test-HwpEditProperty -InputObject $Operation -Name 'after') { [string]$Operation.after } else { '' }
    try {
        $null = $Session.Hwp.PutFieldText($fieldName, $newValue)
        $verifiedValue = [string]$Session.Hwp.GetFieldText($fieldName)
    }
    catch {
        return New-HwpResult -Status FAILED -Command set-field -Errors @(
            "필드 입력 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if (-not [string]::Equals($verifiedValue, $newValue, [StringComparison]::Ordinal)) {
        return New-HwpResult -Status FAILED -Command set-field -Errors @(
            "필드 '$fieldName' 값 사후검증에 실패했습니다."
        )
    }

    New-HwpResult -Status PASS -Command set-field -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'set-field'
        Applied = $true
        FieldName = $fieldName
        Before = $currentValue
        After = $verifiedValue
        CandidateCount = $fieldCount
    })
}

function Invoke-HwpEditOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [bool]$ApprovedAdvanced = $false
    )

    $allowed = Assert-HwpOperationAllowed -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced
    if ($allowed.Status -ne 'PASS') {
        return $allowed
    }

    switch ([string]$Operation.type) {
        'replace-text' { Invoke-HwpReplaceText -Session $Session -Operation $Operation; break }
        'insert-before' { Invoke-HwpInsertRelative -Session $Session -Operation $Operation; break }
        'insert-after' { Invoke-HwpInsertRelative -Session $Session -Operation $Operation; break }
        'delete-range' { Invoke-HwpDeleteRange -Session $Session -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced; break }
        'set-field' { Invoke-HwpSetField -Session $Session -Operation $Operation; break }
        default {
            New-HwpResult -Status BLOCKED -Command edit-operation -Data $allowed.Data -Errors @(
                "현재 구현에서 아직 실행할 수 없는 작업입니다: $($Operation.type)"
            )
        }
    }
}

function Save-HwpMemoryDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourcePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
    )

    $resolvedSource = Resolve-HwpLiteralPath -LiteralPath $SourcePath
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([string]::Equals($resolvedSource, $resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
        return New-HwpResult -Status BLOCKED -Command save-memory-document -Errors @(
            '원본 문서와 같은 경로에는 저장하지 않습니다.'
        )
    }
    if ([IO.Path]::GetExtension($resolvedOutput).ToLowerInvariant() -ne '.hwp') {
        return New-HwpResult -Status BLOCKED -Command save-memory-document -Errors @(
            'HWP 메모리 결과는 별도 .hwp 파일로만 저장합니다.'
        )
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        return New-HwpResult -Status BLOCKED -Command save-memory-document -Errors @(
            "기존 결과 파일을 덮어쓰지 않습니다: $resolvedOutput"
        )
    }
    $outputDirectory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        return New-HwpResult -Status BLOCKED -Command save-memory-document -Errors @(
            "결과 폴더가 존재하지 않습니다: $outputDirectory"
        )
    }

    $sourceHash = Get-HwpSha256 -LiteralPath $resolvedSource
    try {
        $base64 = [string]$Session.Hwp.GetTextFile('HWP', '')
        if ([string]::IsNullOrWhiteSpace($base64)) {
            throw '한컴오피스가 HWP 메모리 데이터를 반환하지 않았습니다.'
        }
        $bytes = [Convert]::FromBase64String($base64)
    }
    catch {
        return New-HwpResult -Status FAILED -Command save-memory-document -Errors @(
            "HWP 메모리 결과를 만들지 못했습니다: $($_.Exception.Message)"
        )
    }
    if ($bytes.Length -lt 8 -or [BitConverter]::ToString($bytes, 0, 8) -ne 'D0-CF-11-E0-A1-B1-1A-E1') {
        return New-HwpResult -Status FAILED -Command save-memory-document -Errors @(
            'HWP 메모리 결과의 OLE 시그니처가 올바르지 않습니다.'
        )
    }

    $name = [IO.Path]::GetFileNameWithoutExtension($resolvedOutput)
    $temporaryPath = [IO.Path]::Combine(
        $outputDirectory,
        ('{0}.{1}.partial.hwp' -f $name, [guid]::NewGuid().ToString('n'))
    )
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        $kind = Get-HwpFileKind -LiteralPath $temporaryPath
        if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWP-BINARY') {
            throw '임시 결과의 파일 형식 검증에 실패했습니다.'
        }
        [IO.File]::Move($temporaryPath, $resolvedOutput)
    }
    catch {
        return New-HwpResult -Status FAILED -Command save-memory-document -Errors @(
            "HWP 결과 파일을 원자적으로 저장하지 못했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    $sourceHashAfter = Get-HwpSha256 -LiteralPath $resolvedSource
    if ($sourceHashAfter -ne $sourceHash) {
        if (Test-Path -LiteralPath $resolvedOutput) {
            Remove-Item -LiteralPath $resolvedOutput -Force -ErrorAction SilentlyContinue
        }
        return New-HwpResult -Status FAILED -Command save-memory-document -Errors @(
            '저장 중 원본 문서 해시가 변경되어 결과를 폐기했습니다.'
        )
    }

    New-HwpResult -Status PASS -Command save-memory-document -Data ([pscustomobject]@{
        SourcePath = $resolvedSource
        SourceSha256 = $sourceHash
        OutputPath = $resolvedOutput
        OutputSha256 = Get-HwpSha256 -LiteralPath $resolvedOutput
        ByteLength = $bytes.Length
        SourcePreserved = $true
        HancomDiskAccess = $false
    })
}

Export-ModuleMember -Function @(
    'Resolve-HwpTextTarget',
    'Select-HwpResolvedTarget',
    'Invoke-HwpReplaceText',
    'Invoke-HwpInsertRelative',
    'Invoke-HwpDeleteRange',
    'Invoke-HwpSetField',
    'Invoke-HwpEditOperation',
    'Save-HwpMemoryDocument'
)
