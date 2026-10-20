Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Bounded, local-only sidecar. No generator, COM, GUI or extraction dependency.
# Limits: 512 MiB input, 4096 entries, 64 MiB/entry, 256 MiB expanded total,
# 16 MiB/XML part, 200:1 expansion above 1 MiB, 1000 operations, 1 MiB/text,
# 16 MiB characters of cumulative replacement text before editing the DOM.
$script:ScopedHp = 'http://www.hancom.co.kr/hwpml/2011/paragraph'
$script:ScopedHs = 'http://www.hancom.co.kr/hwpml/2011/section'
$script:ScopedHh = 'http://www.hancom.co.kr/hwpml/2011/head'

function New-ScopedNamespaces {
    param([xml]$Xml)
    $ns = [Xml.XmlNamespaceManager]::new($Xml.NameTable)
    $ns.AddNamespace('hp', $script:ScopedHp)
    $ns.AddNamespace('hs', $script:ScopedHs)
    $ns.AddNamespace('hh', $script:ScopedHh)
    $ns.AddNamespace('hc', 'http://www.hancom.co.kr/hwpml/2011/core')
    $ns.AddNamespace('opf', 'http://www.idpf.org/2007/opf/')
    return ,$ns
}

function Assert-ScopedEntryName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name) -or $Name.Length -gt 1024 -or
        $Name -match '[\\:\x00-\x1f%?#]' -or $Name.StartsWith('/')) {
        throw "Unsafe ZIP entry path: $Name"
    }
    foreach ($segment in $Name.TrimEnd('/').Split('/')) {
        if ($segment -in @('', '.', '..') -or $segment -match '[. ]$') {
            throw "Unsafe ZIP entry path: $Name"
        }
    }
}

function Read-ScopedXml {
    param([byte[]]$Bytes, [string]$Name)
    if ($Bytes.Length -gt 16MB) { throw "XML part exceeds 16 MiB: $Name" }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 16MB
    $settings.MaxCharactersFromEntities = 1024
    $memory = [IO.MemoryStream]::new($Bytes, $false)
    $reader = $null
    try {
        $reader = [Xml.XmlReader]::Create($memory, $settings)
        $xml = [Xml.XmlDocument]::new()
        $xml.PreserveWhitespace = $true
        $xml.XmlResolver = $null
        $xml.Load($reader)
        # Do not invalidate or bypass detected document protection/signatures.
        if ($null -ne $xml.SelectSingleNode("//*[local-name()='encryption-data' or local-name()='EncryptionData' or (namespace-uri()='http://www.w3.org/2000/09/xmldsig#' and local-name()='Signature')]")) {
            throw "Protected or signed XML is not editable: $Name"
        }
        return ,$xml
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $memory.Dispose()
    }
}

function Read-ScopedPackage {
    param([IO.Stream]$Stream)
    if ($Stream.Length -gt 512MB) { throw 'Input exceeds 512 MiB.' }
    $Stream.Position = 0
    $signature = [byte[]]::new(4)
    if ($Stream.Read($signature,0,4) -ne 4 -or [BitConverter]::ToString($signature) -cne '50-4B-03-04') {
        throw 'A real HWPX ZIP local-file signature is required.'
    }
    $Stream.Position = 0
    $zip = [IO.Compression.ZipArchive]::new($Stream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        if ($zip.Entries.Count -gt 4096) { throw 'ZIP exceeds 4096 entries.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $parts = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $xmlParts = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $order = [Collections.Generic.List[string]]::new()
        [long]$total = 0
        # Validate the complete directory before expanding even the first entry.
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            Assert-ScopedEntryName $name
            if (-not $seen.Add($name.TrimEnd('/'))) { throw "Duplicate ZIP entry: $name" }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw "ZIP symlink is not supported: $name" }
            if ($name -match '(?i)^META-INF/.*(signature|encryption)' -or $name -match '(?i)^Scripts/') {
                throw "Protected, signed or active package part is not editable: $name"
            }
            if ($entry.Length -lt 0 -or $entry.Length -gt 64MB -or $entry.CompressedLength -lt 0 -or
                ($entry.Length -gt 1MB -and $entry.Length / [Math]::Max(1,$entry.CompressedLength) -gt 200)) {
                throw "Excessive ZIP expansion: $name"
            }
            $total += $entry.Length
            if ($total -gt 256MB) { throw 'Expanded ZIP exceeds 256 MiB.' }
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $input = $entry.Open()
            $memory = [IO.MemoryStream]::new()
            try {
                $buffer = [byte[]]::new(65536)
                while (($count = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
                    if ($memory.Length + $count -gt $entry.Length) { throw "ZIP length mismatch: $name" }
                    $memory.Write($buffer,0,$count)
                }
                if ($memory.Length -ne $entry.Length) { throw "ZIP length mismatch: $name" }
                $bytes = $memory.ToArray()
            } finally { $input.Dispose(); $memory.Dispose() }
            $parts.Add($name, [pscustomobject]@{Bytes=$bytes; LastWriteTime=$entry.LastWriteTime; Attributes=$entry.ExternalAttributes})
            $order.Add($name)
            if ($name -match '(?i)\.(xml|hpf|rdf|svg)$') { $xmlParts.Add($name, (Read-ScopedXml $bytes $name)) }
        }
        if (-not $parts.ContainsKey('mimetype') -or
            [Text.Encoding]::ASCII.GetString($parts['mimetype'].Bytes) -cne 'application/hwp+zip') {
            throw 'The ZIP mimetype must be application/hwp+zip.'
        }
        foreach ($name in @('version.xml','Contents/header.xml','Contents/content.hpf','META-INF/container.xml')) {
            if (-not $xmlParts.ContainsKey($name)) { throw "Missing HWPX XML part: $name" }
        }
        $header = $xmlParts['Contents/header.xml']
        if ($header.DocumentElement.LocalName -cne 'head' -or $header.DocumentElement.NamespaceURI -cne $script:ScopedHh) {
            throw 'Invalid HWPX header root.'
        }
        $package = $xmlParts['Contents/content.hpf']
        $ns = New-ScopedNamespaces $package
        $items = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($item in $package.SelectNodes('/opf:package/opf:manifest/opf:item', $ns)) {
            $id = $item.GetAttribute('id')
            $href = $item.GetAttribute('href')
            Assert-ScopedEntryName $href
            if ([string]::IsNullOrEmpty($id) -or $items.ContainsKey($id) -or -not $parts.ContainsKey($href)) {
                throw "Invalid manifest item: $id ($href)"
            }
            $items.Add($id,$href)
            if ($item.GetAttribute('media-type') -match '(?i)(/xml|\+xml)$' -and -not $xmlParts.ContainsKey($href)) {
                $xmlParts.Add($href, (Read-ScopedXml $parts[$href].Bytes $href))
            }
        }
        $sections = [Collections.Generic.List[string]]::new()
        foreach ($reference in $package.SelectNodes('/opf:package/opf:spine/opf:itemref', $ns)) {
            $id = $reference.GetAttribute('idref')
            if (-not $items.ContainsKey($id)) { throw "Missing spine resource: $id" }
            $name = $items[$id]
            if ($xmlParts.ContainsKey($name)) {
                $root = $xmlParts[$name].DocumentElement
                if ($root.LocalName -ceq 'sec' -and $root.NamespaceURI -ceq $script:ScopedHs) {
                    if ($sections.Contains($name)) { throw "Duplicate section in spine: $name" }
                    $sections.Add($name)
                }
            }
        }
        $sectionParts = @($xmlParts.Keys | Where-Object {
            $xmlParts[$_].DocumentElement.LocalName -ceq 'sec' -and $xmlParts[$_].DocumentElement.NamespaceURI -ceq $script:ScopedHs
        })
        if ($sections.Count -eq 0 -or $sectionParts.Count -ne $sections.Count -or
            $header.DocumentElement.GetAttribute('secCnt') -cne [string]$sections.Count) {
            throw 'Header section count, section parts and spine must agree.'
        }
        return @{ Parts=$parts; Xml=$xmlParts; Order=$order; Sections=$sections }
    } finally { $zip.Dispose() }
}

function ConvertTo-ScopedMap {
    param([AllowNull()][object]$Value, [string]$Location)
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string]) { throw "$Location keys must be strings." }
            $map.Add($key,$Value[$key])
        }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.MemberType -ne 'NoteProperty') { throw "$Location must contain data properties only." }
            $map.Add($property.Name,$property.Value)
        }
    } else { throw "$Location must be an object." }
    return ,$map
}

function Assert-ScopedKeys {
    param($Map, [string[]]$Keys, [string]$Location, [string[]]$Optional = @())
    foreach ($key in $Map.Keys) {
        if ($Keys -cnotcontains $key -and $Optional -cnotcontains $key) { throw "Unrecognized property: $Location.$key" }
    }
    foreach ($key in $Keys) {
        if (-not $Map.ContainsKey($key)) { throw "Missing property: $Location.$key" }
    }
}

function Test-ScopedInteger {
    param([AllowNull()][object]$Value)
    return ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64])
}

function Get-ScopedIndex {
    param([AllowNull()][object]$Value, [string]$Location)
    if (-not (Test-ScopedInteger $Value) -or $Value -lt 0 -or $Value -gt [int]::MaxValue) {
        throw "$Location must be a nonnegative integer index."
    }
    return [int]$Value
}

function Get-ScopedStyleId {
    param([AllowNull()][object]$Value, [string]$Location)
    if (($Value -isnot [string] -and -not (Test-ScopedInteger $Value)) -or
        [string]$Value -cnotmatch '^(0|[1-9][0-9]{0,9})$' -or [decimal]$Value -gt [uint32]::MaxValue) {
        throw "$Location must be an unsigned style resource ID."
    }
    return [string]$Value
}

function Get-ScopedStyleIds {
    param([xml]$Header, [string]$Kind)
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ns = New-ScopedNamespaces $Header
    $container = if ($Kind -ceq 'charPr') { 'charProperties' } else { 'paraProperties' }
    $collections = $Header.SelectNodes("/hh:head/hh:refList/hh:$container",$ns)
    if ($collections.Count -ne 1) { throw "Expected exactly one header $container collection." }
    $nodes = $collections[0].SelectNodes("hh:$Kind",$ns)
    if ((Get-ScopedXmlInteger $collections[0] 'itemCnt') -ne $nodes.Count) { throw "Header $container itemCnt does not match its resources." }
    foreach ($node in $nodes) {
        $id = Get-ScopedStyleId $node.GetAttribute('id') "header.$Kind.id"
        if (-not $ids.Add($id)) { throw "Duplicate $Kind resource ID: $id" }
    }
    return ,$ids
}

function Get-ScopedTextElement {
    param([Xml.XmlElement]$Run, [string]$Location)
    $elements = @($Run.ChildNodes | Where-Object { $_.NodeType -notin @('Whitespace','SignificantWhitespace') })
    if ($elements.Count -ne 1 -or $elements[0].NodeType -ne 'Element' -or
        $elements[0].LocalName -cne 't' -or $elements[0].NamespaceURI -cne $script:ScopedHp) {
        throw "$Location requires one hp:t; control-bearing or ambiguous runs are blocked."
    }
    foreach ($child in $elements[0].ChildNodes) {
        if ($child.NodeType -notin @('Text','CDATA','Whitespace','SignificantWhitespace')) {
            throw "$Location hp:t must be text-only."
        }
    }
    return ,$elements[0]
}

function Get-ScopedNumber {
    param([AllowNull()][object]$Value, [double]$Minimum, [double]$Maximum, [string]$Location)
    if (-not (Test-ScopedInteger $Value) -and $Value -isnot [double] -and $Value -isnot [single] -and $Value -isnot [decimal]) {
        throw "$Location must be numeric, without string/Boolean coercion."
    }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Location must be finite and between $Minimum and $Maximum."
    }
    return $number
}

function ConvertTo-ScopedMm {
    param([object]$Value, [string]$Location, [switch]$Signed)
    $minimum = if ($Signed) { -2000 } else { 0 }
    $number = Get-ScopedNumber $Value $minimum 2000 $Location
    return [int][Math]::Round(($number * 7200.0 / 25.4),0,[MidpointRounding]::AwayFromZero)
}

function Get-ScopedXmlInteger {
    param([Xml.XmlElement]$Node, [string]$Name, [int]$Minimum = 0, [int]$Maximum = [int]::MaxValue)
    $value = $Node.GetAttribute($Name)
    if ($value -cnotmatch '^(0|[1-9][0-9]{0,9})$' -or [long]$value -lt $Minimum -or [long]$value -gt $Maximum) {
        throw "Invalid $($Node.LocalName).$Name integer."
    }
    return [int]$value
}

function New-ScopedPageReplacement {
    param([Xml.XmlElement]$Page, $Operation, [string]$Location)
    $allowed = @('orientation','margins','paperWidthMm','paperHeightMm')
    $fields = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($key in $allowed) { if ($Operation.ContainsKey($key)) { $fields.Add($key,$Operation[$key]) } }
    if ($Operation.ContainsKey('page')) {
        if ($fields.Count -gt 0) { throw "$Location.page cannot be combined with flat page properties." }
        $fields = ConvertTo-ScopedMap $Operation['page'] "$Location.page"
        Assert-ScopedKeys $fields @() "$Location.page" $allowed
    }
    if ($fields.Count -eq 0) { throw "$Location requires at least one explicit page value." }
    $copy = $Page.CloneNode($true)
    $ns = New-ScopedNamespaces $copy.OwnerDocument
    if (@('NARROWLY','WIDELY') -cnotcontains $copy.GetAttribute('landscape')) { throw 'Invalid pagePr.landscape.' }
    if ($fields.ContainsKey('orientation')) {
        if ($fields['orientation'] -isnot [string] -or @('LANDSCAPE','PORTRAIT') -cnotcontains $fields['orientation']) {
            throw "$Location.orientation must be LANDSCAPE or PORTRAIT."
        }
        $value = if ($fields['orientation'] -ceq 'LANDSCAPE') { 'NARROWLY' } else { 'WIDELY' }
        $copy.SetAttribute('landscape',$value)
    }
    if ($fields.ContainsKey('paperWidthMm') -ne $fields.ContainsKey('paperHeightMm')) { throw "$Location requires both paper dimensions." }
    if ($fields.ContainsKey('paperWidthMm')) {
        foreach ($pair in @(@('paperWidthMm','width'),@('paperHeightMm','height'))) {
            $units = ConvertTo-ScopedMm $fields[$pair[0]] "$Location.$($pair[0])"
            if ($units -lt 1) { throw "$Location.$($pair[0]) must round to a positive HWPUNIT value." }
            $copy.SetAttribute($pair[1],[string]$units)
        }
    }
    $width = Get-ScopedXmlInteger $copy 'width' 1
    $height = Get-ScopedXmlInteger $copy 'height' 1
    $margins = $copy.SelectNodes('hp:margin',$ns)
    if ($margins.Count -ne 1) { throw "$Location requires exactly one page margin element." }
    $margin = $margins[0]
    if ($fields.ContainsKey('margins')) {
        $values = ConvertTo-ScopedMap $fields['margins'] "$Location.margins"
        Assert-ScopedKeys $values @() "$Location.margins" @('leftMm','rightMm','topMm','bottomMm','headerMm','footerMm','gutterMm')
        if ($values.Count -eq 0) { throw "$Location.margins cannot be empty." }
        foreach ($key in $values.Keys) { $margin.SetAttribute($key.Substring(0,$key.Length-2),[string](ConvertTo-ScopedMm $values[$key] "$Location.margins.$key")) }
    }
    $m = @{}
    foreach ($name in @('left','right','top','bottom','header','footer','gutter')) { $m[$name] = Get-ScopedXmlInteger $margin $name }
    $gutterType = $copy.GetAttribute('gutterType')
    if (@('LEFT_ONLY','LEFT_RIGHT','TOP_ONLY','TOP_BOTTOM') -cnotcontains $gutterType) { throw 'Unsupported pagePr.gutterType.' }
    $effectiveWidth = if ($copy.GetAttribute('landscape') -ceq 'NARROWLY') { $height } else { $width }
    $effectiveHeight = if ($copy.GetAttribute('landscape') -ceq 'NARROWLY') { $width } else { $height }
    $topGutter = $gutterType -cin @('TOP_ONLY','TOP_BOTTOM')
    $bodyWidth = [long]$effectiveWidth - $m.left - $m.right
    $bodyHeight = [long]$effectiveHeight - $m.top - $m.bottom - $m.header - $m.footer
    if ($topGutter) { $bodyHeight -= $m.gutter } else { $bodyWidth -= $m.gutter }
    if ($bodyWidth -le 0 -or $bodyHeight -le 0) { throw "$Location effective body must remain positive after orientation and margins." }
    return ,$copy
}

function Get-ScopedOneChild {
    param([Xml.XmlElement]$Node, [string]$XPath)
    $nodes = $Node.SelectNodes($XPath,(New-ScopedNamespaces $Node.OwnerDocument))
    if ($nodes.Count -ne 1) { throw "Ambiguous or missing $($Node.LocalName)/$XPath." }
    return ,$nodes[0]
}

function Get-ScopedTableGrid {
    param([Xml.XmlElement]$Table)
    $ns = New-ScopedNamespaces $Table.OwnerDocument
    $rowCount = Get-ScopedXmlInteger $Table 'rowCnt' 1 256
    $columnCount = Get-ScopedXmlInteger $Table 'colCnt' 1 256
    if ($rowCount*$columnCount -gt 4096) { throw 'Table exceeds 4096 grid positions.' }
    if ((Get-ScopedXmlInteger $Table 'cellSpacing') -ne 0) { throw 'Table edits require zero cellSpacing.' }
    foreach ($flag in @('protect','lock')) {
        if ($Table.HasAttribute($flag) -and $Table.GetAttribute($flag) -cnotin @('0','false')) { throw "Protected table: $flag." }
    }
    if ($Table.SelectNodes('hp:cellzoneList',$ns).Count -gt 0) { throw 'Table cellzone overrides require a separate editor.' }
    $rows = $Table.SelectNodes('hp:tr',$ns)
    if ($rows.Count -ne $rowCount) { throw 'Table rowCnt does not match direct rows.' }
    $grid = @{}
    $cells = [Collections.Generic.List[object]]::new()
    $widths = [long[]]::new($columnCount)
    $heights = [long[]]::new($rowCount)
    for ($r=0; $r -lt $rowCount; $r++) {
        $lastColumn = -1
        foreach ($cell in $rows[$r].SelectNodes('hp:tc',$ns)) {
            $address = Get-ScopedOneChild $cell 'hp:cellAddr'
            $span = Get-ScopedOneChild $cell 'hp:cellSpan'
            $size = Get-ScopedOneChild $cell 'hp:cellSz'
            $row = Get-ScopedXmlInteger $address 'rowAddr'
            $column = Get-ScopedXmlInteger $address 'colAddr'
            $rs = Get-ScopedXmlInteger $span 'rowSpan' 1 256
            $cs = Get-ScopedXmlInteger $span 'colSpan' 1 256
            $w = Get-ScopedXmlInteger $size 'width' 1
            $h = Get-ScopedXmlInteger $size 'height' 1
            if ($row -ne $r -or $column -le $lastColumn -or [long]$row+$rs -gt $rowCount -or [long]$column+$cs -gt $columnCount) {
                throw 'Table cell address/span is unordered or out of range.'
            }
            $lastColumn = $column
            $record = [pscustomobject]@{Node=$cell;Row=$row;Column=$column;RowSpan=$rs;ColumnSpan=$cs;Width=$w;Height=$h}
            for ($rr=$row; $rr -lt $row+$rs; $rr++) {
                for ($cc=$column; $cc -lt $column+$cs; $cc++) {
                    $key = "$rr,$cc"
                    if ($grid.ContainsKey($key)) { throw "Overlapping table occupancy: $key." }
                    $grid[$key] = $record
                }
            }
            if ($cs -eq 1) {
                if ($widths[$column] -ne 0 -and $widths[$column] -ne $w) { throw 'Inconsistent table column widths.' }
                $widths[$column] = $w
            }
            if ($rs -eq 1) {
                if ($heights[$row] -ne 0 -and $heights[$row] -ne $h) { throw 'Inconsistent table row heights.' }
                $heights[$row] = $h
            }
            $cells.Add($record)
        }
    }
    if ($grid.Count -ne $rowCount*$columnCount) { throw 'Table occupancy contains missing cells.' }
    $model = @{Rows=$rows;Cells=$cells;Occupancy=$grid;Widths=$widths;Heights=$heights;RowCount=$rowCount;ColumnCount=$columnCount}
    Assert-ScopedGridDimensions $model
    return $model
}

function Assert-ScopedGridDimensions {
    param($Grid)
    foreach ($cell in $Grid.Cells) {
        foreach ($axis in @('Width','Height')) {
            $start = if ($axis -ceq 'Width') {$cell.Column} else {$cell.Row}
            $count = if ($axis -ceq 'Width') {$cell.ColumnSpan} else {$cell.RowSpan}
            $sizes = if ($axis -ceq 'Width') {$Grid.Widths} else {$Grid.Heights}
            [long]$sum=0; $known=$true
            for ($n=$start; $n -lt $start+$count; $n++) {
                if ($sizes[$n] -eq 0) { $known=$false }
                $sum += $sizes[$n]
            }
            if ($known -and $sum -ne $cell.$axis) { throw "Inconsistent table span $axis." }
            if (-not $known -and $sum -ge $cell.$axis) { throw "Inconsistent table span $axis leaves no positive size for unknown tracks." }
        }
    }
}

function Assert-ScopedCellAttributes {
    param([Xml.XmlElement]$Node, [string[]]$Allowed)
    foreach ($attr in $Node.Attributes) {
        if ($attr.NamespaceURI -ceq 'http://www.w3.org/2000/xmlns/') { continue }
        if ($attr.NamespaceURI -cne '' -or $Allowed -cnotcontains $attr.LocalName) {
            throw "Unknown cell metadata cannot be removed or duplicated: $($Node.LocalName)/$($attr.Name)."
        }
    }
}

function Get-ScopedCellContent {
    param([Xml.XmlElement]$Cell, $CharacterIds, $ParagraphIds, [switch]$PreserveCellMetadata)
    $ns = New-ScopedNamespaces $Cell.OwnerDocument
    if (-not $PreserveCellMetadata) {
        Assert-ScopedCellAttributes $Cell @('name','header','hasMargin','protect','editable','dirty','borderFillIDRef')
        if ($Cell.GetAttribute('name') -cne '') { throw 'Named cells cannot be merged or split.' }
    }
    foreach ($flag in @('protect','editable')) {
        if ($Cell.HasAttribute($flag) -and $Cell.GetAttribute($flag) -cnotin @('0','false')) { throw "Protected or special cell: $flag." }
    }
    $children = @('subList','cellAddr','cellSpan','cellSz','cellMargin')
    foreach ($child in $Cell.ChildNodes) {
        if ($PreserveCellMetadata) { continue }
        if ($child.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
        if ($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or $children -cnotcontains $child.LocalName) {
            throw 'Unknown cell structure cannot be removed or duplicated.'
        }
    }
    $attributes = @{
        subList=@('id','textDirection','lineWrap','vertAlign','linkListIDRef','linkListNextIDRef','textWidth','textHeight','hasTextRef','hasNumRef')
        cellAddr=@('rowAddr','colAddr'); cellSpan=@('rowSpan','colSpan'); cellSz=@('width','height'); cellMargin=@('left','right','top','bottom')
    }
    foreach ($name in $children) {
        $node = Get-ScopedOneChild $Cell "hp:$name"
        if ($PreserveCellMetadata) { continue }
        Assert-ScopedCellAttributes $node $attributes[$name]
        if ($name -cne 'subList' -and $node.HasChildNodes) { throw "Unknown cell metadata children: $name." }
    }
    $sub = Get-ScopedOneChild $Cell 'hp:subList'
    foreach ($name in @('id','linkListIDRef','linkListNextIDRef','textWidth','textHeight','hasTextRef','hasNumRef')) {
        if ($sub.HasAttribute($name) -and $sub.GetAttribute($name) -cnotin @('','0')) { throw "Linked or special cell subList: $name." }
    }
    if (-not $PreserveCellMetadata -and $sub.HasAttribute('textDirection') -and $sub.GetAttribute('textDirection') -cne 'HORIZONTAL') { throw 'Only horizontal text-only cells are supported.' }
    foreach ($child in $sub.ChildNodes) {
        if ($child.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
        if ($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or $child.LocalName -cne 'p') { throw 'Cell subList must contain only direct paragraphs.' }
    }
    $paragraphs = @($sub.SelectNodes('hp:p',$ns))
    if ($paragraphs.Count -eq 0) { throw 'Cell must contain at least one paragraph.' }
    $texts = [Collections.Generic.List[string]]::new()
    foreach ($p in $paragraphs) {
        if (-not $ParagraphIds.Contains((Get-ScopedStyleId $p.GetAttribute('paraPrIDRef') 'cell.paraPrIDRef'))) { throw 'Cell paragraph style resource is absent.' }
        foreach ($child in $p.ChildNodes) {
            if ($child.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
            if ($child.NodeType -ne 'Element' -or $child.NamespaceURI -cne $script:ScopedHp -or $child.LocalName -cnotin @('run','linesegarray')) { throw 'Cell paragraph contains an unknown control.' }
        }
        $runs = $p.SelectNodes('hp:run',$ns)
        if ($runs.Count -eq 0) { throw 'Cell paragraph must contain a text run.' }
        $line = [Text.StringBuilder]::new()
        foreach ($run in $runs) {
            if (-not $CharacterIds.Contains((Get-ScopedStyleId $run.GetAttribute('charPrIDRef') 'cell.charPrIDRef'))) { throw 'Cell character style resource is absent.' }
            $null = $line.Append((Get-ScopedInlineText $run))
        }
        $texts.Add($line.ToString())
    }
    $text = $texts -join "`n"
    if ($text.Length -gt 1MB) { throw 'Cell expected text exceeds 1 MiB.' }
    return @{SubList=$sub;Paragraphs=$paragraphs;Text=$text}
}

function New-ScopedMergedTable {
    param([Xml.XmlElement]$Table, $Operation, [xml]$Header)
    $copy = $Table.CloneNode($true)
    $grid = Get-ScopedTableGrid $copy
    $row = Get-ScopedIndex $Operation['row'] 'merge.row'
    $column = Get-ScopedIndex $Operation['column'] 'merge.column'
    $rowSpan = Get-ScopedIndex $Operation['rowSpan'] 'merge.rowSpan'
    $columnSpan = Get-ScopedIndex $Operation['columnSpan'] 'merge.columnSpan'
    if ($rowSpan -lt 1 -or $columnSpan -lt 1 -or [long]$row+$rowSpan -gt $grid.RowCount -or [long]$column+$columnSpan -gt $grid.ColumnCount -or $rowSpan*$columnSpan -lt 2) { throw 'Merge rectangle is empty or out of range.' }
    if ($Operation['contentOrder'] -isnot [string] -or $Operation['contentOrder'] -cne 'row-major') { throw 'merge.contentOrder must explicitly be row-major.' }
    $expected = $Operation['expectedTexts']
    if ($expected -isnot [Collections.IList] -or $expected.Count -ne $rowSpan*$columnSpan) { throw 'merge.expectedTexts must match the rectangle in row-major order.' }
    $charIds = Get-ScopedStyleIds $Header 'charPr'
    $paraIds = Get-ScopedStyleIds $Header 'paraPr'
    $selected = [Collections.Generic.List[object]]::new()
    $affected = @{}
    for ($r=$row; $r -lt $row+$rowSpan; $r++) {
        for ($c=$column; $c -lt $column+$columnSpan; $c++) {
            $cell = $grid.Occupancy["$r,$c"]
            if ($cell.RowSpan -ne 1 -or $cell.ColumnSpan -ne 1) { throw 'Merge requires initially unmerged rectangular cells.' }
            $content = Get-ScopedCellContent $cell.Node $charIds $paraIds
            if ($expected[$selected.Count] -isnot [string] -or $expected[$selected.Count] -cne $content.Text) { throw 'merge.expectedTexts does not match the original cell text.' }
            $selected.Add(@{Cell=$cell;Content=$content})
            $affected["$r,$c"] = $true
        }
    }
    $anchor = $selected[0]
    for ($n=1; $n -lt $selected.Count; $n++) {
        foreach ($p in $selected[$n].Content.Paragraphs) { $null = $anchor.Content.SubList.AppendChild($p) }
        $cell = $selected[$n].Cell.Node
        $null = $cell.ParentNode.RemoveChild($cell)
    }
    $ns = New-ScopedNamespaces $copy.OwnerDocument
    foreach ($cache in @($anchor.Content.SubList.SelectNodes('hp:p/hp:linesegarray',$ns))) { $null = $cache.ParentNode.RemoveChild($cache) }
    $span = Get-ScopedOneChild $anchor.Cell.Node 'hp:cellSpan'
    $span.SetAttribute('rowSpan',[string]$rowSpan); $span.SetAttribute('colSpan',[string]$columnSpan)
    [long]$width=0; [long]$height=0
    for ($c=$column; $c -lt $column+$columnSpan; $c++) { $width += $grid.Widths[$c] }
    for ($r=$row; $r -lt $row+$rowSpan; $r++) { $height += $grid.Heights[$r] }
    if ($width -gt [int]::MaxValue -or $height -gt [int]::MaxValue) { throw 'Merged cell dimensions exceed HWPUNIT limits.' }
    $size = Get-ScopedOneChild $anchor.Cell.Node 'hp:cellSz'
    $size.SetAttribute('width',[string]$width); $size.SetAttribute('height',[string]$height)
    $after = Get-ScopedTableGrid $copy
    # Explicit preservation proof for every cell outside the selected rectangle.
    $before = Get-ScopedTableGrid $Table
    foreach ($cell in $before.Cells) {
        $key = "$($cell.Row),$($cell.Column)"
        if (-not $affected.ContainsKey($key) -and $cell.Node.OuterXml -cne $after.Occupancy[$key].Node.OuterXml) { throw "Outside cell changed: $key." }
    }
    return ,$copy
}

function Resolve-ScopedSplitAxis {
    param([long[]]$Sizes, [int]$Start, [int]$Count, [long]$Total)
    [long]$known = 0
    $missing = [Collections.Generic.List[int]]::new()
    for ($n=$Start; $n -lt $Start+$Count; $n++) {
        if ($Sizes[$n] -eq 0) { $missing.Add($n) } else { $known += $Sizes[$n] }
    }
    if ($missing.Count -eq 0) {
        if ($known -ne $Total) { throw 'Split dimensions conflict with neighbors.' }
    } else {
        $remainder = $Total - $known
        if ($remainder -le 0 -or $remainder % $missing.Count -ne 0) { throw 'Split dimensions are ambiguous: unknown tracks are not evenly divisible.' }
        foreach ($n in $missing) { $Sizes[$n] = [long]($remainder / $missing.Count) }
    }
}

function New-ScopedSplitTable {
    param([Xml.XmlElement]$Table, $Operation, $Package, $Allocation)
    $copy = $Table.CloneNode($true)
    $grid = Get-ScopedTableGrid $copy
    $row = Get-ScopedIndex $Operation['row'] 'split.row'
    $column = Get-ScopedIndex $Operation['column'] 'split.column'
    $key = "$row,$column"
    if (-not $grid.Occupancy.ContainsKey($key)) { throw 'Split cell address is out of range.' }
    $anchor = $grid.Occupancy[$key]
    if ($anchor.Row -ne $row -or $anchor.Column -ne $column) { throw 'Split address must be the merged anchor, not a covered position.' }
    if ($anchor.RowSpan*$anchor.ColumnSpan -lt 2) { throw 'Split requires an existing merged anchor.' }
    $charIds = Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'charPr'
    $paraIds = Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'paraPr'
    $content = Get-ScopedCellContent $anchor.Node $charIds $paraIds
    if ($Operation['expectedText'] -isnot [string] -or $Operation['expectedText'] -cne $content.Text) { throw 'split.expectedText does not match the original anchor paragraph text (LF-separated).' }
    Resolve-ScopedSplitAxis $grid.Widths $column $anchor.ColumnSpan $anchor.Width
    Resolve-ScopedSplitAxis $grid.Heights $row $anchor.RowSpan $anchor.Height
    Assert-ScopedGridDimensions $grid
    if (-not $Allocation.ContainsKey('NextParagraphId')) {
        [long]$maximum = 0
        foreach ($part in $Package.Sections) {
            $xml = $Package.Xml[$part]
            foreach ($p in $xml.SelectNodes('//hp:p[@id]',(New-ScopedNamespaces $xml))) {
                $id = Get-ScopedStyleId $p.GetAttribute('id') 'paragraph.id'
                $maximum = [Math]::Max($maximum,[long]$id)
            }
        }
        $Allocation.NextParagraphId = $maximum+1
    }
    $ns = New-ScopedNamespaces $copy.OwnerDocument
    $template = $anchor.Node.CloneNode($true)
    $firstParagraph = $content.Paragraphs[0]
    $firstRun = $firstParagraph.SelectNodes('hp:run',$ns)[0]
    for ($r=$row; $r -lt $row+$anchor.RowSpan; $r++) {
        for ($c=$column; $c -lt $column+$anchor.ColumnSpan; $c++) {
            if ($r -eq $row -and $c -eq $column) {
                $cell = $anchor.Node
            } else {
                if ($Allocation.NextParagraphId -gt [uint32]::MaxValue) { throw 'No unique paragraph IDs remain for split cells.' }
                $cell = $template.CloneNode($false)
                $sub = (Get-ScopedOneChild $template 'hp:subList').CloneNode($false)
                $p = $copy.OwnerDocument.CreateElement('hp','p',$script:ScopedHp)
                $p.SetAttribute('id',[string]$Allocation.NextParagraphId)
                $Allocation.NextParagraphId++
                $p.SetAttribute('paraPrIDRef',$firstParagraph.GetAttribute('paraPrIDRef'))
                if ($firstParagraph.HasAttribute('styleIDRef')) { $p.SetAttribute('styleIDRef',$firstParagraph.GetAttribute('styleIDRef')) }
                $p.SetAttribute('pageBreak','0'); $p.SetAttribute('columnBreak','0'); $p.SetAttribute('merged','0')
                $run = $copy.OwnerDocument.CreateElement('hp','run',$script:ScopedHp)
                $run.SetAttribute('charPrIDRef',$firstRun.GetAttribute('charPrIDRef'))
                $null = $run.AppendChild($copy.OwnerDocument.CreateElement('hp','t',$script:ScopedHp))
                $null = $p.AppendChild($run); $null = $sub.AppendChild($p); $null = $cell.AppendChild($sub)
                foreach ($name in @('cellAddr','cellSpan','cellSz','cellMargin')) { $null = $cell.AppendChild((Get-ScopedOneChild $template "hp:$name").CloneNode($true)) }
            }
            $addr = Get-ScopedOneChild $cell 'hp:cellAddr'
            $addr.SetAttribute('rowAddr',[string]$r); $addr.SetAttribute('colAddr',[string]$c)
            $span = Get-ScopedOneChild $cell 'hp:cellSpan'
            $span.SetAttribute('rowSpan','1'); $span.SetAttribute('colSpan','1')
            $size = Get-ScopedOneChild $cell 'hp:cellSz'
            $size.SetAttribute('width',[string]$grid.Widths[$c]); $size.SetAttribute('height',[string]$grid.Heights[$r])
            if ($r -ne $row -or $c -ne $column) {
                $next = $null
                foreach ($existing in $grid.Rows[$r].SelectNodes('hp:tc',$ns)) {
                    if ((Get-ScopedXmlInteger (Get-ScopedOneChild $existing 'hp:cellAddr') 'colAddr') -gt $c) { $next=$existing; break }
                }
                if ($null -eq $next) { $null=$grid.Rows[$r].AppendChild($cell) }
                else { $null=$grid.Rows[$r].InsertBefore($cell,$next) }
            }
        }
    }
    foreach ($cache in @($content.SubList.SelectNodes('hp:p/hp:linesegarray',$ns))) { $null=$cache.ParentNode.RemoveChild($cache) }
    $after = Get-ScopedTableGrid $copy
    $before = Get-ScopedTableGrid $Table
    foreach ($cell in $before.Cells) {
        $cellKey = "$($cell.Row),$($cell.Column)"
        if ($cellKey -cne $key -and $cell.Node.OuterXml -cne $after.Occupancy[$cellKey].Node.OuterXml) { throw "Outside cell changed: $cellKey." }
    }
    return ,$copy
}

function Get-ScopedParagraphBranches {
    param([Xml.XmlElement]$Resource, [string]$Child)
    $ns = New-ScopedNamespaces $Resource.OwnerDocument
    $direct = $Resource.SelectNodes("hh:$Child",$ns)
    $switches = $Resource.SelectNodes('hp:switch',$ns)
    if ($switches.Count -eq 0) {
        if ($direct.Count -ne 1) { throw "Paragraph resource needs one direct $Child." }
        return ,@($direct)
    }
    if ($switches.Count -ne 1 -or $direct.Count -ne 0) { throw "Ambiguous paragraph resource $Child branches." }
    $switch = $switches[0]
    $branches = @($switch.SelectNodes('hp:case | hp:default',$ns))
    if ($branches.Count -ne 2 -or $switch.SelectNodes('hp:case',$ns).Count -ne 1 -or $switch.SelectNodes('hp:default',$ns).Count -ne 1) {
        throw 'Only one canonical paragraph case/default switch is supported.'
    }
    $case = $switch.SelectSingleNode('hp:case',$ns)
    if ($case.GetAttribute('required-namespace',$script:ScopedHp) -cne 'http://www.hancom.co.kr/hwpml/2016/HwpUnitChar') { throw 'Unsupported paragraph switch namespace.' }
    foreach ($node in $switch.ChildNodes) {
        if ($node.NodeType -in @('Whitespace','SignificantWhitespace','Comment')) { continue }
        if ($node.NodeType -ne 'Element' -or $node.NamespaceURI -cne $script:ScopedHp -or $node.LocalName -cnotin @('case','default')) { throw 'Unknown paragraph switch branch.' }
    }
    $result = @()
    foreach ($branch in $branches) { $result += ,(Get-ScopedOneChild $branch "hh:$Child") }
    return ,$result
}

function Set-ScopedCharacterToggle {
    param([Xml.XmlElement]$Resource, [string]$Name, [object]$Value)
    if ($Value -isnot [bool]) { throw "textStyle.$Name must be Boolean." }
    $ns = New-ScopedNamespaces $Resource.OwnerDocument
    $nodes = $Resource.SelectNodes("hh:$Name",$ns)
    if ($nodes.Count -gt 1) { throw "Duplicate character property: $Name." }
    if ($Value -and $nodes.Count -eq 0) {
        # Canonical order: italic, bold, underline. Preserve every existing node.
        $before = Get-ScopedOneChild $Resource 'hh:underline'
        if ($Name -ceq 'italic') {
            $bold = $Resource.SelectNodes('hh:bold',$ns)
            if ($bold.Count -gt 1) { throw 'Duplicate bold property.' }
            if ($bold.Count -eq 1) { $before=$bold[0] }
        }
        $null = $Resource.InsertBefore($Resource.OwnerDocument.CreateElement('hh',$Name,$script:ScopedHh),$before)
    } elseif (-not $Value -and $nodes.Count -eq 1) {
        if ($nodes[0].Attributes.Count -gt 0 -or $nodes[0].HasChildNodes) { throw "Cannot remove unknown metadata from character $Name." }
        $null = $Resource.RemoveChild($nodes[0])
    }
}

function New-ScopedFormatResource {
    param([xml]$Header, [Xml.XmlElement]$Target, [string]$Kind, [object]$Style, $Allocation)
    $fields = ConvertTo-ScopedMap $Style 'format'
    if ($Kind -ceq 'charPr') {
        $allowed = @('fontFamily','fontSizePt','bold','italic','textColor','underline','strikeout','superscript','subscript','letterSpacingPercent','widthPercent')
        $collectionName = 'charProperties'
    } else {
        $allowed = @('alignment','lineSpacingPercent','lineSpacing','leftMarginMm','rightMarginMm','indentMm','marginBeforeMm','marginAfterMm','keepWithNext','keepLines','widowOrphan','pageBreakBefore')
        $collectionName = 'paraProperties'
    }
    Assert-ScopedKeys $fields @() 'format' $allowed
    if ($fields.Count -eq 0) { throw 'Formatting requires at least one explicit property.' }
    if ($fields.ContainsKey('lineSpacing') -and $fields.ContainsKey('lineSpacingPercent')) { throw 'Choose lineSpacing or lineSpacingPercent, not both.' }
    if ($fields.ContainsKey('superscript') -and $fields.ContainsKey('subscript') -and $fields['superscript'] -eq $true -and $fields['subscript'] -eq $true) { throw 'Superscript and subscript cannot both be enabled.' }
    if (-not $Allocation.ContainsKey($Kind)) { $Allocation[$Kind] = Get-ScopedStyleIds $Header $Kind }
    $ids = $Allocation[$Kind]
    $originalId = Get-ScopedStyleId $Target.GetAttribute($Kind+'IDRef') "target.$($Kind)IDRef"
    if (-not $Allocation.ContainsKey('FormatCache')) { $Allocation.FormatCache = @{} }
    $cacheKey = $Kind + '|' + $originalId + '|' + (ConvertTo-Json -InputObject $Style -Depth 15 -Compress)
    if ($Allocation.FormatCache.ContainsKey($cacheKey)) { return $Allocation.FormatCache[$cacheKey] }
    $ns = New-ScopedNamespaces $Header
    $collection = $Header.SelectNodes("/hh:head/hh:refList/hh:$collectionName",$ns)[0]
    $sources = $collection.SelectNodes(('hh:{0}[@id="{1}"]' -f $Kind,$originalId),$ns)
    if($sources.Count -eq 0 -and $Allocation.ContainsKey('Resources')){$sources=@($Allocation.Resources|Where-Object {$_.Kind -ceq $Kind -and $_.Id -ceq $originalId}|ForEach-Object {$_.Node})}
    if ($sources.Count -ne 1) { throw "Original $Kind resource is absent or ambiguous: $originalId." }
    [long]$next = 0
    foreach ($id in $ids) { $next = [Math]::Max($next,([long]$id+1)) }
    if ($next -gt [uint32]::MaxValue) { throw "No unique $Kind resource IDs remain." }
    if (-not $Allocation.ContainsKey('ClonedResourceCharacters')) { $Allocation.ClonedResourceCharacters = [long]0 }
    $Allocation.ClonedResourceCharacters += $sources[0].OuterXml.Length
    if ($Allocation.ClonedResourceCharacters -gt 16MB) { throw 'Cumulative cloned style resources exceed 16 MiB characters.' }
    $copy = $sources[0].CloneNode($true)
    $copy.SetAttribute('id',[string]$next)
    foreach ($key in $fields.Keys) {
        $value = $fields[$key]
        if ($Kind -ceq 'charPr') {
            switch -CaseSensitive ($key) {
                'fontFamily' { Set-ScopedFontFamily $Header $copy $value $Allocation }
                'fontSizePt' {
                    $pt = Get-ScopedNumber $value 1 1000 'textStyle.fontSizePt'
                    $copy.SetAttribute('height',[string][int][Math]::Round(($pt*100),0,[MidpointRounding]::AwayFromZero))
                }
                'textColor' {
                    if ($value -isnot [string] -or $value -cnotmatch '\A#[0-9A-Fa-f]{6}\z') { throw 'textStyle.textColor must be #RRGGBB.' }
                    $copy.SetAttribute('textColor',$value)
                }
                'underline' {
                    if ($value -isnot [string] -or @('NONE','BOTTOM','CENTER','TOP') -cnotcontains $value) { throw 'textStyle.underline must be NONE, BOTTOM, CENTER or TOP.' }
                    (Get-ScopedOneChild $copy 'hh:underline').SetAttribute('type',$value)
                }
                'strikeout' {
                    if ($value -isnot [bool]) { throw 'strikeout must be Boolean.' }
                    (Get-ScopedOneChild $copy 'hh:strikeout').SetAttribute('shape',$(if ($value) {'SOLID'} else {'NONE'}))
                }
                {$_ -cin @('letterSpacingPercent','widthPercent')} {
                    $minimum=if ($key -ceq 'widthPercent') {50} else {-50}; $maximum=if ($key -ceq 'widthPercent') {200} else {50}
                    if (-not (Test-ScopedInteger $value) -or $value -lt $minimum -or $value -gt $maximum) {throw "Invalid integer textStyle.$key."}
                    $node=Get-ScopedOneChild $copy $(if ($key -ceq 'widthPercent') {'hh:ratio'} else {'hh:spacing'})
                    foreach ($lang in @('hangul','latin','hanja','japanese','other','symbol','user')) {$node.SetAttribute($lang,[string]$value)}
                }
                {$_ -cin @('superscript','subscript')} {
                    if ($value -isnot [bool]) {throw "$key must be Boolean."}
                    $name=if ($key -ceq 'superscript') {'supscript'} else {'subscript'}
                    $opposite=if ($key -ceq 'superscript') {'subscript'} else {'supscript'}
                    foreach ($remove in @($(if (-not $value) {$name}),$(if ($value) {$opposite}))) {
                        if ($null -eq $remove) {continue}
                        foreach ($node in @($copy.SelectNodes(('hh:'+$remove),$ns))) {
                            if ($node.Attributes.Count -gt 0 -or $node.HasChildNodes) {throw 'Unknown script metadata cannot be removed.'}
                            $null=$copy.RemoveChild($node)
                        }
                    }
                    if ($value -and $copy.SelectNodes(('hh:'+$name),$ns).Count -eq 0) {$null=$copy.AppendChild($Header.CreateElement('hh',$name,$script:ScopedHh))}
                }
                default { Set-ScopedCharacterToggle $copy $key $value }
            }
        } else {
            switch -CaseSensitive ($key) {
                'alignment' {
                    if ($value -isnot [string] -or @('LEFT','CENTER','RIGHT','JUSTIFY','DISTRIBUTE','DISTRIBUTE_SPACE') -cnotcontains $value) { throw 'Unsupported paragraphStyle.alignment.' }
                    (Get-ScopedOneChild $copy 'hh:align').SetAttribute('horizontal',$value)
                }
                'lineSpacingPercent' {
                    $percent = Get-ScopedIndex $value 'paragraphStyle.lineSpacingPercent'
                    if ($percent -lt 1 -or $percent -gt 1000) { throw 'lineSpacingPercent must be 1 to 1000.' }
                    foreach ($line in (Get-ScopedParagraphBranches $copy 'lineSpacing')) {
                        $line.SetAttribute('type','PERCENT'); $line.SetAttribute('value',[string]$percent)
                        $line.SetAttribute('unit','HWPUNIT')
                    }
                }
                'lineSpacing' {
                    $spacing=ConvertTo-ScopedMap $value 'paragraphStyle.lineSpacing'
                    Assert-ScopedKeys $spacing @('type','valuePt') 'lineSpacing'
                    if ($spacing['type'] -isnot [string] -or $spacing['type'] -cnotin @('FIXED','AT_LEAST')) {throw 'lineSpacing.type must be FIXED or AT_LEAST.'}
                    $pt=Get-ScopedNumber $spacing['valuePt'] 1 1000 'lineSpacing.valuePt'
                    foreach ($line in (Get-ScopedParagraphBranches $copy 'lineSpacing')) {
                        $scale=if ($line.ParentNode.LocalName -ceq 'case') {1} else {2}
                        $line.SetAttribute('type',$spacing['type']); $line.SetAttribute('value',[string][long][Math]::Round(($pt*100*$scale),0,[MidpointRounding]::AwayFromZero)); $line.SetAttribute('unit','HWPUNIT')
                    }
                }
                {$_ -cin @('keepWithNext','keepLines','widowOrphan','pageBreakBefore')} {
                    if ($value -isnot [bool]) { throw "paragraphStyle.$key must be Boolean." }
                    (Get-ScopedOneChild $copy 'hh:breakSetting').SetAttribute($key,[string][int]$value)
                }
                default {
                    $names = @{leftMarginMm='left';rightMarginMm='right';indentMm='intent';marginBeforeMm='prev';marginAfterMm='next'}
                    $units = ConvertTo-ScopedMm $value "paragraphStyle.$key" -Signed:($key -ceq 'indentMm')
                    foreach ($margin in (Get-ScopedParagraphBranches $copy 'margin')) {
                        $node = Get-ScopedOneChild $margin ('hc:'+$names[$key])
                        # HwpUnitChar uses 1/7200 inch; the legacy paragraph branch
                        # (including direct pre-switch resources) uses twice the value.
                        $scale = if ($margin.ParentNode.NamespaceURI -ceq $script:ScopedHp -and $margin.ParentNode.LocalName -ceq 'case') { 1 } else { 2 }
                        $node.SetAttribute('value',[string]([long]$units*$scale)); $node.SetAttribute('unit','HWPUNIT')
                    }
                }
            }
        }
    }
    $null = $ids.Add([string]$next)
    $resource = @{Node=$copy;Collection=$collection;Kind=$Kind;Id=[string]$next;CountAttribute='itemCnt'}
    Add-ScopedPreparedResource $Allocation $resource
    $Allocation.FormatCache[$cacheKey]=$resource
    return $resource
}

function Get-ScopedNextParagraphId {
    param($Package, $Allocation)
    if (-not $Allocation.ContainsKey('NextParagraphId')) {
        [long]$maximum = 0
        foreach ($part in $Package.Sections) {
            $xml = $Package.Xml[$part]
            foreach ($p in $xml.SelectNodes('//hp:p[@id]',(New-ScopedNamespaces $xml))) {
                $maximum = [Math]::Max($maximum,[long](Get-ScopedStyleId $p.GetAttribute('id') 'paragraph.id'))
            }
        }
        $Allocation.NextParagraphId = $maximum+1
    }
    if ($Allocation.NextParagraphId -gt [uint32]::MaxValue) { throw 'No unique paragraph IDs remain.' }
    $id = [string]$Allocation.NextParagraphId
    $Allocation.NextParagraphId++
    return $id
}

function New-ScopedEmptyCell {
    param([Xml.XmlElement]$Template, $Content, $Package, $Allocation)
    $xml = $Template.OwnerDocument
    $ns = New-ScopedNamespaces $xml
    $cell = $Template.CloneNode($false)
    $cell.SetAttribute('header','0')
    $sub = $Content.SubList.CloneNode($false)
    $firstParagraph = $Content.Paragraphs[0]
    $p = $xml.CreateElement('hp','p',$script:ScopedHp)
    $p.SetAttribute('id',(Get-ScopedNextParagraphId $Package $Allocation))
    $p.SetAttribute('paraPrIDRef',$firstParagraph.GetAttribute('paraPrIDRef'))
    if ($firstParagraph.HasAttribute('styleIDRef')) { $p.SetAttribute('styleIDRef',$firstParagraph.GetAttribute('styleIDRef')) }
    $p.SetAttribute('pageBreak','0'); $p.SetAttribute('columnBreak','0'); $p.SetAttribute('merged','0')
    $run = $xml.CreateElement('hp','run',$script:ScopedHp)
    $run.SetAttribute('charPrIDRef',$firstParagraph.SelectSingleNode('hp:run',$ns).GetAttribute('charPrIDRef'))
    $null = $run.AppendChild($xml.CreateElement('hp','t',$script:ScopedHp))
    $null = $p.AppendChild($run); $null = $sub.AppendChild($p); $null = $cell.AppendChild($sub)
    foreach ($name in @('cellAddr','cellSpan','cellSz','cellMargin')) { $null = $cell.AppendChild((Get-ScopedOneChild $Template "hp:$name").CloneNode($true)) }
    return ,$cell
}

function New-ScopedInsertedTable {
    param([Xml.XmlElement]$Table, $Operation, $Package, $Allocation)
    $ns = New-ScopedNamespaces $Table.OwnerDocument
    if ($null -ne $Table.SelectSingleNode('ancestor::hp:tc | ancestor::hp:header | ancestor::hp:footer',$ns)) { throw 'Insertion requires a body table, not a nested/header/footer table.' }
    $copy = $Table.CloneNode($true)
    $grid = Get-ScopedTableGrid $copy
    foreach ($node in $copy.ChildNodes) {
        if ($node.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
        if ($node.NodeType -ne 'Element' -or $node.NamespaceURI -cne $script:ScopedHp -or $node.LocalName -cnotin @('sz','pos','inMargin','outMargin','tr')) { throw 'Unknown table geometry cannot be updated for insertion.' }
    }
    foreach ($row in $grid.Rows) {
        Assert-ScopedCellAttributes $row @()
        foreach ($node in $row.ChildNodes) {
            if ($node.NodeType -in @('Whitespace','SignificantWhitespace')) { continue }
            if ($node.NodeType -ne 'Element' -or $node.NamespaceURI -cne $script:ScopedHp -or $node.LocalName -cne 'tc') { throw 'Unknown table row metadata cannot be duplicated.' }
        }
    }
    $charIds = Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'charPr'
    $paraIds = Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'paraPr'
    $contents = @{}
    foreach ($cell in $grid.Cells) {
        if ($cell.RowSpan -ne 1 -or $cell.ColumnSpan -ne 1) { throw 'Insertion requires an unmerged rectangular table.' }
        $contents["$($cell.Row),$($cell.Column)"] = Get-ScopedCellContent $cell.Node $charIds $paraIds
    }
    $isRow = $Operation['type'] -ceq 'insert-table-row'
    $index = Get-ScopedIndex $Operation['index'] 'insert.index'
    $count = if ($isRow) { $grid.RowCount } else { $grid.ColumnCount }
    $tracks = if ($isRow) { $grid.Widths } else { $grid.Heights }
    if ($index -gt $count -or $count -ge 256 -or ($count+1)*$tracks.Count -gt 4096) { throw 'Insertion index or resulting table exceeds grid limits.' }
    $key = if ($isRow) { 'heightMm' } else { 'widthMm' }
    $units = ConvertTo-ScopedMm $Operation[$key] "insert.$key"
    if ($units -lt 1) { throw "insert.$key must round to a positive HWPUNIT value." }
    $size = Get-ScopedOneChild $copy 'hp:sz'
    if ($size.GetAttribute('widthRelTo') -cne 'ABSOLUTE' -or $size.GetAttribute('heightRelTo') -cne 'ABSOLUTE') { throw 'Insertion requires absolute table dimensions.' }
    [long]$width = ($grid.Widths | Measure-Object -Sum).Sum
    [long]$height = ($grid.Heights | Measure-Object -Sum).Sum
    if ((Get-ScopedXmlInteger $size 'width' 1) -ne $width -or (Get-ScopedXmlInteger $size 'height' 1) -ne $height) { throw 'Table size must match the rectangular cell grid for insertion.' }
    if ($isRow) { $height += $units } else { $width += $units }
    if ($width -gt [int]::MaxValue -or $height -gt [int]::MaxValue) { throw 'Inserted table exceeds HWPUNIT dimensions.' }
    $size.SetAttribute('width',[string]$width); $size.SetAttribute('height',[string]$height)
    # Original cells retain content and metadata; only shifted addresses change.
    foreach ($cell in $grid.Cells) {
        $coordinate = if ($isRow) { $cell.Row } else { $cell.Column }
        if ($coordinate -ge $index) {
            $name = if ($isRow) { 'rowAddr' } else { 'colAddr' }
            (Get-ScopedOneChild $cell.Node 'hp:cellAddr').SetAttribute($name,[string]($coordinate+1))
        }
    }
    $templateIndex = [Math]::Max(0,$index-1)
    if ($isRow) { $newRow = $copy.OwnerDocument.CreateElement('hp','tr',$script:ScopedHp) }
    for ($track=0; $track -lt $tracks.Count; $track++) {
        $templateKey = if ($isRow) { "$templateIndex,$track" } else { "$track,$templateIndex" }
        $cell = New-ScopedEmptyCell $grid.Occupancy[$templateKey].Node $contents[$templateKey] $Package $Allocation
        $addr = Get-ScopedOneChild $cell 'hp:cellAddr'
        $addr.SetAttribute('rowAddr',[string]$(if ($isRow) {$index} else {$track}))
        $addr.SetAttribute('colAddr',[string]$(if ($isRow) {$track} else {$index}))
        $cellSize = Get-ScopedOneChild $cell 'hp:cellSz'
        $cellSize.SetAttribute('width',[string]$(if ($isRow) {$tracks[$track]} else {$units}))
        $cellSize.SetAttribute('height',[string]$(if ($isRow) {$units} else {$tracks[$track]}))
        if ($isRow) { $null = $newRow.AppendChild($cell) }
        elseif ($index -eq $count) { $null = $grid.Rows[$track].AppendChild($cell) }
        else { $null = $grid.Rows[$track].InsertBefore($cell,$grid.Occupancy["$track,$index"].Node) }
    }
    if ($isRow) {
        if ($index -eq $count) { $null = $copy.AppendChild($newRow) }
        else { $null = $copy.InsertBefore($newRow,$grid.Rows[$index]) }
        $copy.SetAttribute('rowCnt',[string]($count+1))
    } else { $copy.SetAttribute('colCnt',[string]($count+1)) }
    foreach ($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',$ns))) { $null = $cache.ParentNode.RemoveChild($cache) }
    $null = Get-ScopedTableGrid $copy
    return ,$copy
}

function Get-ScopedRasterMediaType {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 33 -and [BitConverter]::ToString($Bytes,0,8) -ceq '89-50-4E-47-0D-0A-1A-0A' -and
        [Text.Encoding]::ASCII.GetString($Bytes,12,4) -ceq 'IHDR') { return 'image/png' }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 216 -and $Bytes[2] -eq 255 -and
        $Bytes[$Bytes.Length-2] -eq 255 -and $Bytes[$Bytes.Length-1] -eq 217) { return 'image/jpeg' }
    if ($Bytes.Length -ge 14 -and [Text.Encoding]::ASCII.GetString($Bytes,0,6) -cin @('GIF87a','GIF89a')) { return 'image/gif' }
    if ($Bytes.Length -ge 54 -and $Bytes[0] -eq 66 -and $Bytes[1] -eq 77) { return 'image/bmp' }
    throw 'Replacement requires a supported PNG/JPEG/GIF/BMP signature; decoding/rendering is not performed.'
}

function New-ScopedImageBytes {
    param([Xml.XmlElement]$Picture, $Operation, $Package)
    if ($Picture.HasAttribute('lock') -and $Picture.GetAttribute('lock') -cnotin @('0','false')) { throw 'Locked picture cannot be replaced.' }
    $image = Get-ScopedOneChild $Picture 'hc:img'
    $id = $image.GetAttribute('binaryItemIDRef')
    if ([string]::IsNullOrEmpty($id)) { throw 'Picture has no embedded image reference.' }
    $hpf = $Package.Xml['Contents/content.hpf']
    $items = @($hpf.SelectNodes('/opf:package/opf:manifest/opf:item',(New-ScopedNamespaces $hpf)) | Where-Object { $_.GetAttribute('id') -ceq $id })
    if ($items.Count -ne 1) { throw 'Picture must reference exactly one manifest item.' }
    $part = $items[0].GetAttribute('href')
    if (-not $part.StartsWith('BinData/',[StringComparison]::Ordinal) -or -not $Package.Parts.ContainsKey($part)) { throw 'Picture must reference a local BinData part.' }
    $aliases = @($hpf.SelectNodes('/opf:package/opf:manifest/opf:item',(New-ScopedNamespaces $hpf)) | Where-Object { $_.GetAttribute('href') -ceq $part })
    if ($aliases.Count -ne 1) { throw 'Shared image manifest aliases are not supported.' }
    $references = 0
    foreach ($xml in $Package.Xml.Values) {
        foreach ($attribute in $xml.SelectNodes('//@*[local-name()="binaryItemIDRef"]')) {
            if ($attribute.Value -ceq $id) { $references++ }
        }
    }
    if ($references -ne 1) { throw 'Shared image references are not replaced implicitly.' }
    $expected = $Operation['expectedSha256']
    if ($expected -isnot [string] -or $expected -notmatch '^[a-fA-F0-9]{64}$' -or
        $expected -ine (Get-ScopedBytesHash $Package.Parts[$part].Bytes).Replace('-','')) { throw 'replace-image.expectedSha256 does not match the original image bytes.' }
    $path = $Operation['path']
    if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or $path -match '^[\\/]{2}|^[a-zA-Z]+://') { throw 'replace-image.path must be a local filesystem path.' }
    $localPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    if ($localPath.StartsWith('\\') -or $localPath.Substring([IO.Path]::GetPathRoot($localPath).Length).Contains(':')) { throw 'Network paths and alternate data streams are not supported.' }
    $stream = [IO.File]::Open($localPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 64MB) { throw 'Replacement image must contain 1 byte to 64 MiB.' }
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
    $mediaType = Get-ScopedRasterMediaType $bytes
    if ($mediaType -cne $items[0].GetAttribute('media-type') -or $mediaType -cne (Get-ScopedRasterMediaType $Package.Parts[$part].Bytes)) { throw 'Replacement image format must match the original manifest media-type.' }
    return @{ Part=$part; Bytes=$bytes }
}

function Get-ScopedNodeXPath {
    param([Xml.XmlElement]$Node)
    $segments = [Collections.Generic.List[string]]::new()
    $current = $Node
    while ($current.ParentNode -is [Xml.XmlElement]) {
        $index = 1
        $sibling = $current.PreviousSibling
        while ($null -ne $sibling) {
            if ($sibling.NodeType -eq [Xml.XmlNodeType]::Element) { $index++ }
            $sibling = $sibling.PreviousSibling
        }
        $segments.Insert(0,"/*[$index]")
        $current = $current.ParentNode
    }
    return '/*[1]' + ($segments -join '')
}

function Assert-ScopedEditContext {
    param([Xml.XmlElement]$Node)
    $current = $Node
    while ($current.ParentNode -is [Xml.XmlElement]) {
        if ($current.NamespaceURI -cne $script:ScopedHp -or
            $current.LocalName -cnotin @('t','p','run','tbl','tr','tc','subList','ctrl','header','footer','pic','rect','ellipse','line')) {
            throw 'Address crosses an unsupported or unknown container.'
        }
        if ($current.LocalName -cin @('tc','tbl')) {
            foreach ($flag in @('protect','lock','editable')) {
                if ($current.HasAttribute($flag) -and $current.GetAttribute($flag) -cnotin @('0','false')) {
                    throw "Protected or special address ancestor: $flag."
                }
            }
        }
        $current = $current.ParentNode
    }
}

function Resolve-ScopedAddress {
    param($Value, $Package, [string]$Kind)
    $address = ConvertTo-ScopedMap $Value 'address'
    Assert-ScopedKeys $address @('version','sourceSha256','part','path','kind') 'address'
    if ($address['version'] -isnot [string] -or $address['version'] -cne '1.0') { throw 'Unsupported address.version.' }
    if ($address['sourceSha256'] -isnot [string] -or $address['sourceSha256'] -notmatch '^[a-fA-F0-9]{64}$' -or
        $address['sourceSha256'] -ine $Package.SourceSha256) { throw 'address.sourceSha256 does not match the inspected original.' }
    if ($address['part'] -isnot [string] -or -not $Package.Sections.Contains($address['part'])) { throw 'address.part is not a package section.' }
    if ($address['kind'] -isnot [string] -or $address['kind'] -cne $Kind) { throw "address.kind must be $Kind for this operation." }
    $path = $address['path']
    if ($path -isnot [Collections.IList] -or $path.Count -lt 1 -or $path.Count -gt 64) { throw 'address.path must contain 1 to 64 element-child indexes.' }
    $node = $Package.Xml[$address['part']].DocumentElement
    foreach ($position in $path) {
        $index = Get-ScopedIndex $position 'address.path'
        $children = $node.SelectNodes('*')
        if ($index -ge $children.Count) { throw 'address.path target is absent.' }
        $node = $children[$index]
    }
    if ($node.NamespaceURI -cne $script:ScopedHp -or $node.LocalName -cne $Kind) { throw 'address.path resolves to the wrong node kind.' }
    Assert-ScopedEditContext $node
    return @{ Part=$address['part']; Node=$node }
}

. (Join-Path $PSScriptRoot 'HwpHwpxTableEdit.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxAdvancedTable.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxTableCalculate.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxDocumentEdit.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxTextRangeEdit.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxObjectEdit.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxSectionSettings.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxParagraphTabs.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxNoteSettings.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxHeaderFooterEdit.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxParagraphMove.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxNamedStyle.ps1')
. (Join-Path $PSScriptRoot 'HwpHwpxCellDiagonal.ps1')

function Get-ScopedSteps {
    param([AllowNull()][object]$Plan, $Package)
    $map = ConvertTo-ScopedMap $Plan 'plan'
    Assert-ScopedKeys $map @('version','operations') 'plan' @('sourceSha256')
    if ($map.ContainsKey('sourceSha256')) {
        if ($map['sourceSha256'] -isnot [string] -or $map['sourceSha256'] -notmatch '^[0-9a-fA-F]{64}$') { throw 'plan.sourceSha256 must be a SHA-256 hex string.' }
        if ($map['sourceSha256'] -ine $Package.SourceSha256) { throw 'plan.sourceSha256 does not match the inspected original.' }
    }
    if ($map['version'] -isnot [string] -or $map['version'] -cne '2.0') { throw 'plan.version must be "2.0".' }
    if ($map['operations'] -isnot [Collections.IList] -or $map['operations'].Count -lt 1 -or $map['operations'].Count -gt 1000) {
        throw 'plan.operations must be an array of 1 to 1000 operations.'
    }
    $steps = [Collections.Generic.List[object]]::new()
    $writes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $styles = @{}
    $allocation = @{}
    [long]$replacementCharacters = 0
    [long]$replacementImageBytes = 0
    for ($i=0; $i -lt $map['operations'].Count; $i++) {
        $location = "plan.operations[$i]"
        $op = ConvertTo-ScopedMap $map['operations'][$i] $location
        if (-not $op.ContainsKey('type') -or $op['type'] -isnot [string]) { throw "$location.type is required." }
        $type = $op['type']
        $keys = switch -CaseSensitive ($type) {
            'set-page' { @('type','sectionIndex') }
            'set-section-settings' { @('type','sectionIndex','settings') }
            'set-paragraph-tabs' { @('type','address','tabs') }
            'set-note-settings' { @('type','sectionIndex','kind','settings') }
            'set-header-footer' { @('type','sectionIndex','kind','applyTo','expectedText','paragraphs') }
            'replace-paragraph-text' { @('type','address','expectedText','find','replacement') }
            'set-object-format' { @('type','address') }
            'set-columns' { @('type','sectionIndex','count','gapMm') }
            'set-page-border' { @('type','sectionIndex','applyTo','style') }
            'set-paragraph-content' { @('type','address','expectedText','paragraph') }
            'set-paragraph-breaks' { @('type','address') }
            'insert-paragraphs' { @('type','address','placement','paragraphs') }
            'delete-paragraph' { @('type','address','expectedText') }
            'move-paragraph' { @('type','address','targetAddress','placement','expectedText') }
            'apply-named-style' { @('type','address','styleId') }
            'set-cell-diagonal' { @('type','address','direction') }
            'sort-table-rows' { @('type','address','startRow','endRow','column','dataType','direction') }
            'replace-run-text' { @('type','sectionIndex','paragraphIndex','runIndex','text','expectedText') }
            'set-run-style' { @('type','sectionIndex','paragraphIndex','runIndex','charPrIDRef') }
            'set-paragraph-style' { @('type','sectionIndex','paragraphIndex','paraPrIDRef') }
            'set-run-format' { @('type','sectionIndex','paragraphIndex','runIndex','textStyle') }
            'set-paragraph-format' { @('type','sectionIndex','paragraphIndex','paragraphStyle') }
            'merge-cells' { @('type','sectionIndex','tableIndex','row','column','rowSpan','columnSpan','contentOrder','expectedTexts') }
            'split-cell' { @('type','sectionIndex','tableIndex','row','column','expectedText') }
            'set-table-cell' { @('type','sectionIndex','tableIndex','row','column','text','expectedText') }
            'set-cell-content' { @('type','sectionIndex','tableIndex','row','column','paragraphs','expectedText') }
            'set-cell-format' { @('type','sectionIndex','tableIndex','row','column') }
            'set-table-format' { @('type','sectionIndex','tableIndex') }
            'calculate-table' { @('type','sectionIndex','tableIndex','calculations') }
            'insert-cell-image' { @('type','sectionIndex','tableIndex','row','column','path','expectedText','placement') }
            'insert-cell-table' { @('type','sectionIndex','tableIndex','row','column','table','expectedText','placement') }
            'insert-table-row' { @('type','sectionIndex','tableIndex','index','heightMm') }
            'insert-table-column' { @('type','sectionIndex','tableIndex','index','widthMm') }
            'delete-table-row' { @('type','sectionIndex','tableIndex','index','expectedTexts') }
            'delete-table-column' { @('type','sectionIndex','tableIndex','index','expectedTexts') }
            'replace-image' { @('type','address','path','expectedSha256') }
            default { throw "Unsupported operation: $location.type=$type" }
        }
        $optional = switch -CaseSensitive ($type) {
            'set-page' { @('orientation','margins','paperWidthMm','paperHeightMm','page') }
            'replace-paragraph-text' { @('replaceAll') }
            'set-paragraph-tabs' { @('autoTabLeft','autoTabRight') }
            'apply-named-style' { @('expectedText','textStyle','paragraphStyle','name','englishName') }
            'set-cell-diagonal' { @('line') }
            'set-object-format' { @('placement','textWrap','altText','rotation','flipHorizontal','flipVertical','widthMm','heightMm','crop') }
            'set-columns' { @('widthsMm') }
            'set-page-border' { @('offsetMm') }
            'set-paragraph-breaks' { @('pageBreak','columnBreak') }
            'set-cell-format' { @('verticalAlignment','textDirection','lineWrap','style','textStyle','paragraphStyle') }
            'set-table-format' { @('columnWidthsMm','rowHeightsMm','repeatHeader','headerRows','pageBreak','alignment','verticalAlignment','textDirection','lineWrap','style','textStyle','paragraphStyle') }
            'insert-cell-image' { @('widthMm','heightMm','altText') }
            {$_ -cin @('insert-table-row','insert-table-column','delete-table-row','delete-table-column')} { @('columnWidthsMm','rowHeightsMm') }
            default { @() }
        }
        if ($type -cin @('set-cell-format','set-table-format') -and @($op.Keys|Where-Object {$_ -cin $optional}).Count -eq 0) {throw 'Format operation needs at least one explicit property.'}
        $addressed = $op.ContainsKey('address')
        if ($addressed) {
            if ($type -cin @('set-page','set-columns','set-page-border','set-section-settings','set-note-settings','set-header-footer')) { throw "$type requires an explicit sectionIndex." }
            $keys = @($keys | Where-Object { $_ -cnotin @('sectionIndex','paragraphIndex','runIndex','tableIndex','address') }) + @('address')
            if ($type -cin @('set-table-cell','set-cell-content','set-cell-format','insert-cell-image','insert-cell-table')) { $keys = @($keys | Where-Object { $_ -cnotin @('row','column') }) }
        }
        Assert-ScopedKeys $op $keys $location $optional
        $addressTarget = $null
        if ($addressed) {
            $kind = if ($type -cin @('merge-cells','split-cell','insert-table-row','insert-table-column','delete-table-row','delete-table-column','set-table-format','calculate-table','sort-table-rows')) {'tbl'}
                elseif ($type -ceq 'replace-image') {'pic'}
                elseif ($type -ceq 'set-object-format') {
                    $objectAddress=ConvertTo-ScopedMap $op['address'] 'address'
                    if(-not $objectAddress.ContainsKey('kind') -or $objectAddress['kind'] -isnot [string] -or $objectAddress['kind'] -cnotin @('pic','rect','ellipse','line')){throw 'Object address must select pic, rect, ellipse or line.'}
                    $objectAddress['kind']
                }
                elseif ($type -cin @('set-table-cell','set-cell-content','set-cell-format','insert-cell-image','insert-cell-table','set-cell-diagonal')) {'tc'}
                elseif ($type -cin @('set-paragraph-style','set-paragraph-format','set-paragraph-content','set-paragraph-breaks','insert-paragraphs','delete-paragraph','move-paragraph','replace-paragraph-text','set-paragraph-tabs','apply-named-style')) {'p'} else {'run'}
            $resolved = Resolve-ScopedAddress $op['address'] $Package $kind
            $part = $resolved.Part; $addressTarget = $resolved.Node
        } else {
            $index = Get-ScopedIndex $op['sectionIndex'] "$location.sectionIndex"
            if ($index -ge $Package.Sections.Count) { throw "$location.sectionIndex is absent." }
            $part = $Package.Sections[$index]
        }
        $xml = $Package.Xml[$part]
        $ns = New-ScopedNamespaces $xml
        $paragraph = $null
        $attribute = ''
        $replacement = $null
        $resource = $null
        $binary = $null
        if ($type -ceq 'set-cell-diagonal') {
            $target=$addressTarget;$value=''
            $replacement=New-ScopedCellDiagonal $target $op $Package $allocation
        } elseif ($type -ceq 'apply-named-style') {
            $target=$addressTarget;$paragraph=$target;$value=''
            $replacement=New-ScopedNamedStyle $target $op $Package $allocation
        } elseif ($type -ceq 'set-paragraph-tabs') {
            $target=$addressTarget;$paragraph=$target;$attribute='paraPrIDRef'
            $resource=New-ScopedParagraphTabs $target $op $Package $allocation;$value=$resource.Id
        } elseif ($type -ceq 'set-note-settings') {
            $nodes=$xml.SelectNodes('/hs:sec/hp:p/hp:run/hp:secPr',$ns)
            if($nodes.Count -ne 1 -or $xml.SelectNodes('//hp:secPr',$ns).Count -ne 1){throw 'Note settings require one canonical section-property definition.'}
            $target=$nodes[0];Assert-ScopedEditContext $target.ParentNode
            $replacement=New-ScopedNoteSettings $target $op $Package $allocation;$value=''
        } elseif ($type -cin @('set-section-settings','set-header-footer')) {
            $nodes=$xml.SelectNodes('/hs:sec/hp:p/hp:run[hp:secPr]',$ns)
            if($nodes.Count -ne 1 -or $xml.SelectNodes('//hp:secPr',$ns).Count -ne 1){throw 'Section settings require one canonical section-property run.'}
            $target=$nodes[0];Assert-ScopedEditContext $target
            $replacement=if($type -ceq 'set-header-footer'){New-ScopedHeaderFooter $target $op $Package $allocation}else{New-ScopedSectionSettings $target $op $Package $allocation};$value=''
        } elseif ($type -ceq 'replace-paragraph-text') {
            $target=$addressTarget;$paragraph=$target;$value=''
            $replacement=New-ScopedTextRangeReplacement $target $op $Package $allocation
        } elseif ($type -ceq 'set-object-format') {
            $target=$addressTarget;$value=''
            $replacement=New-ScopedObjectFormat $target $op $Package $allocation
        } elseif ($type -ceq 'move-paragraph') {
            $destination=Resolve-ScopedAddress $op['targetAddress'] $Package 'p'
            if($destination.Part -cne $part){throw 'Paragraph move cannot cross section parts.'}
            $target=$addressTarget.ParentNode;$replacement=New-ScopedParagraphMove $addressTarget $destination.Node $op $Package $allocation;$value=''
        } elseif ($type -cin @('insert-paragraphs','delete-paragraph')) {
            $target=$addressTarget.ParentNode;$replacement=New-ScopedParagraphStructure $addressTarget $op $Package $allocation;$value=''
        } elseif ($type -cin @('set-paragraph-content','set-paragraph-breaks')) {
            $target=$addressTarget;$paragraph=$target;$value=''
            $replacement=if($type -ceq 'set-paragraph-content'){New-ScopedParagraphContent $target $op $Package $allocation}else{New-ScopedParagraphBreaks $target $op}
        } elseif ($type -cin @('set-columns','set-page-border')) {
            if($type -ceq 'set-columns') {
                $nodes=$xml.SelectNodes('/hs:sec/hp:p/hp:run/hp:ctrl/hp:colPr',$ns)
                $allColumns=$xml.SelectNodes('//hp:colPr',$ns).Count
                if($allColumns -gt 1 -or $allColumns -ne $nodes.Count){throw 'Noncanonical or multiple section column transitions require separate targeted editing.'}
                if($nodes.Count -eq 1){$target=$nodes[0]}else{$runs=$xml.SelectNodes('/hs:sec/hp:p/hp:run[hp:secPr]',$ns);if($runs.Count -ne 1){throw 'One canonical section-property run is required.'};$target=$runs[0]}
                $replacement=New-ScopedColumns $target $op
            } else {
                $nodes=$xml.SelectNodes('/hs:sec/hp:p/hp:run/hp:secPr',$ns);if($nodes.Count -ne 1){throw 'One direct section-property definition is required.'};$target=$nodes[0]
                $replacement=New-ScopedPageBorder $target $op $Package $allocation
            }
            # Section controls are explicitly selected above, never accepted as text addresses.
            Assert-ScopedEditContext $target.ParentNode;$value=''
        } elseif ($type -ceq 'replace-image') {
            $target = $addressTarget
            $binary = New-ScopedImageBytes $target $op $Package
            $replacementImageBytes += $binary.Bytes.Length
            if ($replacementImageBytes -gt 256MB) { throw 'Cumulative replacement image bytes exceed 256 MiB.' }
            $value = ''
            if (-not $writes.Add('binary|'+$binary.Part)) { throw 'Duplicate image byte replacement.' }
        } elseif ($type -ceq 'set-page') {
            $xpath = '/hs:sec/hp:p/hp:run/hp:secPr/hp:pagePr'
            $nodes = $xml.SelectNodes($xpath,$ns)
            if ($nodes.Count -ne 1) { throw "$location requires exactly one direct section pagePr." }
            $target = $nodes[0]
            $replacement = New-ScopedPageReplacement $target $op $location
            $value = ''
        } elseif ($type -cin @('merge-cells','split-cell','insert-table-row','insert-table-column','delete-table-row','delete-table-column','set-table-format','calculate-table','sort-table-rows')) {
            if ($addressed) { $target = $addressTarget }
            else {
                $tableIndex = Get-ScopedIndex $op['tableIndex'] "$location.tableIndex"
                $tables = $xml.SelectNodes('/hs:sec/hp:tbl | /hs:sec/hp:p/hp:run/hp:tbl',$ns)
                if ($tableIndex -ge $tables.Count) { throw "$location.tableIndex is absent (nested tables are not addressed)." }
                $target = $tables[$tableIndex]
            }
            Assert-ScopedEditContext $target
            if ($target.ParentNode.LocalName -ceq 'run') { $paragraph = $target.ParentNode.ParentNode }
            if ($type -ceq 'merge-cells') { $replacement = New-ScopedMergedTable $target $op $Package.Xml['Contents/header.xml'] }
            elseif ($type -ceq 'split-cell') { $replacement = New-ScopedSplitTable $target $op $Package $allocation }
            elseif ($type -ceq 'set-table-format') { $replacement = New-ScopedFormattedTable $target $op $Package $allocation }
            elseif ($type -ceq 'calculate-table') { $replacement = New-ScopedCalculatedTable $target $op $Package $allocation }
            elseif ($type -ceq 'sort-table-rows') { $replacement = New-ScopedSortedTable $target $op $Package }
            elseif (@((Get-ScopedTableGrid $target).Cells|Where-Object {$_.RowSpan -gt 1 -or $_.ColumnSpan -gt 1}).Count -gt 0 -or
                $op.ContainsKey('columnWidthsMm') -or $op.ContainsKey('rowHeightsMm') -or $null -ne $target.SelectSingleNode('ancestor::hp:tc',$ns)) {
                $replacement=New-ScopedMergedTrackTable $target $op $Package $allocation
            }
            elseif ($type -cin @('delete-table-row','delete-table-column')) { $replacement = New-ScopedDeletedTable $target $op $Package }
            else { $replacement = New-ScopedInsertedTable $target $op $Package $allocation }
            $value = ''
        } elseif ($type -cin @('set-cell-content','set-cell-format','insert-cell-image','insert-cell-table')) {
            if ($addressed) { $target=$addressTarget }
            else {
                $tables=$xml.SelectNodes('/hs:sec/hp:tbl | /hs:sec/hp:p/hp:run/hp:tbl',$ns)
                $tableIndex=Get-ScopedIndex $op['tableIndex'] "$location.tableIndex"
                if ($tableIndex -ge $tables.Count) {throw 'Table is absent.'}
                $grid=Get-ScopedTableGrid $tables[$tableIndex]
                $row=Get-ScopedIndex $op['row'] "$location.row"; $column=Get-ScopedIndex $op['column'] "$location.column"
                $cell=$grid.Occupancy["$row,$column"]
                if ($null -eq $cell -or $cell.Row -ne $row -or $cell.Column -ne $column) {throw 'Select a real cell anchor.'}
                $target=$cell.Node
            }
            Assert-ScopedEditContext $target
            if ($type -ceq 'set-cell-content') { $replacement=New-ScopedCellContentReplacement $target $op $Package $allocation }
            elseif ($type -cin @('insert-cell-image','insert-cell-table')) { $replacement=Add-ScopedCellObject $target $op $Package $allocation }
            else { $replacement=$target.CloneNode($true); Set-ScopedCellFormat $replacement $op $Package $allocation }
            $value=''
        } else {
            if ($type -ceq 'set-table-cell') {
                if ($addressed) { $cell = $addressTarget }
                else {
                    $tables = $xml.SelectNodes('/hs:sec/hp:tbl | /hs:sec/hp:p/hp:run/hp:tbl',$ns)
                    $tableIndex = Get-ScopedIndex $op['tableIndex'] "$location.tableIndex"
                    if ($tableIndex -ge $tables.Count) { throw "$location.tableIndex is absent." }
                    $grid = Get-ScopedTableGrid $tables[$tableIndex]
                    $row = Get-ScopedIndex $op['row'] "$location.row"
                    $column = Get-ScopedIndex $op['column'] "$location.column"
                    $record = $grid.Occupancy["$row,$column"]
                    if ($null -eq $record -or $record.Row -ne $row -or $record.Column -ne $column) { throw 'Cell address must select a real anchor.' }
                    $cell = $record.Node
                }
                Assert-ScopedEditContext $cell
                $content = Get-ScopedCellContent $cell (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'charPr') (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'paraPr')
                if ($content.Paragraphs.Count -ne 1 -or $content.Paragraphs[0].SelectNodes('hp:run',$ns).Count -ne 1) { throw 'set-table-cell requires a single text-only paragraph/run; use inspected run addresses for richer cells.' }
                $paragraph = $content.Paragraphs[0]
                $target = $paragraph.SelectSingleNode('hp:run',$ns)
            } elseif ($addressed) {
                $target = $addressTarget
                $paragraph = if ($target.LocalName -ceq 'p') { $target } else { $target.ParentNode }
                if ($paragraph.LocalName -cne 'p' -or $paragraph.NamespaceURI -cne $script:ScopedHp) { throw 'Run must belong to a paragraph.' }
            } else {
                $paragraphIndex = Get-ScopedIndex $op['paragraphIndex'] "$location.paragraphIndex"
                $paragraphs = $xml.SelectNodes('/hs:sec/hp:p',$ns)
                if ($paragraphIndex -ge $paragraphs.Count) { throw "$location.paragraphIndex is absent." }
                $paragraph = $paragraphs[$paragraphIndex]
                $target = $paragraph
                if ($type -cnotin @('set-paragraph-style','set-paragraph-format')) {
                    $runIndex = Get-ScopedIndex $op['runIndex'] "$location.runIndex"
                    $runs = $paragraph.SelectNodes('hp:run',$ns)
                    if ($runIndex -ge $runs.Count) { throw "$location.runIndex is absent." }
                    $target = $runs[$runIndex]
                }
            }
            Assert-ScopedEditContext $target
            if ($type -cin @('replace-run-text','set-table-cell')) {
                $textElement = Get-ScopedTextElement $target $location
            } elseif ($type -cin @('set-run-style','set-run-format')) {
                $null = Get-ScopedInlineText $target
            }
            if ($type -cin @('replace-run-text','set-table-cell')) {
                foreach ($key in @('text','expectedText')) {
                    if ($op[$key] -isnot [string] -or $op[$key].Length -gt 1MB) { throw "$location.$key must be a string up to 1 MiB characters." }
                    $null = [Xml.XmlConvert]::VerifyXmlChars($op[$key])
                }
                if ($textElement.InnerText -cne $op['expectedText']) { throw "$location.expectedText does not match the original run." }
                $replacementCharacters += $op['text'].Length
                if ($replacementCharacters -gt 16MB) { throw 'Cumulative replacement text exceeds 16 MiB characters.' }
                $target = $textElement
                $value = $op['text']
            } else {
                $kind = if ($type -cin @('set-run-style','set-run-format')) { 'charPr' } else { 'paraPr' }
                $attribute = $kind + 'IDRef'
                if ($type -cin @('set-run-format','set-paragraph-format')) {
                    $styleKey = if ($kind -ceq 'charPr') {'textStyle'} else {'paragraphStyle'}
                    $resource = New-ScopedFormatResource $Package.Xml['Contents/header.xml'] $target $kind $op[$styleKey] $allocation
                    $value = $resource.Id
                } else {
                    $value = Get-ScopedStyleId $op[$attribute] "$location.$attribute"
                    if (-not $styles.ContainsKey($kind)) { $styles[$kind] = Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] $kind }
                    if (-not $styles[$kind].Contains($value)) { throw "$location.$attribute refers to an absent header resource: $value" }
                }
            }
        }
        $xpath = Get-ScopedNodeXPath $target
        if (-not $writes.Add("$part|$xpath|$attribute")) { throw "Duplicate target property: $location" }
        foreach ($previous in $steps) {
            if ($previous.Part -cne $part) { continue }
            if (($null -ne $previous.Replacement -and ($xpath.StartsWith($previous.XPath+'/') -or $xpath -ceq $previous.XPath)) -or
                ($null -ne $replacement -and ($previous.XPath.StartsWith($xpath+'/') -or $previous.XPath -ceq $xpath))) {
                throw 'Overlapping subtree replacement and edit; use separate inspect/edit passes.'
            }
        }
        $boundsChanged=$true
        if($type -cin @('set-cell-format','set-table-format')){
            $boundsChanged=@(@('columnWidthsMm','rowHeightsMm','alignment','pageBreak','textDirection','repeatHeader','headerRows')|Where-Object {$op.ContainsKey($_)}).Count -gt 0
            if($op.ContainsKey('style')){
                $tableStyle=ConvertTo-ScopedMap $op['style'] 'style'
                $boundsChanged=$boundsChanged -or $tableStyle.ContainsKey('cellPaddingMm') -or $tableStyle.ContainsKey('cellMargins')
            }
        }
        $steps.Add([pscustomobject]@{Part=$part; XPath=$xpath; Target=$target; Paragraph=$paragraph; Attribute=$attribute; Value=$value; Type=$type; Replacement=$replacement; Resource=$resource; Binary=$binary; BoundsChanged=$boundsChanged})
    }
    foreach($part in $Package.Sections) {
        if(@($steps|Where-Object {$_.Part -ceq $part -and $_.Type -ceq 'set-page'}).Count -gt 0 -and
            @($steps|Where-Object {$_.Part -ceq $part -and $_.Type -ceq 'set-columns'}).Count -gt 0){throw 'Change page dimensions and column layout in separate inspect/edit passes.'}
    }
    $Package.PreparedResources=@();$Package.NewParts=@();$Package.CalculationResults=@()
    if($allocation.ContainsKey('Resources')){$Package.PreparedResources=@($allocation.Resources.ToArray())}
    if($allocation.ContainsKey('NewParts')){$Package.NewParts=@($allocation.NewParts.ToArray())}
    if($allocation.ContainsKey('Calculations')){$Package.CalculationResults=@($allocation.Calculations.ToArray())}
    return ,$steps
}

function ConvertTo-ScopedXmlBytes {
    param([xml]$Xml)
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Encoding = [Text.UTF8Encoding]::new($false)
    $settings.Indent = $false
    # Entitize CR so an XML round trip retains the exact replacement string.
    $settings.NewLineHandling = [Xml.NewLineHandling]::Entitize
    $memory = [IO.MemoryStream]::new()
    $writer = [Xml.XmlWriter]::Create($memory,$settings)
    try { $Xml.Save($writer); $writer.Flush(); return ,$memory.ToArray() }
    finally { $writer.Dispose(); $memory.Dispose() }
}

function Get-ScopedBytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)) }
    finally { $sha.Dispose() }
}

function Invoke-HwpxScopedEdit {
    <#
    .SYNOPSIS
    Applies bounded HWPX edits in a separate, structurally verified copy.
    .DESCRIPTION
    Plan is a hashtable or JSON object with version "2.0" and operations.
    Optional sourceSha256 is a 64-digit expected original hash (case-insensitive).
    sectionIndex follows the package spine; paragraphIndex selects direct hs:sec
    hp:p children; runIndex selects direct hp:run children. Indices are zero-based.
    Inspector paragraph/index and table/index are inventory ordinals, NOT these
    legacy edit indexes. Prefer the inspector's address objects:
    {version:"1.0",sourceSha256:<hex>,part:<section ZIP entry>,path:[0,...],kind:"p"}.
    path holds zero-based element-child indexes beneath the section root (1..64
    levels); whitespace/comments are excluded. Every address requires the exact
    original file hash and binds to a part, independently of spine/inventory order.
    Address and legacy selectors cannot be mixed. Paragraph operations take a p
    address; run operations take paragraphs[].charShapeRuns[].address (kind run).
    Plain runs inside cells, nested tables, headers and footers are supported;
    unknown containers and protected cell/table ancestors are blocked.
    replace-run-text requires exact expectedText. set-run-style and
    set-paragraph-style reference existing header IDs. set-run-format/textStyle
    and set-paragraph-format/paragraphStyle clone the original resource to a new,
    unique ID without modifying other consumers. Font names are registered per
    language without embedding fonts or launching a font installer.

    textStyle additionally supports fontFamily, strikeout, superscript/subscript,
    letterSpacingPercent (-50..50), widthPercent (50..200), fontSizePt (1..1000),
    bold/italic, textColor and underline. paragraphStyle: alignment including
    DISTRIBUTE/DISTRIBUTE_SPACE, lineSpacingPercent (integer 1..1000) or
    lineSpacing {type:FIXED/AT_LEAST,valuePt:1..1000},
    leftMarginMm/rightMarginMm/marginBeforeMm/marginAfterMm (0..2000),
    indentMm (-2000..2000), keepWithNext/keepLines/widowOrphan/pageBreakBefore.
    Paragraph spacing accepts direct resources or one canonical HwpUnitChar
    case/default switch; both branches are updated. Unknown resource XML stays.

    set-page takes orientation (PORTRAIT/LANDSCAPE), paired paperWidthMm and
    paperHeightMm, and partial margins {leftMm,rightMm,topMm,bottomMm,headerMm,
    footerMm,gutterMm}. Alternatively wrap these fields in page; never mix forms.
    At least one explicit value is required. Omitted orientation is preserved;
    orientation alone never swaps stored dimensions. Millimeters are finite
    numbers in 0..2000, rounded to HWPUNIT (7200/25.4 per mm); paper dimensions
    must round positive. Effective body subtracts margins, header/footer space
    and the axis-appropriate gutter, and must remain positive.

    merge-cells/split-cell use sectionIndex/tableIndex/row/column, all zero-based.
    Tables are direct hs:sec/hp:tbl or hs:sec/hp:p/hp:run/hp:tbl, in document order;
    nested tables are excluded. Merge additionally requires rowSpan/columnSpan,
    contentOrder="row-major", and exact expectedTexts. Cell text joins paragraphs
    with LF; runs concatenate within a paragraph. Merge moves entire paragraphs
    into the anchor and keeps its cell formatting. Split takes expectedText for
    the merged anchor, retains its paragraphs, and creates empty cells with its
    cell style/margins and first paragraph/run style. Track sizes must match
    neighbors; unknown tracks use an exactly divisible equal remainder or block.
    Only complete, nonoverlapping grids (at most 4096 positions, 256 per axis),
    zero cell spacing, and known, unprotected, unlinked text-only target cells
    are supported. Unknown target cell metadata blocks; outside cells survive.
    Merge inputs must be unmerged. One structural operation per table per plan.
    merge-cells/split-cell alternatively take a tbl address instead of the section
    and table indexes, with the same row/column and expected-text arguments.

    set-table-cell takes a tc address (or sectionIndex/tableIndex/row/column),
    expectedText and text. It changes only the text in a single plain paragraph
    and single run, preserving the cell geometry and style. For richer cells use
    individual inspected run/paragraph addresses; no content is flattened.

    insert-table-row and insert-table-column take a tbl address (or sectionIndex/
    tableIndex), index (0..count, count appends) and heightMm or widthMm respectively.
    The legacy path inserts a blank track into an unmerged rectangular body table with
    absolute size equal to its cell grid. New cells inherit margins/border and
    first paragraph/run style from the preceding track (first track at index 0),
    have unique paragraph IDs and header=0. Stored extent grows by the explicit
    dimension; this does not guarantee page fit. Nested/header/footer tables,
    unknown geometry/cell metadata, controls, links and protected cells block in
    that legacy path. The merged/nested path expands or contracts crossing spans
    and relocates surviving anchors with their objects. Original track dimensions
    must be known, or explicitly supplied as columnWidthsMm/rowHeightsMm.
    A table replacement cannot overlap another edit within its subtree.

    set-cell-content replaces text-only cell paragraphs with structured text/runs
    and optional textStyle/paragraphStyle, guarded by LF-separated expectedText.
    set-cell-format changes cell verticalAlignment, style (borders/fill/margins),
    and optionally every contained text/paragraph style. Both take a tc address
    or zero-based section/table/row/column selectors. Named cell metadata remains.
    set-table-format takes a tbl address or section/table selectors and explicit
    columnWidthsMm/rowHeightsMm, alignment, repeatHeader (first row), pageBreak,
    and common cell format fields. Resizing supports complete merged grids.
    delete-table-row/column require index and exact expectedTexts and support
    rectangular grids, with per-position guards repeated for covered merge slots.
    insert-cell-image/table append or prepend real objects without removing the
    existing content. calculate-table evaluates decimal references/arithmetic and
    SUM/AVERAGE/MIN/MAX/COUNT/ROUND into verified text, not native live fields.
    All new operations preserve other parts,
    clone shared resources, invalidate affected caches, and reopen the output.

    replace-image requires a pic address, local path and expectedSha256 of the
    original BinData payload. The unshared manifest resource must match the new
    PNG/JPEG/GIF/BMP signature/media-type. Only bytes change: picture geometry,
    crops, rotation, IDs and section XML are preserved. No image decoding or pixel
    validation; at most 64 MiB/image and 256 MiB cumulative replacement bytes.

    All addresses and expected text bind to the original. Duplicate writes to
    one property (including format versus ID-reference writes) are rejected.
    One set-page operation per section per plan. No unsupported key is ignored.
    All operations, clones and table occupancy are preflighted before any output.
    Page changes
    invalidate all paragraph line caches in that section; set-object-format and
    set-section-settings do so as well. Other XML edits clear
    target and ancestor paragraph caches. Insertions also clear table paragraph
    caches; image-only replacement preserves line caches. Preview/ entries are
    removed on success.
    This is structural verification, never native rendering/page-cache validation.
    Output must be a nonexistent .hwpx in an existing local directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OutputPath,
        [Parameter(Mandatory)][AllowNull()][object]$Plan
    )
    $sourceStream = $null
    $partial = $null
    $ownsPartial = $false
    $result = $null
    try {
        foreach ($path in @($LiteralPath,$OutputPath)) {
            if ([string]::IsNullOrWhiteSpace($path) -or $path -match '^[\\/]{2}' -or $path -match '^[a-zA-Z]+://') {
                throw 'Source and output must be local filesystem paths.'
            }
        }
        $source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath)
        $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
        foreach ($path in @($source,$output)) {
            if ($path.StartsWith('\\') -or $path.Substring([IO.Path]::GetPathRoot($path).Length).Contains(':')) {
                throw 'Network paths and alternate data streams are not supported.'
            }
        }
        if ([string]::Equals($source,$output,[StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be distinct from the original.' }
        if (-not [IO.File]::Exists($source)) { throw 'Source file does not exist.' }
        if ([IO.Path]::GetExtension($output) -ine '.hwpx') { throw 'Output must have the .hwpx extension.' }
        if (Test-Path -LiteralPath $output) { throw 'Output already exists; overwriting is forbidden.' }
        $directory = [IO.Path]::GetDirectoryName($output)
        if (-not [IO.Directory]::Exists($directory)) { throw 'Output parent directory must already exist.' }

        # Keep one read handle denying writes/deletes until the copy is promoted.
        $sourceStream = [IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sourceHash = Get-HwpSha256 -LiteralPath $source
        $package = Read-ScopedPackage $sourceStream
        $package.SourceSha256 = $sourceHash
        $steps = Get-ScopedSteps $Plan $package
        # Preflight above uses only the original tree; no filesystem writes yet.
        $changed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $binaryPayloads = @{}
        foreach($part in $package.NewParts){
            if($package.Parts.Count -ge 4096){throw 'Edited package exceeds 4096 entries.'}
            Assert-ScopedEntryName $part.Name
            $package.Parts.Add($part.Name,[pscustomobject]@{Bytes=$part.Bytes;LastWriteTime=[DateTimeOffset]::UtcNow;Attributes=0})
            $package.Order.Add($part.Name);$binaryPayloads[$part.Name]=$part.Bytes;$null=$changed.Add($part.Name)
            $hpf=$package.Xml['Contents/content.hpf'];$item=$hpf.CreateElement('opf','item','http://www.idpf.org/2007/opf/')
            $item.SetAttribute('id',$part.Id);$item.SetAttribute('href',$part.Name);$item.SetAttribute('media-type',$part.MediaType);$item.SetAttribute('isEmbeded','1')
            $null=$hpf.SelectSingleNode('/opf:package/opf:manifest',(New-ScopedNamespaces $hpf)).AppendChild($item)
            $null=$changed.Add('Contents/content.hpf')
        }
        foreach ($resource in $package.PreparedResources) {
            $collection=$resource.Collection
            $null=$collection.AppendChild($resource.Node)
            $collection.SetAttribute($resource.CountAttribute,[string]$collection.SelectNodes(('hh:'+$resource.Kind),(New-ScopedNamespaces $collection.OwnerDocument)).Count)
            $resource.XPath=Get-ScopedNodeXPath $resource.Node
            $null=$changed.Add('Contents/header.xml')
        }
        foreach ($step in $steps) {
            if ($null -ne $step.Binary) {
                $binaryPayloads[$step.Binary.Part] = $step.Binary.Bytes
                $null = $changed.Add($step.Binary.Part)
                continue
            }
            if ($null -ne $step.Replacement) {
                $null = $step.Target.ParentNode.ReplaceChild($step.Replacement,$step.Target)
                $step.Target = $step.Replacement
            }
            elseif ($step.Attribute -ceq '') { $step.Target.InnerText = $step.Value }
            else { $step.Target.SetAttribute($step.Attribute,$step.Value) }
            $null = $changed.Add($step.Part)
        }
        # Validate the final tree, including a page resize paired with a table repair.
        $boundTables=[Collections.Generic.HashSet[Xml.XmlElement]]::new()
        foreach($step in $steps){
            if(-not $step.BoundsChanged){continue}
            $ns=New-ScopedNamespaces $package.Xml[$step.Part]
            $tables=@()
            if($step.Type -cin @('set-page','set-columns')){$tables=@($package.Xml[$step.Part].SelectNodes('//hp:tbl',$ns))}
            elseif($step.Type -cin @('set-table-format','insert-table-row','insert-table-column','delete-table-row','delete-table-column')){$tables=@($step.Target.SelectNodes('ancestor::hp:tbl | descendant-or-self::hp:tbl',$ns))}
            elseif($step.Type -cin @('set-cell-format','insert-cell-table')){$tables=@($step.Target.SelectNodes('ancestor::hp:tbl | .//hp:tbl',$ns))}
            elseif($step.Type -cin @('set-paragraph-format','set-paragraph-style','apply-named-style')){$tables=@($step.Target.SelectNodes('.//hp:tbl',$ns))}
            foreach($table in $tables){$null=$boundTables.Add($table)}
        }
        foreach($table in $boundTables){Assert-ScopedTableBounds $table $package}
        # Invalidate caches after all prepared subtrees are installed: a later
        # table replacement must not restore caches cleared by an earlier page edit.
        foreach ($step in $steps) {
            # Raster bytes cannot change saved placement or paragraph geometry.
            if ($null -ne $step.Binary) { continue }
            $xml = $package.Xml[$step.Part]
            $ns = New-ScopedNamespaces $xml
            # Objects, tabs and section controls may change subsequent pagination.
            $caches = if ($step.Type -cin @('set-page','set-columns','set-page-border','set-section-settings','set-note-settings','set-header-footer','set-object-format','set-paragraph-tabs','insert-paragraphs','delete-paragraph','move-paragraph','apply-named-style')) { @($xml.SelectNodes('//hp:p/hp:linesegarray',$ns)) }
                else { @($step.Target.SelectNodes('ancestor-or-self::hp:p/hp:linesegarray',$ns)) }
            foreach ($cache in $caches) { $null = $cache.ParentNode.RemoveChild($cache) }
        }
        foreach ($step in $steps) { $step.XPath = Get-ScopedNodeXPath $step.Target }
        $payloads = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $removed = @($package.Order | Where-Object { $_ -match '(?i)^Preview/' })
        [long]$payloadBytes = 0
        foreach ($name in $package.Order) {
            if ($removed -ccontains $name) { continue }
            if ($binaryPayloads.ContainsKey($name)) { $bytes = $binaryPayloads[$name] }
            elseif ($changed.Contains($name)) {
                $bytes = ConvertTo-ScopedXmlBytes $package.Xml[$name]
                if ($bytes.Length -gt 16MB) { throw "Edited XML part exceeds 16 MiB: $name" }
            }
            else { $bytes = $package.Parts[$name].Bytes }
            $payloadBytes += $bytes.Length
            if ($payloadBytes -gt 256MB) { throw 'Edited package exceeds 256 MiB.' }
            $payloads.Add($name,[byte[]]$bytes)
        }
        # Serialization and validation of every operation finished before CreateNew.
        $partial = [IO.Path]::Combine($directory,('.hwpx-scoped-' + [guid]::NewGuid().ToString('N') + '.partial.hwpx'))
        $targetStream = [IO.File]::Open($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $ownsPartial = $true
        try {
            Initialize-HwpxZipStream -Stream $targetStream
            $zip = [IO.Compression.ZipArchive]::new($targetStream,[IO.Compression.ZipArchiveMode]::Update,$true)
            try {
                # HWPX mimetype is first and uncompressed, regardless of input order.
                $mime=$zip.GetEntry('mimetype')
                $mime.LastWriteTime=$package.Parts['mimetype'].LastWriteTime
                $mime.ExternalAttributes=$package.Parts['mimetype'].Attributes
                $names = @($package.Order | Where-Object { $_ -cne 'mimetype' -and $payloads.ContainsKey($_) })
                foreach ($name in $names) {
                    $entry = $zip.CreateEntry($name,[IO.Compression.CompressionLevel]::NoCompression)
                    $entry.LastWriteTime = $package.Parts[$name].LastWriteTime
                    $entry.ExternalAttributes = $package.Parts[$name].Attributes
                    $stream = $entry.Open()
                    try { $stream.Write($payloads[$name],0,$payloads[$name].Length) }
                    finally { $stream.Dispose() }
                }
            } finally { $zip.Dispose() }
            $targetStream.Flush($true)
        } finally { $targetStream.Dispose() }
        $verifyStream = [IO.File]::Open($partial,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $verified = Read-ScopedPackage $verifyStream
            if ($verified.Parts.Count -ne $payloads.Count) { throw 'Reopened output part count differs.' }
            foreach ($name in $payloads.Keys) {
                if (-not $verified.Parts.ContainsKey($name) -or
                    (Get-ScopedBytesHash $verified.Parts[$name].Bytes) -cne (Get-ScopedBytesHash $payloads[$name])) {
                    throw "Reopened output payload mismatch: $name"
                }
            }
            foreach ($resource in $package.PreparedResources) {
                $header=$verified.Xml['Contents/header.xml']
                $resourceNode=$header.SelectSingleNode($resource.XPath)
                if ($null -eq $resourceNode -or $resourceNode.OuterXml -cne $resource.Node.OuterXml) {throw 'Reopened prepared style/font/border resource differs.'}
                $siblings=$resourceNode.ParentNode.SelectNodes(('hh:'+$resource.Kind),(New-ScopedNamespaces $header))
                if ((Get-ScopedXmlInteger $resourceNode.ParentNode $resource.CountAttribute) -ne $siblings.Count) {throw 'Reopened resource count differs.'}
            }
            foreach ($step in $steps) {
                if ($null -ne $step.Binary) { continue } # All payload bytes were compared above.
                $xml = $verified.Xml[$step.Part]
                $node = $xml.SelectSingleNode($step.XPath,(New-ScopedNamespaces $xml))
                if ($null -eq $node) { throw "Reopened output target absent: $($step.Part)" }
                if ($null -ne $step.Resource) {
                    $header = $verified.Xml['Contents/header.xml']
                    $ids = Get-ScopedStyleIds $header $step.Resource.Kind
                    if (-not $ids.Contains($step.Resource.Id)) { throw 'Cloned style reference is absent after reopening.' }
                    $resourcePath = '/hh:head/hh:refList/*/hh:{0}[@id="{1}"]' -f $step.Resource.Kind,$step.Resource.Id
                    $resourceNode = $header.SelectSingleNode($resourcePath,(New-ScopedNamespaces $header))
                    if ($resourceNode.OuterXml -cne $step.Resource.Node.OuterXml) { throw 'Reopened cloned style resource differs.' }
                }
                if ($null -ne $step.Replacement) {
                    if ($node.OuterXml -cne $step.Replacement.OuterXml) { throw "Reopened output subtree mismatch: $($step.Part)" }
                } else {
                    $actual = if ($step.Attribute -ceq '') { $node.InnerText } else { $node.GetAttribute($step.Attribute) }
                    if ($actual -cne $step.Value) { throw "Reopened output value mismatch: $($step.Part)" }
                }
            }
            $outputHash = Get-HwpSha256 -LiteralPath $partial
            if ((Get-HwpSha256 -LiteralPath $source) -cne $sourceHash) { throw 'Original SHA-256 changed; promotion blocked.' }
        } finally { $verifyStream.Dispose() }
        # File.Move never replaces a competing destination; cleanup owns only partial.
        [IO.File]::Move($partial,$output)
        $ownsPartial = $false
        $changedParts = @($package.Order | Where-Object { $changed.Contains($_) -or $removed -ccontains $_ })
        $result = New-HwpResult -Status PASS_WITH_WARNINGS -Command 'hwpx-scoped-edit' -Data ([ordered]@{
            SourcePath=$source; OutputPath=$output; SourceSha256=$sourceHash; OutputSha256=$outputHash
            ChangedParts=$changedParts; RemovedParts=$removed; NativeLayoutVerified=$false
            CalculationResults=@($package.CalculationResults)
        }) -Warnings @('Native rendering/layout and page cache are not verified. Affected paragraph line caches and Preview/ entries were removed; repagination requires a renderer.')
    } catch {
        $result = New-HwpResult -Status BLOCKED -Command 'hwpx-scoped-edit' -Errors @($_.Exception.Message)
    } finally {
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        if ($ownsPartial) {
            try { [IO.File]::Delete($partial) }
            catch { if ($null -ne $result) { $result.Warnings += "Could not remove owned partial: $partial" } }
        }
    }
    return $result
}

Export-ModuleMember -Function Invoke-HwpxScopedEdit
