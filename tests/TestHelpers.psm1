function New-Operation {
    [CmdletBinding()]
    param(
        [string]$Type = 'replace-text',
        [string]$Anchor = '기존 문구',
        [string]$Before = '기존 문구',
        [string]$After = '새 문구',
        [ValidateSet('safe','advanced')]
        [string]$Risk = 'safe',
        [int]$ExpectedMatches = 1,
        [ValidateSet('stop','skip')]
        [string]$OnFailure = 'stop'
    )

    [pscustomobject]@{
        id = [guid]::NewGuid().ToString('n')
        type = $Type
        risk = $Risk
        expectedMatches = $ExpectedMatches
        target = [pscustomobject]@{
            anchor = $Anchor
            beforeContext = ''
            afterContext = ''
        }
        before = $Before
        after = $After
        onFailure = $OnFailure
        verify = [pscustomobject]@{
            kind = 'text-contains'
            expected = $After
        }
    }
}

function New-ValidPlan {
    [CmdletBinding()]
    param(
        [string]$Type = 'replace-text',
        [ValidateSet('safe','advanced')]
        [string]$Risk = 'safe',
        [bool]$ApprovedAdvanced = $false,
        [string]$VerifyExpected = '새 문구',
        [string]$SourcePath = 'C:\fixture.hwp',
        [string]$SourceSha256 = ('a' * 64)
    )

    [pscustomobject]@{
        version = '1.0'
        source = [pscustomobject]@{
            path = $SourcePath
            sha256 = $SourceSha256
        }
        approvedAdvanced = $ApprovedAdvanced
        operations = @(
            New-Operation -Type $Type -Anchor '기존 문구' -Before '기존 문구' -After $VerifyExpected -Risk $Risk
        )
    }
}

function New-FieldOperation {
    [CmdletBinding()]
    param(
        [string]$Name = '담당자',
        [string]$Before = '시험 담당자',
        [string]$After = '홍길동'
    )

    $operation = New-Operation -Type 'set-field' -Anchor $Name -Before $Before -After $After
    $operation.target | Add-Member NoteProperty fieldName $Name
    $operation.verify.kind = 'field-equals'
    $operation
}

function Set-OperationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Operation,
        [string]$BeforeContext = '',
        [string]$AfterContext = ''
    )

    process {
        $Operation.target.beforeContext = $BeforeContext
        $Operation.target.afterContext = $AfterContext
        $Operation
    }
}

function New-InsertTableOperation {
    [CmdletBinding()]
    param(
        [string]$Anchor = '표 삽입 위치',
        [ValidateRange(1, 100)]
        [int]$Rows = 2,
        [ValidateRange(1, 100)]
        [int]$Columns = 2,
        [ValidateSet('before','after')]
        [string]$Placement = 'after'
    )

    $operation = New-Operation -Type 'insert-table' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty rows $Rows
    $operation.target | Add-Member NoteProperty columns $Columns
    $operation.target | Add-Member NoteProperty placement $Placement
    $operation.verify.kind = 'control-count'
    $operation.verify.expected = 1
    $operation.verify | Add-Member NoteProperty ctrlId 'tbl'
    $operation
}

function New-TableCellOperation {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 1000)][int]$TableIndex,
        [ValidateRange(1, 1000)][int]$Row,
        [ValidateRange(1, 1000)][int]$Column,
        [string]$Before = '',
        [string]$After
    )

    $operation = New-Operation -Type 'set-table-cell' -Anchor 'table-cell' -Before $Before -After $After
    $operation.target | Add-Member NoteProperty tableIndex $TableIndex
    $operation.target | Add-Member NoteProperty row $Row
    $operation.target | Add-Member NoteProperty column $Column
    $operation.verify.kind = 'text-contains'
    $operation.verify.expected = $After
    $operation
}

function New-AddTableRowOperation {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 1000)][int]$TableIndex,
        [ValidateRange(1, 1000)][int]$AfterRow
    )

    $operation = New-Operation -Type 'add-table-row' -Anchor 'table-row' -Before '' -After '' -Risk 'advanced'
    $operation.target | Add-Member NoteProperty tableIndex $TableIndex
    $operation.target | Add-Member NoteProperty afterRow $AfterRow
    $operation.verify.kind = 'operation-applied'
    $operation.verify.expected = $true
    $operation
}

function New-InsertImageOperation {
    [CmdletBinding()]
    param(
        [string]$Anchor = '이미지 삽입 위치',
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 1000)][double]$WidthMm = 20,
        [ValidateRange(1, 1000)][double]$HeightMm = 20
    )

    $operation = New-Operation -Type 'insert-image' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty imagePath $Path
    $operation.target | Add-Member NoteProperty widthMm $WidthMm
    $operation.target | Add-Member NoteProperty heightMm $HeightMm
    $operation.target | Add-Member NoteProperty placement 'after'
    $operation.verify.kind = 'control-count'
    $operation.verify.expected = 1
    $operation.verify | Add-Member NoteProperty ctrlId 'gso'
    $operation
}

Export-ModuleMember -Function @(
    'New-Operation',
    'New-ValidPlan',
    'New-FieldOperation',
    'Set-OperationContext',
    'New-InsertTableOperation',
    'New-TableCellOperation',
    'New-AddTableRowOperation',
    'New-InsertImageOperation'
)
