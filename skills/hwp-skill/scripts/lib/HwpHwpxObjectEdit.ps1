# Private prepared replacement; dot-source inside HwpHwpxScopedEdit.psm1.
# Caller resolves the source-bound address, registers subtree conflicts, and clears
# paragraph caches after installing the returned detached node. No package writes.
# Allocation.ObjectFormatCharacters reserves at most 16 MiB cloned XML characters;
# a failed operation never reserves budget or modifies the original tree.
# Enum spellings: hancom-io/hwpx-owpml-model, commit
# 1453388472c703a4b299a0834f425cdac16644b9, OWPML/Class/enumdef.h.
# Geometry is limited to the local HwpHwpxObjects.psm1 generator's coordinate frame;
# this is structural editing, not evidence of native Hancom layout/rendering.

function Get-ScopedObjectPoints {
    param([string]$Kind,[int]$Width,[int]$Height)
    $cx=[int][Math]::Round($Width/2.0);$cy=[int][Math]::Round($Height/2.0)
    $points=switch -CaseSensitive ($Kind) {
        {$_ -cin @('pic','rect')} { @(@('pt0',0,0),@('pt1',$Width,0),@('pt2',$Width,$Height),@('pt3',0,$Height)) }
        'ellipse' { @(@('center',$cx,$cy),@('ax1',$Width,$cy),@('ax2',$cx,$Height),@('start1',0,0),@('start2',0,0),@('end1',0,0),@('end2',0,0)) }
        'line' { @(@('startPt',0,0),@('endPt',$Width,$Height)) }
    }
    foreach($point in $points){[pscustomobject]@{Name=$point[0];X=$point[1];Y=$point[2]}}
}

function Get-ScopedObjectRotationMatrix {
    param([int]$Angle,[double]$CenterX,[double]$CenterY)
    $r=$Angle*[Math]::PI/180.0;$c=[Math]::Cos($r);$s=[Math]::Sin($r)
    return @($c,(-$s),($CenterX-$c*$CenterX+$s*$CenterY),$s,$c,($CenterY-$s*$CenterX-$c*$CenterY))
}

function Get-ScopedObjectCenterCoordinate {
    param([string]$Kind,[int]$Length)
    # New-HwpxPictureXml uses floor; New-HwpxBasicShapeXml uses PS integer rounding.
    if($Kind -ceq 'pic'){return [int][Math]::Floor($Length/2.0)}
    return [int][Math]::Round($Length/2.0)
}

function Assert-ScopedObjectMatrix {
    param([Xml.XmlElement]$Node,[double[]]$Expected)
    if($Node.SelectNodes('*').Count -ne 0){throw 'Nested matrix transforms are not established.'}
    for($i=0;$i -lt 6;$i++){
        [double]$number=0
        if(-not [double]::TryParse($Node.GetAttribute('e'+($i+1)),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or
            [double]::IsNaN($number) -or [double]::IsInfinity($number) -or [Math]::Abs($number-$Expected[$i]) -gt 0.00000002){
            throw "Unproven $($Node.LocalName) transform."
        }
    }
}

function Get-ScopedObjectFrame {
    param([Xml.XmlElement]$Node)
    $org=Get-ScopedOneChild $Node 'hp:orgSz';$cur=Get-ScopedOneChild $Node 'hp:curSz';$sz=Get-ScopedOneChild $Node 'hp:sz'
    $w=Get-ScopedXmlInteger $org 'width' 1;$h=Get-ScopedXmlInteger $org 'height' 1
    foreach($size in @($cur,$sz)){
        if((Get-ScopedXmlInteger $size 'width' 1) -ne $w -or (Get-ScopedXmlInteger $size 'height' 1) -ne $h){throw 'Unproven original/current/display size mapping.'}
    }
    if($sz.GetAttribute('widthRelTo') -cne 'ABSOLUTE' -or $sz.GetAttribute('heightRelTo') -cne 'ABSOLUTE'){throw 'Relative size transforms are not supported.'}
    $offset=Get-ScopedOneChild $Node 'hp:offset'
    if((Get-ScopedXmlInteger $offset 'x') -ne 0 -or (Get-ScopedXmlInteger $offset 'y') -ne 0){throw 'Nonzero local object offsets require a separate transform editor.'}
    $rotation=Get-ScopedOneChild $Node 'hp:rotationInfo'
    $angle=Get-ScopedXmlInteger $rotation 'angle' 0 359
    $cx=Get-ScopedXmlInteger $rotation 'centerX';$cy=Get-ScopedXmlInteger $rotation 'centerY'
    if($cx -ne (Get-ScopedObjectCenterCoordinate $Node.LocalName $w) -or $cy -ne (Get-ScopedObjectCenterCoordinate $Node.LocalName $h) -or $rotation.GetAttribute('rotateimage') -cnotin @('1','true')){throw 'Unproven rotation center or rotateimage mode.'}
    # The generator uses half extents for the matrix and integral center attributes.
    if($angle -ne 0 -and ($w%2 -ne 0 -or $h%2 -ne 0)){throw 'Fractional rotation centers are not established.'}
    $render=Get-ScopedOneChild $Node 'hp:renderingInfo'
    if($render.SelectNodes('*').Count -ne 3){throw 'Additional rendering transforms are not established.'}
    Assert-ScopedObjectMatrix (Get-ScopedOneChild $render 'hc:transMatrix') @(1,0,0,0,1,0)
    Assert-ScopedObjectMatrix (Get-ScopedOneChild $render 'hc:scaMatrix') @(1,0,0,0,1,0)
    Assert-ScopedObjectMatrix (Get-ScopedOneChild $render 'hc:rotMatrix') (Get-ScopedObjectRotationMatrix $angle ($w/2.0) ($h/2.0))
    $flip=Get-ScopedOneChild $Node 'hp:flip'
    foreach($axis in @('horizontal','vertical')){if($flip.GetAttribute($axis) -cnotin @('0','1','false','true')){throw 'Invalid saved flip flag.'}}
    $geometry=$Node
    switch -CaseSensitive ($Node.LocalName){
        'pic' {
            if($Node.GetAttribute('reverse') -cne '0'){throw 'Reversed pictures require a separate transform editor.'}
            $geometry=Get-ScopedOneChild $Node 'hp:imgRect'
            $dim=Get-ScopedOneChild $Node 'hp:imgDim'
            if((Get-ScopedXmlInteger $dim 'dimwidth' 1) -ne $w -or (Get-ScopedXmlInteger $dim 'dimheight' 1) -ne $h){throw 'Unproven image dimension coordinate space.'}
            $margin=Get-ScopedOneChild $Node 'hp:inMargin'
            foreach($edge in @('left','right','top','bottom')){if((Get-ScopedXmlInteger $margin $edge) -ne 0){throw 'Image inner margins require a separate transform editor.'}}
            $effects=Get-ScopedOneChild $Node 'hp:effects'
            if($effects.SelectNodes('*').Count -ne 0){throw 'Picture effects require a separate transform editor.'}
        }
        'rect' {if($Node.GetAttribute('ratio') -cne '0'){throw 'Rounded rectangles require a separate transform editor.'}}
        'ellipse' {if($Node.GetAttribute('hasArcPr') -cnotin @('0','false') -or $Node.GetAttribute('arcType') -cne 'NORMAL'){throw 'Ellipse arcs require a separate transform editor.'}}
        'line' {if($Node.GetAttribute('isReverseHV') -cnotin @('0','false')){throw 'Reversed lines require a separate transform editor.'}}
    }
    foreach($point in @(Get-ScopedObjectPoints $Node.LocalName $w $h)){
        $child=Get-ScopedOneChild $geometry ('hc:'+$point.Name)
        if((Get-ScopedXmlInteger $child 'x') -ne $point.X -or (Get-ScopedXmlInteger $child 'y') -ne $point.Y){throw 'Unproven basic geometry coordinates.'}
    }
    $clip=$null
    if($Node.LocalName -ceq 'pic'){
        $clip=Get-ScopedOneChild $Node 'hp:imgClip'
        $l=Get-ScopedXmlInteger $clip 'left' 0 $w;$r=Get-ScopedXmlInteger $clip 'right' 0 $w
        $t=Get-ScopedXmlInteger $clip 'top' 0 $h;$b=Get-ScopedXmlInteger $clip 'bottom' 0 $h
        if($l -ge $r -or $t -ge $b){throw 'Saved crop must have a positive area.'}
    }
    return @{Width=$w;Height=$h;Angle=$angle;Rotation=$rotation;Flip=$flip;Geometry=$geometry;Clip=$clip;Render=$render}
}

function New-ScopedObjectFormat {
    param([Xml.XmlElement]$Target,$Operation,$Package,$Allocation)
    try {
        $op=ConvertTo-ScopedMap $Operation 'objectFormat'
        $options=@('placement','textWrap','altText','rotation','flipHorizontal','flipVertical','widthMm','heightMm','crop')
        Assert-ScopedKeys $op @('type','address') 'objectFormat' $options
        if($op['type'] -isnot [string] -or $op['type'] -cne 'set-object-format'){throw 'Expected set-object-format.'}
        if(@($op.Keys|Where-Object {$_ -cin $options}).Count -eq 0){throw 'At least one explicit property is required.'}
        if($null -eq $Target -or $Target.NamespaceURI -cne $script:ScopedHp -or $Target.LocalName -cnotin @('pic','rect','ellipse','line')){throw 'Target must be hp:pic, hp:rect, hp:ellipse or hp:line.'}
        $address=ConvertTo-ScopedMap $op['address'] 'objectFormat.address'
        if(-not $address.ContainsKey('kind') -or $address['kind'] -isnot [string] -or $address['kind'] -cne $Target.LocalName){throw 'Address kind does not match the resolved object.'}
        $attached=$false
        foreach($part in $Package.Sections){if([object]::ReferenceEquals($Package.Xml[$part],$Target.OwnerDocument)){$attached=$true}}
        if(-not $attached -or $Target.ParentNode -isnot [Xml.XmlElement]){throw 'Target must be attached to an original package section.'}
        $root=$Target
        while($root.ParentNode -is [Xml.XmlElement]){$root=$root.ParentNode}
        if(-not [object]::ReferenceEquals($root,$Target.OwnerDocument.DocumentElement)){throw 'Detached object branches are not editable.'}
        # Validate the parent so old shared-context code need not recognize new leaf kinds.
        Assert-ScopedEditContext $Target.ParentNode
        if($Target.HasAttribute('groupLevel') -and $Target.GetAttribute('groupLevel') -cne '0'){throw 'Grouped objects are not supported.'}
        $current=$Target
        while($current -is [Xml.XmlElement]){
            foreach($flag in @('lock','protect')){if($current.HasAttribute($flag) -and $current.GetAttribute($flag) -cnotin @('0','false')){throw 'Locked or protected objects are not editable.'}}
            $current=$current.ParentNode
        }
        $sz=Get-ScopedOneChild $Target 'hp:sz'
        if($sz.HasAttribute('protect') -and $sz.GetAttribute('protect') -cnotin @('0','false')){throw 'Protected object size is not editable.'}
        $copy=$Target.CloneNode($true)
        $placement=$null
        if($op.ContainsKey('placement')){
            $placement=ConvertTo-ScopedMap $op['placement'] 'objectFormat.placement'
            Assert-ScopedKeys $placement @() 'objectFormat.placement' @('treatAsChar','horizontalAlignment','verticalAlignment','horizontalRelativeTo','verticalRelativeTo','horizontalOffsetMm','verticalOffsetMm','textWrap')
            if($placement.Count -eq 0){throw 'placement cannot be empty.'}
            $pos=Get-ScopedOneChild $copy 'hp:pos'
            foreach($key in $placement.Keys){
                $value=$placement[$key]
                switch -CaseSensitive ($key){
                    'treatAsChar' {if($value -isnot [bool]){throw 'treatAsChar must be Boolean.'};$pos.SetAttribute('treatAsChar',[string][int]$value)}
                    'horizontalOffsetMm' {$pos.SetAttribute('horzOffset',[string](ConvertTo-ScopedMm $value $key -Signed))}
                    'verticalOffsetMm' {$pos.SetAttribute('vertOffset',[string](ConvertTo-ScopedMm $value $key -Signed))}
                    'textWrap' {if($op.ContainsKey('textWrap')){throw 'textWrap cannot be specified twice.'}}
                    default {
                        $attribute,$allowed=switch -CaseSensitive ($key){
                            'horizontalAlignment' {'horzAlign';,@('LEFT','CENTER','RIGHT','INSIDE','OUTSIDE')}
                            'verticalAlignment' {'vertAlign';,@('TOP','CENTER','BOTTOM','INSIDE','OUTSIDE')}
                            'horizontalRelativeTo' {'horzRelTo';,@('PAPER','PAGE','COLUMN','PARA')}
                            'verticalRelativeTo' {'vertRelTo';,@('PAPER','PAGE','PARA')}
                        }
                        if($value -isnot [string] -or $allowed -cnotcontains $value){throw "Invalid placement.$key enum."}
                        $pos.SetAttribute($attribute,$value)
                    }
                }
            }
        }
        $hasWrap=$op.ContainsKey('textWrap') -or ($null -ne $placement -and $placement.ContainsKey('textWrap'))
        if($hasWrap){
            $wrap=if($op.ContainsKey('textWrap')){$op['textWrap']}else{$placement['textWrap']}
            if($wrap -isnot [string] -or $wrap -cnotin @('SQUARE','TOP_AND_BOTTOM','BEHIND_TEXT','IN_FRONT_OF_TEXT')){throw 'Invalid textWrap enum.'}
            $copy.SetAttribute('textWrap',$wrap)
        }
        if($op.ContainsKey('altText')){
            $text=$op['altText']
            if($text -isnot [string] -or $text.Length -gt 1MB){throw 'altText must be a string of at most 1 MiB characters.'}
            $null=[Xml.XmlConvert]::VerifyXmlChars($text)
            $comment=Get-ScopedOneChild $copy 'hp:shapeComment'
            foreach($child in $comment.ChildNodes){if($child.NodeType -notin @('Text','CDATA','Whitespace','SignificantWhitespace')){throw 'Structured shapeComment content cannot be replaced.'}}
            $comment.InnerText=$text
        }
        $hasSize=$op.ContainsKey('widthMm') -or $op.ContainsKey('heightMm')
        $hasTransform=$hasSize -or $op.ContainsKey('crop') -or $op.ContainsKey('rotation') -or $op.ContainsKey('flipHorizontal') -or $op.ContainsKey('flipVertical')
        if($hasTransform){
            $frame=Get-ScopedObjectFrame $copy
            $w=$frame.Width;$h=$frame.Height
            if($hasSize){
                if($frame.Angle -ne 0 -or $frame.Flip.GetAttribute('horizontal') -cnotin @('0','false') -or $frame.Flip.GetAttribute('vertical') -cnotin @('0','false')){throw 'Resize requires an unrotated, unflipped frame.'}
                if($copy.SelectNodes('hp:drawText',(New-ScopedNamespaces $copy.OwnerDocument)).Count -gt 0){throw 'Text box resizing requires text layout geometry not established here.'}
                if($op.ContainsKey('widthMm')){$w=ConvertTo-ScopedMm $op['widthMm'] 'widthMm'}
                if($op.ContainsKey('heightMm')){$h=ConvertTo-ScopedMm $op['heightMm'] 'heightMm'}
                if($w -lt 1 -or $h -lt 1){throw 'Dimensions must round to positive HWPUNIT values.'}
                foreach($name in @('orgSz','curSz','sz')){$size=Get-ScopedOneChild $copy ('hp:'+$name);$size.SetAttribute('width',[string]$w);$size.SetAttribute('height',[string]$h)}
                foreach($point in @(Get-ScopedObjectPoints $copy.LocalName $w $h)){$child=Get-ScopedOneChild $frame.Geometry ('hc:'+$point.Name);$child.SetAttribute('x',[string]$point.X);$child.SetAttribute('y',[string]$point.Y)}
                $frame.Rotation.SetAttribute('centerX',[string](Get-ScopedObjectCenterCoordinate $copy.LocalName $w));$frame.Rotation.SetAttribute('centerY',[string](Get-ScopedObjectCenterCoordinate $copy.LocalName $h))
                if($copy.LocalName -ceq 'pic'){$dim=Get-ScopedOneChild $copy 'hp:imgDim';$dim.SetAttribute('dimwidth',[string]$w);$dim.SetAttribute('dimheight',[string]$h)}
            }
            if($op.ContainsKey('crop') -or ($hasSize -and $copy.LocalName -ceq 'pic')){
                if($copy.LocalName -cne 'pic'){throw 'crop requires a picture target.'}
                $clip=$frame.Clip
                $ratios=@{left=([double](Get-ScopedXmlInteger $clip 'left')/$frame.Width);right=(1-[double](Get-ScopedXmlInteger $clip 'right')/$frame.Width);top=([double](Get-ScopedXmlInteger $clip 'top')/$frame.Height);bottom=(1-[double](Get-ScopedXmlInteger $clip 'bottom')/$frame.Height)}
                if($op.ContainsKey('crop')){
                    $crop=ConvertTo-ScopedMap $op['crop'] 'objectFormat.crop';Assert-ScopedKeys $crop @() 'objectFormat.crop' @('left','right','top','bottom')
                    if($crop.Count -eq 0){throw 'crop cannot be empty.'}
                    foreach($edge in $crop.Keys){$ratio=Get-ScopedNumber $crop[$edge] 0 1 ('crop.'+$edge);if($ratio -ge 1){throw 'Each crop ratio must be less than one.'};$ratios[$edge]=$ratio}
                }
                if($ratios.left+$ratios.right -ge 1 -or $ratios.top+$ratios.bottom -ge 1){throw 'Crop must leave positive area.'}
                $edges=@{left=[int][Math]::Round($w*$ratios.left);right=[int][Math]::Round($w*(1-$ratios.right));top=[int][Math]::Round($h*$ratios.top);bottom=[int][Math]::Round($h*(1-$ratios.bottom))}
                if($edges.left -ge $edges.right -or $edges.top -ge $edges.bottom){throw 'Crop rounds to an empty area.'}
                foreach($edge in $edges.Keys){$clip.SetAttribute($edge,[string]$edges[$edge])}
            }
            if($op.ContainsKey('rotation')){
                $angle=$op['rotation']
                if(-not (Test-ScopedInteger $angle) -or $angle -lt 0 -or $angle -gt 359){throw 'rotation must be an integer from 0 to 359.'}
                if($angle -ne 0 -and ($w%2 -ne 0 -or $h%2 -ne 0)){throw 'Fractional rotation centers are not established.'}
                $frame.Rotation.SetAttribute('angle',[string]$angle)
                $matrix=Get-ScopedOneChild $frame.Render 'hc:rotMatrix';$values=Get-ScopedObjectRotationMatrix $angle ($w/2.0) ($h/2.0)
                for($i=0;$i -lt 6;$i++){$matrix.SetAttribute('e'+($i+1),([double]$values[$i]).ToString('0.########',[Globalization.CultureInfo]::InvariantCulture))}
            }
            foreach($pair in @(@('flipHorizontal','horizontal'),@('flipVertical','vertical'))){
                if($op.ContainsKey($pair[0])){if($op[$pair[0]] -isnot [bool]){throw "$($pair[0]) must be Boolean."};$frame.Flip.SetAttribute($pair[1],[string][int]$op[$pair[0]])}
            }
        }
        [long]$prepared=0
        if($Allocation.ContainsKey('ObjectFormatCharacters')){
            $value=$Allocation['ObjectFormatCharacters']
            if(-not (Test-ScopedInteger $value) -or $value -lt 0 -or $value -gt 16MB){throw 'Invalid prepared object character budget.'}
            $prepared=[long]$value
        }
        $prepared+=$copy.OuterXml.Length
        if($prepared -gt 16MB){throw 'Cumulative prepared object XML exceeds 16 MiB characters.'}
        $Allocation['ObjectFormatCharacters']=$prepared
        return ,$copy
    } catch { throw "Object format: $($_.Exception.Message)" }
}
