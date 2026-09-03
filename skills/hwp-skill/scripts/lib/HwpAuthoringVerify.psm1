Set-StrictMode -Version Latest

# Deliberately independent of the plan normalizer, writer, styles and inspector.
$script:HavNs = @{
    hh='http://www.hancom.co.kr/hwpml/2011/head'
    hp='http://www.hancom.co.kr/hwpml/2011/paragraph'
    hp10='http://www.hancom.co.kr/hwpml/2016/paragraph'
    hs='http://www.hancom.co.kr/hwpml/2011/section'
    hc='http://www.hancom.co.kr/hwpml/2011/core'
    opf='http://www.idpf.org/2007/opf/'
}

function Get-HavValue {
    param([AllowNull()][object]$Object, [string]$Name, [AllowNull()][object]$Default=$null)
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Assert-Hav {
    param([object]$State, [bool]$Condition, [string]$Message)
    $State.Checks++
    if (-not $Condition) {
        $State.Errors.Add($Message)
        if ($State.Errors.Count -ge 128) { throw 'Contract error limit reached (128).' }
    }
    if ($State.Checks -gt 1000000) { throw 'Contract check limit exceeded.' }
}

function Get-HavUnit {
    param([double]$Mm)
    if ([double]::IsNaN($Mm) -or [double]::IsInfinity($Mm) -or $Mm -lt 0 -or $Mm -gt 100000) {
        throw 'Invalid normalized plan millimeter value.'
    }
    return [long][Math]::Round($Mm * 283.4645669)
}

function Get-HavId {
    param([string]$Value)
    [long]$id=0
    if ($Value -cnotmatch '^\d+$' -or -not [long]::TryParse($Value,[ref]$id) -or $id -gt 4294967295) {
        throw "Invalid resource/field ID '$Value'."
    }
    return $id.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Assert-HavNumber {
    param([object]$State, [AllowNull()][Xml.XmlElement]$Node, [string]$Attribute,
        [long]$Expected, [string]$Context, [switch]$Minimum)
    $value = if ($null -eq $Node) { '' } else { $Node.GetAttribute($Attribute) }
    [long]$number=0
    $valid=$value -cmatch '^\d+$' -and [long]::TryParse($value,[ref]$number)
    $matches=if ($Minimum) { $number -ge $Expected } else { $number -eq $Expected }
    $relation=if ($Minimum) {'at least'} else {'exactly'}
    Assert-Hav $State ($valid -and $matches) "$Context @$Attribute expected $relation $Expected; found '$value'."
}

function Assert-HavText {
    param([object]$State, [AllowNull()][Xml.XmlElement]$Node, [string]$Attribute,
        [string]$Expected, [string]$Context)
    $value=if ($null -eq $Node) {''} else {$Node.GetAttribute($Attribute)}
    Assert-Hav $State ($value -ceq $Expected) "$Context @$Attribute expected '$Expected'; found '$value'."
}

function Test-HavPackagePath {
    param([string]$Name)
    # HWPX manifest hrefs are package-root paths, never filesystem paths or URLs.
    return ($Name.Length -gt 0 -and $Name.Length -le 1024 -and
        $Name -cnotmatch '(^/|\\|:|[?#%\x00-\x1f]|(^|/)\.{1,2}(/|$)|//)')
}

function Read-HavBytes {
    param([IO.Stream]$Stream, [long]$Limit)
    $memory=[IO.MemoryStream]::new()
    try {
        $buffer=New-Object byte[] 65536
        while (($read=$Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if ($memory.Length+$read -gt $Limit) { throw 'Expanded entry/asset byte limit exceeded.' }
            $memory.Write($buffer,0,$read)
        }
        return ,$memory.ToArray()
    } finally { $memory.Dispose() }
}

function Read-HavXml {
    param([object]$State, [object]$Entries, [string]$Name, [string]$RootName, [string]$Prefix)
    if (-not $Entries.ContainsKey($Name)) { throw "Missing package XML entry: $Name" }
    $entry=$Entries[$Name]
    if ($entry.Length -gt 16MB) { throw "XML byte limit exceeded: $Name (16 MiB)." }
    $stream=$entry.Open()
    try { $bytes=Read-HavBytes $stream 16MB } finally { $stream.Dispose() }
    $settings=[Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver=$null
    $settings.MaxCharactersInDocument=16MB
    $settings.MaxCharactersFromEntities=1024
    $memory=[IO.MemoryStream]::new($bytes,$false)
    $reader=$null
    try {
        # Bound nesting and cumulative node count before constructing the DOM.
        $reader=[Xml.XmlReader]::Create($memory,$settings)
        while ($reader.Read()) {
            $State.XmlNodes++
            if ($reader.Depth -gt 128 -or $State.XmlNodes -gt 500000) { throw 'XML depth/node limit exceeded.' }
        }
        $reader.Dispose(); $reader=$null; $memory.Position=0
        $reader=[Xml.XmlReader]::Create($memory,$settings)
        $doc=[Xml.XmlDocument]::new(); $doc.XmlResolver=$null
        $doc.Load($reader)
        Assert-Hav $State ($doc.DocumentElement.LocalName -ceq $RootName -and $doc.DocumentElement.NamespaceURI -ceq $script:HavNs[$Prefix]) "$Name root/namespace does not match $Prefix`:$RootName."
        $ns=[Xml.XmlNamespaceManager]::new($doc.NameTable)
        foreach ($key in $script:HavNs.Keys) { $ns.AddNamespace($key,$script:HavNs[$key]) }
        return [pscustomobject]@{Doc=$doc;Ns=$ns;Name=$Name}
    } finally { if ($null -ne $reader) {$reader.Dispose()}; $memory.Dispose() }
}

function Get-HavResources {
    param([object]$State, [object]$Xml)
    $sets=@{}
    $collections=@{charPr='charProperties';paraPr='paraProperties';borderFill='borderFills';style='styles';tabPr='tabProperties';numbering='numberings';bullet='bullets'}
    foreach ($kind in $collections.Keys) {
        $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($node in $Xml.Doc.SelectNodes('/hh:head/hh:refList/hh:'+$collections[$kind]+'/hh:'+$kind,$Xml.Ns)) {
            $id=Get-HavId $node.GetAttribute('id')
            Assert-Hav $State ($set.Add($id)) "header duplicate $kind ID '$id'."
        }
        $sets[$kind]=$set
    }
    $fonts=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($face in $Xml.Doc.SelectNodes('/hh:head/hh:refList/hh:fontfaces/hh:fontface',$Xml.Ns)) {
        foreach ($font in $face.SelectNodes('hh:font',$Xml.Ns)) {
            $key=$face.GetAttribute('lang')+':'+(Get-HavId $font.GetAttribute('id'))
            Assert-Hav $State ($fonts.Add($key)) "header duplicate font ID '$key'."
        }
    }
    $sets['font']=$fonts
    return $sets
}

function Test-HavReferences {
    param([object]$State, [object]$Xml, [hashtable]$Resources)
    $refs=@{charPrIDRef='charPr';paraPrIDRef='paraPr';borderFillIDRef='borderFill';styleIDRef='style';nextStyleIDRef='style';tabPrIDRef='tabPr';numberingIDRef='numbering';bulletIDRef='bullet';outlineShapeIDRef='numbering'}
    foreach ($node in $Xml.Doc.SelectNodes('//*')) {
        if ($node.NamespaceURI -cnotin @($script:HavNs.hh,$script:HavNs.hp,$script:HavNs.hp10,$script:HavNs.hc)) {continue}
        foreach ($attr in $node.Attributes) {
            if ($attr.NamespaceURI.Length -ne 0 -or -not $refs.ContainsKey($attr.LocalName)) {continue}
            # HWPX UINT_MAX on a numbering paraHead means inherit the paragraph font.
            if ($node.NamespaceURI -ceq $script:HavNs.hh -and $node.LocalName -ceq 'paraHead' -and $attr.LocalName -ceq 'charPrIDRef' -and $attr.Value -ceq '4294967295') {continue}
            $id=Get-HavId $attr.Value
            Assert-Hav $State ($Resources[$refs[$attr.LocalName]].Contains($id)) "$($Xml.Name) dangling $($attr.LocalName)='$id' on $($node.LocalName)."
        }
    }
    foreach ($node in $Xml.Doc.SelectNodes('//hh:fontRef',$Xml.Ns)) {
        foreach ($language in @('hangul','latin','hanja','japanese','other','symbol','user')) {
            $id=Get-HavId $node.GetAttribute($language)
            Assert-Hav $State ($Resources.font.Contains($language.ToUpperInvariant()+':'+$id)) "$($Xml.Name) dangling font reference $language='$id'."
        }
    }
    foreach ($node in $Xml.Doc.SelectNodes('//hh:heading',$Xml.Ns)) {
        $kind=switch -CaseSensitive ($node.GetAttribute('type')) {'NUMBER' {'numbering'}; 'OUTLINE' {'numbering'}; 'BULLET' {'bullet'}}
        if ($null -ne $kind) {
            $id=Get-HavId $node.GetAttribute('idRef')
            # OUTLINE zero uses the section's outlineShapeIDRef resource.
            if ($node.GetAttribute('type') -ceq 'OUTLINE' -and $id -ceq '0') {continue}
            Assert-Hav $State ($Resources[$kind].Contains($id)) "$($Xml.Name) dangling heading $kind idRef='$id'."
        }
    }
}

function Test-HavPage {
    param([object]$State, [object]$Xml, [object]$Document)
    $page=Get-HavValue $Document 'page'
    $landscape=(Get-HavValue $page 'orientation' 'PORTRAIT') -ceq 'LANDSCAPE'
    $displayWidth=Get-HavUnit (Get-HavValue $page 'widthMm' $(if($landscape){297}else{210}))
    $displayHeight=Get-HavUnit (Get-HavValue $page 'heightMm' $(if($landscape){210}else{297}))
    $pages=@($Xml.Doc.SelectNodes('/hs:sec/hp:p/hp:run/hp:secPr/hp:pagePr',$Xml.Ns))
    Assert-Hav $State ($pages.Count -eq 1) "$($Xml.Name) expected one pagePr in the section properties."
    if ($pages.Count -ne 1) {return 0}
    $node=$pages[0]; $where=$Xml.Name+' pagePr'
    Assert-HavText $State $node 'landscape' $(if($landscape){'WIDELY'}else{'NARROWLY'}) $where
    Assert-HavNumber $State $node 'width' $(if($landscape){$displayHeight}else{$displayWidth}) $where
    Assert-HavNumber $State $node 'height' $(if($landscape){$displayWidth}else{$displayHeight}) $where
    $gutterType=Get-HavValue $page 'gutterType' 'LEFT_ONLY'
    Assert-HavText $State $node 'gutterType' $gutterType $where
    $margins=Get-HavValue $page 'margins'
    $defaults=@{left=15;right=15;top=10;bottom=10;header=15;footer=15;gutter=0}
    $units=@{}
    $marginNodes=@($node.SelectNodes('hp:margin',$Xml.Ns))
    Assert-Hav $State ($marginNodes.Count -eq 1) "$where expected one margin element."
    $margin=$node.SelectSingleNode('hp:margin',$Xml.Ns)
    foreach ($name in $defaults.Keys) {
        $units[$name]=Get-HavUnit (Get-HavValue $margins ($name+'Mm') $defaults[$name])
        Assert-HavNumber $State $margin $name $units[$name] "$where margin"
    }
    $bodyWidth=$displayWidth-$units.left-$units.right
    if ($gutterType -cne 'TOP_ONLY') {$bodyWidth-=$units.gutter}
    $columns=Get-HavValue $Document 'columns'
    $count=[int](Get-HavValue $columns 'count' 1)
    if ($count -lt 1 -or $count -gt 256) {throw 'Normalized column count outside 1..256.'}
    $gap=Get-HavUnit (Get-HavValue $columns 'gapMm' 0)
    $widths=@(Get-HavValue $columns 'widthsMm' @())
    $cols=@($Xml.Doc.SelectNodes('/hs:sec/hp:p/hp:run/hp:ctrl/hp:colPr',$Xml.Ns))
    Assert-Hav $State ($cols.Count -eq 1) "$($Xml.Name) expected one colPr."
    $col=$Xml.Doc.SelectSingleNode('/hs:sec/hp:p/hp:run/hp:ctrl/hp:colPr',$Xml.Ns)
    Assert-HavNumber $State $col 'colCount' $count "$($Xml.Name) colPr"
    Assert-HavNumber $State $col 'sameGap' $gap "$($Xml.Name) colPr"
    Assert-HavNumber $State $col 'sameSz' ([int]($widths.Count -eq 0)) "$($Xml.Name) colPr"
    $available=[long][Math]::Floor(($bodyWidth-($count-1)*$gap)/$count)
    if ($null -ne $col) {
        $sizes=@($col.SelectNodes('hp:colSz',$Xml.Ns))
        Assert-Hav $State ($sizes.Count -eq $widths.Count) "$($Xml.Name) colSz count differs from custom widths."
        if ($widths.Count -gt 0) {
            if ($widths.Count -ne $count) {throw 'Normalized column widths/count mismatch.'}
            $available=[long]::MaxValue
            for ($i=0;$i -lt $widths.Count;$i++) {
                $width=Get-HavUnit $widths[$i]; $available=[Math]::Min($available,$width)
                if ($i -lt $sizes.Count) {
                    Assert-HavNumber $State $sizes[$i] 'width' $width "$($Xml.Name) colSz[$i]"
                    Assert-HavNumber $State $sizes[$i] 'gap' $(if($i -eq $count-1){0}else{$gap}) "$($Xml.Name) colSz[$i]"
                }
            }
        }
    }
    Assert-Hav $State ($available -gt 0) "$($Xml.Name) nonpositive column width."
    return $available
}

function Test-HavTable {
    param([object]$State, [Xml.XmlElement]$Table, [object]$Ns, [object]$Block, [long]$Available, [string]$Context)
    $rows=[int](Get-HavValue $Block 'rows'); $cols=[int](Get-HavValue $Block 'columns')
    if ($rows -lt 1 -or $cols -lt 1 -or [long]$rows*$cols -gt 20000) {throw 'Normalized table grid limit exceeded.'}
    $State.GridSlots+=$rows*$cols
    if ($State.GridSlots -gt 20000) {throw 'Document table grid limit exceeded (20000).'}
    Assert-HavNumber $State $Table 'rowCnt' $rows $Context
    Assert-HavNumber $State $Table 'colCnt' $cols $Context
    $repeat=[int][bool](Get-HavValue $Block 'repeatHeader' $false)
    Assert-HavNumber $State $Table 'repeatHeader' $repeat $Context
    $widthMm=Get-HavValue $Block 'widthMm'
    $width=if ($null -eq $widthMm) {$Available} else {Get-HavUnit $widthMm}
    $size=$Table.SelectSingleNode('hp:sz',$Ns)
    Assert-HavNumber $State $size 'width' $width $Context
    $requestedWidths=@(Get-HavValue $Block 'columnWidthsMm' @())
    if ($requestedWidths.Count -ne 0 -and $requestedWidths.Count -ne $cols) {throw 'Normalized table column width count mismatch.'}
    $widths=New-Object long[] $cols; [long]$sum=0
    for ($c=0;$c -lt $cols;$c++) {
        $widths[$c]=if($requestedWidths.Count){Get-HavUnit $requestedWidths[$c]}else{[long][Math]::Floor($width/$cols)}
        $sum+=$widths[$c]
    }
    $widths[$cols-1]+=$width-$sum
    $requestedHeights=@(Get-HavValue $Block 'rowHeightsMm' @())
    if ($requestedHeights.Count -ne 0 -and $requestedHeights.Count -ne $rows) {throw 'Normalized table row height count mismatch.'}
    $heights=New-Object long[] $rows; [long]$height=0
    for ($r=0;$r -lt $rows;$r++) {
        $heights[$r]=if($requestedHeights.Count){Get-HavUnit $requestedHeights[$r]}else{1800}
        $height+=$heights[$r]
    }
    Assert-HavNumber $State $size 'height' $height $Context -Minimum:($requestedHeights.Count -eq 0)
    $origins=@{}; $occupied=[Collections.Generic.HashSet[string]]::new()
    foreach ($cell in @(Get-HavValue $Block 'cells' @())) {
        $r=[int](Get-HavValue $cell 'row')-1; $c=[int](Get-HavValue $cell 'column')-1
        $rs=[int](Get-HavValue $cell 'rowSpan' 1);$cs=[int](Get-HavValue $cell 'colSpan' 1)
        if ($r -lt 0 -or $c -lt 0 -or $rs -lt 1 -or $cs -lt 1 -or [long]$r+$rs -gt $rows -or [long]$c+$cs -gt $cols) {throw 'Normalized table span outside grid.'}
        $origins["${r}:${c}"]=@($rs,$cs)
        for ($rr=$r;$rr -lt $r+$rs;$rr++) {for ($cc=$c;$cc -lt $c+$cs;$cc++) {
            if (-not $occupied.Add("${rr}:${cc}")) {throw 'Normalized table has overlapping cells.'}
        }}
    }
    $actualRows=@($Table.SelectNodes('hp:tr',$Ns))
    Assert-Hav $State ($actualRows.Count -eq $rows) "$Context row element count mismatch."
    for ($r=0;$r -lt $rows;$r++) {
        $expected=[Collections.Generic.List[object]]::new()
        for ($c=0;$c -lt $cols;$c++) {
            $key="${r}:${c}"
            if (-not $origins.ContainsKey($key) -and $occupied.Contains($key)) {continue}
            $span=if ($origins.ContainsKey($key)) {$origins[$key]} else {@(1,1)}
            [long]$cw=0;[long]$ch=0
            for ($cc=$c;$cc -lt $c+$span[1];$cc++) {$cw+=$widths[$cc]}
            for ($rr=$r;$rr -lt $r+$span[0];$rr++) {$ch+=$heights[$rr]}
            $expected.Add(@($c,$span[0],$span[1],$cw,$ch))
        }
        if ($r -ge $actualRows.Count) {continue}
        $actual=@($actualRows[$r].SelectNodes('hp:tc',$Ns))
        Assert-Hav $State ($actual.Count -eq $expected.Count) "$Context row[$r] cell count/spans mismatch."
        for ($i=0;$i -lt [Math]::Min($actual.Count,$expected.Count);$i++) {
            $want=$expected[$i];$cell=$actual[$i];$where="$Context cell[$r,$($want[0])]"
            $addr=$cell.SelectSingleNode('hp:cellAddr',$Ns);$span=$cell.SelectSingleNode('hp:cellSpan',$Ns);$sz=$cell.SelectSingleNode('hp:cellSz',$Ns)
            foreach ($tag in @('cellAddr','cellSpan','cellSz')) {Assert-Hav $State ($cell.SelectNodes('hp:'+$tag,$Ns).Count -eq 1) "$where expected one $tag."}
            Assert-HavNumber $State $addr 'rowAddr' $r $where
            Assert-HavNumber $State $addr 'colAddr' $want[0] $where
            Assert-HavNumber $State $span 'rowSpan' $want[1] $where
            Assert-HavNumber $State $span 'colSpan' $want[2] $where
            Assert-HavNumber $State $sz 'width' $want[3] $where
            Assert-HavNumber $State $sz 'height' $want[4] $where -Minimum:($requestedHeights.Count -eq 0)
            Assert-HavNumber $State $cell 'header' ([int]($r -eq 0 -and $repeat)) $where
        }
    }
}

function Get-HavRasterRatio {
    param([byte[]]$Bytes)
    # Header-only raster geometry; no renderer, image resampling or writer helper.
    [long]$w=0;[long]$h=0; $n=$Bytes.Length
    if ($n -ge 24 -and [BitConverter]::ToString($Bytes,0,8) -ceq '89-50-4E-47-0D-0A-1A-0A') {
        for ($i=16;$i -lt 20;$i++) {$w=$w*256+$Bytes[$i];$h=$h*256+$Bytes[$i+4]}
    } elseif ($n -ge 10 -and [Text.Encoding]::ASCII.GetString($Bytes,0,6) -in @('GIF87a','GIF89a')) {
        $w=[int]$Bytes[6]+256*[int]$Bytes[7];$h=[int]$Bytes[8]+256*[int]$Bytes[9]
    } elseif ($n -ge 26 -and $Bytes[0] -eq 66 -and $Bytes[1] -eq 77) {
        $dib=[BitConverter]::ToUInt32($Bytes,14)
        if ($dib -eq 12) {$w=[BitConverter]::ToUInt16($Bytes,18);$h=[BitConverter]::ToUInt16($Bytes,20)}
        elseif ($dib -ge 40) {$w=[BitConverter]::ToInt32($Bytes,18);$h=[Math]::Abs([long][BitConverter]::ToInt32($Bytes,22))}
    } elseif ($n -ge 4 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 216) {
        $p=2
        while ($p -lt $n) {
            if ($Bytes[$p] -ne 255) {break}
            while ($p -lt $n -and $Bytes[$p] -eq 255) {$p++}
            if ($p -ge $n) {break};$marker=$Bytes[$p];$p++
            if ($marker -in @(217,218)) {break}
            if ($marker -eq 1 -or ($marker -ge 208 -and $marker -le 216)) {continue}
            if ($p+2 -gt $n) {break}
            $length=[int]$Bytes[$p]*256+[int]$Bytes[$p+1]
            if ($length -lt 2 -or $p+$length -gt $n) {break}
            if ($marker -in @(192,193,194,195,197,198,199,201,202,203,205,206,207) -and $length -ge 8) {
                $h=[int]$Bytes[$p+3]*256+[int]$Bytes[$p+4];$w=[int]$Bytes[$p+5]*256+[int]$Bytes[$p+6];break
            }
            $p+=$length
        }
    }
    if ($w -le 0 -or $h -le 0 -or $w -gt 100000000 -or $h -gt 100000000 -or $w*$h -gt 100000000) {throw 'Cannot derive bounded original image dimensions; specify both dimensions.'}
    return [double]$w/$h
}

function Get-HavSha256 {
    param([byte[]]$Bytes)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-','')} finally {$hash.Dispose()}
}

function Get-HavLocalPath {
    param([string]$Path, [string]$Context)
    if ($Path -match '^[\\/]{2}|^[a-zA-Z]+://') {throw "$Context must be a local file."}
    $provider=$null;$drive=$null
    $resolved=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path,[ref]$provider,[ref]$drive)
    if ($provider.Name -ne 'FileSystem' -or $resolved -match '^[\\/]{2}' -or
        ($null -ne $drive -and ($drive.Root -match '^[\\/]{2}' -or $drive.DisplayRoot -match '^[\\/]{2}'))) {
        throw "$Context must be a local file."
    }
    return $resolved
}

function Test-HavPicture {
    param([object]$State, [object]$Xml, [Xml.XmlElement]$Picture, [object]$Block,
        [object]$Manifest, [object]$Entries, [bool]$V2, [string]$Context)
    $path=[string](Get-HavValue $Block 'path')
    $resolved=Get-HavLocalPath $path "$Context image source"
    if (-not $State.Assets.ContainsKey($resolved)) {
        $stream=[IO.File]::Open($resolved,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 32MB) {throw "$Context original image exceeds 32 MiB."}
            $State.AssetBytes+=$stream.Length
            if ($State.AssetBytes -gt 128MB) {throw 'Original image cumulative byte limit exceeded.'}
            $bytes=Read-HavBytes $stream 32MB
        } finally {$stream.Dispose()}
        $State.Assets[$resolved]=[pscustomobject]@{Hash=(Get-HavSha256 $bytes);Bytes=$bytes}
    }
    $asset=$State.Assets[$resolved]
    $images=@($Picture.SelectNodes('hc:img',$Xml.Ns))
    Assert-Hav $State ($images.Count -eq 1) "$Context expected one embedded image reference."
    if ($images.Count -eq 1) {
        $id=$images[0].GetAttribute('binaryItemIDRef')
        Assert-Hav $State ($Manifest.ContainsKey($id)) "$Context dangling image binaryItemIDRef='$id'."
        if ($Manifest.ContainsKey($id)) {
            $item=$Manifest[$id];$href=$item.GetAttribute('href')
            Assert-Hav $State ($href.StartsWith('BinData/',[StringComparison]::Ordinal) -and $Entries.ContainsKey($href)) "$Context image reference must resolve to an existing BinData entry."
            Assert-HavText $State $item 'isEmbeded' '1' $Context
            if ($Entries.ContainsKey($href) -and $href.StartsWith('BinData/',[StringComparison]::Ordinal)) {
                if (-not $State.ImageHashes.ContainsKey($href)) {
                    $stream=$Entries[$href].Open()
                    try {$embedded=Read-HavBytes $stream 32MB} finally {$stream.Dispose()}
                    $State.ImageHashes[$href]=Get-HavSha256 $embedded
                }
                Assert-Hav $State ($State.ImageHashes[$href] -ceq $asset.Hash) "$Context original image/BinData SHA256 mismatch ($href)."
            }
        }
    }
    $w=Get-HavValue $Block 'widthMm';$h=Get-HavValue $Block 'heightMm'
    if ($V2 -and ($null -eq $w -or $null -eq $h)) {
        $ratio=Get-HavRasterRatio $asset.Bytes
        if ($null -eq $w -and $null -eq $h) {$w=40}
        if ($null -eq $w) {$w=[double]$h*$ratio}
        if ($null -eq $h) {$h=[double]$w/$ratio}
    } else {
        if ($null -eq $w) {$w=40};if ($null -eq $h) {$h=30}
    }
    foreach ($tag in @('sz','orgSz','curSz')) {
        $sizes=@($Picture.SelectNodes('hp:'+$tag,$Xml.Ns))
        Assert-Hav $State ($sizes.Count -eq 1) "$Context expected one $tag."
        $size=$Picture.SelectSingleNode('hp:'+$tag,$Xml.Ns)
        Assert-HavNumber $State $size 'width' (Get-HavUnit $w) "$Context $tag"
        Assert-HavNumber $State $size 'height' (Get-HavUnit $h) "$Context $tag"
    }
}

function Test-HavFields {
    param([object]$State, [object]$Xml)
    $stack=[Collections.Generic.Stack[object]]::new()
    foreach ($node in $Xml.Doc.SelectNodes('//hp:fieldBegin | //hp:fieldEnd',$Xml.Ns)) {
        if ($node.LocalName -ceq 'fieldBegin') {
            $id=Get-HavId $node.GetAttribute('id')
            Assert-Hav $State ($State.FieldIds.Add($id)) "$($Xml.Name) duplicate fieldBegin ID '$id'."
            $fieldId=if ($node.HasAttribute('fieldid')) {Get-HavId $node.GetAttribute('fieldid')} else {$null}
            if ($null -ne $fieldId) {Assert-Hav $State ($State.FieldValues.Add($fieldId)) "$($Xml.Name) duplicate fieldid '$fieldId'."}
            $stack.Push([pscustomobject]@{Id=$id;FieldId=$fieldId})
        } else {
            $id=Get-HavId $node.GetAttribute('beginIDRef')
            Assert-Hav $State ($stack.Count -gt 0) "$($Xml.Name) fieldEnd '$id' has no preceding fieldBegin."
            if ($stack.Count -gt 0) {
                $begin=$stack.Pop()
                Assert-Hav $State ($id -ceq $begin.Id) "$($Xml.Name) fieldEnd beginIDRef='$id' does not match fieldBegin '$($begin.Id)'."
                if ($node.HasAttribute('fieldid') -or $null -ne $begin.FieldId) {
                    Assert-HavText $State $node 'fieldid' $begin.FieldId "$($Xml.Name) fieldEnd"
                }
            }
        }
    }
    Assert-Hav $State ($stack.Count -eq 0) "$($Xml.Name) fieldBegin without matching fieldEnd."
}

function Test-HwpxGeneratedContract {
    <#
    .SYNOPSIS
    Independently verifies the bounded ZIP/XML contract of a generated HWPX.
    .DESCRIPTION
    Plan must be the normalized internal object from ConvertTo-HwpAuthoringPlan.
    This function opens local files read-only, never extracts ZIP paths, and has
    no writer/inspector dependencies. Limits: 256 MiB archive/expanded bytes,
    4096 entries, 64 MiB/entry, 16 MiB/XML, depth 128, 500000 XML nodes,
    256 sections, 20000 table grid slots, 32 MiB/image, 128 MiB source images.
    Only specified structural and geometry contracts are checked. Extra unused
    resources are permitted. Text fidelity, advanced styling, pagination, native
    rendering and visual layout are outside this gate. PASS never verifies them.
    .OUTPUTS
    PSCustomObject: Status (PASS|FAILED), Errors (string[]), Checks (int),
    NativeLayoutVerified (always false). Corrupt/unreadable inputs fail closed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateNotNull()][object]$Plan)
    $state=[pscustomobject]@{
        Errors=[Collections.Generic.List[string]]::new();Checks=0;XmlNodes=0;GridSlots=0;AssetBytes=[long]0
        Assets=@{};ImageHashes=@{}
        FieldIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        FieldValues=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    $file=$null;$zip=$null
    try {
        $ErrorActionPreference='Stop'
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $version=Get-HavValue $Plan 'sourceVersion'
        if ((Get-HavValue $Plan 'version') -cne '1.0' -or $version -cnotin @('1.0','2.0')) {throw 'Expected a normalized internal authoring Plan.'}
        $sections=@(Get-HavValue $Plan 'sections' @())
        if ($sections.Count -lt 1 -or $sections.Count -gt 256) {throw 'Normalized Plan section count outside 1..256.'}
        $path=Get-HavLocalPath $LiteralPath 'HWPX contract input'
        $file=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($file.Length -gt 256MB) {throw 'Archive byte limit exceeded (256 MiB).'}
        $reader=[IO.BinaryReader]::new($file,[Text.Encoding]::ASCII,$true)
        try { $prefix=$reader.ReadBytes(57) } finally { $reader.Dispose();$file.Position=0 }
        if ($prefix.Length -ne 57 -or [BitConverter]::ToUInt32($prefix,0) -ne 0x04034b50 -or
            [BitConverter]::ToUInt16($prefix,8) -ne 0 -or [BitConverter]::ToUInt16($prefix,26) -ne 8 -or
            [BitConverter]::ToUInt16($prefix,28) -ne 0 -or [BitConverter]::ToUInt32($prefix,18) -ne 19 -or
            [BitConverter]::ToUInt32($prefix,22) -ne 19 -or
            [Text.Encoding]::ASCII.GetString($prefix,30,27) -cne 'mimetypeapplication/hwp+zip') {
            throw 'HWPX first local entry must be the uncompressed mimetype.'
        }
        $zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Read,$true)
        if ($zip.Entries.Count -gt 4096) {throw 'ZIP entry count limit exceeded (4096).'}
        if ($zip.Entries.Count -eq 0 -or $zip.Entries[0].FullName -cne 'mimetype' -or
            $zip.Entries[0].Length -ne 19 -or $zip.Entries[0].CompressedLength -ne 19) {
            throw 'HWPX central directory must start with the uncompressed mimetype.'
        }
        $entries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        [long]$expanded=0
        foreach ($entry in $zip.Entries) {
            $name=$entry.FullName
            if (-not (Test-HavPackagePath $name)) {throw "Unsafe ZIP entry path: $name"}
            if ($entries.ContainsKey($name)) {throw "ZIP duplicate entry: $name"}
            if ($entry.Length -gt 64MB) {throw "ZIP entry byte limit exceeded: $name"}
            $expanded+=$entry.Length
            if ($expanded -gt 256MB) {throw 'ZIP expanded byte limit exceeded (256 MiB).'}
            $entries.Add($name,$entry)
        }
        $package=Read-HavXml $state $entries 'Contents/content.hpf' 'package' 'opf'
        $header=Read-HavXml $state $entries 'Contents/header.xml' 'head' 'hh'
        Assert-HavNumber $state $header.Doc.DocumentElement 'secCnt' $sections.Count 'header'
        foreach ($tag in @('manifest','spine')) {Assert-Hav $state ($package.Doc.SelectNodes('/opf:package/opf:'+$tag,$package.Ns).Count -eq 1) "package expected one $tag."}
        $manifest=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $sectionItems=[Collections.Generic.List[object]]::new()
        $hrefs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in $package.Doc.SelectNodes('/opf:package/opf:manifest/opf:item',$package.Ns)) {
            $id=$item.GetAttribute('id');$href=$item.GetAttribute('href')
            if ($id.Length -eq 0 -or $manifest.ContainsKey($id)) {throw "manifest missing/duplicate ID '$id'."}
            $manifest.Add($id,$item)
            Assert-Hav $state (Test-HavPackagePath $href) "manifest unsafe href '$href'."
            Assert-Hav $state ($entries.ContainsKey($href)) "manifest entry missing: '$href'."
            Assert-Hav $state ($hrefs.Add($href)) "manifest duplicate href '$href'."
            if ($href -cmatch '^Contents/section[0-9]+\.xml$') {$sectionItems.Add($item)}
        }
        Assert-Hav $state ($sectionItems.Count -eq $sections.Count) 'manifest section count does not match Plan.'
        $zipSections=@($entries.Keys | Where-Object {$_ -cmatch '^Contents/section[0-9]+\.xml$'})
        Assert-Hav $state ($zipSections.Count -eq $sections.Count) 'ZIP section entry count does not match Plan.'
        $spine=@($package.Doc.SelectNodes('/opf:package/opf:spine/opf:itemref',$package.Ns))
        Assert-Hav $state ($spine.Count -eq $sections.Count+1) 'spine must contain header followed by all sections.'
        for ($i=0;$i -lt $spine.Count;$i++) {
            $id=$spine[$i].GetAttribute('idref')
            Assert-Hav $state ($manifest.ContainsKey($id)) "spine dangling idref '$id'."
            if ($manifest.ContainsKey($id)) {
                $want=if($i -eq 0){'Contents/header.xml'}else{'Contents/section'+($i-1)+'.xml'}
                Assert-HavText $state $manifest[$id] 'href' $want "spine[$i] order"
            }
        }
        for ($i=0;$i -lt $sectionItems.Count;$i++) {Assert-HavText $state $sectionItems[$i] 'href' ('Contents/section'+$i+'.xml') "manifest section[$i] order"}
        $resources=Get-HavResources $state $header
        Test-HavReferences $state $header $resources
        for ($s=0;$s -lt $sections.Count;$s++) {
            $name='Contents/section'+$s+'.xml'
            $xml=Read-HavXml $state $entries $name 'sec' 'hs'
            $blocks=@(Get-HavValue $sections[$s] 'content' @())
            if ($blocks.Count -gt 20000) {throw 'Normalized section content limit exceeded.'}
            $available=Test-HavPage $state $xml (Get-HavValue $sections[$s] 'document')
            Test-HavReferences $state $xml $resources
            Test-HavFields $state $xml
            if ($version -ceq '2.0') {Assert-Hav $state ($xml.Doc.SelectNodes('//hp:linesegarray',$xml.Ns).Count -eq 0) "$name V2 must not contain linesegarray caches."}
            $tables=@($xml.Doc.SelectNodes('//hp:tbl',$xml.Ns));$expectedTables=@($blocks | Where-Object {(Get-HavValue $_ 'type') -ceq 'table'})
            $columnSettings=Get-HavValue (Get-HavValue $sections[$s] 'document') 'columns'
            $columnWidths=@(Get-HavValue $columnSettings 'widthsMm' @())
            $columnCount=[int](Get-HavValue $columnSettings 'count' 1);$columnIndex=0
            $expectedTableWidths=[Collections.Generic.List[long]]::new()
            foreach ($block in $blocks) {
                $type=Get-HavValue $block 'type'
                if ($type -ceq 'column-break') {$columnIndex=($columnIndex+1)%$columnCount}
                if ($type -ceq 'page-break') {$columnIndex=0}
                if ($type -ceq 'table') {$expectedTableWidths.Add($(if($columnWidths.Count){Get-HavUnit $columnWidths[$columnIndex]}else{$available}))}
            }
            Assert-Hav $state ($tables.Count -eq $expectedTables.Count) "$name table count mismatch."
            for ($i=0;$i -lt [Math]::Min($tables.Count,$expectedTables.Count);$i++) {Test-HavTable $state $tables[$i] $xml.Ns $expectedTables[$i] $expectedTableWidths[$i] "$name table[$i]"}
            $pictures=@($xml.Doc.SelectNodes('//hp:pic',$xml.Ns));$expectedPictures=@($blocks | Where-Object {(Get-HavValue $_ 'type') -ceq 'image'})
            Assert-Hav $state ($pictures.Count -eq $expectedPictures.Count) "$name embedded picture count mismatch."
            for ($i=0;$i -lt [Math]::Min($pictures.Count,$expectedPictures.Count);$i++) {Test-HavPicture $state $xml $pictures[$i] $expectedPictures[$i] $manifest $entries ($version -ceq '2.0') "$name image[$i]"}
        }
    } catch { $state.Errors.Add("Contract verification failed: $($_.Exception.Message)") }
    finally {if ($null -ne $zip) {$zip.Dispose()};if ($null -ne $file) {$file.Dispose()}}
    [pscustomobject]@{
        Status=$(if($state.Errors.Count){'FAILED'}else{'PASS'})
        Errors=[string[]]$state.Errors.ToArray(); Checks=[int]$state.Checks; NativeLayoutVerified=$false
    }
}

Export-ModuleMember -Function Test-HwpxGeneratedContract
