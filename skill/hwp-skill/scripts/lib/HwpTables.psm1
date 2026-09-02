Set-StrictMode -Version Latest

function New-HwpTableGrid {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 65535)][int]$RowCount,
        [ValidateRange(0, 65535)][int]$ColumnCount,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Cells,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Warnings,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TableLabel,
        [ValidateRange(1, 100000000)][long]$MaximumGridSlots = 5000000
    )

    [long]$slotCount = [long]$RowCount * [long]$ColumnCount
    if ($slotCount -gt $MaximumGridSlots) {
        throw [IO.InvalidDataException]::new(
            "$TableLabel 표 그리드가 안전 한도 $MaximumGridSlots 칸을 초과했습니다."
        )
    }

    $grid = [Collections.Generic.List[object]]::new()
    for ($row = 0; $row -lt $RowCount; $row++) {
        $grid.Add([object[]]::new($ColumnCount))
    }

    foreach ($cell in $Cells) {
        $rowAddress = [int]$cell.RowAddress
        $columnAddress = [int]$cell.ColumnAddress
        $rowSpan = [int]$cell.RowSpan
        $columnSpan = [int]$cell.ColumnSpan
        if ($rowAddress -lt 0 -or $columnAddress -lt 0 -or $rowSpan -lt 1 -or $columnSpan -lt 1 -or
                ($rowAddress + $rowSpan) -gt $RowCount -or
                ($columnAddress + $columnSpan) -gt $ColumnCount) {
            $Warnings.Add(
                "$TableLabel 셀 $($cell.Index)의 주소 또는 병합 범위가 선언된 행·열 범위를 벗어났습니다."
            )
            continue
        }

        $overlap = $false
        for ($row = $rowAddress; $row -lt ($rowAddress + $rowSpan); $row++) {
            for ($column = $columnAddress; $column -lt ($columnAddress + $columnSpan); $column++) {
                if ($null -ne $grid[$row][$column]) {
                    $overlap = $true
                    break
                }
            }
            if ($overlap) { break }
        }
        if ($overlap) {
            $Warnings.Add(
                "$TableLabel 셀 $($cell.Index)은 기존 셀과 겹치는 셀이므로 그리드에 중복 배치하지 않았습니다."
            )
            continue
        }

        for ($row = $rowAddress; $row -lt ($rowAddress + $rowSpan); $row++) {
            for ($column = $columnAddress; $column -lt ($columnAddress + $columnSpan); $column++) {
                $isAnchor = $row -eq $rowAddress -and $column -eq $columnAddress
                $grid[$row][$column] = [pscustomobject][ordered]@{
                    cellIndex = [int]$cell.Index
                    isAnchor = $isAnchor
                    mergedInto = if ($isAnchor) {
                        $null
                    }
                    else {
                        [pscustomobject][ordered]@{
                            rowAddress = $rowAddress
                            columnAddress = $columnAddress
                        }
                    }
                }
            }
        }
    }

    $missingSlots = 0
    for ($row = 0; $row -lt $RowCount; $row++) {
        for ($column = 0; $column -lt $ColumnCount; $column++) {
            if ($null -eq $grid[$row][$column]) { $missingSlots++ }
        }
    }
    if ($missingSlots -gt 0) {
        $Warnings.Add("$TableLabel 선언 그리드에서 셀이 배치되지 않은 칸이 ${missingSlots}개 있습니다.")
    }

    foreach ($row in $grid) {
        Write-Output -NoEnumerate ([object[]]$row)
    }
}

Export-ModuleMember -Function 'New-HwpTableGrid'
