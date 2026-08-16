Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpExecution.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpCapabilities.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpBackendRouter.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpSession.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpPlan.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpEdit.psm1') -ErrorAction Stop

function Test-HwpGenerateProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
}

function New-HwpGenerateResult {
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')][string]$Status,
        [string]$Mode = '',
        [string]$TemplatePath = '',
        [string]$TemplateSha256 = '',
        [string]$OutputPath = '',
        [AllowNull()][object]$Before = $null,
        [AllowNull()][object]$After = $null,
        [object[]]$OperationResults = @(),
        [string]$FailedArtifactPath = '',
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $data = [pscustomobject]@{
        Mode = $Mode
        TemplatePath = $TemplatePath
        TemplateSha256 = $TemplateSha256
        OutputPath = $OutputPath
        Before = $Before
        After = $After
        OperationResults = @($OperationResults)
        FailedArtifactPath = $FailedArtifactPath
    }
    $result = New-HwpResult -Status $Status -Command generate -Data $data -Warnings $Warnings -Errors $Errors
    foreach ($property in $data.PSObject.Properties) {
        $result | Add-Member NoteProperty $property.Name $property.Value
    }
    $result
}

function Test-HwpNewDocumentPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][object]$Plan)

    $errors = [Collections.Generic.List[string]]::new()
    if (-not (Test-HwpGenerateProperty -InputObject $Plan -Name 'version') -or [string]$Plan.version -ne '1.0') {
        $errors.Add("새 문서 계획 version은 '1.0'이어야 합니다.")
    }
    $content = @()
    if (Test-HwpGenerateProperty -InputObject $Plan -Name 'content') {
        $content = @($Plan.content)
    }
    if ($content.Count -lt 1 -or $content.Count -gt 500) {
        $errors.Add('새 문서 content에는 1~500개의 블록이 필요합니다.')
        $content = @()
    }

    $tableCount = 0
    $imageCount = 0
    $fieldNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $content.Count; $index++) {
        $block = $content[$index]
        $prefix = "content[$index]"
        if ($null -eq $block -or -not (Test-HwpGenerateProperty -InputObject $block -Name 'type')) {
            $errors.Add("$prefix.type이 없습니다.")
            continue
        }
        $type = [string]$block.type
        switch ($type) {
            'paragraph' {
                if (-not (Test-HwpGenerateProperty -InputObject $block -Name 'text')) {
                    $errors.Add("$prefix.text가 없습니다.")
                }
                elseif ([string]$block.text -match "\x00") {
                    $errors.Add("$prefix.text에 NUL 문자를 사용할 수 없습니다.")
                }
                break
            }
            'table' {
                $tableCount++
                $rows = if (Test-HwpGenerateProperty -InputObject $block -Name 'rows') { [int]$block.rows } else { 0 }
                $columns = if (Test-HwpGenerateProperty -InputObject $block -Name 'columns') { [int]$block.columns } else { 0 }
                if ($rows -lt 1 -or $rows -gt 100 -or $columns -lt 1 -or $columns -gt 100) {
                    $errors.Add("$prefix 행과 열은 각각 1~100이어야 합니다.")
                }
                foreach ($cell in @(if (Test-HwpGenerateProperty -InputObject $block -Name 'cells') { $block.cells } else { @() })) {
                    if ($null -eq $cell -or
                        -not (Test-HwpGenerateProperty -InputObject $cell -Name 'row') -or
                        -not (Test-HwpGenerateProperty -InputObject $cell -Name 'column') -or
                        -not (Test-HwpGenerateProperty -InputObject $cell -Name 'text')) {
                        $errors.Add("$prefix.cells 항목에는 row, column, text가 필요합니다.")
                        continue
                    }
                    if ([int]$cell.row -lt 1 -or [int]$cell.row -gt $rows -or
                        [int]$cell.column -lt 1 -or [int]$cell.column -gt $columns) {
                        $errors.Add("$prefix.cells 좌표가 표 범위를 벗어났습니다.")
                    }
                }
                break
            }
            'field' {
                foreach ($required in 'name','value') {
                    if (-not (Test-HwpGenerateProperty -InputObject $block -Name $required)) {
                        $errors.Add("$prefix.$required 값이 없습니다.")
                    }
                }
                if (Test-HwpGenerateProperty -InputObject $block -Name 'name') {
                    $name = [string]$block.name
                    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\x00\r\n]') {
                        $errors.Add("$prefix.name이 올바르지 않습니다.")
                    }
                    elseif (-not $fieldNames.Add($name)) {
                        $errors.Add("중복 필드 이름입니다: $name")
                    }
                }
                break
            }
            'image' {
                $imageCount++
                if (-not (Test-HwpGenerateProperty -InputObject $block -Name 'path')) {
                    $errors.Add("$prefix.path가 없습니다.")
                }
                break
            }
            'page-break' { break }
            default { $errors.Add("지원하지 않는 새 문서 블록입니다: $type") }
        }
    }

    $status = if ($errors.Count -eq 0) { 'PASS' } else { 'BLOCKED' }
    New-HwpResult -Status $status -Command validate-generate-plan -Data ([pscustomobject]@{
        BlockCount = $content.Count
        TableCount = $tableCount
        ImageCount = $imageCount
        FieldCount = $fieldNames.Count
    }) -Errors @($errors)
}

function Invoke-HwpGenerateInsertText {
    param(
        [Parameter(Mandatory)][object]$Session,
        [AllowEmptyString()][string]$Text
    )

    if ($Text.Length -eq 0) { return $true }
    $insert = $Session.Hwp.HParameterSet.HInsertText
    $null = $Session.Hwp.HAction.GetDefault('InsertText', $insert.HSet)
    $insert.Text = $Text
    [bool]$Session.Hwp.HAction.Execute('InsertText', $insert.HSet)
}

function New-HwpGenerateEditOperation {
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Anchor
    )

    [pscustomobject]@{
        id = [guid]::NewGuid().ToString('n')
        type = $Type
        expectedMatches = 1
        target = [pscustomobject]@{
            anchor = $Anchor
            beforeContext = ''
            afterContext = ''
        }
        before = ''
        after = ''
    }
}

function Invoke-HwpGenerateParagraph {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Block
    )

    $text = [string]$Block.text
    try {
        $null = $Session.Hwp.HAction.Run('MoveDocEnd')
        if (-not (Invoke-HwpGenerateInsertText -Session $Session -Text $text)) {
            throw '문단 본문을 입력하지 못했습니다.'
        }
        if (-not $Session.Hwp.HAction.Run('BreakPara')) {
            throw '문단 나누기를 삽입하지 못했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command generate-paragraph -Errors @($_.Exception.Message)
    }
    New-HwpResult -Status PASS -Command generate-paragraph -Data ([pscustomobject]@{
        Type = 'paragraph'
        Applied = $true
        Text = $text
    })
}

function Invoke-HwpGenerateTable {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Block
    )

    $rows = [int]$Block.rows
    $columns = [int]$Block.columns
    $marker = '__HWP_NATIVE_TABLE_' + [guid]::NewGuid().ToString('n') + '__'
    try {
        $null = $Session.Hwp.HAction.Run('MoveDocEnd')
        if (-not (Invoke-HwpGenerateInsertText -Session $Session -Text $marker)) {
            throw '표 삽입용 내부 기준 문구를 만들지 못했습니다.'
        }
        $insertOperation = New-HwpGenerateEditOperation -Type 'insert-table' -Anchor $marker
        $insertOperation.target | Add-Member NoteProperty rows $rows
        $insertOperation.target | Add-Member NoteProperty columns $columns
        $insertOperation.target | Add-Member NoteProperty placement 'after'
        $insertResult = Invoke-HwpInsertTable -Session $Session -Operation $insertOperation
        if ($insertResult.Status -ne 'PASS') {
            throw ($insertResult.Errors -join ' ')
        }
        $tableIndex = [int]$insertResult.Data.TableCountAfter
        $cellResults = [Collections.Generic.List[object]]::new()
        foreach ($cell in @(if (Test-HwpGenerateProperty -InputObject $Block -Name 'cells') { $Block.cells } else { @() })) {
            $cellOperation = New-HwpGenerateEditOperation -Type 'set-table-cell' -Anchor 'table-cell'
            $cellOperation.target | Add-Member NoteProperty tableIndex $tableIndex
            $cellOperation.target | Add-Member NoteProperty row ([int]$cell.row)
            $cellOperation.target | Add-Member NoteProperty column ([int]$cell.column)
            $cellOperation.after = [string]$cell.text
            $cellResult = Invoke-HwpSetTableCell -Session $Session -Operation $cellOperation
            $cellResults.Add($cellResult)
            if ($cellResult.Status -ne 'PASS') {
                throw ($cellResult.Errors -join ' ')
            }
        }
        $removeOperation = New-HwpGenerateEditOperation -Type 'replace-text' -Anchor $marker
        $removeOperation.before = $marker
        $removeOperation.after = ''
        $removeResult = Invoke-HwpReplaceText -Session $Session -Operation $removeOperation
        if ($removeResult.Status -ne 'PASS') {
            throw ($removeResult.Errors -join ' ')
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command generate-table -Errors @(
            "표 생성 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    New-HwpResult -Status PASS -Command generate-table -Data ([pscustomobject]@{
        Type = 'table'
        Applied = $true
        Rows = $rows
        Columns = $columns
        TableIndex = $tableIndex
        CellResults = @($cellResults)
    })
}

function Invoke-HwpGenerateField {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Block
    )

    $name = [string]$Block.name
    $value = [string]$Block.value
    $label = if (Test-HwpGenerateProperty -InputObject $Block -Name 'label') { [string]$Block.label } else { '' }
    $memo = if (Test-HwpGenerateProperty -InputObject $Block -Name 'memo') { [string]$Block.memo } else { 'hwp-skill 생성 필드' }
    $display = if (Test-HwpGenerateProperty -InputObject $Block -Name 'display') { [string]$Block.display } else { "{{$name}}" }
    try {
        $null = $Session.Hwp.HAction.Run('MoveDocEnd')
        if ($label.Length -gt 0 -and -not (Invoke-HwpGenerateInsertText -Session $Session -Text $label)) {
            throw '필드 앞 라벨을 입력하지 못했습니다.'
        }
        if (-not $Session.Hwp.CreateField($display, $memo, $name)) {
            throw "필드를 만들지 못했습니다: $name"
        }
        $null = $Session.Hwp.PutFieldText($name, $value)
        if ([string]$Session.Hwp.GetFieldText($name) -ne $value) {
            throw "필드 값 사후검증에 실패했습니다: $name"
        }
        if (-not $Session.Hwp.MoveToField($name, $false, $false, $false)) {
            throw "필드 끝으로 이동하지 못했습니다: $name"
        }
        $null = $Session.Hwp.HAction.Run('BreakPara')
    }
    catch {
        return New-HwpResult -Status FAILED -Command generate-field -Errors @($_.Exception.Message)
    }
    New-HwpResult -Status PASS -Command generate-field -Data ([pscustomobject]@{
        Type = 'field'
        Applied = $true
        Name = $name
        Value = $value
    })
}

function Invoke-HwpGenerateImage {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][object]$Block
    )

    $marker = '__HWP_NATIVE_IMAGE_' + [guid]::NewGuid().ToString('n') + '__'
    try {
        $null = $Session.Hwp.HAction.Run('MoveDocEnd')
        if (-not (Invoke-HwpGenerateInsertText -Session $Session -Text $marker)) {
            throw '이미지 삽입용 내부 기준 문구를 만들지 못했습니다.'
        }
        $operation = New-HwpGenerateEditOperation -Type 'insert-image' -Anchor $marker
        $operation.target | Add-Member NoteProperty imagePath ([string]$Block.path)
        $operation.target | Add-Member NoteProperty widthMm $(if (Test-HwpGenerateProperty -InputObject $Block -Name 'widthMm') { [double]$Block.widthMm } else { 40 })
        $operation.target | Add-Member NoteProperty heightMm $(if (Test-HwpGenerateProperty -InputObject $Block -Name 'heightMm') { [double]$Block.heightMm } else { 30 })
        $operation.target | Add-Member NoteProperty placement 'after'
        $insertResult = Invoke-HwpInsertImage -Session $Session -Operation $operation
        if ($insertResult.Status -notin 'PASS','PASS_WITH_WARNINGS') {
            return $insertResult
        }
        $removeOperation = New-HwpGenerateEditOperation -Type 'replace-text' -Anchor $marker
        $removeOperation.before = $marker
        $removeOperation.after = ''
        $removeResult = Invoke-HwpReplaceText -Session $Session -Operation $removeOperation
        if ($removeResult.Status -ne 'PASS') {
            throw ($removeResult.Errors -join ' ')
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command generate-image -Errors @($_.Exception.Message)
    }
    New-HwpResult -Status $insertResult.Status -Command generate-image -Data ([pscustomobject]@{
        Type = 'image'
        Applied = $true
        Image = $insertResult.Data
    }) -Warnings @($insertResult.Warnings)
}

function Invoke-HwpGeneratePageBreak {
    param([Parameter(Mandatory)][object]$Session)

    try {
        $null = $Session.Hwp.HAction.Run('MoveDocEnd')
        if (-not $Session.Hwp.IsActionEnable('BreakPage')) {
            return New-HwpResult -Status BLOCKED -Command generate-page-break -Errors @('BreakPage 작업을 사용할 수 없습니다.')
        }
        if (-not $Session.Hwp.HAction.Run('BreakPage')) {
            throw 'BreakPage 작업이 거짓을 반환했습니다.'
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command generate-page-break -Errors @($_.Exception.Message)
    }
    New-HwpResult -Status PASS -Command generate-page-break -Data ([pscustomobject]@{
        Type = 'page-break'
        Applied = $true
    })
}

function Save-HwpGeneratedMemoryDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Session,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
    )

    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput).ToLowerInvariant() -ne '.hwp') {
        return New-HwpResult -Status BLOCKED -Command save-generated-document -Errors @('생성 결과는 .hwp 파일이어야 합니다.')
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        return New-HwpResult -Status BLOCKED -Command save-generated-document -Errors @("기존 결과를 덮어쓰지 않습니다: $resolvedOutput")
    }
    $directory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return New-HwpResult -Status BLOCKED -Command save-generated-document -Errors @("결과 폴더가 없습니다: $directory")
    }

    $temporaryPath = [IO.Path]::Combine(
        $directory,
        ('{0}.{1}.partial.hwp' -f [IO.Path]::GetFileNameWithoutExtension($resolvedOutput), [guid]::NewGuid().ToString('n'))
    )
    try {
        $base64 = [string]$Session.Hwp.GetTextFile('HWP', '')
        if ([string]::IsNullOrWhiteSpace($base64)) {
            throw '한컴오피스가 HWP 메모리 데이터를 반환하지 않았습니다.'
        }
        $bytes = [Convert]::FromBase64String($base64)
        if ($bytes.Length -lt 8 -or [BitConverter]::ToString($bytes, 0, 8) -ne 'D0-CF-11-E0-A1-B1-1A-E1') {
            throw '생성 HWP 메모리 데이터의 OLE 시그니처가 올바르지 않습니다.'
        }
        [IO.File]::WriteAllBytes($temporaryPath, $bytes)
        $kind = Get-HwpFileKind -LiteralPath $temporaryPath
        if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWP-BINARY') {
            throw '생성 임시 결과의 형식 검증에 실패했습니다.'
        }
        [IO.File]::Move($temporaryPath, $resolvedOutput)
    }
    catch {
        return New-HwpResult -Status FAILED -Command save-generated-document -Errors @(
            "생성 HWP를 원자적으로 저장하지 못했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    New-HwpResult -Status PASS -Command save-generated-document -Data ([pscustomobject]@{
        OutputPath = $resolvedOutput
        OutputSha256 = Get-HwpSha256 -LiteralPath $resolvedOutput
        ByteLength = $bytes.Length
        HancomDiskAccess = $false
    })
}

function Get-HwpGenerateFailurePath {
    param([Parameter(Mandatory)][string]$OutputPath)

    $directory = [IO.Path]::GetDirectoryName($OutputPath)
    $name = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $candidate = [IO.Path]::Combine($directory, "${name}_${stamp}.failed.hwp")
    $sequence = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = [IO.Path]::Combine($directory, ('{0}_{1}_{2:D2}.failed.hwp' -f $name, $stamp, $sequence))
        $sequence++
    }
    $candidate
}

function Move-HwpGenerateStagingToFailure {
    param(
        [Parameter(Mandatory)][string]$StagingPath,
        [Parameter(Mandatory)][string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $StagingPath -PathType Leaf)) { return '' }
    $failurePath = Get-HwpGenerateFailurePath -OutputPath $OutputPath
    try {
        [IO.File]::Move($StagingPath, $failurePath)
        $failurePath
    }
    catch {
        ''
    }
}

function Invoke-HwpGenerateFromTemplate {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$OutputPath,
        [bool]$ApproveAdvanced = $false,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [scriptblock]$Inspector = {
            param($path, $executionContext, $capabilities)
            Get-HwpInspection -LiteralPath $path -ExecutionContext $executionContext -Capabilities $capabilities
        }
    )

    try {
        $kind = Get-HwpFileKind -LiteralPath $TemplatePath
        $templateHash = Get-HwpSha256 -LiteralPath $kind.Path
    }
    catch {
        return New-HwpGenerateResult -Status BLOCKED -Mode template -Errors @($_.Exception.Message)
    }
    if (-not $kind.ExtensionMatches -or $kind.DetectedKind -ne 'HWP-BINARY') {
        return New-HwpGenerateResult -Status BLOCKED -Mode template -TemplatePath $kind.Path `
            -TemplateSha256 $templateHash -Errors @(
                '현재 안전한 양식 생성은 실제 형식이 HWP 바이너리인 HWP 또는 HWT만 지원합니다.'
            )
    }
    $route = Resolve-HwpBackend -Command generate -DetectedKind $kind.DetectedKind `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpGenerateResult -Status $route.Status -Mode template -TemplatePath $kind.Path `
            -TemplateSha256 $templateHash -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpGenerateResult -Status BLOCKED -Mode template -TemplatePath $kind.Path `
            -TemplateSha256 $templateHash -Errors @("백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)")
    }
    $before = Get-HwpInspection -LiteralPath $kind.Path -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($before.Status -notin 'PASS','PASS_WITH_WARNINGS') {
        return New-HwpGenerateResult -Status BLOCKED -Mode template -TemplatePath $kind.Path `
            -TemplateSha256 $templateHash -Before $before -Errors @($before.Errors)
    }

    $apply = Invoke-HwpApply -LiteralPath $kind.Path -Plan $Plan -OutputPath $OutputPath `
        -ApproveAdvanced:$ApproveAdvanced -ExecutionContext $ExecutionContext `
        -Capabilities $Capabilities -SessionFactory $SessionFactory -Inspector $Inspector
    $currentHash = Get-HwpSha256 -LiteralPath $kind.Path
    if ($currentHash -ne $templateHash) {
        return New-HwpGenerateResult -Status FAILED -Mode template -TemplatePath $kind.Path `
            -TemplateSha256 $templateHash -OutputPath $apply.OutputPath -Before $before -After $apply.Inspection `
            -OperationResults @($apply.OperationResults) -Errors @('양식 원본 SHA-256이 변경되었습니다.')
    }
    if ($apply.Status -notin 'PASS','PASS_WITH_WARNINGS') {
        return New-HwpGenerateResult -Status $apply.Status -Mode template -TemplatePath $kind.Path `
            -TemplateSha256 $templateHash -OutputPath $apply.OutputPath -Before $before -After $apply.Inspection `
            -OperationResults @($apply.OperationResults) -FailedArtifactPath $apply.FailedArtifactPath `
            -Warnings @($apply.Warnings) -Errors @($apply.Errors)
    }

    New-HwpGenerateResult -Status $apply.Status -Mode template -TemplatePath $kind.Path `
        -TemplateSha256 $templateHash -OutputPath $apply.OutputPath -Before $before -After $apply.Inspection `
        -OperationResults @($apply.OperationResults) -Warnings @($apply.Warnings)
}

function Invoke-HwpGenerateNewDocument {
    param(
        [Parameter(Mandatory)][object]$Plan,
        [Parameter(Mandatory)][string]$OutputPath,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [scriptblock]$Inspector = {
            param($path, $executionContext, $capabilities)
            Get-HwpInspection -LiteralPath $path -ExecutionContext $executionContext -Capabilities $capabilities
        }
    )

    $validation = Test-HwpNewDocumentPlan -Plan $Plan
    if ($validation.Status -ne 'PASS') {
        return New-HwpGenerateResult -Status BLOCKED -Mode new-document -Errors @($validation.Errors)
    }
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    try {
        $requestedFormat = Get-HwpRequestedFormat -OutputPath $resolvedOutput
    }
    catch {
        return New-HwpGenerateResult -Status BLOCKED -Mode new-document -OutputPath $resolvedOutput `
            -Errors @($_.Exception.Message)
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        return New-HwpGenerateResult -Status BLOCKED -Mode new-document -OutputPath $resolvedOutput `
            -Errors @("기존 결과를 덮어쓰지 않습니다: $resolvedOutput")
    }
    $directory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return New-HwpGenerateResult -Status BLOCKED -Mode new-document -OutputPath $resolvedOutput `
            -Errors @("결과 폴더가 없습니다: $directory")
    }
    $route = Resolve-HwpBackend -Command generate -DetectedKind NONE -RequestedFormat $requestedFormat `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpGenerateResult -Status $route.Status -Mode new-document -OutputPath $resolvedOutput `
            -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpGenerateResult -Status BLOCKED -Mode new-document -OutputPath $resolvedOutput `
            -Errors @("백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)")
    }
    $stagingPath = [IO.Path]::Combine(
        $directory,
        ('{0}.{1}.partial.hwp' -f [IO.Path]::GetFileNameWithoutExtension($resolvedOutput), [guid]::NewGuid().ToString('n'))
    )

    $session = $null
    $operationResults = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    try {
        $session = & $SessionFactory $ExecutionContext
        if ($session.Hwp.IsActionEnable('FileNew')) {
            $null = $session.Hwp.HAction.Run('FileNew')
        }
        foreach ($block in @($Plan.content)) {
            $result = switch ([string]$block.type) {
                'paragraph' { Invoke-HwpGenerateParagraph -Session $session -Block $block; break }
                'table' { Invoke-HwpGenerateTable -Session $session -Block $block; break }
                'field' { Invoke-HwpGenerateField -Session $session -Block $block; break }
                'image' { Invoke-HwpGenerateImage -Session $session -Block $block; break }
                'page-break' { Invoke-HwpGeneratePageBreak -Session $session; break }
                default { New-HwpResult -Status BLOCKED -Command generate-block -Errors @("지원하지 않는 블록입니다: $($block.type)") }
            }
            $operationResults.Add($result)
            foreach ($warning in @($result.Warnings)) { $warnings.Add([string]$warning) }
            if ($result.Status -notin 'PASS','PASS_WITH_WARNINGS') {
                foreach ($message in @($result.Errors)) { $errors.Add([string]$message) }
                break
            }
        }
        if ($errors.Count -eq 0) {
            $save = Save-HwpGeneratedMemoryDocument -Session $session -OutputPath $stagingPath
            if ($save.Status -ne 'PASS') {
                foreach ($message in @($save.Errors)) { $errors.Add([string]$message) }
            }
        }
    }
    catch {
        $errors.Add("새 문서 생성 중 오류가 발생했습니다: $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $session) { Close-HwpSession -Session $session }
    }
    if ($errors.Count -gt 0) {
        $failedArtifactPath = Move-HwpGenerateStagingToFailure -StagingPath $stagingPath -OutputPath $resolvedOutput
        return New-HwpGenerateResult -Status BLOCKED -Mode new-document -OutputPath $resolvedOutput `
            -OperationResults @($operationResults) -FailedArtifactPath $failedArtifactPath `
            -Warnings @($warnings) -Errors @($errors)
    }

    try {
        $after = & $Inspector $stagingPath $ExecutionContext $Capabilities
    }
    catch {
        $after = $null
        $errors.Add("생성 임시 결과 재열기 검사 중 오류가 발생했습니다: $($_.Exception.Message)")
    }
    if ($null -eq $after) {
        $failedArtifactPath = Move-HwpGenerateStagingToFailure -StagingPath $stagingPath -OutputPath $resolvedOutput
        return New-HwpGenerateResult -Status FAILED -Mode new-document -OutputPath $resolvedOutput `
            -OperationResults @($operationResults) -FailedArtifactPath $failedArtifactPath `
            -Warnings @($warnings) -Errors @($errors)
    }
    if ($after.Status -notin 'PASS','PASS_WITH_WARNINGS') {
        $failedArtifactPath = Move-HwpGenerateStagingToFailure -StagingPath $stagingPath -OutputPath $resolvedOutput
        return New-HwpGenerateResult -Status FAILED -Mode new-document -OutputPath $resolvedOutput `
            -After $after -OperationResults @($operationResults) -FailedArtifactPath $failedArtifactPath `
            -Warnings @($warnings) -Errors @($after.Errors)
    }

    $expectedTableCount = @($Plan.content | Where-Object type -eq 'table').Count
    $actualTableCount = @($after.Controls | Where-Object CtrlId -eq 'tbl').Count
    if ($actualTableCount -ne $expectedTableCount) {
        $errors.Add("재열기 후 표 수가 계획과 다릅니다: $expectedTableCount / $actualTableCount")
    }
    foreach ($block in @($Plan.content)) {
        if ([string]$block.type -eq 'paragraph' -and
            -not ([string]$after.Text).Contains([string]$block.text, [StringComparison]::Ordinal)) {
            $errors.Add("재열기 후 문단을 찾지 못했습니다: $($block.text)")
        }
        if ([string]$block.type -eq 'field') {
            $field = $after.Fields.PSObject.Properties[[string]$block.name]
            if ($null -eq $field -or [string]$field.Value -ne [string]$block.value) {
                $errors.Add("재열기 후 필드값이 다릅니다: $($block.name)")
            }
        }
        if ([string]$block.type -eq 'table') {
            foreach ($cell in @($block.cells)) {
                if (-not ([string]$after.Text).Contains([string]$cell.text, [StringComparison]::Ordinal)) {
                    $errors.Add("재열기 후 표 셀 문구를 찾지 못했습니다: $($cell.text)")
                }
            }
        }
    }
    if ($errors.Count -gt 0) {
        $failedArtifactPath = Move-HwpGenerateStagingToFailure -StagingPath $stagingPath -OutputPath $resolvedOutput
        return New-HwpGenerateResult -Status FAILED -Mode new-document -OutputPath $resolvedOutput `
            -After $after -OperationResults @($operationResults) -FailedArtifactPath $failedArtifactPath `
            -Warnings @($warnings) -Errors @($errors)
    }

    try {
        if (Test-Path -LiteralPath $resolvedOutput) {
            throw "검증 중 결과 경로가 새로 생성되어 덮어쓰지 않습니다: $resolvedOutput"
        }
        [IO.File]::Move($stagingPath, $resolvedOutput)
        if ($after.PSObject.Properties.Name -contains 'path') {
            $after.path = $resolvedOutput
        }
    }
    catch {
        $errors.Add("검증된 생성 결과를 최종 경로로 승격하지 못했습니다: $($_.Exception.Message)")
        $failedArtifactPath = Move-HwpGenerateStagingToFailure -StagingPath $stagingPath -OutputPath $resolvedOutput
        return New-HwpGenerateResult -Status FAILED -Mode new-document -OutputPath $resolvedOutput `
            -After $after -OperationResults @($operationResults) -FailedArtifactPath $failedArtifactPath `
            -Warnings @($warnings) -Errors @($errors)
    }

    $status = if ($warnings.Count -gt 0 -or $after.Status -eq 'PASS_WITH_WARNINGS') { 'PASS_WITH_WARNINGS' } else { 'PASS' }
    New-HwpGenerateResult -Status $status -Mode new-document -OutputPath $resolvedOutput -After $after `
        -OperationResults @($operationResults) -Warnings @($warnings)
}

function Invoke-HwpGenerate {
    [CmdletBinding(DefaultParameterSetName = 'Template')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Template')]
        [ValidateNotNullOrEmpty()][string]$TemplatePath,

        [Parameter(Mandatory, ParameterSetName = 'New')]
        [switch]$NewDocument,

        [Parameter(Mandatory)][ValidateNotNull()][object]$Plan,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
        [switch]$ApproveAdvanced,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [scriptblock]$Inspector = {
            param($path, $executionContext, $capabilities)
            Get-HwpInspection -LiteralPath $path -ExecutionContext $executionContext -Capabilities $capabilities
        }
    )

    if ($PSCmdlet.ParameterSetName -eq 'Template') {
        return Invoke-HwpGenerateFromTemplate -TemplatePath $TemplatePath -Plan $Plan -OutputPath $OutputPath `
            -ApproveAdvanced:([bool]$ApproveAdvanced) -ExecutionContext $ExecutionContext `
            -Capabilities $Capabilities -SessionFactory $SessionFactory -Inspector $Inspector
    }
    Invoke-HwpGenerateNewDocument -Plan $Plan -OutputPath $OutputPath -ExecutionContext $ExecutionContext `
        -Capabilities $Capabilities -SessionFactory $SessionFactory -Inspector $Inspector
}

Export-ModuleMember -Function @(
    'Test-HwpNewDocumentPlan',
    'Save-HwpGeneratedMemoryDocument',
    'Invoke-HwpGenerate'
)
