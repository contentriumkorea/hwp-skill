Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HwpAuthoringPlan.psm1') -ErrorAction Stop

function Get-HwpxRasterSize {
    param([string]$Path)
    $stream=[IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -gt 33554432) {throw 'Image asset exceeds 32 MiB.'}
        $b=New-Object byte[] 32; $n=$stream.Read($b,0,32)
        if ($n -ge 24 -and $b[0] -eq 137 -and $b[1] -eq 80) {
            $w=[long]$b[16]*16777216+[long]$b[17]*65536+[long]$b[18]*256+$b[19]
            $h=[long]$b[20]*16777216+[long]$b[21]*65536+[long]$b[22]*256+$b[23]
        } elseif ($n -ge 10 -and $b[0] -eq 71 -and $b[1] -eq 73) {
            $w=[int]$b[6]+[int]$b[7]*256; $h=[int]$b[8]+[int]$b[9]*256
        } elseif ($n -ge 26 -and $b[0] -eq 66 -and $b[1] -eq 77) {
            $w=[BitConverter]::ToInt32($b,18);$h=[Math]::Abs([BitConverter]::ToInt32($b,22))
        } elseif ($n -ge 4 -and $b[0] -eq 255 -and $b[1] -eq 216) {
            $stream.Position=2;$w=0;$h=0
            while ($stream.Position -lt $stream.Length-8) {
                if ($stream.ReadByte() -ne 255) {throw 'Invalid JPEG marker.'}
                do {$marker=$stream.ReadByte()} while ($marker -eq 255)
                if ($marker -in @(217,218)) {break}
                if ($marker -in @(1,216) -or ($marker -ge 208 -and $marker -le 215)) {continue}
                $len=$stream.ReadByte()*256+$stream.ReadByte();if ($len -lt 2 -or $stream.Position+$len-2 -gt $stream.Length) {throw 'Invalid JPEG length.'}
                if ($marker -in @(192,193,194,195,197,198,199,201,202,203,205,206,207)) {
                    $null=$stream.ReadByte();$h=$stream.ReadByte()*256+$stream.ReadByte();$w=$stream.ReadByte()*256+$stream.ReadByte();break
                }
                $stream.Position+=$len-2
            }
        } else {return $null}
        if ($w -le 0 -or $h -le 0 -or $w*$h -gt 100000000) {throw 'Invalid or excessive image dimensions.'}
        [pscustomobject]@{width=$w;height=$h}
    } finally {$stream.Dispose()}
}

function Test-HwpxRasterIntegrity {
    param([string]$Path)
    # Windows' built-in in-memory raster decoder; no application or display surface.
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $probe=$null;$validated=$null
    try {
        if ($stream.Length -gt 32MB -or $stream.Length -lt 8) {throw 'Invalid image byte length.'}
        $probe=[Drawing.Image]::FromStream($stream,$false,$false)
        if ([long]$probe.Width*$probe.Height -gt 100000000 -or $probe.Width -le 0 -or $probe.Height -le 0) {throw 'Invalid or excessive image dimensions.'}
        $allowed=@([Drawing.Imaging.ImageFormat]::Png.Guid,[Drawing.Imaging.ImageFormat]::Jpeg.Guid,[Drawing.Imaging.ImageFormat]::Gif.Guid,[Drawing.Imaging.ImageFormat]::Bmp.Guid,[Drawing.Imaging.ImageFormat]::Tiff.Guid)
        if ($probe.RawFormat.Guid -notin $allowed) {throw 'Unsupported raster encoding.'}
        $probe.Dispose();$probe=$null;$stream.Position=0
        $validated=[Drawing.Image]::FromStream($stream,$false,$true)
        return $true
    } catch {throw "Invalid or incomplete image asset: $($_.Exception.Message)"}
    finally {if ($null -ne $probe){$probe.Dispose()};if($null -ne $validated){$validated.Dispose()};$stream.Dispose()}
}

function Set-HwpxObjectOptions {
    param([string]$Xml,[object]$Block,[int]$Width,[int]$Height)
    $doc=[Xml.XmlDocument]::new();$doc.XmlResolver=$null
    $doc.LoadXml('<root xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core">'+$Xml+'</root>')
    $node=$doc.DocumentElement.FirstChild
    $placement=Get-HwpPlanValue $Block 'placement'
    $node.SetAttribute('textWrap',[string](Get-HwpPlanValue $placement 'textWrap' 'TOP_AND_BOTTOM'))
    $pos=$node.SelectSingleNode("*[local-name()='pos']")
    $pos.SetAttribute('treatAsChar',[string][int][bool](Get-HwpPlanValue $placement 'treatAsChar' $true))
    foreach ($pair in @(@('horzAlign','horizontalAlignment','LEFT'),@('vertAlign','verticalAlignment','TOP'),@('horzRelTo','horizontalRelativeTo','COLUMN'),@('vertRelTo','verticalRelativeTo','PARA'))) {
        $pos.SetAttribute($pair[0],[string](Get-HwpPlanValue $placement $pair[1] $pair[2]))
    }
    $pos.SetAttribute('horzOffset',[string][int][Math]::Round((Get-HwpPlanValue $placement 'horizontalOffsetMm' 0)*283.4645669))
    $pos.SetAttribute('vertOffset',[string][int][Math]::Round((Get-HwpPlanValue $placement 'verticalOffsetMm' 0)*283.4645669))
    $angle=Get-HwpPlanValue $Block 'rotation' 0
    $rotation=$node.SelectSingleNode("*[local-name()='rotationInfo']");$rotation.SetAttribute('angle',[string]$angle)
    $rad=$angle*[Math]::PI/180;$cos=[Math]::Cos($rad);$sin=[Math]::Sin($rad)
    $cx=$Width/2;$cy=$Height/2
    $matrix=$node.SelectSingleNode("*[local-name()='renderingInfo']/*[local-name()='rotMatrix']")
    $values=@($cos,-$sin,($cx-$cos*$cx+$sin*$cy),$sin,$cos,($cy-$sin*$cx-$cos*$cy))
    for ($i=0;$i -lt 6;$i++) {$matrix.SetAttribute(('e'+($i+1)),([double]$values[$i]).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture))}
    $flip=$node.SelectSingleNode("*[local-name()='flip']")
    $flip.SetAttribute('horizontal',[string][int][bool](Get-HwpPlanValue $Block 'flipHorizontal' $false))
    $flip.SetAttribute('vertical',[string][int][bool](Get-HwpPlanValue $Block 'flipVertical' $false))
    $clip=$node.SelectSingleNode("*[local-name()='imgClip']")
    if ($null -ne $clip) {
        $crop=Get-HwpPlanValue $Block 'crop'
        $clip.SetAttribute('left',[string][int][Math]::Round($Width*(Get-HwpPlanValue $crop 'left' 0)))
        $clip.SetAttribute('right',[string][int][Math]::Round($Width*(1-(Get-HwpPlanValue $crop 'right' 0))))
        $clip.SetAttribute('top',[string][int][Math]::Round($Height*(Get-HwpPlanValue $crop 'top' 0)))
        $clip.SetAttribute('bottom',[string][int][Math]::Round($Height*(1-(Get-HwpPlanValue $crop 'bottom' 0))))
    }
    if ($null -ne $Block.PSObject.Properties['altText']) {$node.SelectSingleNode("*[local-name()='shapeComment']").InnerText=[string]$Block.altText}
    $node.OuterXml
}

function New-HwpxBasicShapeXml {
    param([object]$Block,[int]$Id)
    $w=[int][Math]::Round($Block.widthMm*283.4645669);$h=[int][Math]::Round($Block.heightMm*283.4645669)
    $cx=[int]($w/2);$cy=[int]($h/2)
    $tag=switch ($Block.shape) {'rectangle' {'rect'};'text-box' {'rect'};'ellipse' {'ellipse'};'line' {'line'}}
    $extra=switch ($tag) {'rect' {'ratio="0"'};'ellipse' {'intervalDirty="0" hasArcPr="0" arcType="NORMAL"'};'line' {'isReverseHV="0"'}}
    $geometry=switch ($tag) {
        'rect' {"<hc:pt0 x=`"0`" y=`"0`"/><hc:pt1 x=`"$w`" y=`"0`"/><hc:pt2 x=`"$w`" y=`"$h`"/><hc:pt3 x=`"0`" y=`"$h`"/>"}
        'ellipse' {"<hc:center x=`"$cx`" y=`"$cy`"/><hc:ax1 x=`"$w`" y=`"$cy`"/><hc:ax2 x=`"$cx`" y=`"$h`"/><hc:start1 x=`"0`" y=`"0`"/><hc:start2 x=`"0`" y=`"0`"/><hc:end1 x=`"0`" y=`"0`"/><hc:end2 x=`"0`" y=`"0`"/>"}
        'line' {"<hc:startPt x=`"0`" y=`"0`"/><hc:endPt x=`"$w`" y=`"$h`"/>"}
    }
    $style=Get-HwpPlanValue $Block 'style'
    $color=Get-HwpPlanValue $style 'borderColor' '#000000';$line=Get-HwpPlanValue $style 'borderType' 'SOLID'
    $stroke=[int][Math]::Round((Get-HwpPlanValue $style 'borderWidthMm' 0.12)*283.4645669)
    $fill=Get-HwpPlanValue $style 'fillColor' 'none'
    $fillXml=if ($fill -ne 'none') {"<hc:fillBrush><hc:winBrush faceColor=`"$fill`" hatchColor=`"#000000`" alpha=`"0`"/></hc:fillBrush>"} else {''}
    $textXml=''
    if ($null -ne $Block.PSObject.Properties['text']) {
        $text=[Security.SecurityElement]::Escape([string]$Block.text)
        $text=[regex]::Replace($text,"\r\n|\r|\n",'<hp:lineBreak/>').Replace("`t",'<hp:tab width="0" leader="0" type="0"/>')
        $char=Get-HwpPlanValue $Block '__charPrId' 0;$para=Get-HwpPlanValue $Block '__paraPrId' 0
        $textXml="<hp:drawText lastWidth=`"$w`" name=`"`" editable=`"1`"><hp:textMargin left=`"283`" right=`"283`" top=`"283`" bottom=`"283`"/><hp:subList id=`"`" textDirection=`"HORIZONTAL`" lineWrap=`"BREAK`" vertAlign=`"CENTER`" linkListIDRef=`"0`" linkListNextIDRef=`"0`" textWidth=`"0`" textHeight=`"0`" hasTextRef=`"0`" hasNumRef=`"0`"><hp:p id=`"0`" paraPrIDRef=`"$para`" styleIDRef=`"0`" pageBreak=`"0`" columnBreak=`"0`" merged=`"0`"><hp:run charPrIDRef=`"$char`"><hp:t>$text</hp:t></hp:run></hp:p></hp:subList></hp:drawText>"
    }
    $xml="<hp:$tag id=`"$Id`" zOrder=`"0`" numberingType=`"PICTURE`" textWrap=`"TOP_AND_BOTTOM`" textFlow=`"BOTH_SIDES`" lock=`"0`" dropcapstyle=`"None`" href=`"`" groupLevel=`"0`" instid=`"$Id`" $extra><hp:offset x=`"0`" y=`"0`"/><hp:orgSz width=`"$w`" height=`"$h`"/><hp:curSz width=`"$w`" height=`"$h`"/><hp:flip horizontal=`"0`" vertical=`"0`"/><hp:rotationInfo angle=`"0`" centerX=`"$cx`" centerY=`"$cy`" rotateimage=`"1`"/><hp:renderingInfo><hc:transMatrix e1=`"1`" e2=`"0`" e3=`"0`" e4=`"0`" e5=`"1`" e6=`"0`"/><hc:scaMatrix e1=`"1`" e2=`"0`" e3=`"0`" e4=`"0`" e5=`"1`" e6=`"0`"/><hc:rotMatrix e1=`"1`" e2=`"0`" e3=`"0`" e4=`"0`" e5=`"1`" e6=`"0`"/></hp:renderingInfo><hp:lineShape color=`"$color`" width=`"$stroke`" style=`"$line`" endCap=`"FLAT`" headStyle=`"NORMAL`" tailStyle=`"NORMAL`" headfill=`"1`" tailfill=`"1`" headSz=`"SMALL_SMALL`" tailSz=`"SMALL_SMALL`" outlineStyle=`"NORMAL`" alpha=`"0`"/>$fillXml$textXml$geometry<hp:sz width=`"$w`" widthRelTo=`"ABSOLUTE`" height=`"$h`" heightRelTo=`"ABSOLUTE`" protect=`"0`"/><hp:pos treatAsChar=`"1`" affectLSpacing=`"0`" flowWithText=`"1`" allowOverlap=`"0`" holdAnchorAndSO=`"0`" vertRelTo=`"PARA`" horzRelTo=`"COLUMN`" vertAlign=`"TOP`" horzAlign=`"LEFT`" vertOffset=`"0`" horzOffset=`"0`"/><hp:outMargin left=`"0`" right=`"0`" top=`"0`" bottom=`"0`"/><hp:shapeComment/></hp:$tag>"
    Set-HwpxObjectOptions -Xml $xml -Block $Block -Width $w -Height $h
}

Export-ModuleMember -Function @('Get-HwpxRasterSize','Test-HwpxRasterIntegrity','Set-HwpxObjectOptions','New-HwpxBasicShapeXml')
