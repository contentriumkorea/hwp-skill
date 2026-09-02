Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpExecution.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpCapabilities.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpBackendRouter.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpSession.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpPortable.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpTables.psm1') -ErrorAction Stop

function New-HwpInspectionRecord {
    [CmdletBinding()]
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')]
        [string]$Status,
        [string]$Path,
        [string]$Sha256 = '',
        [string]$DetectedKind = 'UNKNOWN',
        [string]$Text = '',
        [object]$Fields = ([pscustomobject]@{}),
        [object[]]$Controls = @(),
        [object[]]$Tables = @(),
        [int]$PageCount = 0,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @(),
        [string]$HancomVersion = ''
    )

    [pscustomobject][ordered]@{
        status = $Status
        path = $Path
        sha256 = $Sha256
        detectedKind = $DetectedKind
        text = $Text
        fields = $Fields
        controls = @($Controls)
        tables = @($Tables)
        pageCount = $PageCount
        warnings = @($Warnings)
        errors = @($Errors)
        hancomVersion = $HancomVersion
    }
}

function Open-HwpDocumentReadOnly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [AllowNull()]
        [scriptblock]$SecurityModuleReader = $null
    )

    $format = Get-HwpFileKind -LiteralPath $LiteralPath
    if (-not $format.ExtensionMatches) {
        return New-HwpResult -Status BLOCKED -Command open-read-only -Data $format -Errors @(
            '확장자와 실제 파일 형식이 다릅니다.'
        )
    }

    $security = if ($null -ne $SecurityModuleReader) {
        Register-HwpSecurityModules -Session $Session -SecurityModuleReader $SecurityModuleReader
    }
    else {
        Register-HwpSecurityModules -Session $Session
    }
    if ($security.Status -eq 'BLOCKED' -or $security.Status -eq 'FAILED') {
        return New-HwpResult -Status BLOCKED -Command open-read-only -Data ([pscustomobject]@{
            Path = $format.Path
            FileKind = $format
            Security = $security.Data
        }) -Warnings @($security.Warnings) -Errors @($security.Errors)
    }

    $openArgument = 'lock:false;suspendpassword:true;forceopen:true;versionwarning:false'
    try {
        $opened = [bool]$Session.Hwp.Open($format.Path, '', $openArgument)
    }
    catch {
        return New-HwpResult -Status FAILED -Command open-read-only -Data $format -Errors @(
            "한컴오피스 문서 열기 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }

    if (-not $opened) {
        return New-HwpResult -Status BLOCKED -Command open-read-only -Data $format -Errors @(
            '한컴오피스가 문서를 열지 못했습니다. 암호, 손상 또는 보호 제한을 확인하십시오.'
        )
    }

    New-HwpResult -Status $security.Status -Command open-read-only -Data ([pscustomobject]@{
        Path = $format.Path
        FileKind = $format
        OpenArgument = $openArgument
        Security = $security.Data
    }) -Warnings @($security.Warnings)
}

function Open-HwpDocumentFromMemory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [ValidateRange(8, 2147483647)]
        [long]$MaximumFileBytes = 134217728
    )

    $format = Get-HwpFileKind -LiteralPath $LiteralPath
    if (-not $format.ExtensionMatches -or $format.DetectedKind -ne 'HWP-BINARY') {
        return New-HwpResult -Status BLOCKED -Command open-memory -Data $format -Errors @(
            '메모리 열기는 실제 형식이 HWP 바이너리인 HWP 또는 HWT에만 사용할 수 있습니다.'
        )
    }
    $fileLength = (Get-Item -LiteralPath $format.Path -ErrorAction Stop).Length
    if ($fileLength -gt $MaximumFileBytes) {
        return New-HwpResult -Status BLOCKED -Command open-memory -Data ([pscustomobject]@{
            Path = $format.Path
            FileKind = $format
            ByteLength = [long]$fileLength
            MaximumFileBytes = [long]$MaximumFileBytes
        }) -Errors @("HWP/HWT 파일 크기가 메모리 처리 안전 한도 $MaximumFileBytes 바이트를 초과했습니다.")
    }

    try {
        $bytes = [IO.File]::ReadAllBytes($format.Path)
        $base64 = [Convert]::ToBase64String($bytes)
        $loaded = [int]$Session.Hwp.SetTextFile($base64, 'HWP', '')
    }
    catch {
        return New-HwpResult -Status FAILED -Command open-memory -Data $format -Errors @(
            "한컴 메모리 문서 로드 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }

    if ($loaded -le 0) {
        return New-HwpResult -Status BLOCKED -Command open-memory -Data $format -Errors @(
            '한컴오피스가 HWP 메모리 문서를 불러오지 못했습니다. 암호, DRM, 서명 또는 손상 여부를 확인하십시오.'
        )
    }

    New-HwpResult -Status PASS -Command open-memory -Data ([pscustomobject]@{
        Path = $format.Path
        FileKind = $format
        ByteLength = $bytes.Length
        DiskAccessByHancom = $false
    })
}

function Get-HwpPlainText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session
    )

    [string]$Session.Hwp.GetTextFile('UNICODE', '')
}

function Get-HwpFieldMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session
    )

    $map = [ordered]@{}
    $rawList = [string]$Session.Hwp.GetFieldList(0, 0)
    if ([string]::IsNullOrEmpty($rawList)) {
        return [pscustomobject]$map
    }

    $names = $rawList -split [char]2
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name) -or $map.Contains($name)) {
            continue
        }
        $map[$name] = [string]$Session.Hwp.GetFieldText($name)
    }

    [pscustomobject]$map
}

function Get-HwpControlInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [ValidateRange(1, 100000)]
        [int]$MaximumControls = 10000
    )

    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $control = $Session.Hwp.HeadCtrl
    $index = 0
    while ($null -ne $control) {
        if ($index -ge $MaximumControls) {
            throw "컨트롤 수가 안전 한도 $MaximumControls 개를 초과했습니다."
        }

        $instanceId = try {
            [string]$control.GetCtrlInstID()
        }
        catch {
            ''
        }
        $identity = if ([string]::IsNullOrWhiteSpace($instanceId)) {
            'runtime:{0}' -f [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($control)
        }
        else {
            'instance:{0}' -f $instanceId
        }
        if (-not $visited.Add($identity)) {
            break
        }

        $ctrlId = try { [string]$control.CtrlID } catch { '' }
        $userDesc = try { [string]$control.UserDesc } catch { '' }
        [pscustomobject]@{
            index = $index
            ctrlId = $ctrlId
            userDesc = $userDesc
            instanceId = $instanceId
        }

        $control = try { $control.Next } catch { $null }
        $index++
    }
}

function Test-HwpxEntryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EntryName
    )

    if ($EntryName.Contains('\')) {
        return $false
    }
    if ([IO.Path]::IsPathRooted($EntryName) -or $EntryName.Contains(':')) {
        return $false
    }

    foreach ($part in $EntryName.Split('/')) {
        if ($part -eq '..' -or $part -eq '.') {
            return $false
        }
    }

    $true
}

function Read-HwpxXmlEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Entry,

        [ValidateRange(1, 268435456)]
        [long]$MaximumCharacters = 67108864
    )

    if ([long]$Entry.Length -gt $MaximumCharacters) {
        throw "HWPX XML 항목이 안전 한도를 초과했습니다: $($Entry.FullName)"
    }

    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = $MaximumCharacters
    $settings.IgnoreComments = $true

    $stream = $Entry.Open()
    try {
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.PreserveWhitespace = $false
            $document.Load($reader)
            $document
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-HwpxNodeAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Xml.XmlNode]$Node,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalName
    )

    foreach ($attribute in @($Node.Attributes)) {
        if ([string]::Equals($attribute.LocalName, $LocalName, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$attribute.Value
        }
    }
    ''
}

function Get-HwpxNodeIntegerAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string]$LocalName,
        [int]$Default = 0
    )

    $raw = Get-HwpxNodeAttribute -Node $Node -LocalName $LocalName
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $value = 0
    if (-not [int]::TryParse($raw, [Globalization.NumberStyles]::Integer,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        throw [Xml.XmlException]::new("HWPX $LocalName 속성이 정수가 아닙니다: $raw")
    }
    $value
}

function Get-HwpxNodeBooleanAttribute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string]$LocalName,
        [bool]$Default = $false
    )

    $raw = Get-HwpxNodeAttribute -Node $Node -LocalName $LocalName
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    switch ($raw.Trim().ToLowerInvariant()) {
        { $_ -in @('1', 'true', 'yes') } { return $true }
        { $_ -in @('0', 'false', 'no') } { return $false }
        default { throw [Xml.XmlException]::new("HWPX $LocalName 속성이 참/거짓 값이 아닙니다: $raw") }
    }
}

function Get-HwpxParagraphText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Xml.XmlNode]$Paragraph)

    $parts = [Collections.Generic.List[string]]::new()
    foreach ($textNode in @($Paragraph.SelectNodes(".//*[local-name()='t']"))) {
        $nearestParagraph = $textNode.ParentNode
        while ($null -ne $nearestParagraph -and $nearestParagraph.LocalName -ne 'p') {
            $nearestParagraph = $nearestParagraph.ParentNode
        }
        if ([object]::ReferenceEquals($nearestParagraph, $Paragraph)) {
            $parts.Add([string]$textNode.InnerText)
        }
    }
    $parts -join ''
}

function Get-HwpxTableStructures {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$SectionName,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Tables,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$StructureWarnings,
        [ValidateRange(1, 100000000)][long]$MaximumGridSlots = 5000000
    )

    foreach ($tableNode in @($Document.SelectNodes("//*[local-name()='tbl']"))) {
        $tableIndex = $Tables.Count
        $rowNodes = @($tableNode.SelectNodes("./*[local-name()='tr']"))
        $cells = [Collections.Generic.List[object]]::new()
        $derivedColumnCount = 0
        for ($rowIndex = 0; $rowIndex -lt $rowNodes.Count; $rowIndex++) {
            $cellNodes = @($rowNodes[$rowIndex].SelectNodes("./*[local-name()='tc']"))
            $fallbackColumn = 0
            foreach ($cellNode in $cellNodes) {
                $addressNode = $cellNode.SelectSingleNode("./*[local-name()='cellAddr']")
                $spanNode = $cellNode.SelectSingleNode("./*[local-name()='cellSpan']")
                $sizeNode = $cellNode.SelectSingleNode("./*[local-name()='cellSz']")
                $marginNode = $cellNode.SelectSingleNode("./*[local-name()='cellMargin']")
                $subListNode = $cellNode.SelectSingleNode("./*[local-name()='subList']")

                if ($null -eq $addressNode) {
                    $StructureWarnings.Add(
                        "$SectionName 표 $tableIndex 셀 $($cells.Count)에 cellAddr가 없어 tr/tc 순서로 주소를 복원했습니다."
                    )
                    $rowAddress = $rowIndex
                    $columnAddress = $fallbackColumn
                }
                else {
                    $rowAddress = Get-HwpxNodeIntegerAttribute -Node $addressNode -LocalName 'rowAddr' -Default $rowIndex
                    $columnAddress = Get-HwpxNodeIntegerAttribute -Node $addressNode -LocalName 'colAddr' -Default $fallbackColumn
                }
                $rowSpan = if ($null -eq $spanNode) { 1 } else {
                    Get-HwpxNodeIntegerAttribute -Node $spanNode -LocalName 'rowSpan' -Default 1
                }
                $columnSpan = if ($null -eq $spanNode) { 1 } else {
                    Get-HwpxNodeIntegerAttribute -Node $spanNode -LocalName 'colSpan' -Default 1
                }
                $fallbackColumn = [Math]::Max($fallbackColumn, $columnAddress + [Math]::Max(1, $columnSpan))
                $derivedColumnCount = [Math]::Max($derivedColumnCount, $columnAddress + [Math]::Max(1, $columnSpan))

                $paragraphs = [Collections.Generic.List[string]]::new()
                if ($null -ne $subListNode) {
                    foreach ($paragraphNode in @($subListNode.SelectNodes("./*[local-name()='p']"))) {
                        $paragraphs.Add((Get-HwpxParagraphText -Paragraph $paragraphNode))
                    }
                }
                $paragraphArray = @($paragraphs)
                $cells.Add([pscustomobject][ordered]@{
                    index = $cells.Count
                    id = ('table-{0}-cell-{1}' -f $tableIndex, $cells.Count)
                    name = Get-HwpxNodeAttribute -Node $cellNode -LocalName 'name'
                    rowAddress = $rowAddress
                    columnAddress = $columnAddress
                    rowSpan = $rowSpan
                    columnSpan = $columnSpan
                    width = if ($null -eq $sizeNode) { 0 } else {
                        Get-HwpxNodeIntegerAttribute -Node $sizeNode -LocalName 'width'
                    }
                    height = if ($null -eq $sizeNode) { 0 } else {
                        Get-HwpxNodeIntegerAttribute -Node $sizeNode -LocalName 'height'
                    }
                    margins = [pscustomobject][ordered]@{
                        left = if ($null -eq $marginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $marginNode -LocalName 'left' }
                        right = if ($null -eq $marginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $marginNode -LocalName 'right' }
                        top = if ($null -eq $marginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $marginNode -LocalName 'top' }
                        bottom = if ($null -eq $marginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $marginNode -LocalName 'bottom' }
                    }
                    borderFillId = Get-HwpxNodeIntegerAttribute -Node $cellNode -LocalName 'borderFillIDRef'
                    cellFlagsRaw = $null
                    hasMargin = Get-HwpxNodeBooleanAttribute -Node $cellNode -LocalName 'hasMargin'
                    protect = Get-HwpxNodeBooleanAttribute -Node $cellNode -LocalName 'protect'
                    header = Get-HwpxNodeBooleanAttribute -Node $cellNode -LocalName 'header'
                    editable = Get-HwpxNodeBooleanAttribute -Node $cellNode -LocalName 'editable'
                    dirty = Get-HwpxNodeBooleanAttribute -Node $cellNode -LocalName 'dirty'
                    paragraphCountDeclared = $paragraphArray.Count
                    paragraphs = $paragraphArray
                    text = $paragraphArray -join "`r`n"
                    listPropertiesRaw = $null
                    textDirectionCode = $null
                    textDirection = if ($null -eq $subListNode) { '' } else { Get-HwpxNodeAttribute -Node $subListNode -LocalName 'textDirection' }
                    lineWrapCode = $null
                    lineWrap = if ($null -eq $subListNode) { '' } else { Get-HwpxNodeAttribute -Node $subListNode -LocalName 'lineWrap' }
                    verticalAlignmentCode = $null
                    verticalAlignment = if ($null -eq $subListNode) { '' } else { Get-HwpxNodeAttribute -Node $subListNode -LocalName 'vertAlign' }
                })
            }
        }

        $rowCount = Get-HwpxNodeIntegerAttribute -Node $tableNode -LocalName 'rowCnt' -Default $rowNodes.Count
        $columnCount = Get-HwpxNodeIntegerAttribute -Node $tableNode -LocalName 'colCnt' -Default $derivedColumnCount
        if ($rowCount -lt 1 -or $columnCount -lt 1) {
            $StructureWarnings.Add("$SectionName 표 $tableIndex 행·열 수를 복원할 수 없어 빈 그리드로 반환했습니다.")
            $rowCount = [Math]::Max(0, $rowCount)
            $columnCount = [Math]::Max(0, $columnCount)
        }
        $rowSizes = [object[]]::new($rowCount)
        for ($rowIndex = 0; $rowIndex -lt $rowCount; $rowIndex++) {
            $directHeights = @(
                $cells | Where-Object {
                    [int]$_.RowAddress -eq $rowIndex -and [int]$_.RowSpan -eq 1 -and [long]$_.Height -gt 0
                } | ForEach-Object { [long]$_.Height }
            )
            if ($directHeights.Count -gt 0) {
                $rowSizes[$rowIndex] = [long](($directHeights | Measure-Object -Maximum).Maximum)
            }
        }
        $inMarginNode = $tableNode.SelectSingleNode("./*[local-name()='inMargin']")
        $validZones = [Collections.Generic.List[object]]::new()
        foreach ($zoneNode in @($tableNode.SelectNodes(
                    "./*[local-name()='cellzoneList']/*[local-name()='cellzone']"
                ))) {
            $validZones.Add([pscustomobject][ordered]@{
                index = $validZones.Count
                startColumnAddress = Get-HwpxNodeIntegerAttribute -Node $zoneNode -LocalName 'startColAddr'
                startRowAddress = Get-HwpxNodeIntegerAttribute -Node $zoneNode -LocalName 'startRowAddr'
                endColumnAddress = Get-HwpxNodeIntegerAttribute -Node $zoneNode -LocalName 'endColAddr'
                endRowAddress = Get-HwpxNodeIntegerAttribute -Node $zoneNode -LocalName 'endRowAddr'
                borderFillId = Get-HwpxNodeIntegerAttribute -Node $zoneNode -LocalName 'borderFillIDRef'
            })
        }
        $label = "$SectionName 표 $tableIndex"
        $grid = @(New-HwpTableGrid -RowCount $rowCount -ColumnCount $columnCount -Cells @($cells) `
            -Warnings $StructureWarnings -TableLabel $label -MaximumGridSlots $MaximumGridSlots)

        $Tables.Add([pscustomobject][ordered]@{
            index = $tableIndex
            section = $SectionName
            source = 'hwpx-package'
            recordLevel = $null
            rowCount = $rowCount
            columnCount = $columnCount
            cellSpacing = Get-HwpxNodeIntegerAttribute -Node $tableNode -LocalName 'cellSpacing'
            innerMargins = [pscustomobject][ordered]@{
                left = if ($null -eq $inMarginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $inMarginNode -LocalName 'left' }
                right = if ($null -eq $inMarginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $inMarginNode -LocalName 'right' }
                top = if ($null -eq $inMarginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $inMarginNode -LocalName 'top' }
                bottom = if ($null -eq $inMarginNode) { 0 } else { Get-HwpxNodeIntegerAttribute -Node $inMarginNode -LocalName 'bottom' }
            }
            rowSizes = @($rowSizes)
            borderFillId = Get-HwpxNodeIntegerAttribute -Node $tableNode -LocalName 'borderFillIDRef'
            properties = [pscustomobject][ordered]@{
                raw = $null
                pageBreakCode = $null
                pageBreak = Get-HwpxNodeAttribute -Node $tableNode -LocalName 'pageBreak'
                repeatHeader = Get-HwpxNodeBooleanAttribute -Node $tableNode -LocalName 'repeatHeader'
                noAdjust = Get-HwpxNodeBooleanAttribute -Node $tableNode -LocalName 'noAdjust'
            }
            validZones = @($validZones)
            cells = @($cells)
            grid = $grid
        })
    }
}

function Get-HwpxSectionData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Xml.XmlDocument]$Document,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SectionName,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Controls,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [AllowEmptyCollection()]
        [Collections.Specialized.OrderedDictionary]$FieldMap,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Tables,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$StructureWarnings
    )

    $paragraphs = [Collections.Generic.List[string]]::new()
    foreach ($paragraph in @($Document.SelectNodes("//*[local-name()='p']"))) {
        $parts = [Collections.Generic.List[string]]::new()
        foreach ($textNode in @($paragraph.SelectNodes(".//*[local-name()='t']"))) {
            $nearestParagraph = $textNode.ParentNode
            while ($null -ne $nearestParagraph -and $nearestParagraph.LocalName -ne 'p') {
                $nearestParagraph = $nearestParagraph.ParentNode
            }
            if ([object]::ReferenceEquals($nearestParagraph, $paragraph)) {
                $parts.Add([string]$textNode.InnerText)
            }
        }
        $paragraphs.Add(($parts -join ''))
    }

    $controlMap = @{
        tbl = 'tbl'
        pic = 'pic'
        fieldBegin = 'fieldBegin'
        equation = 'eqed'
        footNote = 'fn'
        endNote = 'en'
        header = 'head'
        footer = 'foot'
    }
    foreach ($node in @($Document.SelectNodes(
        "//*[local-name()='tbl' or local-name()='pic' or local-name()='fieldBegin' or " +
        "local-name()='equation' or local-name()='footNote' or local-name()='endNote' or " +
        "local-name()='header' or local-name()='footer']"
    ))) {
        $controls.Add([pscustomobject]@{
            index = $Controls.Count
            ctrlId = [string]$controlMap[$node.LocalName]
            userDesc = $node.LocalName
            instanceId = (Get-HwpxNodeAttribute -Node $node -LocalName 'id')
            section = $SectionName
            source = 'hwpx-package'
        })
    }

    $activeFields = [Collections.Generic.List[object]]::new()
    $fieldNodes = @($Document.SelectNodes(
        "//*[local-name()='fieldBegin' or local-name()='fieldEnd' or local-name()='t']"
    ))
    foreach ($node in $fieldNodes) {
        if ($node.LocalName -eq 'fieldBegin') {
            $activeFields.Add([pscustomobject]@{
                Id = Get-HwpxNodeAttribute -Node $node -LocalName 'id'
                Name = Get-HwpxNodeAttribute -Node $node -LocalName 'name'
                Text = [Text.StringBuilder]::new()
            })
            continue
        }

        if ($node.LocalName -eq 't') {
            $insideFieldDefinition = $false
            $ancestor = $node.ParentNode
            while ($null -ne $ancestor) {
                if ($ancestor.LocalName -eq 'fieldBegin') {
                    $insideFieldDefinition = $true
                    break
                }
                $ancestor = $ancestor.ParentNode
            }
            if (-not $insideFieldDefinition) {
                foreach ($active in $activeFields) {
                    $null = $active.Text.Append([string]$node.InnerText)
                }
            }
            continue
        }

        $beginId = Get-HwpxNodeAttribute -Node $node -LocalName 'beginIDRef'
        $matchingIndex = -1
        for ($index = $activeFields.Count - 1; $index -ge 0; $index--) {
            if ([string]::IsNullOrEmpty($beginId) -or $activeFields[$index].Id -eq $beginId) {
                $matchingIndex = $index
                break
            }
        }
        if ($matchingIndex -lt 0) {
            continue
        }

        $completed = $activeFields[$matchingIndex]
        $activeFields.RemoveAt($matchingIndex)
        if (-not [string]::IsNullOrWhiteSpace($completed.Name) -and -not $FieldMap.Contains($completed.Name)) {
            $FieldMap.Add($completed.Name, $completed.Text.ToString())
        }
    }

    foreach ($unfinished in $activeFields) {
        if (-not [string]::IsNullOrWhiteSpace($unfinished.Name) -and -not $FieldMap.Contains($unfinished.Name)) {
            $FieldMap.Add($unfinished.Name, $unfinished.Text.ToString())
        }
    }

    Get-HwpxTableStructures -Document $Document -SectionName $SectionName -Tables $Tables `
        -StructureWarnings $StructureWarnings

    @($paragraphs)
}

function Get-HwpxPackageInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [ValidateRange(1, 100000)]
        [int]$MaximumEntries = 10000,

        [ValidateRange(1, 2147483648)]
        [long]$MaximumUncompressedBytes = 536870912,

        [ValidateRange(1, 268435456)]
        [long]$MaximumXmlCharacters = 67108864
    )

    Add-Type -AssemblyName System.IO.Compression
    $resolvedPath = Resolve-HwpLiteralPath -LiteralPath $LiteralPath
    $warnings = [Collections.Generic.List[string]]::new()
    $stream = [IO.File]::Open($resolvedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            if ($archive.Entries.Count -gt $MaximumEntries) {
                return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                    "HWPX ZIP 항목 수가 안전 한도 $MaximumEntries 개를 초과했습니다."
                )
            }

            $entryMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
            [long]$totalLength = 0
            foreach ($entry in $archive.Entries) {
                if (-not (Test-HwpxEntryPath -EntryName $entry.FullName)) {
                    return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                        "HWPX ZIP 항목의 경로가 안전하지 않습니다: $($entry.FullName)"
                    )
                }
                if ($entryMap.ContainsKey($entry.FullName)) {
                    return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                        "HWPX ZIP에 중복 경로가 있습니다: $($entry.FullName)"
                    )
                }
                $entryMap.Add($entry.FullName, $entry)
                $totalLength += [long]$entry.Length
                if ($totalLength -gt $MaximumUncompressedBytes) {
                    return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                        'HWPX ZIP의 전체 압축 해제 크기가 안전 한도를 초과했습니다.'
                    )
                }
            }

            if (-not $entryMap.ContainsKey('mimetype')) {
                return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                    'HWPX ZIP에 mimetype 항목이 없습니다.'
                )
            }
            $mimeEntry = $entryMap['mimetype']
            if ([long]$mimeEntry.Length -gt 128) {
                return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                    'HWPX mimetype 항목이 비정상적으로 큽니다.'
                )
            }
            $mimeStream = $mimeEntry.Open()
            try {
                $mimeReader = [IO.StreamReader]::new($mimeStream, [Text.UTF8Encoding]::new($false), $true, 128, $true)
                try {
                    $mimeType = $mimeReader.ReadToEnd().Trim()
                }
                finally {
                    $mimeReader.Dispose()
                }
            }
            finally {
                $mimeStream.Dispose()
            }
            if ($mimeType -ne 'application/hwp+zip') {
                return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                    "HWPX mimetype 값이 올바르지 않습니다: $mimeType"
                )
            }
            if ($archive.Entries.Count -gt 0 -and $archive.Entries[0].FullName -ne 'mimetype') {
                $warnings.Add('HWPX mimetype 항목이 ZIP의 첫 번째 항목이 아닙니다.')
            }

            $sectionEntries = @(
                $archive.Entries |
                    Where-Object { $_.FullName -match '^Contents/(?:section|sec)(?<number>\d+)\.xml$' } |
                    Sort-Object @{ Expression = {
                        if ($_.FullName -match '(?<number>\d+)\.xml$') { [int]$Matches.number } else { [int]::MaxValue }
                    } }, FullName
            )
            if ($sectionEntries.Count -eq 0) {
                return New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
                    'HWPX ZIP에 Contents/sectionN.xml 본문이 없습니다.'
                )
            }

            $paragraphs = [Collections.Generic.List[string]]::new()
            $controls = [Collections.Generic.List[object]]::new()
            $tables = [Collections.Generic.List[object]]::new()
            $structureWarnings = [Collections.Generic.List[string]]::new()
            $fields = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($sectionEntry in $sectionEntries) {
                $document = Read-HwpxXmlEntry -Entry $sectionEntry -MaximumCharacters $MaximumXmlCharacters
                foreach ($paragraph in @(Get-HwpxSectionData -Document $document -SectionName $sectionEntry.FullName `
                    -Controls $controls -FieldMap $fields -Tables $tables -StructureWarnings $structureWarnings)) {
                    $paragraphs.Add([string]$paragraph)
                }
            }

            $warnings.Add('HWPX를 ZIP/XML 구조로 읽었습니다. 페이지 수와 최종 레이아웃은 한컴오피스에서 별도 확인해야 합니다.')
            foreach ($structureWarning in $structureWarnings) { $warnings.Add($structureWarning) }
            New-HwpResult -Status PASS_WITH_WARNINGS -Command inspect-hwpx-package -Data ([pscustomobject]@{
                Path = $resolvedPath
                Text = $paragraphs -join "`r`n"
                Fields = [pscustomobject]$fields
                Controls = @($controls)
                Tables = @($tables)
                PageCount = 0
                SectionCount = $sectionEntries.Count
                EntryCount = $archive.Entries.Count
                UncompressedBytes = $totalLength
                NativeLayoutVerified = $false
            }) -Warnings @($warnings)
        }
        finally {
            $archive.Dispose()
        }
    }
    catch [IO.InvalidDataException] {
        New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
            "HWPX ZIP을 읽을 수 없습니다: $($_.Exception.Message)"
        )
    }
    catch [Xml.XmlException] {
        New-HwpResult -Status BLOCKED -Command inspect-hwpx-package -Errors @(
            "HWPX XML을 안전하게 읽을 수 없습니다: $($_.Exception.Message)"
        )
    }
    catch {
        New-HwpResult -Status FAILED -Command inspect-hwpx-package -Errors @(
            "HWPX 패키지 검사 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        $stream.Dispose()
    }
}

function Get-HwpInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LiteralPath,

        [object]$ExecutionContext = (New-HwpExecutionContext),

        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),

        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },

        [AllowNull()]
        [scriptblock]$SecurityModuleReader = $null
    )

    $resolvedPath = ''
    $sha256 = ''
    $detectedKind = 'UNKNOWN'
    try {
        $format = Get-HwpFileKind -LiteralPath $LiteralPath
        $resolvedPath = $format.Path
        $detectedKind = $format.DetectedKind
        $sha256 = Get-HwpSha256 -LiteralPath $resolvedPath
    }
    catch {
        return New-HwpInspectionRecord -Status FAILED -Path ([IO.Path]::GetFullPath($LiteralPath)) -Errors @(
            $_.Exception.Message
        )
    }

    if (-not $format.ExtensionMatches) {
        return New-HwpInspectionRecord -Status BLOCKED -Path $resolvedPath -Sha256 $sha256 `
            -DetectedKind $detectedKind -Errors @('확장자와 실제 파일 형식이 다릅니다.')
    }

    if ($detectedKind -eq 'HWPX-ZIP') {
        $package = Get-HwpxPackageInspection -LiteralPath $resolvedPath
        if ($package.Status -eq 'BLOCKED' -or $package.Status -eq 'FAILED') {
            return New-HwpInspectionRecord -Status $package.Status -Path $resolvedPath -Sha256 $sha256 `
                -DetectedKind $detectedKind -Warnings @($package.Warnings) -Errors @($package.Errors)
        }

        return New-HwpInspectionRecord -Status $package.Status -Path $resolvedPath -Sha256 $sha256 `
            -DetectedKind $detectedKind -Text ([string]$package.Data.Text) -Fields $package.Data.Fields `
            -Controls @($package.Data.Controls) -Tables @($package.Data.Tables) `
            -PageCount ([int]$package.Data.PageCount) `
            -Warnings @($package.Warnings)
    }

    $route = Resolve-HwpBackend -Command inspect -DetectedKind $detectedKind `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpInspectionRecord -Status $route.Status -Path $resolvedPath `
            -Sha256 $sha256 -DetectedKind $detectedKind `
            -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -eq 'hwp-portable') {
        $portable = Get-HwpPortableInspection -LiteralPath $resolvedPath -ExpectedSha256 $sha256
        if ($portable.Status -eq 'BLOCKED' -or $portable.Status -eq 'FAILED') {
            return New-HwpInspectionRecord -Status $portable.Status -Path $resolvedPath -Sha256 $sha256 `
                -DetectedKind $detectedKind -Warnings @($portable.Warnings) -Errors @($portable.Errors)
        }

        return New-HwpInspectionRecord -Status $portable.Status -Path $resolvedPath -Sha256 $sha256 `
            -DetectedKind $detectedKind -Text ([string]$portable.Data.Text) `
            -Fields $portable.Data.Fields -Controls @($portable.Data.Controls) `
            -Tables @($portable.Data.Tables) -PageCount ([int]$portable.Data.PageCount) `
            -Warnings @($portable.Warnings)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpInspectionRecord -Status BLOCKED -Path $resolvedPath `
            -Sha256 $sha256 -DetectedKind $detectedKind `
            -Errors @("백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)")
    }

    $session = $null
    try {
        $session = & $SessionFactory $ExecutionContext
        if ($null -eq $session) {
            throw '세션 팩터리가 한컴 세션을 반환하지 않았습니다.'
        }

        $openResult = if ($detectedKind -eq 'HWP-BINARY') {
            Open-HwpDocumentFromMemory -Session $session -LiteralPath $resolvedPath
        }
        elseif ($null -ne $SecurityModuleReader) {
            Open-HwpDocumentReadOnly -Session $session -LiteralPath $resolvedPath -SecurityModuleReader $SecurityModuleReader
        }
        else {
            Open-HwpDocumentReadOnly -Session $session -LiteralPath $resolvedPath
        }
        if ($openResult.Status -eq 'BLOCKED' -or $openResult.Status -eq 'FAILED') {
            return New-HwpInspectionRecord -Status $openResult.Status -Path $resolvedPath -Sha256 $sha256 `
                -DetectedKind $detectedKind -Warnings @($openResult.Warnings) -Errors @($openResult.Errors) `
                -HancomVersion ([string]$session.Version)
        }

        $text = Get-HwpPlainText -Session $session
        $fields = Get-HwpFieldMap -Session $session
        $controls = @(Get-HwpControlInventory -Session $session)
        $pageCount = [int]$session.Hwp.PageCount
        $status = if ($openResult.Warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }

        New-HwpInspectionRecord -Status $status -Path $resolvedPath -Sha256 $sha256 `
            -DetectedKind $detectedKind -Text $text -Fields $fields -Controls $controls `
            -PageCount $pageCount -Warnings @($openResult.Warnings) -HancomVersion ([string]$session.Version)
    }
    catch {
        New-HwpInspectionRecord -Status FAILED -Path $resolvedPath -Sha256 $sha256 `
            -DetectedKind $detectedKind -Errors @($_.Exception.Message) `
            -HancomVersion $(if ($null -ne $session) { [string]$session.Version } else { '' })
    }
    finally {
        if ($null -ne $session) {
            Close-HwpSession -Session $session
        }
    }
}

Export-ModuleMember -Function @(
    'Open-HwpDocumentReadOnly',
    'Open-HwpDocumentFromMemory',
    'Get-HwpPlainText',
    'Get-HwpFieldMap',
    'Get-HwpControlInventory',
    'Get-HwpxPackageInspection',
    'Get-HwpInspection'
)
