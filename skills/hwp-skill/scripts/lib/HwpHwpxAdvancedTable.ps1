# Private in-memory table objects, merged-track edits and decimal calculations.

function Get-ScopedCellVisibleText {
    param([Xml.XmlElement]$Cell)
    $ns=New-ScopedNamespaces $Cell.OwnerDocument
    $lines=[Collections.Generic.List[string]]::new()
    foreach ($p in $Cell.SelectNodes('hp:subList/hp:p',$ns)) {
        $line=[Text.StringBuilder]::new()
        foreach ($t in $p.SelectNodes('hp:run/hp:t',$ns)) {
            foreach ($node in $t.ChildNodes) {
                if ($node.NodeType -in @('Text','CDATA','Whitespace','SignificantWhitespace')) {$null=$line.Append($node.Value)}
                elseif ($node.NodeType -eq 'Element' -and $node.NamespaceURI -ceq $script:ScopedHp -and $node.LocalName -cin @('lineBreak','tab')) {$null=$line.Append($(if($node.LocalName -ceq 'tab'){"`t"}else{"`n"}))}
                else {throw 'Unknown inline text cannot be used as a cell guard.'}
            }
        }
        $lines.Add($line.ToString())
    }
    return $lines -join "`n"
}

function Get-ScopedCellTemplate {
    param([Xml.XmlElement]$Cell)
    $ns=New-ScopedNamespaces $Cell.OwnerDocument
    $sub=Get-ScopedOneChild $Cell 'hp:subList'
    foreach ($key in @('linkListIDRef','linkListNextIDRef','hasTextRef','hasNumRef')) {
        if ($sub.HasAttribute($key) -and $sub.GetAttribute($key) -cnotin @('','0')) {throw 'Linked cell lists are not editable.'}
    }
    $p=$sub.SelectSingleNode('hp:p',$ns)
    if ($null -eq $p -or $p.SelectNodes('hp:run',$ns).Count -lt 1) {throw 'Cell needs a paragraph/run style template.'}
    return @{SubList=$sub;Paragraphs=@($p)}
}

function Get-ScopedCellInnerWidth {
    param([Xml.XmlElement]$Cell)
    $size=Get-ScopedOneChild $Cell 'hp:cellSz'
    $margin=Get-ScopedOneChild $Cell 'hp:cellMargin'
    if ($Cell.HasAttribute('hasMargin') -and $Cell.GetAttribute('hasMargin') -cin @('0','false')) {
        $table=$Cell.SelectSingleNode('ancestor::hp:tbl[1]',(New-ScopedNamespaces $Cell.OwnerDocument))
        if ($null -eq $table) {throw 'A cell without its own margins needs its parent table.'}
        $margin=Get-ScopedOneChild $table 'hp:inMargin'
    }
    $width=(Get-ScopedXmlInteger $size 'width' 1)-(Get-ScopedXmlInteger $margin 'left')-(Get-ScopedXmlInteger $margin 'right')
    if ($width -lt 1) {throw 'Cell has no positive inner width.'}
    return $width
}

function Get-ScopedNextObjectId {
    param($Package,$Allocation)
    if (-not $Allocation.ContainsKey('ObjectId')) {
        [long]$maximum=0
        foreach ($part in $Package.Sections) {foreach ($node in $Package.Xml[$part].SelectNodes('//*[@id]')) {
            $value=$node.GetAttribute('id')
            if ($value -cmatch '^[0-9]{1,10}$') {$maximum=[Math]::Max($maximum,[long]$value)}
        }}
        $Allocation.ObjectId=$maximum+1
    }
    if ($Allocation.ObjectId -gt [uint32]::MaxValue) {throw 'No object IDs remain.'}
    $id=[string]$Allocation.ObjectId; $Allocation.ObjectId++
    return $id
}

function New-ScopedObjectParagraph {
    param([Xml.XmlElement]$Cell,$Package,$Allocation,[Xml.XmlElement]$Object)
    $template=Get-ScopedCellTemplate $Cell
    $p=$Cell.OwnerDocument.CreateElement('hp','p',$script:ScopedHp)
    $p.SetAttribute('paraPrIDRef',$template.Paragraphs[0].GetAttribute('paraPrIDRef'))
    if($template.Paragraphs[0].HasAttribute('styleIDRef')){$p.SetAttribute('styleIDRef',$template.Paragraphs[0].GetAttribute('styleIDRef'))}
    $p.SetAttribute('id',(Get-ScopedNextParagraphId $Package $Allocation))
    foreach ($key in @('pageBreak','columnBreak','merged')) {$p.SetAttribute($key,'0')}
    $run=$Cell.OwnerDocument.CreateElement('hp','run',$script:ScopedHp)
    $run.SetAttribute('charPrIDRef',$template.Paragraphs[0].SelectSingleNode('hp:run',(New-ScopedNamespaces $Cell.OwnerDocument)).GetAttribute('charPrIDRef'))
    $null=$run.AppendChild($Object)
    $null=$run.AppendChild($Cell.OwnerDocument.CreateElement('hp','t',$script:ScopedHp))
    $null=$p.AppendChild($run)
    return ,$p
}

function Add-ScopedCellObject {
    param([Xml.XmlElement]$Cell,$Operation,$Package,$Allocation)
    if (-not (Test-ScopedExpectedCellText $Operation['expectedText'] (Get-ScopedCellVisibleText $Cell))) {throw 'Cell object expectedText does not match inspection.'}
    $placement=$Operation['placement']
    if ($placement -isnot [string] -or $placement -cnotin @('append','prepend')) {throw 'placement must be append or prepend.'}
    $inner=Get-ScopedCellInnerWidth $Cell
    if ($Operation['type'] -ceq 'insert-cell-image') {$object=New-ScopedCellImage $Cell $Operation $Package $Allocation $inner}
    else {$object=New-ScopedNestedTable $Cell $Operation['table'] $Package $Allocation $inner 1}
    $copy=$Cell.CloneNode($true); $sub=Get-ScopedOneChild $copy 'hp:subList'
    $p=New-ScopedObjectParagraph $Cell $Package $Allocation $object
    if ($placement -ceq 'prepend') {$null=$sub.InsertBefore($p,$sub.SelectSingleNode('hp:p',(New-ScopedNamespaces $Cell.OwnerDocument)))} else {$null=$sub.AppendChild($p)}
    foreach ($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',(New-ScopedNamespaces $Cell.OwnerDocument)))) {$null=$cache.ParentNode.RemoveChild($cache)}
    return ,$copy
}

function New-ScopedCellImage {
    param([Xml.XmlElement]$Cell,$Operation,$Package,$Allocation,[long]$Available)
    $path=$Operation['path']
    if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or $path -match '^[\\/]{2}|^[a-zA-Z]+://') {throw 'Image path must be local.'}
    $local=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    if ($local.Substring([IO.Path]::GetPathRoot($local).Length).Contains(':')) {throw 'Image alternate data streams are not supported.'}
    Import-Module (Join-Path $PSScriptRoot 'HwpHwpxObjects.psm1') -ErrorAction Stop
    $stream=[IO.File]::Open($local,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 8 -or $stream.Length -gt 32MB) {throw 'Image must be between 8 bytes and 32 MiB.'}
        $memory=[IO.MemoryStream]::new()
        try {$stream.CopyTo($memory); $bytes=$memory.ToArray()} finally {$memory.Dispose()}
        $media=Get-ScopedRasterMediaType $bytes
        $raster=Get-HwpxRasterSize $local
        if ($null -eq $raster) {throw 'A PNG, JPEG, GIF or BMP with known dimensions is required.'}
        if(-not $Allocation.ContainsKey('NewImagePixels')){$Allocation.NewImagePixels=[long]0}
        $Allocation.NewImagePixels += [long]$raster.width*$raster.height
        if($Allocation.NewImagePixels -gt 100000000){throw 'Cumulative decoded image pixels exceed 100 million.'}
        $null=Test-HwpxRasterIntegrity $local
        if((Get-HwpSha256 -LiteralPath $local) -ine (Get-ScopedBytesHash $bytes).Replace('-','')){throw 'Image changed during validation.'}
    } finally {$stream.Dispose()}
    $w=if($Operation.ContainsKey('widthMm')){Get-ScopedNumber $Operation['widthMm'] 0.01 2000 'image.widthMm'}else{$null}
    $h=if($Operation.ContainsKey('heightMm')){Get-ScopedNumber $Operation['heightMm'] 0.01 2000 'image.heightMm'}else{$null}
    if ($null -eq $w -and $null -eq $h) {$w=[Math]::Min(40,$Available*25.4/7200)}
    if ($null -eq $w) {$w=$h*$raster.width/$raster.height}
    if ($null -eq $h) {$h=$w*$raster.height/$raster.width}
    $width=ConvertTo-ScopedMm $w 'image.widthMm'; $height=ConvertTo-ScopedMm $h 'image.heightMm'
    if ($width -lt 1 -or $height -lt 1 -or $width -gt $Available) {throw 'Image exceeds the cell inner width or rounds to zero.'}
    $hpf=$Package.Xml['Contents/content.hpf']; $ns=New-ScopedNamespaces $hpf
    $id='hwpSkillImage'+(Get-ScopedNextObjectId $Package $Allocation)
    $manifestIds=@($hpf.SelectNodes('/opf:package/opf:manifest/opf:item',$ns)|ForEach-Object {$_.GetAttribute('id')})
    while ($manifestIds -ccontains $id) {$id='hwpSkillImage'+(Get-ScopedNextObjectId $Package $Allocation)}
    $extension=@{'image/png'='png';'image/jpeg'='jpg';'image/gif'='gif';'image/bmp'='bmp'}[$media]
    $part='BinData/'+$id+'.'+$extension
    if ($Package.Parts.ContainsKey($part)) {throw 'New image part collides with the original.'}
    if (-not $Allocation.ContainsKey('NewParts')) {$Allocation.NewParts=[Collections.Generic.List[object]]::new();$Allocation.NewImageBytes=[long]0}
    if($Package.Parts.Count+$Allocation.NewParts.Count -ge 4096){throw 'Too many embedded image parts.'}
    $Allocation.NewImageBytes+=$bytes.Length
    if ($Allocation.NewImageBytes -gt 128MB) {throw 'New cell images exceed 128 MiB.'}
    $Allocation.NewParts.Add(@{Name=$part;Bytes=$bytes;Id=$id;MediaType=$media})
    $objectId=Get-ScopedNextObjectId $Package $Allocation
    $cx=[long][Math]::Floor($width/2);$cy=[long][Math]::Floor($height/2)
    # Same canonical inline picture geometry as the document authoring engine.
    $fragment=$Cell.OwnerDocument.CreateDocumentFragment()
    $fragment.InnerXml='<hp:pic xmlns:hp="'+$script:ScopedHp+'" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" id="'+$objectId+'" zOrder="0" numberingType="PICTURE" textWrap="TOP_AND_BOTTOM" textFlow="BOTH_SIDES" lock="0" dropcapstyle="None" href="" groupLevel="0" instid="'+$objectId+'" reverse="0"><hp:offset x="0" y="0"/><hp:orgSz width="'+$width+'" height="'+$height+'"/><hp:curSz width="'+$width+'" height="'+$height+'"/><hp:flip horizontal="0" vertical="0"/><hp:rotationInfo angle="0" centerX="'+$cx+'" centerY="'+$cy+'" rotateimage="1"/><hp:renderingInfo><hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/></hp:renderingInfo><hc:img binaryItemIDRef="'+$id+'" bright="0" contrast="0" effect="REAL_PIC" alpha="0"/><hp:imgRect><hc:pt0 x="0" y="0"/><hc:pt1 x="'+$width+'" y="0"/><hc:pt2 x="'+$width+'" y="'+$height+'"/><hc:pt3 x="0" y="'+$height+'"/></hp:imgRect><hp:imgClip left="0" right="'+$width+'" top="0" bottom="'+$height+'"/><hp:inMargin left="0" right="0" top="0" bottom="0"/><hp:imgDim dimwidth="'+$width+'" dimheight="'+$height+'"/><hp:effects/><hp:sz width="'+$width+'" widthRelTo="ABSOLUTE" height="'+$height+'" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" affectLSpacing="0" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" vertRelTo="PARA" horzRelTo="COLUMN" vertAlign="TOP" horzAlign="LEFT" vertOffset="0" horzOffset="0"/><hp:outMargin left="0" right="0" top="0" bottom="0"/><hp:shapeComment/></hp:pic>'
    $pic=$fragment.FirstChild
    if ($Operation.ContainsKey('altText')) {
        $alt=$Operation['altText']; if ($alt -isnot [string] -or $alt.Length -gt 4096) {throw 'altText must be at most 4096 characters.'}
        $null=[Xml.XmlConvert]::VerifyXmlChars($alt)
        (Get-ScopedOneChild $pic 'hp:shapeComment').InnerText=$alt
    }
    return ,$pic
}

function New-ScopedNestedTable {
    param([Xml.XmlElement]$ParentCell,$Value,$Package,$Allocation,[long]$Available,[int]$Depth)
    if ($Depth -gt 8) {throw 'Nested table depth exceeds eight levels.'}
    $plan=ConvertTo-ScopedMap $Value 'nested.table'
    Assert-ScopedKeys $plan @('rows','columns','cells') 'nested.table' @('widthMm','columnWidthsMm','rowHeightsMm','style','textStyle','paragraphStyle','repeatHeader','alignment','pageBreak')
    $rows=Get-ScopedIndex $plan['rows'] 'table.rows';$columns=Get-ScopedIndex $plan['columns'] 'table.columns'
    if ($rows -lt 1 -or $columns -lt 1 -or $rows -gt 256 -or $columns -gt 256 -or $rows*$columns -gt 4096) {throw 'Nested table exceeds grid limits.'}
    if (-not $Allocation.ContainsKey('NestedGridSlots')) {$Allocation.NestedGridSlots=0}
    $Allocation.NestedGridSlots+=$rows*$columns
    if ($Allocation.NestedGridSlots -gt 16384) {throw 'Nested table plan exceeds 16384 grid slots.'}
    $width=if($plan.ContainsKey('widthMm')){ConvertTo-ScopedMm $plan['widthMm'] 'table.widthMm'}else{$Available}
    if ($width -lt 1 -or $width -gt $Available) {throw 'Nested table exceeds the parent cell inner width.'}
    $widths=@(1..$columns|ForEach-Object {[long][Math]::Floor($width/$columns)});$widths[$columns-1]+=$width-($widths|Measure-Object -Sum).Sum
    $heights=@(1..$rows|ForEach-Object {2268L})
    foreach ($axis in @('columnWidthsMm','rowHeightsMm')) {
        if (-not $plan.ContainsKey($axis)) {continue}
        $array=$plan[$axis];$count=if($axis -ceq 'columnWidthsMm'){$columns}else{$rows}
        if ($array -isnot [Collections.IList] -or $array.Count -ne $count) {throw 'Nested table track count mismatch.'}
        $units=@(foreach($n in $array){$u=ConvertTo-ScopedMm $n $axis;if($u -lt 1){throw 'Nested track must round positive.'};$u})
        if ($axis -ceq 'columnWidthsMm') {
            $widths=$units
            $sumMm=0.0;foreach($number in $array){$sumMm+=[double]$number}
            if([Math]::Abs($sumMm-$width*25.4/7200) -gt 0.02){throw 'Nested column widths must sum to its width.'}
            $widths[$columns-1]+=$width-($widths|Measure-Object -Sum).Sum
            if($widths[$columns-1] -lt 1){throw 'Nested rounding leaves no final column width.'}
        } else {$heights=$units}
    }
    $cells=$plan['cells']; if($cells -isnot [Collections.IList]){throw 'Nested cells must be an array.'}
    $anchors=@{};$occupied=@{}
    foreach ($entry in $cells) {
        $cell=ConvertTo-ScopedMap $entry 'nested.cell'
        Assert-ScopedKeys $cell @('row','column') 'nested.cell' @('rowSpan','colSpan','text','paragraphs','content','style','textStyle','paragraphStyle','verticalAlignment')
        $r=Get-ScopedIndex $cell['row'] 'cell.row';$c=Get-ScopedIndex $cell['column'] 'cell.column'
        $rs=if($cell.ContainsKey('rowSpan')){Get-ScopedIndex $cell['rowSpan'] 'cell.rowSpan'}else{1}
        $cs=if($cell.ContainsKey('colSpan')){Get-ScopedIndex $cell['colSpan'] 'cell.colSpan'}else{1}
        if ($r -lt 1 -or $c -lt 1 -or $rs -lt 1 -or $cs -lt 1 -or $r+$rs-1 -gt $rows -or $c+$cs-1 -gt $columns) {throw 'Nested cell address/span is out of bounds.'}
        if (@(@('text','paragraphs','content')|Where-Object {$cell.ContainsKey($_)}).Count -gt 1) {throw 'Choose text, paragraphs or content for a nested cell.'}
        for($rr=$r;$rr -lt $r+$rs;$rr++){for($cc=$c;$cc -lt $c+$cs;$cc++){if($occupied.ContainsKey("$rr,$cc")){throw 'Nested cells overlap.'};$occupied["$rr,$cc"]=$true}}
        $anchors["$r,$c"]=@{Plan=$cell;RowSpan=$rs;ColumnSpan=$cs}
    }
    $xml=$ParentCell.OwnerDocument;$ns=New-ScopedNamespaces $xml
    $table=$xml.CreateElement('hp','tbl',$script:ScopedHp)
    foreach($pair in @(@('id',(Get-ScopedNextObjectId $Package $Allocation)),@('rowCnt',[string]$rows),@('colCnt',[string]$columns),@('cellSpacing','0'),@('borderFillIDRef',$ParentCell.GetAttribute('borderFillIDRef')),@('lock','0'),@('zOrder','0'),@('numberingType','TABLE'),@('textWrap','TOP_AND_BOTTOM'),@('textFlow','BOTH_SIDES'),@('pageBreak','CELL'),@('repeatHeader','0'),@('noAdjust','0'))) {$table.SetAttribute($pair[0],$pair[1])}
    $table.SetAttribute('dropcapstyle','None')
    $sz=$xml.CreateElement('hp','sz',$script:ScopedHp);$sz.SetAttribute('width',[string]$width);$sz.SetAttribute('height',[string](($heights|Measure-Object -Sum).Sum));$sz.SetAttribute('widthRelTo','ABSOLUTE');$sz.SetAttribute('heightRelTo','ABSOLUTE');$sz.SetAttribute('protect','0');$null=$table.AppendChild($sz)
    $pos=$xml.CreateElement('hp','pos',$script:ScopedHp)
    foreach($pair in @(@('treatAsChar','1'),@('affectLSpacing','0'),@('flowWithText','1'),@('allowOverlap','0'),@('holdAnchorAndSO','0'),@('vertRelTo','PARA'),@('horzRelTo','COLUMN'),@('vertAlign','TOP'),@('horzAlign','LEFT'),@('vertOffset','0'),@('horzOffset','0'))) {$pos.SetAttribute($pair[0],$pair[1])}
    $null=$table.AppendChild($pos)
    foreach($name in @('outMargin','inMargin')) {$margin=$xml.CreateElement('hp',$name,$script:ScopedHp);foreach($side in @('left','right','top','bottom')){$margin.SetAttribute($side,'0')};$null=$table.AppendChild($margin)}
    $template=Get-ScopedCellTemplate $ParentCell
    for($r=1;$r -le $rows;$r++) {
        $tr=$xml.CreateElement('hp','tr',$script:ScopedHp);$null=$table.AppendChild($tr)
        for($c=1;$c -le $columns;$c++) {
            $key="$r,$c";if($occupied.ContainsKey($key) -and -not $anchors.ContainsKey($key)){continue}
            $entry=$anchors[$key];$definition=if($null -ne $entry){$entry.Plan}else{@{}}
            $rs=if($null -ne $entry){$entry.RowSpan}else{1};$cs=if($null -ne $entry){$entry.ColumnSpan}else{1}
            $tc=New-ScopedEmptyCell $ParentCell $template $Package $Allocation
            foreach($attribute in @($tc.Attributes)){if($attribute.NamespaceURI -cne 'http://www.w3.org/2000/xmlns/' -and ($attribute.NamespaceURI -cne '' -or $attribute.LocalName -cnotin @('name','header','hasMargin','protect','editable','dirty','borderFillIDRef'))){$null=$tc.RemoveAttributeNode($attribute)}}
            $tc.SetAttribute('name','');$tc.SetAttribute('header','0')
            $subList=Get-ScopedOneChild $tc 'hp:subList';$subList.SetAttribute('id','');foreach($key in @('linkListIDRef','linkListNextIDRef','textWidth','textHeight','hasTextRef','hasNumRef')){$subList.SetAttribute($key,'0')};$subList.SetAttribute('textDirection','HORIZONTAL')
            $addr=Get-ScopedOneChild $tc 'hp:cellAddr';$addr.SetAttribute('rowAddr',[string]($r-1));$addr.SetAttribute('colAddr',[string]($c-1))
            $span=Get-ScopedOneChild $tc 'hp:cellSpan';$span.SetAttribute('rowSpan',[string]$rs);$span.SetAttribute('colSpan',[string]$cs)
            $size=Get-ScopedOneChild $tc 'hp:cellSz';$size.SetAttribute('width',[string](($widths[($c-1)..($c+$cs-2)]|Measure-Object -Sum).Sum));$size.SetAttribute('height',[string](($heights[($r-1)..($r+$rs-2)]|Measure-Object -Sum).Sum))
            $padding=[Math]::Min(100,[Math]::Floor(([Math]::Min([long]$size.GetAttribute('width'),[long]$size.GetAttribute('height'))-1)/2))
            $margin=Get-ScopedOneChild $tc 'hp:cellMargin';foreach($side in @('left','right','top','bottom')){$margin.SetAttribute($side,[string]$padding)};$tc.SetAttribute('hasMargin','1')
            $null=$tr.AppendChild($tc)
            $paragraphs=@(@{text=''});if($definition.ContainsKey('paragraphs')){$paragraphs=$definition['paragraphs']}elseif($definition.ContainsKey('text')){$paragraphs=@(@{text=$definition['text']})}
            $fields=@{}
            foreach($name in @('style','textStyle','paragraphStyle')){if($plan.ContainsKey($name)){$fields[$name]=$plan[$name]};if($definition.ContainsKey($name)){
                if($fields.ContainsKey($name)){$base=ConvertTo-ScopedMap $fields[$name] $name;$over=ConvertTo-ScopedMap $definition[$name] $name;foreach($k in $over.Keys){$base[$k]=$over[$k]};$fields[$name]=$base}else{$fields[$name]=$definition[$name]}
            }}
            if($definition.ContainsKey('verticalAlignment')){$fields['verticalAlignment']=$definition['verticalAlignment']}
            if($fields.Count -gt 0){Set-ScopedCellFormat $tc $fields $Package $Allocation}
            $replacement=New-ScopedCellContentReplacement $tc @{expectedText='';paragraphs=$paragraphs} $Package $Allocation
            $null=$tr.ReplaceChild($replacement,$tc);$tc=$replacement
            if($definition.ContainsKey('content')) {
                $blocks=$definition['content'];if($blocks -isnot [Collections.IList] -or $blocks.Count -gt 128){throw 'Nested cell content must be an array of at most 128 blocks.'}
                $sub=Get-ScopedOneChild $tc 'hp:subList'
                $initial=$sub.SelectSingleNode('hp:p',$ns)
                foreach($blockValue in $blocks){
                    $block=ConvertTo-ScopedMap $blockValue 'cell.content';Assert-ScopedKeys $block @('type') 'cell.content' @('table','path','widthMm','heightMm','altText','text','runs','textStyle','paragraphStyle')
                    $inner=Get-ScopedCellInnerWidth $tc
                    if($block['type'] -ceq 'table') {Assert-ScopedKeys $block @('type','table') 'cell.table';$object=New-ScopedNestedTable $tc $block['table'] $Package $Allocation $inner ($Depth+1);$p=New-ScopedObjectParagraph $tc $Package $Allocation $object}
                    elseif($block['type'] -ceq 'image') {Assert-ScopedKeys $block @('type','path') 'cell.image' @('widthMm','heightMm','altText');$object=New-ScopedCellImage $tc $block $Package $Allocation $inner;$p=New-ScopedObjectParagraph $tc $Package $Allocation $object}
                    elseif($block['type'] -ceq 'paragraph') {
                        $temp=New-ScopedEmptyCell $tc (Get-ScopedCellTemplate $tc) $Package $Allocation
                        $temp=New-ScopedCellContentReplacement $temp @{expectedText='';paragraphs=@($block)} $Package $Allocation
                        $p=(Get-ScopedOneChild $temp 'hp:subList').SelectSingleNode('hp:p',$ns)
                    }else{throw 'Nested content supports paragraph, image and table blocks.'}
                    $null=$sub.AppendChild($p)
                }
                if($blocks.Count -gt 0){$null=$sub.RemoveChild($initial)}
            }
        }
    }
    foreach($key in @('repeatHeader','pageBreak','alignment')) {
        if(-not $plan.ContainsKey($key)){continue}
        if($key -ceq 'repeatHeader') {if($plan[$key] -isnot [bool]){throw 'repeatHeader must be Boolean.'};$table.SetAttribute($key,[string][int]$plan[$key]);foreach($tc in $table.SelectNodes('hp:tr[1]/hp:tc',$ns)){$tc.SetAttribute('header',[string][int]$plan[$key])}}
        elseif($key -ceq 'pageBreak'){if($plan[$key] -isnot [string] -or $plan[$key] -cnotin @('CELL','TABLE','NONE')){throw 'Invalid pageBreak.'};$table.SetAttribute($key,$plan[$key])}
        else {if($plan[$key] -isnot [string] -or $plan[$key] -cnotin @('LEFT','CENTER','RIGHT')){throw 'Invalid table alignment.'};$pos.SetAttribute('horzAlign',$plan[$key])}
    }
    $null=Get-ScopedTableGrid $table
    return ,$table
}

function Resolve-ScopedMergedTracks {
    param($Grid,[Xml.XmlElement]$Table,$Operation)
    foreach($axis in @('Width','Height')) {
        $sizes=if($axis -ceq 'Width'){$Grid.Widths}else{$Grid.Heights}
        $key=if($axis -ceq 'Width'){'columnWidthsMm'}else{'rowHeightsMm'}
        if($Operation.ContainsKey($key)) {
            $values=$Operation[$key];if($values -isnot [Collections.IList] -or $values.Count -ne $sizes.Count){throw 'Original track dimension count mismatch.'}
            for($n=0;$n -lt $sizes.Count;$n++){$sizes[$n]=ConvertTo-ScopedMm $values[$n] $key;if($sizes[$n] -lt 1){throw 'Track sizes must round positive.'}}
        }
        if(@($sizes|Where-Object {$_ -lt 1}).Count -gt 0){throw "Merged track dimensions are ambiguous; supply original $key explicitly."}
        $sz=Get-ScopedOneChild $Table 'hp:sz';$attribute=$axis.ToLowerInvariant()
        if($sz.GetAttribute($attribute+'RelTo') -cne 'ABSOLUTE' -or ($sz.HasAttribute('protect') -and $sz.GetAttribute('protect') -cnotin @('0','false'))){throw 'Merged tracks need unprotected absolute table dimensions.'}
        if((Get-ScopedXmlInteger $sz $attribute 1) -ne ($sizes|Measure-Object -Sum).Sum){throw 'Table extent differs from its resolved original tracks.'}
    }
    Assert-ScopedGridDimensions $Grid
}

function New-ScopedMergedTrackTable {
    param([Xml.XmlElement]$Table,$Operation,$Package,$Allocation)
    $copy=$Table.CloneNode($true);$ns=New-ScopedNamespaces $copy.OwnerDocument;$grid=Get-ScopedTableGrid $copy
    Resolve-ScopedMergedTracks $grid $copy $Operation
    $rowAxis=$Operation['type'].EndsWith('-row',[StringComparison]::Ordinal)
    $insert=$Operation['type'].StartsWith('insert-',[StringComparison]::Ordinal)
    $index=Get-ScopedIndex $Operation['index'] 'track.index'
    $count=if($rowAxis){$grid.RowCount}else{$grid.ColumnCount};$other=if($rowAxis){$grid.ColumnCount}else{$grid.RowCount}
    if($index -gt $count -or (-not $insert -and ($index -eq $count -or $count -le 1)) -or ($insert -and ($count -ge 256 -or ($count+1)*$other -gt 4096))){throw 'Track index/resulting grid is invalid.'}
    $units=if($insert){ConvertTo-ScopedMm $Operation[$(if($rowAxis){'heightMm'}else{'widthMm'})] 'insert.dimension'}else{$(if($rowAxis){$grid.Heights[$index]}else{$grid.Widths[$index]})}
    if($units -lt 1){throw 'Track dimension must round positive.'}
    foreach($tr in $grid.Rows){Assert-ScopedCellAttributes $tr @();foreach($node in $tr.ChildNodes){if($node.NodeType -in @('Whitespace','SignificantWhitespace')){continue};if($node.NodeType -ne 'Element' -or $node.NamespaceURI -cne $script:ScopedHp -or $node.LocalName -cne 'tc'){throw 'Unknown row metadata cannot be moved.'}}}
    foreach($cell in $grid.Cells){Assert-ScopedEditContext $cell.Node;Assert-ScopedCellAttributes $cell.Node @('name','header','hasMargin','protect','editable','dirty','borderFillIDRef');$null=Get-ScopedCellTemplate $cell.Node}
    if(-not $insert) {
        $expected=$Operation['expectedTexts'];if($expected -isnot [Collections.IList] -or $expected.Count -ne $other){throw 'expectedTexts must cover every grid position in the deleted track.'}
        for($n=0;$n -lt $other;$n++){$key=if($rowAxis){"$index,$n"}else{"$n,$index"};if(-not(Test-ScopedExpectedCellText $expected[$n] (Get-ScopedCellVisibleText $grid.Occupancy[$key].Node))){throw 'Deleted merged track expectedTexts mismatch.'}}
    }
    $records=[Collections.Generic.List[object]]::new();$occupied=@{}
    foreach($cell in $grid.Cells){
        $start=if($rowAxis){$cell.Row}else{$cell.Column};$span=if($rowAxis){$cell.RowSpan}else{$cell.ColumnSpan}
        $cross=if($insert){$start -lt $index -and $start+$span -gt $index}else{$start -le $index -and $start+$span -gt $index}
        if(-not $insert -and $cross -and $span -eq 1){
            $null=Get-ScopedCellContent $cell.Node (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'charPr') (Get-ScopedStyleIds $Package.Xml['Contents/header.xml'] 'paraPr')
            continue
        }
        if($cross){$span+= $(if($insert){1}else{-1});$dimension=if($rowAxis){'height'}else{'width'};$old=Get-ScopedOneChild $cell.Node 'hp:cellSz';$old.SetAttribute($dimension,[string]((Get-ScopedXmlInteger $old $dimension 1)+$(if($insert){$units}else{-$units})))}
        if($insert -and $start -ge $index){$start++}elseif(-not $insert -and $start -gt $index){$start--}
        if($rowAxis){$cell.Row=$start;$cell.RowSpan=$span}else{$cell.Column=$start;$cell.ColumnSpan=$span}
        $addr=Get-ScopedOneChild $cell.Node 'hp:cellAddr';$addr.SetAttribute('rowAddr',[string]$cell.Row);$addr.SetAttribute('colAddr',[string]$cell.Column)
        $spanNode=Get-ScopedOneChild $cell.Node 'hp:cellSpan';$spanNode.SetAttribute('rowSpan',[string]$cell.RowSpan);$spanNode.SetAttribute('colSpan',[string]$cell.ColumnSpan)
        $records.Add($cell)
        for($r=$cell.Row;$r -lt $cell.Row+$cell.RowSpan;$r++){for($c=$cell.Column;$c -lt $cell.Column+$cell.ColumnSpan;$c++){$occupied["$r,$c"]=$true}}
    }
    $rows=[Collections.Generic.List[object]]::new();foreach($tr in $grid.Rows){$rows.Add($tr)}
    if($rowAxis){if($insert){$tr=$copy.OwnerDocument.CreateElement('hp','tr',$script:ScopedHp);if($index -eq $count){$null=$copy.InsertAfter($tr,$rows[$count-1])}else{$null=$copy.InsertBefore($tr,$rows[$index])};$rows.Insert($index,$tr)}else{$null=$copy.RemoveChild($rows[$index]);$rows.RemoveAt($index)}}
    if($insert){
        for($n=0;$n -lt $other;$n++){
            $r=if($rowAxis){$index}else{$n};$c=if($rowAxis){$n}else{$index};if($occupied.ContainsKey("$r,$c")){continue}
            $templateIndex=[Math]::Min($count-1,[Math]::Max(0,$index-1));$key=if($rowAxis){"$templateIndex,$n"}else{"$n,$templateIndex"}
            $template=$grid.Occupancy[$key].Node;$cell=New-ScopedEmptyCell $template (Get-ScopedCellTemplate $template) $Package $Allocation;$cell.SetAttribute('name','')
            $addr=Get-ScopedOneChild $cell 'hp:cellAddr';$addr.SetAttribute('rowAddr',[string]$r);$addr.SetAttribute('colAddr',[string]$c)
            $span=Get-ScopedOneChild $cell 'hp:cellSpan';$span.SetAttribute('rowSpan','1');$span.SetAttribute('colSpan','1')
            $sz=Get-ScopedOneChild $cell 'hp:cellSz';$sz.SetAttribute('width',[string]$(if($rowAxis){$grid.Widths[$n]}else{$units}));$sz.SetAttribute('height',[string]$(if($rowAxis){$units}else{$grid.Heights[$n]}))
            $records.Add([pscustomobject]@{Node=$cell;Row=$r;Column=$c})
        }
    }
    foreach($tr in $rows){foreach($cell in @($tr.SelectNodes('hp:tc',$ns))){$null=$tr.RemoveChild($cell)}}
    foreach($cell in @($records|Sort-Object Row,Column)){$null=$rows[$cell.Row].AppendChild($cell.Node)}
    foreach($cell in $records){$null=Get-ScopedCellInnerWidth $cell.Node}
    $attribute=if($rowAxis){'rowCnt'}else{'colCnt'};$copy.SetAttribute($attribute,[string]($count+$(if($insert){1}else{-1})))
    $size=Get-ScopedOneChild $copy 'hp:sz';$dimension=if($rowAxis){'height'}else{'width'};$size.SetAttribute($dimension,[string]((Get-ScopedXmlInteger $size $dimension 1)+$(if($insert){$units}else{-$units})))
    foreach($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',$ns))){$null=$cache.ParentNode.RemoveChild($cache)}
    $null=Get-ScopedTableGrid $copy
    return ,$copy
}
