# Independent literal geometry; never use the object generator as the XML oracle.
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
$script:OeModule = Get-Module HwpHwpxScopedEdit
$script:OeHelper = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxObjectEdit.ps1'
$script:OeTemplate = Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx'

function New-OeFixture([string]$Kind = 'pic') {
    $package = & $script:OeModule {
        param($Path)
        $stream = [IO.File]::OpenRead($Path)
        try { Read-ScopedPackage $stream } finally { $stream.Dispose() }
    } $script:OeTemplate
    $xml = $package.Xml[$package.Sections[0]]
    $geometry = switch ($Kind) {
        'pic' { '<hc:img binaryItemIDRef="object-image" bright="7" contrast="2" effect="REAL_PIC" alpha="0"/><hp:imgRect><hc:pt0 x="0" y="0"/><hc:pt1 x="7200" y="0"/><hc:pt2 x="7200" y="3600"/><hc:pt3 x="0" y="3600"/></hp:imgRect><hp:imgClip left="720" right="6480" top="0" bottom="3600"/><hp:inMargin left="0" right="0" top="0" bottom="0"/><hp:imgDim dimwidth="7200" dimheight="3600"/><hp:effects/>' }
        'rect' { '<hc:pt0 x="0" y="0"/><hc:pt1 x="7200" y="0"/><hc:pt2 x="7200" y="3600"/><hc:pt3 x="0" y="3600"/>' }
        'ellipse' { '<hc:center x="3600" y="1800"/><hc:ax1 x="7200" y="1800"/><hc:ax2 x="3600" y="3600"/><hc:start1 x="0" y="0"/><hc:start2 x="0" y="0"/><hc:end1 x="0" y="0"/><hc:end2 x="0" y="0"/>' }
        'line' { '<hc:startPt x="0" y="0"/><hc:endPt x="7200" y="3600"/>' }
    }
    $extra = switch ($Kind) { 'pic' {'reverse="0"'} 'rect' {'ratio="0"'} 'ellipse' {'intervalDirty="0" hasArcPr="0" arcType="NORMAL"'} 'line' {'isReverseHV="0"'} }
    $fragment = $xml.CreateDocumentFragment()
    $fragment.InnerXml = @"
<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" id="900" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:$Kind id="700" instid="701" zOrder="9" groupLevel="0" lock="0" textWrap="SQUARE" textFlow="BOTH_SIDES" href="https://example.invalid/retained" $extra><hp:offset x="0" y="0"/><hp:orgSz width="7200" height="3600"/><hp:curSz width="7200" height="3600"/><hp:flip horizontal="0" vertical="0"/><hp:rotationInfo angle="0" centerX="3600" centerY="1800" rotateimage="1"/><hp:renderingInfo><hc:transMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:scaMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/><hc:rotMatrix e1="1" e2="0" e3="0" e4="0" e5="1" e6="0"/></hp:renderingInfo><hp:lineShape color="#123456" width="34" style="SOLID"/>$geometry<hp:sz width="7200" height="3600" widthRelTo="ABSOLUTE" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="0" affectLSpacing="1" flowWithText="1" allowOverlap="0" holdAnchorAndSO="0" horzAlign="RIGHT" vertAlign="BOTTOM" horzRelTo="PAGE" vertRelTo="PAPER" horzOffset="1134" vertOffset="-567"/><hp:outMargin left="11" right="12" top="13" bottom="14"/><hp:shapeComment>Original &amp; retained</hp:shapeComment></hp:$Kind><hp:t>Sibling content</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>
"@
    $null = $xml.DocumentElement.AppendChild($fragment)
    $target = $xml.SelectSingleNode('//*[local-name()="'+$Kind+'" and @id="700"]')
    $package.Parts.Add('BinData/object-image.PNG',[pscustomobject]@{Bytes=[byte[]]@(137,80,78,71,0,255,1);LastWriteTime=[DateTimeOffset]::UtcNow;Attributes=0})
    $package.Order.Add('BinData/object-image.PNG')
    $hpf=$package.Xml['Contents/content.hpf'];$item=$hpf.CreateElement('opf','item','http://www.idpf.org/2007/opf/')
    $item.SetAttribute('id','object-image');$item.SetAttribute('href','BinData/object-image.PNG');$item.SetAttribute('media-type','image/png')
    $null=$hpf.SelectSingleNode('//*[local-name()="manifest"]').AppendChild($item)
    return @{Package=$package;Target=$target;Allocation=@{};Xml=$xml}
}
function Invoke-Oe($Fixture,$Values) {
    $operation=@{type='set-object-format';address=@{kind=$Fixture.Target.LocalName}}
    foreach($key in $Values.Keys){$operation[$key]=$Values[$key]}
    & $script:OeModule {
        param($Path,$Fixture,$Operation)
        if(Test-Path -LiteralPath $Path){. $Path}
        New-ScopedObjectFormat $Fixture.Target $Operation $Fixture.Package $Fixture.Allocation
    } $script:OeHelper $Fixture $operation
}
function Get-OeChild($Node,$Name){$Node.SelectSingleNode('*[local-name()="'+$Name+'"]')}
function Assert-OeBlocked($Fixture,$Values) {
    $allocation=$Fixture.Allocation|ConvertTo-Json -Compress -Depth 20
    $before=$Fixture.Xml.OuterXml
    $header=$Fixture.Package.Xml['Contents/header.xml'].OuterXml
    $manifest=$Fixture.Package.Xml['Contents/content.hpf'].OuterXml
    $binary=[Convert]::ToBase64String($Fixture.Package.Parts['BinData/object-image.PNG'].Bytes)
    $caught=$null
    try{$null=Invoke-Oe $Fixture $Values}catch{$caught=$_}
    $caught|Should Not BeNullOrEmpty
    # A missing helper or a parser/binder failure must never masquerade as validation.
    $caught.Exception.Message|Should Match '^Object format:'
    $Fixture.Xml.OuterXml|Should BeExactly $before
    $Fixture.Package.Xml['Contents/header.xml'].OuterXml|Should BeExactly $header
    $Fixture.Package.Xml['Contents/content.hpf'].OuterXml|Should BeExactly $manifest
    [Convert]::ToBase64String($Fixture.Package.Parts['BinData/object-image.PNG'].Bytes)|Should BeExactly $binary
    ($Fixture.Allocation|ConvertTo-Json -Compress -Depth 20)|Should BeExactly $allocation
}

Describe 'Private prepared object formatting using the real scoped editor module' {
    It 'returns one detached clone preserves the package and reserves only the clone character budget' {
        $f=New-OeFixture 'rect';$before=$f.Xml.OuterXml;$manifest=$f.Package.Xml['Contents/content.hpf'].OuterXml
        $hash=(Get-FileHash $script:OeTemplate).Hash
        $copy=Invoke-Oe $f @{altText='Edited <&> text'}
        $copy.GetType().FullName|Should Be 'System.Xml.XmlElement'
        $copy.ParentNode|Should BeNullOrEmpty
        [object]::ReferenceEquals($copy,$f.Target)|Should Be $false
        [object]::ReferenceEquals($copy.OwnerDocument,$f.Target.OwnerDocument)|Should Be $true
        $copy.GetAttribute('id')|Should Be '700';$copy.GetAttribute('instid')|Should Be '701'
        $copy.GetAttribute('zOrder')|Should Be '9';$copy.GetAttribute('href')|Should Be 'https://example.invalid/retained'
        (Get-OeChild $copy 'shapeComment').InnerText|Should Be 'Edited <&> text'
        $expected=$f.Target.CloneNode($true);(Get-OeChild $expected 'shapeComment').InnerText='Edited <&> text'
        $copy.OuterXml|Should BeExactly $expected.OuterXml
        $f.Xml.OuterXml|Should BeExactly $before;$f.Allocation.Count|Should Be 1
        $f.Allocation.ObjectFormatCharacters|Should Be $copy.OuterXml.Length
        $f.Package.Xml['Contents/content.hpf'].OuterXml|Should BeExactly $manifest
        [Convert]::ToBase64String($f.Package.Parts['BinData/object-image.PNG'].Bytes)|Should Be 'iVBORwD/AQ=='
        (Get-FileHash $script:OeTemplate).Hash|Should Be $hash
    }
    It 'supports placement on <Kind> without resetting omitted options' -TestCases @(@{Kind='pic'},@{Kind='rect'},@{Kind='ellipse'},@{Kind='line'}) {
        param($Kind)
        $f=New-OeFixture $Kind
        $copy=Invoke-Oe $f @{placement=@{horizontalOffsetMm=-25.4;verticalOffsetMm=12.7;horizontalAlignment='CENTER';verticalAlignment='TOP';horizontalRelativeTo='COLUMN';verticalRelativeTo='PARA'}}
        $pos=Get-OeChild $copy 'pos'
        $pos.GetAttribute('horzOffset')|Should Be '-7200';$pos.GetAttribute('vertOffset')|Should Be '3600'
        $pos.GetAttribute('horzAlign')|Should Be 'CENTER';$pos.GetAttribute('vertAlign')|Should Be 'TOP'
        $pos.GetAttribute('horzRelTo')|Should Be 'COLUMN';$pos.GetAttribute('vertRelTo')|Should Be 'PARA'
        $pos.GetAttribute('treatAsChar')|Should Be '0';$pos.GetAttribute('affectLSpacing')|Should Be '1'
        $copy.GetAttribute('textWrap')|Should Be 'SQUARE'
        (Get-OeChild $copy 'imgClip').OuterXml|Should Be ((Get-OeChild $f.Target 'imgClip').OuterXml)
    }
    It 'sets wrap and treatAsChar explicitly using generator-compatible placement keys' {
        $f=New-OeFixture
        $copy=Invoke-Oe $f @{placement=@{treatAsChar=$true;textWrap='TOP_AND_BOTTOM'}}
        (Get-OeChild $copy 'pos').GetAttribute('treatAsChar')|Should Be '1'
        $copy.GetAttribute('textWrap')|Should Be 'TOP_AND_BOTTOM'
        (Get-OeChild $copy 'pos').GetAttribute('horzAlign')|Should Be 'RIGHT'
        (Invoke-Oe $f @{textWrap='BEHIND_TEXT'}).GetAttribute('textWrap')|Should Be 'BEHIND_TEXT'
    }
    It 'updates rotation matrix around the proven center and flips only explicit flags' {
        $f=New-OeFixture
        $copy=Invoke-Oe $f @{rotation=90;flipHorizontal=$true}
        $rotation=Get-OeChild $copy 'rotationInfo';$rotation.GetAttribute('angle')|Should Be '90'
        $rotation.GetAttribute('centerX')|Should Be '3600';$rotation.GetAttribute('centerY')|Should Be '1800'
        $matrix=(Get-OeChild $copy 'renderingInfo').SelectSingleNode('*[local-name()="rotMatrix"]')
        @('e1','e2','e3','e4','e5','e6'|ForEach-Object {$matrix.GetAttribute($_)}) -join ','|Should Be '0,-1,5400,1,0,-1800'
        (Get-OeChild $copy 'flip').GetAttribute('horizontal')|Should Be '1'
        (Get-OeChild $copy 'flip').GetAttribute('vertical')|Should Be '0'
        # Editing the other flip must retain the first flip and the saved rotation.
        $null=$f.Target.ParentNode.ReplaceChild($copy,$f.Target);$f.Target=$copy
        $next=Invoke-Oe $f @{flipVertical=$true}
        (Get-OeChild $next 'rotationInfo').OuterXml|Should BeExactly $rotation.OuterXml
        (Get-OeChild $next 'flip').GetAttribute('horizontal')|Should Be '1'
        (Get-OeChild $next 'flip').GetAttribute('vertical')|Should Be '1'
    }
    It 'accepts the pinned model enum values including inside and outside alignment' {
        foreach($alignment in @('INSIDE','OUTSIDE')){
            $f=New-OeFixture
            $copy=Invoke-Oe $f @{placement=@{horizontalAlignment=$alignment;verticalAlignment=$alignment;horizontalRelativeTo='PARA';verticalRelativeTo='PAGE';textWrap='IN_FRONT_OF_TEXT'}}
            (Get-OeChild $copy 'pos').GetAttribute('horzAlign')|Should Be $alignment
            (Get-OeChild $copy 'pos').GetAttribute('vertAlign')|Should Be $alignment
            $copy.GetAttribute('textWrap')|Should Be 'IN_FRONT_OF_TEXT'
        }
    }
    It 'serializes and reopens the prepared subtree through the real shared XML reader' {
        $f=New-OeFixture
        $copy=Invoke-Oe $f @{rotation=270;flipVertical=$true;altText='XML <&> roundtrip'}
        $expected=$copy.OuterXml
        $null=$f.Target.ParentNode.ReplaceChild($copy,$f.Target)
        $reopened=& $script:OeModule {
            param($Xml)
            Read-ScopedXml (ConvertTo-ScopedXmlBytes $Xml) 'Contents/section0.xml'
        } $f.Xml
        $reopened.SelectSingleNode('//*[local-name()="pic" and @id="700"]').OuterXml|Should BeExactly $expected
        $reopened.SelectSingleNode('//*[local-name()="t" and text()="Sibling content"]').InnerText|Should Be 'Sibling content'
    }
    It 'changes partial crop ratios in original image coordinates and retains omitted edges' {
        $f=New-OeFixture
        $copy=Invoke-Oe $f @{crop=@{left=0.25;bottom=0.25}}
        $clip=Get-OeChild $copy 'imgClip'
        $clip.GetAttribute('left')|Should Be '1800';$clip.GetAttribute('right')|Should Be '6480'
        $clip.GetAttribute('top')|Should Be '0';$clip.GetAttribute('bottom')|Should Be '2700'
        (Get-OeChild $copy 'imgRect').OuterXml|Should BeExactly (Get-OeChild $f.Target 'imgRect').OuterXml
        (Get-OeChild $copy 'img').OuterXml|Should BeExactly (Get-OeChild $f.Target 'img').OuterXml
    }
    It 'resizes a canonical <Kind> with every dependent geometry coordinate updated' -TestCases @(@{Kind='pic'},@{Kind='rect'},@{Kind='ellipse'},@{Kind='line'}) {
        param($Kind)
        $f=New-OeFixture $Kind;$copy=Invoke-Oe $f @{widthMm=50.8;heightMm=25.4}
        foreach($name in @('orgSz','curSz','sz')){
            (Get-OeChild $copy $name).GetAttribute('width')|Should Be '14400'
            (Get-OeChild $copy $name).GetAttribute('height')|Should Be '7200'
        }
        (Get-OeChild $copy 'rotationInfo').GetAttribute('centerX')|Should Be '7200'
        (Get-OeChild $copy 'rotationInfo').GetAttribute('centerY')|Should Be '3600'
        switch($Kind){
            'pic' {
                $rect=Get-OeChild $copy 'imgRect';(Get-OeChild $rect 'pt2').GetAttribute('x')|Should Be '14400'
                (Get-OeChild $rect 'pt2').GetAttribute('y')|Should Be '7200'
                (Get-OeChild $copy 'imgDim').GetAttribute('dimwidth')|Should Be '14400'
                (Get-OeChild $copy 'imgClip').GetAttribute('left')|Should Be '1440'
                (Get-OeChild $copy 'imgClip').GetAttribute('right')|Should Be '12960'
            }
            'rect' {(Get-OeChild $copy 'pt2').GetAttribute('x')|Should Be '14400';(Get-OeChild $copy 'pt2').GetAttribute('y')|Should Be '7200'}
            'ellipse' {(Get-OeChild $copy 'center').GetAttribute('x')|Should Be '7200';(Get-OeChild $copy 'ax2').GetAttribute('y')|Should Be '7200'}
            'line' {(Get-OeChild $copy 'endPt').GetAttribute('x')|Should Be '14400';(Get-OeChild $copy 'endPt').GetAttribute('y')|Should Be '7200'}
        }
        (Get-OeChild $copy 'pos').OuterXml|Should BeExactly (Get-OeChild $f.Target 'pos').OuterXml
        (Get-OeChild $copy 'lineShape').OuterXml|Should BeExactly (Get-OeChild $f.Target 'lineShape').OuterXml
    }
    It 'resizes one dimension without resetting the other and applies crop after resizing' {
        $f=New-OeFixture
        $copy=Invoke-Oe $f @{widthMm=50.8;crop=@{right=0.25}}
        (Get-OeChild $copy 'sz').GetAttribute('height')|Should Be '3600'
        (Get-OeChild $copy 'imgClip').GetAttribute('left')|Should Be '1440'
        (Get-OeChild $copy 'imgClip').GetAttribute('right')|Should Be '10800'
    }
    It 'preserves shape text when only alt text or placement is edited' {
        $f=New-OeFixture 'rect';$text=$f.Xml.CreateElement('hp','drawText',$f.Target.NamespaceURI)
        $text.InnerXml='<hp:subList xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:p id="902"><hp:run charPrIDRef="0"><hp:t>Do not remove me</hp:t></hp:run></hp:p></hp:subList>'
        $null=$f.Target.AppendChild($text)
        $copy=Invoke-Oe $f @{altText=''}
        (Get-OeChild $copy 'drawText').OuterXml|Should BeExactly $text.OuterXml
        (Get-OeChild $copy 'shapeComment').InnerText|Should Be ''
    }
}

Describe 'Object format validation never mutates the original package' {
    It 'rejects invalid operation <Name>' -TestCases @(
        @{Name='empty';Values=@{}},@{Name='unknown';Values=@{unknown=1}},
        @{Name='NaN';Values=@{widthMm=[double]::NaN}},@{Name='infinity';Values=@{widthMm=[double]::PositiveInfinity}},
        @{Name='Boolean size';Values=@{widthMm=$true}},@{Name='string size';Values=@{widthMm='20'}},
        @{Name='null size';Values=@{widthMm=$null}},@{Name='zero size';Values=@{heightMm=0}},
        @{Name='tiny size';Values=@{heightMm=0.0001}},@{Name='large size';Values=@{widthMm=2001}},
        @{Name='negative size';Values=@{widthMm=-1}},@{Name='rotation fraction';Values=@{rotation=1.5}},
        @{Name='rotation bound';Values=@{rotation=360}},@{Name='rotation bool';Values=@{rotation=$true}},
        @{Name='flip integer';Values=@{flipHorizontal=1}},@{Name='flip string';Values=@{flipVertical='false'}},
        @{Name='alt bool';Values=@{altText=$true}},@{Name='alt null';Values=@{altText=$null}},
        @{Name='alt oversized';Values=@{altText=('x'*(1MB+1))}},@{Name='alt XML control';Values=@{altText="a$([char]1)b"}},
        @{Name='wrap case';Values=@{textWrap='square'}},@{Name='wrap unknown';Values=@{textWrap='INVALID'}},
        @{Name='wrap duplicate';Values=@{textWrap='SQUARE';placement=@{textWrap='SQUARE'}}},
        @{Name='placement empty';Values=@{placement=@{}}},@{Name='placement unknown';Values=@{placement=@{offset=0}}},
        @{Name='offset bool';Values=@{placement=@{horizontalOffsetMm=$false}}},
        @{Name='offset NaN';Values=@{placement=@{verticalOffsetMm=[double]::NaN}}},
        @{Name='offset bound';Values=@{placement=@{horizontalOffsetMm=-2001}}},
        @{Name='inline string';Values=@{placement=@{treatAsChar='true'}}},
        @{Name='alignment';Values=@{placement=@{horizontalAlignment='TOP'}}},
        @{Name='vertical alignment';Values=@{placement=@{verticalAlignment='RIGHT'}}},
        @{Name='horizontal relative';Values=@{placement=@{horizontalRelativeTo='CHAR'}}},
        @{Name='vertical relative';Values=@{placement=@{verticalRelativeTo='COLUMN'}}},
        @{Name='crop empty';Values=@{crop=@{}}},@{Name='crop unknown';Values=@{crop=@{x=0}}},
        @{Name='crop Boolean';Values=@{crop=@{left=$true}}},@{Name='crop NaN';Values=@{crop=@{left=[double]::NaN}}},
        @{Name='crop bounds';Values=@{crop=@{left=-0.1}}},@{Name='crop one';Values=@{crop=@{left=1}}},
        @{Name='crop empty area';Values=@{crop=@{left=0.9}}},@{Name='crop rounded empty';Values=@{crop=@{left=0.89999}}}
    ) {param($Name,$Values);Assert-OeBlocked (New-OeFixture) $Values}
    It 'blocks grouped locked protected or unknown targets' {
        foreach($change in @('group','lock','protect','namespace','kind','ancestor')){
            $f=New-OeFixture
            switch($change){
                'group' {$f.Target.SetAttribute('groupLevel','1')}
                'lock' {$f.Target.SetAttribute('lock','1')}
                'protect' {(Get-OeChild $f.Target 'sz').SetAttribute('protect','1')}
                'namespace' {$bad=$f.Xml.CreateElement('alien','pic','urn:alien');$null=$f.Target.ParentNode.ReplaceChild($bad,$f.Target);$f.Target=$bad}
                'kind' {$bad=$f.Xml.CreateElement('hp','polygon',$f.Target.NamespaceURI);$null=$f.Target.ParentNode.ReplaceChild($bad,$f.Target);$f.Target=$bad}
                'ancestor' {$group=$f.Xml.CreateElement('hp','container',$f.Target.NamespaceURI);$null=$f.Target.ParentNode.ReplaceChild($group,$f.Target);$null=$group.AppendChild($f.Target)}
            }
            Assert-OeBlocked $f @{altText='Blocked'}
        }
    }
    It 'blocks unproven transforms for rotation crop flips and size' {
        foreach($change in @('scale','translate','offset','curSize','relativeSize','pivot','matrix','reverse','pictureRect','imageDim')){
            foreach($values in @(@{rotation=90},@{widthMm=50.8},@{crop=@{left=0.2}},@{flipVertical=$true})){
                $f=New-OeFixture
                switch($change){
                    'scale' {((Get-OeChild $f.Target 'renderingInfo').FirstChild.NextSibling).SetAttribute('e1','2')}
                    'translate' {(Get-OeChild $f.Target 'renderingInfo').FirstChild.SetAttribute('e3','100')}
                    'offset' {(Get-OeChild $f.Target 'offset').SetAttribute('x','1')}
                    'curSize' {(Get-OeChild $f.Target 'curSz').SetAttribute('width','7000')}
                    'relativeSize' {(Get-OeChild $f.Target 'sz').SetAttribute('widthRelTo','PAGE')}
                    'pivot' {(Get-OeChild $f.Target 'rotationInfo').SetAttribute('centerX','0')}
                    'matrix' {(Get-OeChild $f.Target 'renderingInfo').LastChild.SetAttribute('e2','NaN')}
                    'reverse' {$f.Target.SetAttribute('reverse','1')}
                    'pictureRect' {(Get-OeChild (Get-OeChild $f.Target 'imgRect') 'pt1').SetAttribute('y','10')}
                    'imageDim' {(Get-OeChild $f.Target 'imgDim').SetAttribute('dimwidth','9000')}
                }
                Assert-OeBlocked $f $values
            }
        }
    }
    It 'rejects a detached branch even when its OwnerDocument belongs to the package' {
        $f=New-OeFixture;$parent=$f.Target.ParentNode;$null=$parent.RemoveChild($f.Target)
        $detached=$f.Xml.CreateElement('hp','run',$f.Target.NamespaceURI);$null=$detached.AppendChild($f.Target)
        Assert-OeBlocked $f @{altText='Must remain blocked'}
    }
    It 'rejects additional transform nodes rather than assuming the known matrices are exhaustive' {
        $f=New-OeFixture;$render=Get-OeChild $f.Target 'renderingInfo'
        $null=$render.AppendChild($f.Xml.CreateElement('hc','skewMatrix','http://www.hancom.co.kr/hwpml/2011/core'))
        Assert-OeBlocked $f @{rotation=90}
    }
    It 'allows placement and alt text to preserve an otherwise unproven transform verbatim' {
        $f=New-OeFixture;(Get-OeChild $f.Target 'renderingInfo').FirstChild.SetAttribute('e3','123')
        $copy=Invoke-Oe $f @{altText='Safe metadata';placement=@{verticalOffsetMm=0}}
        (Get-OeChild $copy 'renderingInfo').OuterXml|Should BeExactly (Get-OeChild $f.Target 'renderingInfo').OuterXml
    }
    It 'blocks missing or duplicate touched nodes and preserves structured comments' {
        foreach($change in @('missing','duplicate','structured')){
            $f=New-OeFixture;$node=Get-OeChild $f.Target 'shapeComment'
            switch($change){'missing' {$null=$f.Target.RemoveChild($node)} 'duplicate' {$null=$f.Target.AppendChild($node.CloneNode($true))} 'structured' {$node.InnerXml='<foreign xmlns="urn:retain">Retain</foreign>'}}
            Assert-OeBlocked $f @{altText='Unsafe replacement'}
        }
    }
    It 'blocks shape crops noncanonical paths text-box resizing and transformed resizing' {
        foreach($kind in @('rect','ellipse','line')){Assert-OeBlocked (New-OeFixture $kind) @{crop=@{left=0.1}}}
        $f=New-OeFixture 'line';(Get-OeChild $f.Target 'endPt').SetAttribute('x','0');Assert-OeBlocked $f @{widthMm=50.8}
        $f=New-OeFixture 'rect';$null=$f.Target.AppendChild($f.Xml.CreateElement('hp','drawText',$f.Target.NamespaceURI));Assert-OeBlocked $f @{widthMm=50.8}
        $f=New-OeFixture;$copy=Invoke-Oe $f @{rotation=90};$null=$f.Target.ParentNode.ReplaceChild($copy,$f.Target);$f.Target=$copy
        Assert-OeBlocked $f @{widthMm=50.8}
        $f=New-OeFixture;(Get-OeChild $f.Target 'flip').SetAttribute('horizontal','1');Assert-OeBlocked $f @{widthMm=50.8}
    }
    It 'rejects later invalid fields without publishing the earlier valid fields' {
        $f=New-OeFixture
        Assert-OeBlocked $f @{altText='Would be valid';placement=@{horizontalOffsetMm=1};crop=@{left=1}}
    }
    It 'bounds cumulative prepared object clones and leaves allocation untouched on overflow' {
        $f=New-OeFixture;$f.Allocation.ObjectFormatCharacters=[long](16MB-1)
        Assert-OeBlocked $f @{altText='Too much cloned XML'}
    }
}
