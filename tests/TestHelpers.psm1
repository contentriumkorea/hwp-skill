Import-Module (Join-Path $PSScriptRoot '../skill/hwp-skill/scripts/lib/HwpExecution.psm1') -Force

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

function New-CharStyleOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [ValidateRange(1, 4096)][double]$HeightPt = 10,
        [bool]$Bold = $false,
        [bool]$Italic = $false
    )

    $operation = New-Operation -Type 'apply-char-style' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty heightPt $HeightPt
    $operation.target | Add-Member NoteProperty bold $Bold
    $operation.target | Add-Member NoteProperty italic $Italic
    $operation.verify.kind = 'operation-applied'
    $operation.verify.expected = $true
    $operation
}

function New-ParaStyleOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [ValidateSet('left','center','right','justify')]
        [string]$Align = 'left'
    )

    $operation = New-Operation -Type 'apply-para-style' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty align $Align
    $operation.verify.kind = 'operation-applied'
    $operation.verify.expected = $true
    $operation
}

function New-PageBreakOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [ValidateSet('before','after')]
        [string]$Placement = 'after'
    )

    $operation = New-Operation -Type 'insert-page-break' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty placement $Placement
    $operation.verify.kind = 'operation-applied'
    $operation.verify.expected = $true
    $operation
}

function New-SectionOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [ValidateSet('portrait','landscape')]
        [string]$Orientation = 'portrait',
        [ValidateRange(0, 100)][double]$LeftMarginMm = 15,
        [ValidateRange(0, 100)][double]$RightMarginMm = 15,
        [ValidateRange(0, 100)][double]$TopMarginMm = 10,
        [ValidateRange(0, 100)][double]$BottomMarginMm = 10
    )

    $operation = New-Operation -Type 'set-section' -Anchor $Anchor -Before '' -After '' -Risk 'advanced'
    $operation.target | Add-Member NoteProperty paperSize 'A4'
    $operation.target | Add-Member NoteProperty orientation $Orientation
    $operation.target | Add-Member NoteProperty leftMarginMm $LeftMarginMm
    $operation.target | Add-Member NoteProperty rightMarginMm $RightMarginMm
    $operation.target | Add-Member NoteProperty topMarginMm $TopMarginMm
    $operation.target | Add-Member NoteProperty bottomMarginMm $BottomMarginMm
    $operation.verify.kind = 'operation-applied'
    $operation.verify.expected = $true
    $operation
}

function New-HeaderFooterOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [ValidateSet('header','footer')]
        [string]$Kind,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('both','even','odd')]
        [string]$Pages = 'both'
    )

    $operation = New-Operation -Type 'set-header-footer' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty kind $Kind
    $operation.target | Add-Member NoteProperty pages $Pages
    $operation.target | Add-Member NoteProperty text $Text
    $operation.verify.kind = 'control-count'
    $operation.verify.expected = 1
    $operation.verify | Add-Member NoteProperty ctrlId $(if ($Kind -eq 'header') { 'head' } else { 'foot' })
    $operation
}

function New-PageNumberOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [ValidateSet('top-left','top-center','top-right','bottom-left','bottom-center','bottom-right')]
        [string]$Position = 'bottom-center',
        [ValidateRange(1, 9999)][int]$StartNumber = 1
    )

    $operation = New-Operation -Type 'set-page-number' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty position $Position
    $operation.target | Add-Member NoteProperty startNumber $StartNumber
    $operation.verify.kind = 'control-count'
    $operation.verify.expected = 1
    $operation.verify | Add-Member NoteProperty ctrlId 'pgnp'
    $operation
}

function New-BookmarkOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [Parameter(Mandatory)][ValidatePattern('^[^;\r\n]{1,120}$')][string]$Name
    )

    $operation = New-Operation -Type 'add-bookmark' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty name $Name
    $operation.verify.kind = 'control-count'
    $operation.verify.expected = 1
    $operation.verify | Add-Member NoteProperty ctrlId '%bmk'
    $operation
}

function New-HyperlinkOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [Parameter(Mandatory)][ValidatePattern('^https?://')][string]$Url
    )

    $operation = New-Operation -Type 'add-hyperlink' -Anchor $Anchor -Before '' -After ''
    $operation.target | Add-Member NoteProperty url $Url
    $operation.verify.kind = 'control-count'
    $operation.verify.expected = 1
    $operation.verify | Add-Member NoteProperty ctrlId '%hlk'
    $operation
}

function New-CaptionOperation {
    [CmdletBinding()]
    param(
        [ValidateSet('tbl','gso')][string]$ControlId = 'tbl',
        [ValidateRange(1, 10000)][int]$ControlIndex = 1,
        [Parameter(Mandatory)][string]$Text
    )

    $operation = New-Operation -Type 'add-caption' -Anchor 'control-caption' -Before '' -After $Text
    $operation.target | Add-Member NoteProperty controlId $ControlId
    $operation.target | Add-Member NoteProperty controlIndex $ControlIndex
    $operation.target | Add-Member NoteProperty text $Text
    $operation.verify.kind = 'text-contains'
    $operation.verify.expected = $Text
    $operation
}

function New-NoteOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('add-footnote','add-endnote')][string]$Type,
        [Parameter(Mandatory)][string]$Anchor,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('before','after')][string]$Placement = 'after'
    )

    $operation = New-Operation -Type $Type -Anchor $Anchor -Before '' -After $Text
    $operation.target | Add-Member NoteProperty text $Text
    $operation.target | Add-Member NoteProperty placement $Placement
    $operation.verify.kind = 'text-contains'
    $operation.verify.expected = $Text
    $operation
}

function New-TocOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Anchor,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$HeadingAnchors,
        [string]$Title = '차례',
        [ValidateSet('before','after')][string]$Placement = 'after',
        [bool]$PageBreakBefore = $true
    )

    $operation = New-Operation -Type 'build-toc' -Anchor $Anchor -Before '' -After $Title
    $operation.target | Add-Member NoteProperty headingAnchors @($HeadingAnchors)
    $operation.target | Add-Member NoteProperty title $Title
    $operation.target | Add-Member NoteProperty placement $Placement
    $operation.target | Add-Member NoteProperty pageBreakBefore $PageBreakBefore
    $operation.verify.kind = 'text-contains'
    $operation.verify.expected = $Title
    $operation
}

function New-MergeOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Paths,
        [bool]$PageBreakBetween = $true,
        [string]$VerifyText = '기존 문구',
        [ValidateRange(1, 10000)][int]$VerifyCount = 2
    )

    $operation = New-Operation -Type 'merge-documents' -Anchor 'document-end' -Before '' -After '' -Risk 'advanced'
    $operation.target | Add-Member NoteProperty paths @($Paths)
    $operation.target | Add-Member NoteProperty pageBreakBetween $PageBreakBetween
    $operation.verify.kind = 'text-count'
    $operation.verify.expected = $VerifyCount
    $operation.verify | Add-Member NoteProperty value $VerifyText
    $operation
}

function New-TestInteractiveExecutionContext {
    New-HwpExecutionContext -Mode interactive -AllowInteractiveWindow
}

Export-ModuleMember -Function @(
    'New-Operation',
    'New-TestInteractiveExecutionContext',
    'New-ValidPlan',
    'New-FieldOperation',
    'Set-OperationContext',
    'New-InsertTableOperation',
    'New-TableCellOperation',
    'New-AddTableRowOperation',
    'New-InsertImageOperation',
    'New-CharStyleOperation',
    'New-ParaStyleOperation',
    'New-PageBreakOperation',
    'New-SectionOperation',
    'New-HeaderFooterOperation',
    'New-PageNumberOperation',
    'New-BookmarkOperation',
    'New-HyperlinkOperation',
    'New-CaptionOperation',
    'New-NoteOperation',
    'New-TocOperation',
    'New-MergeOperation'
)
