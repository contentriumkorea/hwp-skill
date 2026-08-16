Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
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
        [scriptblock]$SessionFactory = { New-HwpSession }
    )

    $validation = Test-HwpEditPlan -Plan $Plan
    if ($validation.Status -ne 'PASS') {
        return New-HwpApplyResult -Status BLOCKED -Errors @($validation.Errors) -Warnings @($validation.Warnings)
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
        $session = & $SessionFactory
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
                    -ApprovedAdvanced:([bool]$Plan.approvedAdvanced)
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

    $inspection = Get-HwpInspection -LiteralPath $temporaryPath
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
    'Invoke-HwpEditOperation',
    'Save-HwpMemoryDocument',
    'Test-HwpOperationPostcondition',
    'Invoke-HwpApply'
)
