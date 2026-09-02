Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpExecution.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpCapabilities.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpBackendRouter.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpPlan.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpSession.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1') -ErrorAction Stop

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

function Get-HwpControlsById {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$CtrlId,
        [ValidateRange(1, 100000)][int]$MaximumControls = 10000
    )

    $controls = [Collections.Generic.List[object]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $control = $Session.Hwp.HeadCtrl
    $scanned = 0
    while ($null -ne $control) {
        if ($scanned -ge $MaximumControls) {
            throw "컨트롤 수가 안전 한도 $MaximumControls 개를 초과했습니다."
        }
        $instanceId = try { [string]$control.GetCtrlInstID() } catch { '' }
        $identity = if ([string]::IsNullOrWhiteSpace($instanceId)) {
            'runtime:{0}' -f [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($control)
        }
        else {
            'instance:{0}' -f $instanceId
        }
        if (-not $visited.Add($identity)) {
            break
        }
        if ([string]$control.CtrlID -eq $CtrlId) {
            $controls.Add($control)
        }
        $control = try { $control.Next } catch { $null }
        $scanned++
    }
    @($controls)
}

function Enter-HwpTableCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [ValidateRange(1, 1000)][int]$TableIndex,
        [ValidateRange(1, 1000)][int]$Row,
        [ValidateRange(1, 1000)][int]$Column
    )

    try {
        $tables = @(Get-HwpControlsById -Session $Session -CtrlId 'tbl')
        if ($TableIndex -gt $tables.Count) {
            return New-HwpResult -Status BLOCKED -Command enter-table-cell -Data ([pscustomobject]@{
                TableIndex = $TableIndex
                TableCount = $tables.Count
                Row = $Row
                Column = $Column
            }) -Errors @("표 인덱스가 범위를 벗어났습니다: $TableIndex / $($tables.Count)")
        }
        $table = $tables[$TableIndex - 1]
        if (-not $Session.Hwp.SetPosBySet($table.GetAnchorPos(0))) {
            throw '표의 기준 위치로 이동하지 못했습니다.'
        }
        $found = [string]$Session.Hwp.FindCtrl()
        if ($found -ne 'tbl') {
            throw "대상 위치에서 표 컨트롤을 찾지 못했습니다: $found"
        }
        if (-not $Session.Hwp.HAction.Run('ShapeObjTableSelCell')) {
            throw '표의 첫 셀을 선택하지 못했습니다.'
        }
        for ($rowIndex = 1; $rowIndex -lt $Row; $rowIndex++) {
            if (-not $Session.Hwp.HAction.Run('TableLowerCell')) {
                return New-HwpResult -Status BLOCKED -Command enter-table-cell -Errors @(
                    "표 $TableIndex 에 $Row 번째 행이 없습니다."
                )
            }
        }
        for ($columnIndex = 1; $columnIndex -lt $Column; $columnIndex++) {
            if (-not $Session.Hwp.HAction.Run('TableRightCell')) {
                return New-HwpResult -Status BLOCKED -Command enter-table-cell -Errors @(
                    "표 $TableIndex 의 $Row 번째 행에 $Column 번째 열이 없습니다."
                )
            }
        }
        $fieldState = [int]$Session.Hwp.CurFieldState
        if (($fieldState -band 15) -ne 1) {
            return New-HwpResult -Status BLOCKED -Command enter-table-cell -Errors @(
                "대상 위치가 표 셀이 아닙니다: CurFieldState=$fieldState"
            )
        }

        New-HwpResult -Status PASS -Command enter-table-cell -Data ([pscustomobject]@{
            TableIndex = $TableIndex
            TableCount = $tables.Count
            Row = $Row
            Column = $Column
            FieldState = $fieldState
            TableControl = $table
        })
    }
    catch {
        New-HwpResult -Status FAILED -Command enter-table-cell -Errors @(
            "표 셀 이동 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
}

function Invoke-HwpInsertTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $rows = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'rows') { [int]$Operation.target.rows } else { 0 }
    $columns = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'columns') { [int]$Operation.target.columns } else { 0 }
    if ($rows -lt 1 -or $rows -gt 100 -or $columns -lt 1 -or $columns -gt 100) {
        return New-HwpResult -Status BLOCKED -Command insert-table -Errors @(
            '표 행과 열은 각각 1~100 범위여야 합니다.'
        )
    }
    $placement = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'placement') {
        [string]$Operation.target.placement
    }
    else {
        'after'
    }
    if ($placement -notin 'before', 'after') {
        return New-HwpResult -Status BLOCKED -Command insert-table -Errors @('표 placement는 before 또는 after여야 합니다.')
    }

    $beforeCount = @(Get-HwpControlsById -Session $Session -CtrlId 'tbl').Count
    $resolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    if ($resolution.Status -ne 'PASS') { return $resolution }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation -Resolution $resolution
    if ($selection.Status -ne 'PASS') { return $selection }

    try {
        $position = if ($placement -eq 'before') { $selection.Data.StartPosition } else { $selection.Data.EndPosition }
        if (-not $Session.Hwp.SetPosBySet($position)) {
            throw '표 삽입 기준 위치로 이동하지 못했습니다.'
        }
        if (-not $Session.Hwp.HAction.Run('BreakPara')) {
            throw '표 삽입용 문단을 만들지 못했습니다.'
        }
        $table = $Session.Hwp.HParameterSet.HTableCreation
        $null = $Session.Hwp.HAction.GetDefault('TableCreate', $table.HSet)
        $table.Rows = [uint16]$rows
        $table.Cols = [uint16]$columns
        $table.WidthType = 0
        $table.HeightType = 0
        if (-not $Session.Hwp.HAction.Execute('TableCreate', $table.HSet)) {
            throw '한컴오피스가 표를 만들지 못했습니다.'
        }
        $afterCount = @(Get-HwpControlsById -Session $Session -CtrlId 'tbl').Count
    }
    catch {
        return New-HwpResult -Status FAILED -Command insert-table -Errors @(
            "표 삽입 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1) {
        return New-HwpResult -Status FAILED -Command insert-table -Errors @(
            "표 개수 사후검증에 실패했습니다: $beforeCount -> $afterCount"
        )
    }

    New-HwpResult -Status PASS -Command insert-table -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'insert-table'
        Applied = $true
        Rows = $rows
        Columns = $columns
        Placement = $placement
        TableCountBefore = $beforeCount
        TableCountAfter = $afterCount
    })
}

function Invoke-HwpSetTableCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $tableIndex = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'tableIndex') { [int]$Operation.target.tableIndex } else { 0 }
    $row = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'row') { [int]$Operation.target.row } else { 0 }
    $column = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'column') { [int]$Operation.target.column } else { 0 }
    if ($tableIndex -lt 1 -or $row -lt 1 -or $column -lt 1) {
        return New-HwpResult -Status BLOCKED -Command set-table-cell -Errors @(
            'tableIndex, row, column은 모두 1 이상의 정수여야 합니다.'
        )
    }
    $entered = Enter-HwpTableCell -Session $Session -TableIndex $tableIndex -Row $row -Column $column
    if ($entered.Status -ne 'PASS') { return $entered }

    $temporaryField = '__hwp_native_cell_' + [guid]::NewGuid().ToString('n')
    $fieldAssigned = $false
    try {
        if (-not $Session.Hwp.SetCurFieldName($temporaryField, 0, '', '')) {
            throw '대상 셀에 임시 검증 필드를 지정하지 못했습니다.'
        }
        $fieldAssigned = $true
        $currentValue = [string]$Session.Hwp.GetFieldText($temporaryField)
        if (Test-HwpEditProperty -InputObject $Operation -Name 'before') {
            $expectedBefore = [string]$Operation.before
            if (-not [string]::Equals($currentValue, $expectedBefore, [StringComparison]::Ordinal)) {
                return New-HwpResult -Status BLOCKED -Command set-table-cell -Errors @(
                    "표 $tableIndex 의 ($row,$column) 셀 값이 before와 다릅니다."
                )
            }
        }
        $newValue = if (Test-HwpEditProperty -InputObject $Operation -Name 'after') { [string]$Operation.after } else { '' }
        $null = $Session.Hwp.PutFieldText($temporaryField, $newValue)
        $verifiedValue = [string]$Session.Hwp.GetFieldText($temporaryField)
        if (-not [string]::Equals($verifiedValue, $newValue, [StringComparison]::Ordinal)) {
            throw '셀 값 사후검증에 실패했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command set-table-cell -Errors @(
            "표 셀 변경 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        if ($fieldAssigned) {
            try {
                $null = $Session.Hwp.MoveToField($temporaryField, $true, $true, $false)
                $null = $Session.Hwp.SetCurFieldName('', 0, '', '')
            }
            catch {
                # 임시 필드 정리 실패는 아래 존재 여부 검증에서 보고한다.
            }
        }
    }

    if ([bool]$Session.Hwp.FieldExist($temporaryField)) {
        return New-HwpResult -Status FAILED -Command set-table-cell -Errors @(
            '셀 변경에 사용한 임시 필드를 제거하지 못했습니다.'
        )
    }
    New-HwpResult -Status PASS -Command set-table-cell -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'set-table-cell'
        Applied = $true
        TableIndex = $tableIndex
        Row = $row
        Column = $column
        Before = $currentValue
        After = $verifiedValue
        TemporaryFieldRemoved = $true
    })
}

function Invoke-HwpAddTableRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [bool]$ApprovedAdvanced = $false
    )

    $allowed = Assert-HwpOperationAllowed -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced
    if ($allowed.Status -ne 'PASS') { return $allowed }
    $tableIndex = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'tableIndex') { [int]$Operation.target.tableIndex } else { 0 }
    $afterRow = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'afterRow') { [int]$Operation.target.afterRow } else { 0 }
    if ($tableIndex -lt 1 -or $afterRow -lt 1) {
        return New-HwpResult -Status BLOCKED -Command add-table-row -Errors @('tableIndex와 afterRow는 1 이상이어야 합니다.')
    }
    $entered = Enter-HwpTableCell -Session $Session -TableIndex $tableIndex -Row $afterRow -Column 1
    if ($entered.Status -ne 'PASS') { return $entered }
    if (-not $Session.Hwp.HAction.Run('TableInsertLowerRow')) {
        return New-HwpResult -Status FAILED -Command add-table-row -Errors @('지정 행 아래에 새 행을 추가하지 못했습니다.')
    }
    $verified = Enter-HwpTableCell -Session $Session -TableIndex $tableIndex -Row ($afterRow + 1) -Column 1
    if ($verified.Status -ne 'PASS') {
        return New-HwpResult -Status FAILED -Command add-table-row -Errors @('추가된 행을 다시 찾지 못했습니다.')
    }

    New-HwpResult -Status PASS -Command add-table-row -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'add-table-row'
        Applied = $true
        TableIndex = $tableIndex
        AfterRow = $afterRow
        VerifiedRow = $afterRow + 1
    })
}

function Resolve-HwpImageFile {
    param([Parameter(Mandatory)][string]$LiteralPath)

    $resolved = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw '이미지 경로가 파일이 아닙니다.'
    }
    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($extension -notin '.png', '.jpg', '.jpeg', '.gif', '.bmp') {
        throw 'PNG, JPEG, GIF 또는 BMP 이미지만 지원합니다.'
    }
    $bytes = [IO.File]::ReadAllBytes($resolved)
    $matches = switch ($extension) {
        '.png' { $bytes.Length -ge 8 -and [BitConverter]::ToString($bytes, 0, 8) -eq '89-50-4E-47-0D-0A-1A-0A' }
        { $_ -in '.jpg', '.jpeg' } { $bytes.Length -ge 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF }
        '.gif' { $bytes.Length -ge 6 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 6) -match '^GIF8[79]a$' }
        '.bmp' { $bytes.Length -ge 2 -and $bytes[0] -eq 0x42 -and $bytes[1] -eq 0x4D }
        default { $false }
    }
    if (-not $matches) {
        throw '이미지 확장자와 실제 시그니처가 다릅니다.'
    }
    [pscustomobject]@{
        Path = $resolved
        Extension = $extension
        Sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        ByteLength = $bytes.Length
    }
}

function Get-HwpPictureControls {
    param([Parameter(Mandatory)][object]$Session)

    @(
        Get-HwpControlsById -Session $Session -CtrlId 'gso' |
            Where-Object { [string]$_.UserDesc -match '그림|picture|image' }
    )
}

function Invoke-HwpInsertImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [AllowNull()][scriptblock]$SecurityModuleReader = $null
    )

    try {
        $imagePath = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'imagePath') {
            [string]$Operation.target.imagePath
        }
        else {
            ''
        }
        $image = Resolve-HwpImageFile -LiteralPath $imagePath
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command insert-image -Errors @($_.Exception.Message)
    }

    $security = if ($null -eq $SecurityModuleReader) {
        Register-HwpSecurityModules -Session $Session
    }
    else {
        Register-HwpSecurityModules -Session $Session -SecurityModuleReader $SecurityModuleReader
    }
    if ($security.Status -eq 'BLOCKED' -or $security.Status -eq 'FAILED') {
        return New-HwpResult -Status BLOCKED -Command insert-image -Data $image `
            -Warnings @($security.Warnings) -Errors @($security.Errors)
    }

    $widthMm = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'widthMm') { [int][Math]::Round([double]$Operation.target.widthMm) } else { 20 }
    $heightMm = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'heightMm') { [int][Math]::Round([double]$Operation.target.heightMm) } else { 20 }
    if ($widthMm -lt 1 -or $heightMm -lt 1) {
        return New-HwpResult -Status BLOCKED -Command insert-image -Errors @('이미지 크기는 1mm 이상이어야 합니다.')
    }
    $beforeCount = @(Get-HwpPictureControls -Session $Session).Count
    $resolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    if ($resolution.Status -ne 'PASS') { return $resolution }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation -Resolution $resolution
    if ($selection.Status -ne 'PASS') { return $selection }

    try {
        $placement = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'placement') { [string]$Operation.target.placement } else { 'after' }
        $position = if ($placement -eq 'before') { $selection.Data.StartPosition } else { $selection.Data.EndPosition }
        if (-not $Session.Hwp.SetPosBySet($position)) { throw '이미지 삽입 위치로 이동하지 못했습니다.' }
        if (-not $Session.Hwp.HAction.Run('BreakPara')) { throw '이미지 삽입용 문단을 만들지 못했습니다.' }
        $picture = $Session.Hwp.InsertPicture($image.Path, $true, 1, $false, $false, 0, $widthMm, $heightMm)
        if ($null -eq $picture) { throw 'InsertPicture가 결과 컨트롤을 반환하지 않았습니다.' }
        $afterCount = @(Get-HwpPictureControls -Session $Session).Count
    }
    catch {
        return New-HwpResult -Status FAILED -Command insert-image -Errors @(
            "이미지 삽입 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1) {
        return New-HwpResult -Status FAILED -Command insert-image -Errors @('그림 컨트롤 개수 사후검증에 실패했습니다.')
    }

    New-HwpResult -Status $security.Status -Command insert-image -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'insert-image'
        Applied = $true
        ImagePath = $image.Path
        ImageSha256 = $image.Sha256
        Embedded = $true
        WidthMm = $widthMm
        HeightMm = $heightMm
        PictureCountBefore = $beforeCount
        PictureCountAfter = $afterCount
    }) -Warnings @($security.Warnings)
}

function Invoke-HwpReplaceImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [AllowNull()][scriptblock]$SecurityModuleReader = $null
    )

    try {
        $image = Resolve-HwpImageFile -LiteralPath ([string]$Operation.target.imagePath)
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command replace-image -Errors @($_.Exception.Message)
    }
    $security = if ($null -eq $SecurityModuleReader) {
        Register-HwpSecurityModules -Session $Session
    }
    else {
        Register-HwpSecurityModules -Session $Session -SecurityModuleReader $SecurityModuleReader
    }
    if ($security.Status -eq 'BLOCKED' -or $security.Status -eq 'FAILED') {
        return New-HwpResult -Status BLOCKED -Command replace-image -Data $image -Errors @($security.Errors)
    }
    $controlIndex = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'controlIndex') { [int]$Operation.target.controlIndex } else { 0 }
    $pictures = @(Get-HwpPictureControls -Session $Session)
    if ($controlIndex -lt 1 -or $controlIndex -gt $pictures.Count) {
        return New-HwpResult -Status BLOCKED -Command replace-image -Errors @(
            "그림 컨트롤 인덱스가 범위를 벗어났습니다: $controlIndex / $($pictures.Count)"
        )
    }
    $widthMm = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'widthMm') { [int][Math]::Round([double]$Operation.target.widthMm) } else { 20 }
    $heightMm = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'heightMm') { [int][Math]::Round([double]$Operation.target.heightMm) } else { 20 }
    try {
        $anchor = $pictures[$controlIndex - 1].GetAnchorPos(0)
        if (-not $Session.Hwp.SetPosBySet($anchor)) { throw '기존 그림 위치로 이동하지 못했습니다.' }
        $found = [string]$Session.Hwp.FindCtrl()
        if ($found -ne 'gso') { throw "기존 그림 컨트롤을 선택하지 못했습니다: $found" }
        if (-not $Session.Hwp.HAction.Run('Delete')) { throw '기존 그림을 제거하지 못했습니다.' }
        if (-not $Session.Hwp.SetPosBySet($anchor)) { throw '기존 그림 기준 위치를 복원하지 못했습니다.' }
        $replacement = $Session.Hwp.InsertPicture($image.Path, $true, 1, $false, $false, 0, $widthMm, $heightMm)
        if ($null -eq $replacement) { throw '교체 그림을 삽입하지 못했습니다.' }
        $afterCount = @(Get-HwpPictureControls -Session $Session).Count
    }
    catch {
        return New-HwpResult -Status FAILED -Command replace-image -Errors @(
            "이미지 교체 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $pictures.Count) {
        return New-HwpResult -Status FAILED -Command replace-image -Errors @('그림 교체 후 컨트롤 개수가 달라졌습니다.')
    }

    New-HwpResult -Status $security.Status -Command replace-image -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'replace-image'
        Applied = $true
        ControlIndex = $controlIndex
        ImagePath = $image.Path
        ImageSha256 = $image.Sha256
        Embedded = $true
        WidthMm = $widthMm
        HeightMm = $heightMm
    }) -Warnings @($security.Warnings)
}

function Test-HwpActionAvailable {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$ActionId
    )

    try {
        [bool]$Session.Hwp.IsActionEnable($ActionId)
    }
    catch {
        $false
    }
}

function ConvertFrom-HwpUnitToMillimeter {
    param([double]$Value)

    $Value * 25.4 / 7200
}

function Get-HwpTextStyleSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }

    try {
        $charShape = $Session.Hwp.HParameterSet.HCharShape
        $paraShape = $Session.Hwp.HParameterSet.HParaShape
        $null = $Session.Hwp.HAction.GetDefault('CharShape', $charShape.HSet)
        $null = $Session.Hwp.HAction.GetDefault('ParagraphShape', $paraShape.HSet)
        $alignCode = [int]$paraShape.AlignType
        $align = switch ($alignCode) {
            0 { 'justify' }
            1 { 'left' }
            2 { 'right' }
            3 { 'center' }
            default { "other:$alignCode" }
        }

        New-HwpResult -Status PASS -Command inspect-text-style -Data ([pscustomobject]@{
            OperationId = Get-HwpOperationId -Operation $Operation
            Anchor = Get-HwpOperationAnchor -Operation $Operation
            HeightHwpUnit = [int]$charShape.Height
            HeightPt = [Math]::Round(([double]$charShape.Height / 100), 2)
            Bold = [int]$charShape.Bold -ne 0
            Italic = [int]$charShape.Italic -ne 0
            AlignCode = $alignCode
            Align = $align
        })
    }
    catch {
        New-HwpResult -Status FAILED -Command inspect-text-style -Errors @(
            "글자·문단 서식을 읽지 못했습니다: $($_.Exception.Message)"
        )
    }
}

function Invoke-HwpCharStyle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'CharShape')) {
        return New-HwpResult -Status BLOCKED -Command apply-char-style -Errors @(
            '현재 한컴오피스 위치 또는 버전에서 CharShape 작업을 사용할 수 없습니다.'
        )
    }

    try {
        $shape = $Session.Hwp.HParameterSet.HCharShape
        $null = $Session.Hwp.HAction.GetDefault('CharShape', $shape.HSet)
        $changed = $false
        if (Test-HwpEditProperty -InputObject $Operation.target -Name 'heightPt') {
            $heightPoint = [double]$Operation.target.heightPt
            if ($heightPoint -lt 1 -or $heightPoint -gt 4096) {
                throw "글자 크기가 허용 범위를 벗어났습니다: $heightPoint pt"
            }
            $shape.Height = [int]$Session.Hwp.PointToHwpUnit($heightPoint)
            $changed = $true
        }
        if (Test-HwpEditProperty -InputObject $Operation.target -Name 'bold') {
            $shape.Bold = [uint16]([bool]$Operation.target.bold)
            $changed = $true
        }
        if (Test-HwpEditProperty -InputObject $Operation.target -Name 'italic') {
            $shape.Italic = [uint16]([bool]$Operation.target.italic)
            $changed = $true
        }
        if (-not $changed) {
            return New-HwpResult -Status BLOCKED -Command apply-char-style -Errors @(
                '변경할 글자 서식 값이 없습니다.'
            )
        }
        if (-not $Session.Hwp.HAction.Execute('CharShape', $shape.HSet)) {
            throw 'CharShape 작업이 거짓을 반환했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command apply-char-style -Errors @(
            "글자 서식 변경 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }

    $snapshot = Get-HwpTextStyleSnapshot -Session $Session -Operation $Operation
    if ($snapshot.Status -ne 'PASS') {
        return $snapshot
    }
    if ((Test-HwpEditProperty -InputObject $Operation.target -Name 'heightPt') -and
        [Math]::Abs([double]$snapshot.Data.HeightPt - [double]$Operation.target.heightPt) -gt 0.01) {
        return New-HwpResult -Status FAILED -Command apply-char-style -Data $snapshot.Data -Errors @(
            '글자 크기 사후검증에 실패했습니다.'
        )
    }
    if ((Test-HwpEditProperty -InputObject $Operation.target -Name 'bold') -and
        [bool]$snapshot.Data.Bold -ne [bool]$Operation.target.bold) {
        return New-HwpResult -Status FAILED -Command apply-char-style -Data $snapshot.Data -Errors @(
            '굵게 서식 사후검증에 실패했습니다.'
        )
    }
    if ((Test-HwpEditProperty -InputObject $Operation.target -Name 'italic') -and
        [bool]$snapshot.Data.Italic -ne [bool]$Operation.target.italic) {
        return New-HwpResult -Status FAILED -Command apply-char-style -Data $snapshot.Data -Errors @(
            '기울임 서식 사후검증에 실패했습니다.'
        )
    }

    New-HwpResult -Status PASS -Command apply-char-style -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'apply-char-style'
        Applied = $true
        Snapshot = $snapshot.Data
    })
}

function Invoke-HwpParaStyle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'align')) {
        return New-HwpResult -Status BLOCKED -Command apply-para-style -Errors @('문단 정렬 값이 없습니다.')
    }
    $align = [string]$Operation.target.align
    $actionId = switch ($align) {
        'left' { 'ParagraphShapeAlignLeft' }
        'center' { 'ParagraphShapeAlignCenter' }
        'right' { 'ParagraphShapeAlignRight' }
        'justify' { 'ParagraphShapeAlignJustify' }
        default { '' }
    }
    if ([string]::IsNullOrWhiteSpace($actionId)) {
        return New-HwpResult -Status BLOCKED -Command apply-para-style -Errors @(
            "지원하지 않는 문단 정렬입니다: $align"
        )
    }

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    if (-not (Test-HwpActionAvailable -Session $Session -ActionId $actionId)) {
        return New-HwpResult -Status BLOCKED -Command apply-para-style -Errors @(
            "현재 한컴오피스 위치 또는 버전에서 $actionId 작업을 사용할 수 없습니다."
        )
    }
    try {
        if (-not $Session.Hwp.HAction.Run($actionId)) {
            throw "$actionId 작업이 거짓을 반환했습니다."
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command apply-para-style -Errors @(
            "문단 서식 변경 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }

    $snapshot = Get-HwpTextStyleSnapshot -Session $Session -Operation $Operation
    if ($snapshot.Status -ne 'PASS') {
        return $snapshot
    }
    if ([string]$snapshot.Data.Align -ne $align) {
        return New-HwpResult -Status FAILED -Command apply-para-style -Data $snapshot.Data -Errors @(
            '문단 정렬 사후검증에 실패했습니다.'
        )
    }

    New-HwpResult -Status PASS -Command apply-para-style -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'apply-para-style'
        Applied = $true
        Snapshot = $snapshot.Data
    })
}

function Invoke-HwpPageBreak {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    $placement = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'placement') {
        [string]$Operation.target.placement
    }
    else {
        'after'
    }
    if ($placement -notin 'before','after') {
        return New-HwpResult -Status BLOCKED -Command insert-page-break -Errors @(
            "쪽 나누기 위치는 before 또는 after여야 합니다: $placement"
        )
    }

    try {
        $position = if ($placement -eq 'before') { $selection.Data.StartPosition } else { $selection.Data.EndPosition }
        if (-not $Session.Hwp.SetPosBySet($position)) {
            throw '쪽 나누기 기준 위치로 이동하지 못했습니다.'
        }
        if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'BreakPage')) {
            return New-HwpResult -Status BLOCKED -Command insert-page-break -Errors @(
                '현재 한컴오피스 위치 또는 버전에서 BreakPage 작업을 사용할 수 없습니다.'
            )
        }
        $beforeCount = [int]$Session.Hwp.PageCount
        if (-not $Session.Hwp.HAction.Run('BreakPage')) {
            throw 'BreakPage 작업이 거짓을 반환했습니다.'
        }
        $afterCount = [int]$Session.Hwp.PageCount
    }
    catch {
        return New-HwpResult -Status FAILED -Command insert-page-break -Errors @(
            "쪽 나누기 삽입 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1) {
        return New-HwpResult -Status FAILED -Command insert-page-break -Errors @(
            "쪽 수가 정확히 1 증가하지 않았습니다: $beforeCount -> $afterCount"
        )
    }

    New-HwpResult -Status PASS -Command insert-page-break -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'insert-page-break'
        Applied = $true
        Placement = $placement
        PageCountBefore = $beforeCount
        PageCountAfter = $afterCount
    })
}

function Get-HwpSectionSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    try {
        if (-not $Session.Hwp.SetPosBySet($selection.Data.StartPosition)) {
            throw '구역 기준 위치로 이동하지 못했습니다.'
        }
        $section = $Session.Hwp.HParameterSet.HSecDef
        $null = $Session.Hwp.HAction.GetDefault('PageSetup', $section.HSet)
        $page = $section.PageDef
        $orientation = if ([int]$page.Landscape -eq 1 -or [int]$page.PaperWidth -gt [int]$page.PaperHeight) {
            'landscape'
        }
        else {
            'portrait'
        }
        New-HwpResult -Status PASS -Command inspect-section -Data ([pscustomobject]@{
            OperationId = Get-HwpOperationId -Operation $Operation
            Anchor = Get-HwpOperationAnchor -Operation $Operation
            Orientation = $orientation
            Landscape = [int]$page.Landscape
            PaperWidthMm = ConvertFrom-HwpUnitToMillimeter -Value ([double]$page.PaperWidth)
            PaperHeightMm = ConvertFrom-HwpUnitToMillimeter -Value ([double]$page.PaperHeight)
            LeftMarginMm = ConvertFrom-HwpUnitToMillimeter -Value ([double]$page.LeftMargin)
            RightMarginMm = ConvertFrom-HwpUnitToMillimeter -Value ([double]$page.RightMargin)
            TopMarginMm = ConvertFrom-HwpUnitToMillimeter -Value ([double]$page.TopMargin)
            BottomMarginMm = ConvertFrom-HwpUnitToMillimeter -Value ([double]$page.BottomMargin)
        })
    }
    catch {
        New-HwpResult -Status FAILED -Command inspect-section -Errors @(
            "구역 설정을 읽지 못했습니다: $($_.Exception.Message)"
        )
    }
}

function Invoke-HwpSetSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [bool]$ApprovedAdvanced = $false
    )

    if (-not $ApprovedAdvanced) {
        return New-HwpResult -Status BLOCKED -Command set-section -Errors @(
            '구역 설정에는 approvedAdvanced=true의 명시적 승인이 필요합니다.'
        )
    }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'orientation')) {
        return New-HwpResult -Status BLOCKED -Command set-section -Errors @('용지 방향 값이 없습니다.')
    }
    $orientation = [string]$Operation.target.orientation
    if ($orientation -notin 'portrait','landscape') {
        return New-HwpResult -Status BLOCKED -Command set-section -Errors @(
            "지원하지 않는 용지 방향입니다: $orientation"
        )
    }
    if ((Test-HwpEditProperty -InputObject $Operation.target -Name 'paperSize') -and
        [string]$Operation.target.paperSize -ne 'A4') {
        return New-HwpResult -Status BLOCKED -Command set-section -Errors @('현재 용지 크기는 A4만 지원합니다.')
    }

    try {
        if (-not $Session.Hwp.SetPosBySet($selection.Data.StartPosition)) {
            throw '구역 기준 위치로 이동하지 못했습니다.'
        }
        if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'PageSetup')) {
            return New-HwpResult -Status BLOCKED -Command set-section -Errors @(
                '현재 한컴오피스 위치 또는 버전에서 PageSetup 작업을 사용할 수 없습니다.'
            )
        }
        $section = $Session.Hwp.HParameterSet.HSecDef
        $null = $Session.Hwp.HAction.GetDefault('PageSetup', $section.HSet)
        $page = $section.PageDef
        $landscape = $orientation -eq 'landscape'
        $page.Landscape = [uint16]$landscape
        $page.PaperWidth = [int]$Session.Hwp.MiliToHwpUnit($(if ($landscape) { 297 } else { 210 }))
        $page.PaperHeight = [int]$Session.Hwp.MiliToHwpUnit($(if ($landscape) { 210 } else { 297 }))
        foreach ($mapping in @(
            @('leftMarginMm','LeftMargin'),
            @('rightMarginMm','RightMargin'),
            @('topMarginMm','TopMargin'),
            @('bottomMarginMm','BottomMargin')
        )) {
            if (Test-HwpEditProperty -InputObject $Operation.target -Name $mapping[0]) {
                $millimeter = [double]$Operation.target.($mapping[0])
                if ($millimeter -lt 0 -or $millimeter -gt 100) {
                    throw "여백이 허용 범위를 벗어났습니다: $($mapping[0])=$millimeter"
                }
                $page.($mapping[1]) = [int]$Session.Hwp.MiliToHwpUnit($millimeter)
            }
        }
        $null = $section.HSet.SetItem('ApplyTo', 2)
        if (-not $Session.Hwp.HAction.Execute('PageSetup', $section.HSet)) {
            throw 'PageSetup 작업이 거짓을 반환했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command set-section -Errors @(
            "구역 설정 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }

    $snapshot = Get-HwpSectionSnapshot -Session $Session -Operation $Operation
    if ($snapshot.Status -ne 'PASS') {
        return $snapshot
    }
    if ([string]$snapshot.Data.Orientation -ne $orientation) {
        return New-HwpResult -Status FAILED -Command set-section -Data $snapshot.Data -Errors @(
            '용지 방향 사후검증에 실패했습니다.'
        )
    }
    foreach ($mapping in @(
        @('leftMarginMm','LeftMarginMm'),
        @('rightMarginMm','RightMarginMm'),
        @('topMarginMm','TopMarginMm'),
        @('bottomMarginMm','BottomMarginMm')
    )) {
        if ((Test-HwpEditProperty -InputObject $Operation.target -Name $mapping[0]) -and
            [Math]::Abs([double]$snapshot.Data.($mapping[1]) - [double]$Operation.target.($mapping[0])) -gt 0.1) {
            return New-HwpResult -Status FAILED -Command set-section -Data $snapshot.Data -Errors @(
                "여백 사후검증에 실패했습니다: $($mapping[0])"
            )
        }
    }

    New-HwpResult -Status PASS -Command set-section -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'set-section'
        Applied = $true
        Snapshot = $snapshot.Data
    })
}

function Get-HwpHeaderFooterTextSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][object]$Session)

    $items = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    try {
        foreach ($definition in @(
            [pscustomobject]@{ Kind = 'header'; CtrlId = 'head'; DialogResult = 26 },
            [pscustomobject]@{ Kind = 'footer'; CtrlId = 'foot'; DialogResult = 14 }
        )) {
            $controlCount = @(Get-HwpControlsById -Session $Session -CtrlId $definition.CtrlId).Count
            if ($controlCount -eq 0) {
                continue
            }
            if ($controlCount -gt 1) {
                $warnings.Add("$($definition.Kind) 컨트롤이 $controlCount 개이므로 첫 번째 항목만 추출했습니다.")
            }

            $null = $Session.Hwp.HAction.Run('MoveDocBegin')
            $oldMessageBoxMode = $Session.Hwp.SetMessageBoxMode(0x00010000)
            try {
                $goto = $Session.Hwp.HParameterSet.HGotoE
                $null = $Session.Hwp.HAction.GetDefault('Goto', $goto.HSet)
                $null = $goto.HSet.SetItem('DialogResult', [int]$definition.DialogResult)
                $goto.SetSelectionIndex = 5
                if (-not $Session.Hwp.HAction.Execute('Goto', $goto.HSet)) {
                    throw "$($definition.Kind) 조판 부호로 이동하지 못했습니다."
                }
            }
            finally {
                $null = $Session.Hwp.SetMessageBoxMode($oldMessageBoxMode)
            }
            if (-not $Session.Hwp.HAction.Run('HeaderFooterModify')) {
                throw "$($definition.Kind) 편집 상태로 들어가지 못했습니다."
            }
            try {
                if (-not $Session.Hwp.HAction.Run('SelectAll')) {
                    throw "$($definition.Kind) 본문을 선택하지 못했습니다."
                }
                $text = [string]$Session.Hwp.GetTextFile('UNICODE', 'saveblock')
            }
            finally {
                $null = $Session.Hwp.HAction.Run('CloseEx')
            }
            $items.Add([pscustomobject]@{
                Kind = $definition.Kind
                CtrlId = $definition.CtrlId
                Text = $text
                ControlCount = $controlCount
            })
        }
        $null = $Session.Hwp.HAction.Run('MoveDocBegin')
    }
    catch {
        return New-HwpResult -Status FAILED -Command inspect-header-footer -Data ([pscustomobject]@{
            Items = @($items)
        }) -Errors @("머리말·꼬리말을 읽지 못했습니다: $($_.Exception.Message)")
    }

    $status = if ($warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }
    New-HwpResult -Status $status -Command inspect-header-footer -Data ([pscustomobject]@{
        Items = @($items)
    }) -Warnings @($warnings)
}

function Invoke-HwpHeaderFooter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    foreach ($required in 'kind','text') {
        if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name $required)) {
            return New-HwpResult -Status BLOCKED -Command set-header-footer -Errors @(
                "머리말·꼬리말 대상에 필수 값이 없습니다: $required"
            )
        }
    }
    $kind = [string]$Operation.target.kind
    $pages = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'pages') {
        [string]$Operation.target.pages
    }
    else {
        'both'
    }
    if ($kind -notin 'header','footer' -or $pages -notin 'both','even','odd') {
        return New-HwpResult -Status BLOCKED -Command set-header-footer -Errors @(
            "머리말·꼬리말 kind 또는 pages 값이 올바르지 않습니다: $kind / $pages"
        )
    }

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    $ctrlId = if ($kind -eq 'header') { 'head' } else { 'foot' }
    $existing = @(Get-HwpControlsById -Session $Session -CtrlId $ctrlId)
    if ($existing.Count -gt 0) {
        return New-HwpResult -Status BLOCKED -Command set-header-footer -Errors @(
            "기존 $kind 컨트롤이 있어 자동으로 중복 생성하지 않습니다. 기존 컨트롤 수정은 명시적 인덱스 지원 후 사용할 수 있습니다."
        )
    }
    if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'HeaderFooter')) {
        return New-HwpResult -Status BLOCKED -Command set-header-footer -Errors @(
            '현재 한컴오피스 위치 또는 버전에서 HeaderFooter 작업을 사용할 수 없습니다.'
        )
    }

    $entered = $false
    try {
        if (-not $Session.Hwp.SetPosBySet($selection.Data.StartPosition)) {
            throw '머리말·꼬리말 기준 위치로 이동하지 못했습니다.'
        }
        $set = $Session.Hwp.HParameterSet.HHeaderFooter
        $null = $Session.Hwp.HAction.GetDefault('HeaderFooter', $set.HSet)
        $null = $set.HSet.SetItem('HeaderFooterCtrlType', $(if ($kind -eq 'header') { 0 } else { 1 }))
        $null = $set.HSet.SetItem('HeaderFooterStyle', 0)
        $set.type = switch ($pages) { 'both' { 0 } 'even' { 1 } 'odd' { 2 } }
        if (-not $Session.Hwp.HAction.Execute('HeaderFooter', $set.HSet)) {
            throw 'HeaderFooter 작업이 거짓을 반환했습니다.'
        }
        $entered = $true
        if (-not (Invoke-HwpInsertRawText -Session $Session -Text ([string]$Operation.target.text))) {
            throw '머리말·꼬리말 본문을 입력하지 못했습니다.'
        }
        if (-not $Session.Hwp.HAction.Run('CloseEx')) {
            throw '머리말·꼬리말 편집 상태를 닫지 못했습니다.'
        }
        $entered = $false
    }
    catch {
        if ($entered) {
            $null = $Session.Hwp.HAction.Run('CloseEx')
        }
        return New-HwpResult -Status FAILED -Command set-header-footer -Errors @(
            "머리말·꼬리말 설정 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }

    $snapshot = Get-HwpHeaderFooterTextSnapshot -Session $Session
    if ($snapshot.Status -notin 'PASS','PASS_WITH_WARNINGS') {
        return $snapshot
    }
    $matches = @($snapshot.Data.Items | Where-Object {
        $_.Kind -eq $kind -and [string]::Equals([string]$_.Text, [string]$Operation.target.text, [StringComparison]::Ordinal)
    })
    if ($matches.Count -ne 1) {
        return New-HwpResult -Status FAILED -Command set-header-footer -Data $snapshot.Data -Errors @(
            "$kind 본문 사후검증에 실패했습니다."
        )
    }

    New-HwpResult -Status $snapshot.Status -Command set-header-footer -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'set-header-footer'
        Applied = $true
        Kind = $kind
        Pages = $pages
        Text = [string]$Operation.target.text
    }) -Warnings @($snapshot.Warnings)
}

function Invoke-HwpSetPageNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $position = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'position') {
        [string]$Operation.target.position
    }
    else {
        'bottom-center'
    }
    $drawPosition = switch ($position) {
        'top-left' { 1 }
        'top-center' { 2 }
        'top-right' { 3 }
        'bottom-left' { 4 }
        'bottom-center' { 5 }
        'bottom-right' { 6 }
        default { 0 }
    }
    if ($drawPosition -eq 0) {
        return New-HwpResult -Status BLOCKED -Command set-page-number -Errors @(
            "지원하지 않는 쪽 번호 위치입니다: $position"
        )
    }
    $startNumber = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'startNumber') {
        [int]$Operation.target.startNumber
    }
    else {
        1
    }
    if ($startNumber -lt 1 -or $startNumber -gt 9999) {
        return New-HwpResult -Status BLOCKED -Command set-page-number -Errors @(
            "쪽 번호 시작 값이 허용 범위를 벗어났습니다: $startNumber"
        )
    }

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    $beforeCount = @(Get-HwpControlsById -Session $Session -CtrlId 'pgnp').Count
    if ($beforeCount -gt 0) {
        return New-HwpResult -Status BLOCKED -Command set-page-number -Errors @(
            '기존 쪽 번호 컨트롤이 있어 자동으로 중복 생성하지 않습니다.'
        )
    }
    if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'PageNumPos')) {
        return New-HwpResult -Status BLOCKED -Command set-page-number -Errors @(
            '현재 한컴오피스 위치 또는 버전에서 PageNumPos 작업을 사용할 수 없습니다.'
        )
    }

    try {
        if (-not $Session.Hwp.SetPosBySet($selection.Data.StartPosition)) {
            throw '쪽 번호 기준 위치로 이동하지 못했습니다.'
        }
        $set = $Session.Hwp.HParameterSet.HPageNumPos
        $null = $Session.Hwp.HAction.GetDefault('PageNumPos', $set.HSet)
        $set.NumberFormat = 0
        $set.DrawPos = $drawPosition
        $set.NewNumber = $startNumber
        if (-not $Session.Hwp.HAction.Execute('PageNumPos', $set.HSet)) {
            throw 'PageNumPos 작업이 거짓을 반환했습니다.'
        }
        $afterCount = @(Get-HwpControlsById -Session $Session -CtrlId 'pgnp').Count
    }
    catch {
        return New-HwpResult -Status FAILED -Command set-page-number -Errors @(
            "쪽 번호 설정 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1) {
        return New-HwpResult -Status FAILED -Command set-page-number -Errors @(
            "쪽 번호 컨트롤 수가 정확히 1 증가하지 않았습니다: $beforeCount -> $afterCount"
        )
    }

    New-HwpResult -Status PASS -Command set-page-number -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'set-page-number'
        Applied = $true
        Position = $position
        StartNumber = $startNumber
        ControlCountBefore = $beforeCount
        ControlCountAfter = $afterCount
    })
}

function Invoke-HwpAddBookmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'name')) {
        return New-HwpResult -Status BLOCKED -Command add-bookmark -Errors @('책갈피 이름이 없습니다.')
    }
    $name = [string]$Operation.target.name
    if ($name.Length -lt 1 -or $name.Length -gt 120 -or $name -match '[;\r\n]') {
        return New-HwpResult -Status BLOCKED -Command add-bookmark -Errors @(
            '책갈피 이름은 세미콜론과 줄바꿈 없이 1~120자여야 합니다.'
        )
    }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'Bookmark')) {
        return New-HwpResult -Status BLOCKED -Command add-bookmark -Errors @(
            '현재 한컴오피스 위치 또는 버전에서 Bookmark 작업을 사용할 수 없습니다.'
        )
    }

    $beforeCount = @(Get-HwpControlsById -Session $Session -CtrlId '%bmk').Count
    try {
        $bookmark = $Session.Hwp.HParameterSet.HBookMark
        $null = $Session.Hwp.HAction.GetDefault('Bookmark', $bookmark.HSet)
        $bookmark.Name = $name
        $bookmark.Type = 1
        $bookmark.Command = 0
        if (-not $Session.Hwp.HAction.Execute('Bookmark', $bookmark.HSet)) {
            throw 'Bookmark 작업이 거짓을 반환했습니다.'
        }
        $afterCount = @(Get-HwpControlsById -Session $Session -CtrlId '%bmk').Count
    }
    catch {
        return New-HwpResult -Status FAILED -Command add-bookmark -Errors @(
            "책갈피 추가 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1) {
        return New-HwpResult -Status FAILED -Command add-bookmark -Errors @(
            "책갈피 컨트롤 수가 정확히 1 증가하지 않았습니다: $beforeCount -> $afterCount"
        )
    }

    New-HwpResult -Status PASS -Command add-bookmark -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'add-bookmark'
        Applied = $true
        Name = $name
        Anchor = Get-HwpOperationAnchor -Operation $Operation
        ControlCountBefore = $beforeCount
        ControlCountAfter = $afterCount
    })
}

function Resolve-HwpSafeHyperlink {
    param([Parameter(Mandatory)][string]$Url)

    if ($Url.Length -gt 2048 -or $Url -match '[;\r\n]') {
        throw 'URL은 세미콜론과 줄바꿈 없이 2,048자 이하여야 합니다.'
    }
    $parsed = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed)) {
        throw '절대 URL 형식이 아닙니다.'
    }
    if ($parsed.Scheme -notin 'http','https') {
        throw '하이퍼링크는 http 또는 https URL만 허용합니다.'
    }
    if (-not [string]::IsNullOrWhiteSpace($parsed.UserInfo)) {
        throw '사용자명이나 비밀번호가 포함된 URL은 허용하지 않습니다.'
    }
    $parsed.AbsoluteUri
}

function Invoke-HwpAddHyperlink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'url')) {
        return New-HwpResult -Status BLOCKED -Command add-hyperlink -Errors @('하이퍼링크 URL이 없습니다.')
    }
    try {
        $url = Resolve-HwpSafeHyperlink -Url ([string]$Operation.target.url)
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command add-hyperlink -Errors @($_.Exception.Message)
    }
    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'InsertHyperlink')) {
        return New-HwpResult -Status BLOCKED -Command add-hyperlink -Errors @(
            '현재 한컴오피스 위치 또는 버전에서 InsertHyperlink 작업을 사용할 수 없습니다.'
        )
    }

    $beforeCount = @(Get-HwpControlsById -Session $Session -CtrlId '%hlk').Count
    try {
        # Hyperlink 액션은 대화상자를 열 수 있으므로 DirectInsert를 지원하는 InsertHyperlink만 사용한다.
        $hyperlink = $Session.Hwp.HParameterSet.HHyperLink
        $null = $Session.Hwp.HAction.GetDefault('InsertHyperlink', $hyperlink.HSet)
        $hyperlink.Text = [string]$selection.Data.SelectedText
        $hyperlink.Command = "$url;1;0;0;"
        $hyperlink.NoLInk = 0
        $hyperlink.ShapeObject = 0
        $hyperlink.DirectInsert = 1
        $oldMessageBoxMode = $Session.Hwp.SetMessageBoxMode(0x00010000)
        try {
            $executed = $Session.Hwp.HAction.Execute('InsertHyperlink', $hyperlink.HSet)
        }
        finally {
            $null = $Session.Hwp.SetMessageBoxMode($oldMessageBoxMode)
        }
        if (-not $executed) {
            throw 'InsertHyperlink 작업이 거짓을 반환했습니다.'
        }
        $afterCount = @(Get-HwpControlsById -Session $Session -CtrlId '%hlk').Count
    }
    catch {
        return New-HwpResult -Status FAILED -Command add-hyperlink -Errors @(
            "하이퍼링크 추가 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1) {
        return New-HwpResult -Status FAILED -Command add-hyperlink -Errors @(
            "하이퍼링크 컨트롤 수가 정확히 1 증가하지 않았습니다: $beforeCount -> $afterCount"
        )
    }
    $currentText = [string]$Session.Hwp.GetTextFile('UNICODE', '')
    if (-not $currentText.Contains([string]$selection.Data.SelectedText, [StringComparison]::Ordinal)) {
        return New-HwpResult -Status FAILED -Command add-hyperlink -Errors @(
            '하이퍼링크를 추가한 뒤 표시 문구를 찾지 못했습니다.'
        )
    }

    New-HwpResult -Status PASS -Command add-hyperlink -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'add-hyperlink'
        Applied = $true
        Url = $url
        Text = [string]$selection.Data.SelectedText
        ControlCountBefore = $beforeCount
        ControlCountAfter = $afterCount
    })
}

function Invoke-HwpAddCaption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    foreach ($required in 'controlId','controlIndex','text') {
        if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name $required)) {
            return New-HwpResult -Status BLOCKED -Command add-caption -Errors @(
                "캡션 대상에 필수 값이 없습니다: $required"
            )
        }
    }
    $ctrlId = [string]$Operation.target.controlId
    $controlIndex = [int]$Operation.target.controlIndex
    $text = [string]$Operation.target.text
    if ($ctrlId -notin 'tbl','gso' -or $controlIndex -lt 1 -or [string]::IsNullOrWhiteSpace($text)) {
        return New-HwpResult -Status BLOCKED -Command add-caption -Errors @(
            '캡션은 유효한 표/그림 컨트롤 인덱스와 비어 있지 않은 본문이 필요합니다.'
        )
    }
    try {
        $controls = @(Get-HwpControlsById -Session $Session -CtrlId $ctrlId)
    }
    catch {
        return New-HwpResult -Status FAILED -Command add-caption -Errors @($_.Exception.Message)
    }
    if ($controlIndex -gt $controls.Count) {
        return New-HwpResult -Status BLOCKED -Command add-caption -Errors @(
            "캡션 대상 컨트롤 인덱스가 범위를 벗어났습니다: $controlIndex / $($controls.Count)"
        )
    }

    $beforeAutoNumberCount = @(Get-HwpControlsById -Session $Session -CtrlId 'atno').Count
    $entered = $false
    try {
        $control = $controls[$controlIndex - 1]
        if (-not $Session.Hwp.SetPosBySet($control.GetAnchorPos(0))) {
            throw '캡션 대상 컨트롤 위치로 이동하지 못했습니다.'
        }
        $found = [string]$Session.Hwp.FindCtrl()
        if ($found -ne $ctrlId) {
            throw "캡션 대상 컨트롤을 선택하지 못했습니다: $ctrlId / $found"
        }
        if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'ShapeObjAttachCaption')) {
            return New-HwpResult -Status BLOCKED -Command add-caption -Errors @(
                '현재 컨트롤에서 ShapeObjAttachCaption 작업을 사용할 수 없습니다.'
            )
        }
        if (-not $Session.Hwp.HAction.Run('ShapeObjAttachCaption')) {
            throw 'ShapeObjAttachCaption 작업이 거짓을 반환했습니다.'
        }
        $entered = $true
        if (-not (Invoke-HwpInsertRawText -Session $Session -Text $text)) {
            throw '캡션 본문을 입력하지 못했습니다.'
        }
        if (-not $Session.Hwp.HAction.Run('CloseEx')) {
            throw '캡션 편집 상태를 닫지 못했습니다.'
        }
        $entered = $false
        $afterAutoNumberCount = @(Get-HwpControlsById -Session $Session -CtrlId 'atno').Count
        $currentText = [string]$Session.Hwp.GetTextFile('UNICODE', '')
    }
    catch {
        if ($entered) { $null = $Session.Hwp.HAction.Run('CloseEx') }
        return New-HwpResult -Status FAILED -Command add-caption -Errors @(
            "캡션 추가 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterAutoNumberCount -ne $beforeAutoNumberCount + 1 -or
        -not $currentText.Contains($text, [StringComparison]::Ordinal)) {
        return New-HwpResult -Status FAILED -Command add-caption -Errors @('캡션 사후검증에 실패했습니다.')
    }

    New-HwpResult -Status PASS -Command add-caption -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'add-caption'
        Applied = $true
        ControlId = $ctrlId
        ControlIndex = $controlIndex
        Text = $text
        AutoNumberCountBefore = $beforeAutoNumberCount
        AutoNumberCountAfter = $afterAutoNumberCount
    })
}

function Invoke-HwpAddNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    $type = [string]$Operation.type
    $definition = switch ($type) {
        'add-footnote' { [pscustomobject]@{ ActionId = 'InsertFootnote'; CtrlId = 'fn'; Label = '각주' } }
        'add-endnote' { [pscustomobject]@{ ActionId = 'InsertEndnote'; CtrlId = 'en'; Label = '미주' } }
        default { $null }
    }
    if ($null -eq $definition) {
        return New-HwpResult -Status BLOCKED -Command add-note -Errors @("지원하지 않는 주석 작업입니다: $type")
    }
    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'text')) {
        return New-HwpResult -Status BLOCKED -Command add-note -Errors @("$($definition.Label) 본문이 없습니다.")
    }
    $text = [string]$Operation.target.text
    if ([string]::IsNullOrWhiteSpace($text)) {
        return New-HwpResult -Status BLOCKED -Command add-note -Errors @("$($definition.Label) 본문이 비어 있습니다.")
    }
    $placement = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'placement') {
        [string]$Operation.target.placement
    }
    else {
        'after'
    }
    if ($placement -notin 'before','after') {
        return New-HwpResult -Status BLOCKED -Command add-note -Errors @(
            "$($definition.Label) 위치는 before 또는 after여야 합니다."
        )
    }

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    $beforeCount = @(Get-HwpControlsById -Session $Session -CtrlId $definition.CtrlId).Count
    $entered = $false
    try {
        $position = if ($placement -eq 'before') { $selection.Data.StartPosition } else { $selection.Data.EndPosition }
        if (-not $Session.Hwp.SetPosBySet($position)) {
            throw "$($definition.Label) 기준 위치로 이동하지 못했습니다."
        }
        if (-not (Test-HwpActionAvailable -Session $Session -ActionId $definition.ActionId)) {
            return New-HwpResult -Status BLOCKED -Command add-note -Errors @(
                "현재 위치에서 $($definition.ActionId) 작업을 사용할 수 없습니다."
            )
        }
        if (-not $Session.Hwp.HAction.Run($definition.ActionId)) {
            throw "$($definition.ActionId) 작업이 거짓을 반환했습니다."
        }
        $entered = $true
        if (-not (Invoke-HwpInsertRawText -Session $Session -Text $text)) {
            throw "$($definition.Label) 본문을 입력하지 못했습니다."
        }
        if (-not $Session.Hwp.HAction.Run('CloseEx')) {
            throw "$($definition.Label) 편집 상태를 닫지 못했습니다."
        }
        $entered = $false
        $afterCount = @(Get-HwpControlsById -Session $Session -CtrlId $definition.CtrlId).Count
        $currentText = [string]$Session.Hwp.GetTextFile('UNICODE', '')
    }
    catch {
        if ($entered) { $null = $Session.Hwp.HAction.Run('CloseEx') }
        return New-HwpResult -Status FAILED -Command add-note -Errors @(
            "$($definition.Label) 추가 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if ($afterCount -ne $beforeCount + 1 -or -not $currentText.Contains($text, [StringComparison]::Ordinal)) {
        return New-HwpResult -Status FAILED -Command add-note -Errors @("$($definition.Label) 사후검증에 실패했습니다.")
    }

    New-HwpResult -Status PASS -Command add-note -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = $type
        Applied = $true
        Text = $text
        Placement = $placement
        ControlId = $definition.CtrlId
        ControlCountBefore = $beforeCount
        ControlCountAfter = $afterCount
    })
}

function Get-HwpCurrentPrintedPageNumber {
    param([Parameter(Mandatory)][object]$Session)

    [int]$sectionCount = 0
    [int]$sectionNumber = 0
    [int]$printedPageNumber = 0
    [int]$columnNumber = 0
    [int]$lineNumber = 0
    [int]$position = 0
    [int16]$overwrite = 0
    [string]$controlName = ''
    $ok = $Session.Hwp.KeyIndicator(
        [ref]$sectionCount,
        [ref]$sectionNumber,
        [ref]$printedPageNumber,
        [ref]$columnNumber,
        [ref]$lineNumber,
        [ref]$position,
        [ref]$overwrite,
        [ref]$controlName
    )
    if (-not $ok -or $printedPageNumber -lt 1) {
        throw '현재 인쇄 쪽 번호를 읽지 못했습니다.'
    }
    $printedPageNumber
}

function Invoke-HwpBuildToc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'headingAnchors')) {
        return New-HwpResult -Status BLOCKED -Command build-toc -Errors @('차례 제목 기준 문구 목록이 없습니다.')
    }
    $headingAnchors = @($Operation.target.headingAnchors)
    if ($headingAnchors.Count -lt 1 -or $headingAnchors.Count -gt 200) {
        return New-HwpResult -Status BLOCKED -Command build-toc -Errors @('차례 항목 수는 1~200개여야 합니다.')
    }
    $title = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'title') {
        [string]$Operation.target.title
    }
    else {
        '차례'
    }
    if ([string]::IsNullOrWhiteSpace($title) -or $title.Length -gt 120) {
        return New-HwpResult -Status BLOCKED -Command build-toc -Errors @('차례 제목은 1~120자여야 합니다.')
    }

    $targetResolution = Resolve-HwpTextTarget -Session $Session -Operation $Operation
    if ($targetResolution.Status -ne 'PASS') {
        return $targetResolution
    }
    $entries = [Collections.Generic.List[object]]::new()
    $maximumHeadingIndex = -1
    try {
        $index = 0
        foreach ($headingAnchorValue in $headingAnchors) {
            $headingAnchor = [string]$headingAnchorValue
            if ([string]::IsNullOrWhiteSpace($headingAnchor)) {
                throw '차례 제목 기준 문구가 비어 있습니다.'
            }
            $headingOperation = [pscustomobject]@{
                id = "$(Get-HwpOperationId -Operation $Operation)-heading-$index"
                expectedMatches = 1
                target = [pscustomobject]@{
                    anchor = $headingAnchor
                    beforeContext = ''
                    afterContext = ''
                }
            }
            $headingResolution = Resolve-HwpTextTarget -Session $Session -Operation $headingOperation
            if ($headingResolution.Status -ne 'PASS') {
                throw "차례 항목을 유일하게 찾지 못했습니다: $headingAnchor"
            }
            $headingSelection = Select-HwpResolvedTarget -Session $Session -Operation $headingOperation -Resolution $headingResolution
            if ($headingSelection.Status -ne 'PASS') {
                throw "차례 항목을 선택하지 못했습니다: $headingAnchor"
            }
            $pageNumber = Get-HwpCurrentPrintedPageNumber -Session $Session
            $entries.Add([pscustomobject]@{
                Text = $headingAnchor
                PageNumber = $pageNumber
                StartIndex = [int]$headingResolution.Data.StartIndex
            })
            $maximumHeadingIndex = [Math]::Max($maximumHeadingIndex, [int]$headingResolution.Data.StartIndex)
            $index++
        }
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command build-toc -Data ([pscustomobject]@{
            Entries = @($entries)
        }) -Errors @("차례 항목 분석에 실패했습니다: $($_.Exception.Message)")
    }
    if ([int]$targetResolution.Data.StartIndex -le $maximumHeadingIndex) {
        return New-HwpResult -Status BLOCKED -Command build-toc -Data ([pscustomobject]@{
            Entries = @($entries)
        }) -Errors @('쪽 번호가 바뀌지 않도록 차례 삽입 위치는 모든 차례 항목 뒤에 있어야 합니다.')
    }

    $selection = Select-HwpResolvedTarget -Session $Session -Operation $Operation -Resolution $targetResolution
    if ($selection.Status -ne 'PASS') {
        return $selection
    }
    $placement = if (Test-HwpEditProperty -InputObject $Operation.target -Name 'placement') {
        [string]$Operation.target.placement
    }
    else {
        'after'
    }
    if ($placement -notin 'before','after') {
        return New-HwpResult -Status BLOCKED -Command build-toc -Errors @('차례 위치는 before 또는 after여야 합니다.')
    }
    $pageBreakBefore = (Test-HwpEditProperty -InputObject $Operation.target -Name 'pageBreakBefore') -and
        [bool]$Operation.target.pageBreakBefore
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($title)
    foreach ($entry in $entries) {
        $lines.Add("$($entry.Text)`t$($entry.PageNumber)")
    }
    $tocText = ($lines -join "`r`n") + "`r`n"

    try {
        $positionSet = if ($placement -eq 'before') { $selection.Data.StartPosition } else { $selection.Data.EndPosition }
        if (-not $Session.Hwp.SetPosBySet($positionSet)) {
            throw '차례 삽입 위치로 이동하지 못했습니다.'
        }
        $pageCountBefore = [int]$Session.Hwp.PageCount
        if ($pageBreakBefore) {
            if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'BreakPage')) {
                return New-HwpResult -Status BLOCKED -Command build-toc -Errors @(
                    '차례 앞쪽 나누기에 필요한 BreakPage 작업을 사용할 수 없습니다.'
                )
            }
            if (-not $Session.Hwp.HAction.Run('BreakPage')) {
                throw '차례 앞쪽 나누기에 실패했습니다.'
            }
        }
        if (-not (Invoke-HwpInsertRawText -Session $Session -Text $tocText)) {
            throw '차례 본문을 입력하지 못했습니다.'
        }
        $pageCountAfter = [int]$Session.Hwp.PageCount
        $currentText = [string]$Session.Hwp.GetTextFile('UNICODE', '')
    }
    catch {
        return New-HwpResult -Status FAILED -Command build-toc -Errors @(
            "차례 생성 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    if (-not $currentText.Contains($tocText.TrimEnd("`r","`n"), [StringComparison]::Ordinal)) {
        return New-HwpResult -Status FAILED -Command build-toc -Errors @('차례 본문 사후검증에 실패했습니다.')
    }
    if ($pageBreakBefore -and $pageCountAfter -lt $pageCountBefore + 1) {
        return New-HwpResult -Status FAILED -Command build-toc -Errors @('차례 앞쪽 나누기 사후검증에 실패했습니다.')
    }

    New-HwpResult -Status PASS -Command build-toc -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'build-toc'
        Applied = $true
        Method = 'manual-safe'
        NativeMakeContentsUsed = $false
        Title = $title
        Entries = @($entries)
        Placement = $placement
        PageBreakBefore = $pageBreakBefore
        PageCountBefore = $pageCountBefore
        PageCountAfter = $pageCountAfter
        Text = $tocText
    }) -Warnings @(
        '한컴 2024 일부 빌드에서 MakeContents 자동화가 서버 오류를 일으켜 실제 쪽 번호를 읽은 수동 차례를 생성했습니다.'
    )
}

function Invoke-HwpMergeDocuments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [bool]$ApprovedAdvanced = $false,
        [ValidateRange(1, 2147483647)][long]$MaximumFileBytes = 134217728,
        [ValidateRange(1, 2147483647)][long]$MaximumTotalBytes = 536870912
    )

    if (-not $ApprovedAdvanced) {
        return New-HwpResult -Status BLOCKED -Command merge-documents -Errors @(
            '문서 병합에는 approvedAdvanced=true의 명시적 승인이 필요합니다.'
        )
    }
    if (-not (Test-HwpEditProperty -InputObject $Operation.target -Name 'paths')) {
        return New-HwpResult -Status BLOCKED -Command merge-documents -Errors @('병합할 문서 경로 목록이 없습니다.')
    }
    $paths = @($Operation.target.paths)
    if ($paths.Count -lt 1 -or $paths.Count -gt 50) {
        return New-HwpResult -Status BLOCKED -Command merge-documents -Errors @('병합 문서 수는 1~50개여야 합니다.')
    }
    $pageBreakBetween = -not (Test-HwpEditProperty -InputObject $Operation.target -Name 'pageBreakBetween') -or
        [bool]$Operation.target.pageBreakBetween
    $files = [Collections.Generic.List[object]]::new()
    [long]$totalBytes = 0
    try {
        foreach ($pathValue in $paths) {
            $kind = Get-HwpFileKind -LiteralPath ([string]$pathValue)
            if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWP-BINARY') {
                throw "병합 입력은 실제 형식이 HWP 바이너리인 HWP 또는 HWT여야 합니다: $($kind.Path)"
            }
            $fileInfo = Get-Item -LiteralPath $kind.Path -ErrorAction Stop
            if ($fileInfo.Length -gt $MaximumFileBytes) {
                throw "병합 입력이 파일별 안전 한도를 초과했습니다: $($kind.Path)"
            }
            $totalBytes += $fileInfo.Length
            if ($totalBytes -gt $MaximumTotalBytes) {
                throw '병합 입력 전체 크기가 안전 한도를 초과했습니다.'
            }
            $files.Add([pscustomobject]@{
                Path = $kind.Path
                Extension = $kind.Extension
                ByteLength = [long]$fileInfo.Length
                Sha256Before = Get-HwpSha256 -LiteralPath $kind.Path
            })
        }
    }
    catch {
        return New-HwpResult -Status BLOCKED -Command merge-documents -Data ([pscustomobject]@{
            Files = @($files)
            TotalBytes = $totalBytes
        }) -Errors @($_.Exception.Message)
    }

    $results = [Collections.Generic.List[object]]::new()
    try {
        $textBefore = [string]$Session.Hwp.GetTextFile('UNICODE', '')
        $pageCountBefore = [int]$Session.Hwp.PageCount
        if (-not $Session.Hwp.HAction.Run('MoveDocEnd')) {
            throw '병합 위치인 문서 끝으로 이동하지 못했습니다.'
        }
        foreach ($file in $files) {
            if ($pageBreakBetween) {
                if (-not (Test-HwpActionAvailable -Session $Session -ActionId 'BreakPage')) {
                    throw '병합 문서 사이의 BreakPage 작업을 사용할 수 없습니다.'
                }
                if (-not $Session.Hwp.HAction.Run('BreakPage')) {
                    throw '병합 문서 앞쪽 나누기에 실패했습니다.'
                }
            }
            $bytes = [IO.File]::ReadAllBytes($file.Path)
            $base64 = [Convert]::ToBase64String($bytes)
            $loaded = [int]$Session.Hwp.SetTextFile($base64, 'HWP', 'insertfile')
            if ($loaded -le 0) {
                throw "한컴오피스가 메모리 병합 입력을 삽입하지 못했습니다: $($file.Path)"
            }
            $shaAfter = Get-HwpSha256 -LiteralPath $file.Path
            if ($shaAfter -ne $file.Sha256Before) {
                throw "병합 입력 원본의 SHA-256이 변경되었습니다: $($file.Path)"
            }
            $results.Add([pscustomobject]@{
                Path = $file.Path
                Sha256 = $file.Sha256Before
                ByteLength = $file.ByteLength
                Loaded = $loaded
                SourcePreserved = $true
                HancomDiskAccess = $false
            })
        }
        $textAfter = [string]$Session.Hwp.GetTextFile('UNICODE', '')
        $pageCountAfter = [int]$Session.Hwp.PageCount
    }
    catch {
        return New-HwpResult -Status FAILED -Command merge-documents -Data ([pscustomobject]@{
            Files = @($results)
            TotalBytes = $totalBytes
        }) -Errors @("문서 병합 중 오류가 발생했습니다: $($_.Exception.Message)")
    }
    if ($textAfter.Length -le $textBefore.Length -or $pageCountAfter -lt $pageCountBefore) {
        return New-HwpResult -Status FAILED -Command merge-documents -Errors @('문서 병합 사후검증에 실패했습니다.')
    }

    New-HwpResult -Status PASS -Command merge-documents -Data ([pscustomobject]@{
        OperationId = Get-HwpOperationId -Operation $Operation
        Type = 'merge-documents'
        Applied = $true
        Files = @($results)
        FileCount = $results.Count
        TotalBytes = $totalBytes
        PageBreakBetween = $pageBreakBetween
        PageCountBefore = $pageCountBefore
        PageCountAfter = $pageCountAfter
        TextLengthBefore = $textBefore.Length
        TextLengthAfter = $textAfter.Length
        SourcePreserved = $true
        HancomDiskAccess = $false
    })
}

function Invoke-HwpReferenceObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation
    )

    switch ([string]$Operation.type) {
        'add-bookmark' { Invoke-HwpAddBookmark -Session $Session -Operation $Operation; break }
        'add-hyperlink' { Invoke-HwpAddHyperlink -Session $Session -Operation $Operation; break }
        'add-caption' { Invoke-HwpAddCaption -Session $Session -Operation $Operation; break }
        'add-footnote' { Invoke-HwpAddNote -Session $Session -Operation $Operation; break }
        'add-endnote' { Invoke-HwpAddNote -Session $Session -Operation $Operation; break }
        'build-toc' { Invoke-HwpBuildToc -Session $Session -Operation $Operation; break }
        default {
            New-HwpResult -Status BLOCKED -Command reference-object -Errors @(
                "지원하지 않는 참조 개체 작업입니다: $($Operation.type)"
            )
        }
    }
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
        'insert-table' { Invoke-HwpInsertTable -Session $Session -Operation $Operation; break }
        'set-table-cell' { Invoke-HwpSetTableCell -Session $Session -Operation $Operation; break }
        'add-table-row' { Invoke-HwpAddTableRow -Session $Session -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced; break }
        'insert-image' { Invoke-HwpInsertImage -Session $Session -Operation $Operation; break }
        'replace-image' { Invoke-HwpReplaceImage -Session $Session -Operation $Operation; break }
        'apply-char-style' { Invoke-HwpCharStyle -Session $Session -Operation $Operation; break }
        'apply-para-style' { Invoke-HwpParaStyle -Session $Session -Operation $Operation; break }
        'insert-page-break' { Invoke-HwpPageBreak -Session $Session -Operation $Operation; break }
        'set-section' { Invoke-HwpSetSection -Session $Session -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced; break }
        'set-header-footer' { Invoke-HwpHeaderFooter -Session $Session -Operation $Operation; break }
        'set-page-number' { Invoke-HwpSetPageNumber -Session $Session -Operation $Operation; break }
        'add-bookmark' { Invoke-HwpReferenceObject -Session $Session -Operation $Operation; break }
        'add-hyperlink' { Invoke-HwpReferenceObject -Session $Session -Operation $Operation; break }
        'add-caption' { Invoke-HwpReferenceObject -Session $Session -Operation $Operation; break }
        'add-footnote' { Invoke-HwpReferenceObject -Session $Session -Operation $Operation; break }
        'add-endnote' { Invoke-HwpReferenceObject -Session $Session -Operation $Operation; break }
        'build-toc' { Invoke-HwpReferenceObject -Session $Session -Operation $Operation; break }
        'merge-documents' { Invoke-HwpMergeDocuments -Session $Session -Operation $Operation -ApprovedAdvanced:$ApprovedAdvanced; break }
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

function Get-HwpFailureArtifactPath {
    param([Parameter(Mandatory)][string]$FinalPath)

    $directory = [IO.Path]::GetDirectoryName($FinalPath)
    $name = [IO.Path]::GetFileNameWithoutExtension($FinalPath)
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $candidate = [IO.Path]::Combine($directory, "${name}_${stamp}.failed.hwp")
    $sequence = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = [IO.Path]::Combine($directory, ('{0}_{1}_{2:D2}.failed.hwp' -f $name, $stamp, $sequence))
        $sequence++
    }
    $candidate
}

function Test-HwpOperationPostcondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Operation,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Inspection
    )

    $kind = if ((Test-HwpEditProperty -InputObject $Operation -Name 'verify') -and
        (Test-HwpEditProperty -InputObject $Operation.verify -Name 'kind')) {
        [string]$Operation.verify.kind
    }
    else {
        ''
    }
    $expected = if ((Test-HwpEditProperty -InputObject $Operation -Name 'verify') -and
        (Test-HwpEditProperty -InputObject $Operation.verify -Name 'expected')) {
        $Operation.verify.expected
    }
    else {
        $null
    }
    $operationId = Get-HwpOperationId -Operation $Operation
    $passed = $false
    $actual = $null

    switch ($kind) {
        'text-contains' {
            $actual = [string]$Inspection.Text
            $passed = $actual.Contains([string]$expected, [StringComparison]::Ordinal)
            break
        }
        'text-not-contains' {
            $actual = [string]$Inspection.Text
            $passed = -not $actual.Contains([string]$expected, [StringComparison]::Ordinal)
            break
        }
        'text-count' {
            $needle = if (Test-HwpEditProperty -InputObject $Operation.verify -Name 'value') {
                [string]$Operation.verify.value
            }
            elseif (Test-HwpEditProperty -InputObject $Operation -Name 'after') {
                [string]$Operation.after
            }
            else {
                Get-HwpOperationAnchor -Operation $Operation
            }
            $count = 0
            $offset = 0
            $text = [string]$Inspection.Text
            while ($needle.Length -gt 0 -and $offset -le $text.Length - $needle.Length) {
                $index = $text.IndexOf($needle, $offset, [StringComparison]::Ordinal)
                if ($index -lt 0) { break }
                $count++
                $offset = $index + $needle.Length
            }
            $actual = $count
            $passed = $count -eq [int]$expected
            break
        }
        'field-equals' {
            $fieldName = if ((Test-HwpEditProperty -InputObject $Operation -Name 'target') -and
                (Test-HwpEditProperty -InputObject $Operation.target -Name 'fieldName')) {
                [string]$Operation.target.fieldName
            }
            else {
                Get-HwpOperationAnchor -Operation $Operation
            }
            $property = $Inspection.Fields.PSObject.Properties[$fieldName]
            $actual = if ($null -eq $property) { $null } else { [string]$property.Value }
            $passed = $null -ne $property -and [string]::Equals([string]$actual, [string]$expected, [StringComparison]::Ordinal)
            break
        }
        'control-count' {
            $ctrlId = if (Test-HwpEditProperty -InputObject $Operation.verify -Name 'ctrlId') {
                [string]$Operation.verify.ctrlId
            }
            else {
                ''
            }
            $actual = @($Inspection.Controls | Where-Object { [string]$_.CtrlId -eq $ctrlId }).Count
            $passed = $ctrlId.Length -gt 0 -and $actual -ge [int]$expected
            break
        }
        'operation-applied' {
            $actual = $true
            $passed = [bool]$expected
            break
        }
        default {
            return New-HwpResult -Status BLOCKED -Command verify-operation -Data ([pscustomobject]@{
                OperationId = $operationId
                Kind = $kind
                Expected = $expected
                Actual = $null
                Passed = $false
            }) -Errors @("지원하지 않는 후조건 검사입니다: $kind")
        }
    }

    $data = [pscustomobject]@{
        OperationId = $operationId
        Kind = $kind
        Expected = $expected
        Actual = $actual
        Passed = $passed
    }
    if (-not $passed) {
        return New-HwpResult -Status FAILED -Command verify-operation -Data $data -Errors @(
            "작업 $operationId 후조건이 충족되지 않았습니다: $kind"
        )
    }
    New-HwpResult -Status PASS -Command verify-operation -Data $data
}

function New-HwpApplyResult {
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')][string]$Status,
        [string]$SourcePath = '',
        [string]$SourceSha256 = '',
        [string]$OutputPath = '',
        [string]$TemporaryPath = '',
        [string]$FailedArtifactPath = '',
        [object[]]$OperationResults = @(),
        [object[]]$VerificationResults = @(),
        [AllowNull()][object]$Inspection = $null,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $data = [pscustomobject]@{
        SourcePath = $SourcePath
        SourceSha256 = $SourceSha256
        OutputPath = $OutputPath
        TemporaryPath = $TemporaryPath
        FailedArtifactPath = $FailedArtifactPath
        OperationResults = @($OperationResults)
        VerificationResults = @($VerificationResults)
        Inspection = $Inspection
    }
    $result = New-HwpResult -Status $Status -Command apply-plan -Data $data -Warnings $Warnings -Errors $Errors
    $result | Add-Member NoteProperty SourcePath $SourcePath
    $result | Add-Member NoteProperty SourceSha256 $SourceSha256
    $result | Add-Member NoteProperty OutputPath $OutputPath
    $result | Add-Member NoteProperty TemporaryPath $TemporaryPath
    $result | Add-Member NoteProperty FailedArtifactPath $FailedArtifactPath
    $result | Add-Member NoteProperty OperationResults @($OperationResults)
    $result | Add-Member NoteProperty VerificationResults @($VerificationResults)
    $result | Add-Member NoteProperty Inspection $Inspection
    $result
}

function Invoke-HwpApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Plan,
        [string]$OutputPath = '',
        [bool]$ApproveAdvanced = $false,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [scriptblock]$Inspector = {
            param($path, $executionContext, $capabilities)
            Get-HwpInspection -LiteralPath $path -ExecutionContext $executionContext -Capabilities $capabilities
        }
    )

    $validation = Test-HwpEditPlan -Plan $Plan
    if ($validation.Status -ne 'PASS') {
        return New-HwpApplyResult -Status BLOCKED -Errors @($validation.Errors) -Warnings @($validation.Warnings)
    }
    $runtimeApproval = Assert-HwpRuntimeAdvancedApproval -Plan $Plan -ApproveAdvanced:$ApproveAdvanced
    if ($runtimeApproval.Status -ne 'PASS') {
        return New-HwpApplyResult -Status BLOCKED -Errors @($runtimeApproval.Errors) -Warnings @($runtimeApproval.Warnings)
    }

    try {
        $format = Get-HwpFileKind -LiteralPath $LiteralPath
        $sourcePath = $format.Path
        $sourceHash = Get-HwpSha256 -LiteralPath $sourcePath
    }
    catch {
        return New-HwpApplyResult -Status BLOCKED -Errors @($_.Exception.Message)
    }
    if (-not $format.ExtensionMatches) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash -Errors @(
            '확장자와 실제 파일 형식이 다릅니다.'
        )
    }
    if ($format.DetectedKind -ne 'HWP-BINARY') {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash -Errors @(
            '현재 원자적 네이티브 편집은 HWP 또는 HWT 바이너리만 지원합니다.'
        )
    }
    try {
        $plannedSourcePath = [IO.Path]::GetFullPath([string]$Plan.source.path)
    }
    catch {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash -Errors @(
            "계획의 source.path가 올바르지 않습니다: $($_.Exception.Message)"
        )
    }
    if (-not [string]::Equals($sourcePath, $plannedSourcePath, [StringComparison]::OrdinalIgnoreCase)) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash -Errors @(
            '계획의 source.path가 적용 대상과 다릅니다.'
        )
    }
    if (-not [string]::Equals($sourceHash, [string]$Plan.source.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash -Errors @(
            '계획의 source.sha256이 현재 원본 SHA-256과 다릅니다.'
        )
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $hwpCandidate = [IO.Path]::ChangeExtension($sourcePath, '.hwp')
        $finalPath = Get-HwpVersionedPath -LiteralPath $hwpCandidate
    }
    else {
        $finalPath = [IO.Path]::GetFullPath($OutputPath)
    }
    if ([string]::Equals($sourcePath, $finalPath, [StringComparison]::OrdinalIgnoreCase)) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -Errors @('원본 문서와 같은 출력 경로는 허용되지 않습니다.')
    }
    if ([IO.Path]::GetExtension($finalPath).ToLowerInvariant() -ne '.hwp') {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -Errors @('결과 경로는 .hwp 확장자여야 합니다.')
    }
    $finalDirectory = [IO.Path]::GetDirectoryName($finalPath)
    if (-not (Test-Path -LiteralPath $finalDirectory -PathType Container)) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -Errors @("결과 폴더가 존재하지 않습니다: $finalDirectory")
    }
    if (Test-Path -LiteralPath $finalPath) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -Errors @("기존 결과 파일을 덮어쓰지 않습니다: $finalPath")
    }
    $route = Resolve-HwpBackend -Command apply -DetectedKind $format.DetectedKind `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpApplyResult -Status $route.Status -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -Errors @("백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)")
    }

    $finalName = [IO.Path]::GetFileNameWithoutExtension($finalPath)
    $temporaryPath = [IO.Path]::Combine(
        $finalDirectory,
        ('{0}.{1}.partial.hwp' -f $finalName, [guid]::NewGuid().ToString('n'))
    )
    $operationResults = [Collections.Generic.List[object]]::new()
    $appliedOperations = [Collections.Generic.List[object]]::new()
    $verificationResults = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $session = $null
    $stopped = $false
    $failedArtifactPath = ''
    $inspection = $null

    try {
        $session = & $SessionFactory $ExecutionContext
        if ($null -eq $session) {
            throw '세션 팩터리가 한컴 세션을 반환하지 않았습니다.'
        }
        $open = Open-HwpDocumentFromMemory -Session $session -LiteralPath $sourcePath
        if ($open.Status -ne 'PASS') {
            foreach ($message in @($open.Errors)) { $errors.Add([string]$message) }
            $stopped = $true
        }

        if (-not $stopped) {
            foreach ($operation in @($Plan.operations)) {
                $result = Invoke-HwpEditOperation -Session $session -Operation $operation `
                    -ApprovedAdvanced:([bool]$ApproveAdvanced)
                $operationResults.Add($result)
                if ($result.Status -eq 'PASS') {
                    $appliedOperations.Add($operation)
                    continue
                }

                $policy = if (Test-HwpEditProperty -InputObject $operation -Name 'onFailure') {
                    [string]$operation.onFailure
                }
                else {
                    'stop'
                }
                if ($policy -eq 'skip') {
                    $warnings.Add("작업을 건너뛰었습니다: $(Get-HwpOperationId -Operation $operation)")
                    foreach ($message in @($result.Errors)) { $warnings.Add([string]$message) }
                    continue
                }

                foreach ($message in @($result.Errors)) { $errors.Add([string]$message) }
                $stopped = $true
                break
            }
        }

        if (-not $stopped) {
            $save = Save-HwpMemoryDocument -Session $session -SourcePath $sourcePath -OutputPath $temporaryPath
            if ($save.Status -ne 'PASS') {
                foreach ($message in @($save.Errors)) { $errors.Add([string]$message) }
                $stopped = $true
            }
        }
    }
    catch {
        $errors.Add("편집 계획 실행 중 오류가 발생했습니다: $($_.Exception.Message)")
        $stopped = $true
    }
    finally {
        if ($null -ne $session) {
            Close-HwpSession -Session $session
        }
    }

    if ($stopped) {
        return New-HwpApplyResult -Status BLOCKED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -TemporaryPath $temporaryPath -OperationResults @($operationResults) `
            -Warnings @($warnings) -Errors @($errors)
    }

    $inspection = & $Inspector $temporaryPath $ExecutionContext $Capabilities
    if ($inspection.Status -eq 'BLOCKED' -or $inspection.Status -eq 'FAILED') {
        foreach ($message in @($inspection.Errors)) { $errors.Add([string]$message) }
    }
    else {
        foreach ($operation in $appliedOperations) {
            $verification = Test-HwpOperationPostcondition -Operation $operation -Inspection $inspection
            $verificationResults.Add($verification)
            if ($verification.Status -ne 'PASS') {
                foreach ($message in @($verification.Errors)) { $errors.Add([string]$message) }
            }
        }
    }

    $sourceHashAfter = Get-HwpSha256 -LiteralPath $sourcePath
    if ($sourceHashAfter -ne $sourceHash) {
        $errors.Add('적용 과정에서 원본 SHA-256이 변경되었습니다.')
    }

    if ($errors.Count -gt 0) {
        if (Test-Path -LiteralPath $temporaryPath) {
            $failedArtifactPath = Get-HwpFailureArtifactPath -FinalPath $finalPath
            try {
                [IO.File]::Move($temporaryPath, $failedArtifactPath)
            }
            catch {
                $errors.Add("실패 산출물을 분리하지 못했습니다: $($_.Exception.Message)")
            }
        }
        return New-HwpApplyResult -Status FAILED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -TemporaryPath $temporaryPath -FailedArtifactPath $failedArtifactPath `
            -OperationResults @($operationResults) -VerificationResults @($verificationResults) `
            -Inspection $inspection -Warnings @($warnings) -Errors @($errors)
    }

    try {
        [IO.File]::Move($temporaryPath, $finalPath)
    }
    catch {
        $errors.Add("검증된 임시 결과를 최종 경로로 승격하지 못했습니다: $($_.Exception.Message)")
        if (Test-Path -LiteralPath $temporaryPath) {
            $failedArtifactPath = Get-HwpFailureArtifactPath -FinalPath $finalPath
            try { [IO.File]::Move($temporaryPath, $failedArtifactPath) } catch { }
        }
        return New-HwpApplyResult -Status FAILED -SourcePath $sourcePath -SourceSha256 $sourceHash `
            -OutputPath $finalPath -TemporaryPath $temporaryPath -FailedArtifactPath $failedArtifactPath `
            -OperationResults @($operationResults) -VerificationResults @($verificationResults) `
            -Inspection $inspection -Warnings @($warnings) -Errors @($errors)
    }

    $status = if ($warnings.Count -gt 0 -or $inspection.Status -eq 'PASS_WITH_WARNINGS') {
        'PASS_WITH_WARNINGS'
    }
    else {
        'PASS'
    }
    New-HwpApplyResult -Status $status -SourcePath $sourcePath -SourceSha256 $sourceHash `
        -OutputPath $finalPath -TemporaryPath $temporaryPath -OperationResults @($operationResults) `
        -VerificationResults @($verificationResults) -Inspection $inspection -Warnings @($warnings)
}

Export-ModuleMember -Function @(
    'Resolve-HwpTextTarget',
    'Select-HwpResolvedTarget',
    'Invoke-HwpReplaceText',
    'Invoke-HwpInsertRelative',
    'Invoke-HwpDeleteRange',
    'Invoke-HwpSetField',
    'Enter-HwpTableCell',
    'Invoke-HwpInsertTable',
    'Invoke-HwpSetTableCell',
    'Invoke-HwpAddTableRow',
    'Invoke-HwpInsertImage',
    'Invoke-HwpReplaceImage',
    'Get-HwpTextStyleSnapshot',
    'Invoke-HwpCharStyle',
    'Invoke-HwpParaStyle',
    'Invoke-HwpPageBreak',
    'Get-HwpSectionSnapshot',
    'Invoke-HwpSetSection',
    'Get-HwpHeaderFooterTextSnapshot',
    'Invoke-HwpHeaderFooter',
    'Invoke-HwpSetPageNumber',
    'Invoke-HwpAddBookmark',
    'Invoke-HwpAddHyperlink',
    'Invoke-HwpAddCaption',
    'Invoke-HwpAddNote',
    'Invoke-HwpBuildToc',
    'Invoke-HwpReferenceObject',
    'Invoke-HwpMergeDocuments',
    'Invoke-HwpEditOperation',
    'Save-HwpMemoryDocument',
    'Test-HwpOperationPostcondition',
    'Invoke-HwpApply'
)
