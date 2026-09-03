Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Synthetic package, independent of the writer and its style registry.
function New-AuthoringReadbackFixture {
    param([string]$Path, [switch]$WithoutHeader, [switch]$EmptyResources, [switch]$DefaultNamespace)
    $header = @'
<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core" xmlns:ext="urn:readback-extension" secCnt="1">
 <hh:refList>
  <hh:fontfaces><hh:fontface lang="HANGUL"><hh:font id="0" face="테스트 글꼴" type="TTF" isEmbedded="0"/></hh:fontface></hh:fontfaces>
  <hh:borderFills><hh:borderFill id="2" threeD="0" shadow="0" centerLine="NONE"><hh:leftBorder type="DOUBLE" width="0.3 mm" color="#123456"/></hh:borderFill></hh:borderFills>
  <hh:charProperties>
   <hh:charPr id="4" height="1250" textColor="#123456" shadeColor="#ABCDEF" useFontSpace="1" useKerning="1" symMark="DOT_ABOVE" borderFillIDRef="2">
    <hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
    <hh:ratio hangul="90" latin="110" hanja="100" japanese="100" other="100" symbol="100" user="100"/>
    <hh:spacing hangul="-5" latin="7" hanja="0" japanese="0" other="0" symbol="0" user="0"/>
    <hh:relSz hangul="95" latin="105"/><hh:offset hangul="-3" latin="4"/>
    <hh:bold/><hh:italic/><hh:supscript/>
    <hh:underline type="BOTTOM" shape="DASH" color="#001122"/><hh:strikeout shape="DOUBLE" color="#334455"/>
    <hh:outline type="SOLID"/><hh:shadow type="DROP" color="#556677" offsetX="-2" offsetY="3"/>
    <ext:feature value="unqualified" ext:value="qualified"><ext:a><ext:b><ext:c><ext:d><ext:e>deep value</ext:e></ext:d></ext:c></ext:b></ext:a></ext:feature>
   </hh:charPr>
  </hh:charProperties>
  <hh:paraProperties>
   <hh:paraPr id="9" tabPrIDRef="6" condense="3" fontLineHeight="1" snapToGrid="0" suppressLineNumbers="1" checked="0" textDir="RTL">
    <hh:align horizontal="RIGHT" vertical="BASELINE"/><hh:heading type="NUMBER" idRef="7" level="1"/>
    <hh:breakSetting breakLatinWord="KEEP_WORD" breakNonLatinWord="BREAK_WORD" widowOrphan="1" keepWithNext="1" keepLines="1" pageBreakBefore="1" lineWrap="SQUEEZE"/>
    <hh:autoSpacing eAsianEng="1" eAsianNum="0"/>
    <hh:margin><hc:intent value="-500" unit="HWPUNIT"/><hc:left value="1000" unit="HWPUNIT"/><hc:right value="2000" unit="HWPUNIT"/><hc:prev value="300" unit="HWPUNIT"/><hc:next value="400" unit="HWPUNIT"/></hh:margin>
    <hh:lineSpacing type="FIXED" value="1400" unit="HWPUNIT"/><hh:border borderFillIDRef="2" offsetLeft="100" offsetRight="200" offsetTop="300" offsetBottom="400" connect="1" ignoreMargin="1"/>
   </hh:paraPr>
   <hh:paraPr id="10" tabPrIDRef="6"><hh:heading type="BULLET" idRef="11" level="0"/></hh:paraPr>
  </hh:paraProperties>
  <hh:styles><hh:style id="8" type="PARA" name="브랜드 제목" engName="Brand Heading" paraPrIDRef="9" charPrIDRef="4" nextStyleIDRef="8" langID="1042" lockForm="1"/></hh:styles>
  <hh:tabProperties><hh:tabPr id="6" autoTabLeft="1" autoTabRight="0"><hh:tabItem pos="11339" type="RIGHT" leader="DOT" unit="HWPUNIT"/><hh:tabItem pos="17008" type="CENTER" leader="DASH" unit="HWPUNIT"/></hh:tabPr></hh:tabProperties>
  <hh:numberings><hh:numbering id="7" start="3"><hh:paraHead start="3" level="1" align="LEFT" charPrIDRef="4294967295">제 ^1. &amp; 항</hh:paraHead><hh:paraHead level="2" charPrIDRef="4"><![CDATA[(^2) > ]]></hh:paraHead></hh:numbering></hh:numberings>
  <hh:bullets><hh:bullet id="11" char="●" useImage="0"><hh:paraHead level="1" charPrIDRef="4294967295">• </hh:paraHead></hh:bullet></hh:bullets>
 </hh:refList>
</hh:head>
'@
    if ($EmptyResources) { $header='<hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"><hh:refList/></hh:head>' }
    if ($DefaultNamespace) { $header=$header.Replace('xmlns:hh=','xmlns=').Replace('<hh:','<').Replace('</hh:','</') }
    $section = @'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
 <hp:p id="1" paraPrIDRef="9" styleIDRef="8" pageBreak="1" columnBreak="0" merged="0"><hp:run charPrIDRef="4"><hp:t>첫째</hp:t><hp:tab/><hp:t>Second</hp:t></hp:run></hp:p>
 <hp:p id="2" paraPrIDRef="10" styleIDRef="8" pageBreak="0" columnBreak="1" merged="0"><hp:run charPrIDRef="4"><hp:t>Bullet body</hp:t></hp:run></hp:p>
 <hp:p id="3" paraPrIDRef="9" styleIDRef="8"><hp:run charPrIDRef="4"><hp:ctrl><hp:fieldBegin id="100" name="link"><hp:parameters><hp:stringParam name="Command">https://example.invalid/?a=1&amp;b=2</hp:stringParam></hp:parameters></hp:fieldBegin></hp:ctrl><hp:t>Linked</hp:t><hp:ctrl><hp:fieldEnd beginIDRef="100"/></hp:ctrl></hp:run></hp:p>
</hs:sec>
'@
    $entries=[ordered]@{'mimetype'='application/hwp+zip';'Contents/section0.xml'=$section}
    if (-not $WithoutHeader) {$entries['Contents/header.xml']=$header}
    $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($name in $entries.Keys) {
            $writer=[IO.StreamWriter]::new($zip.CreateEntry($name).Open(),[Text.UTF8Encoding]::new($false))
            try {$writer.Write($entries[$name])} finally {$writer.Dispose()}
        }
    } finally {$zip.Dispose()}
}

function Find-ReadbackProperty {
    param([object]$Properties,[string]$Name)
    @($Properties.children | Where-Object {$_.element -ceq $Name})[0]
}

function Set-ReadbackSectionFixture {
    param([string]$Path,[string]$Xml)
    $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $zip.GetEntry('Contents/section0.xml').Delete()
        $writer=[IO.StreamWriter]::new($zip.CreateEntry('Contents/section0.xml').Open(),[Text.UTF8Encoding]::new($false))
        try {$writer.Write($Xml)} finally {$writer.Dispose()}
    } finally {$zip.Dispose()}
}

Describe 'HWPX authored properties readback without native rendering' {
    BeforeEach {
        $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('n')+'.hwpx')
        New-AuthoringReadbackFixture $path
        $result=Get-HwpxPackageInspection -LiteralPath $path
        if ($result.Status -ne 'PASS_WITH_WARNINGS') {throw ($result.Errors -join '; ')}
        $data=$result.Data
    }

    It 'exposes named styles and source references without changing paragraph style IDs' {
        $data.Resources.styles | Should Not BeNullOrEmpty
        @($data.Resources.styles).Count | Should Be 1
        $style=$data.Resources.styles[0]
        $style.id | Should Be 8
        $style.name | Should Be '브랜드 제목'
        $style.type | Should Be PARA
        $style.properties.attributes.engName | Should Be 'Brand Heading'
        $style.properties.attributes.paraPrIDRef | Should Be '9'
        $style.properties.attributes.charPrIDRef | Should Be '4'
        $style.properties.attributes.nextStyleIDRef | Should Be '8'
        $style.properties.attributes.langID | Should Be '1042'
        $style.properties.attributes.lockForm | Should Be '1'
        $data.Paragraphs[0].styleId | Should Be 8
    }

    It 'keeps tab positions leaders and item order linked from paragraph shapes' {
        $data.Resources.tabProperties | Should Not BeNullOrEmpty
        $tabs=$data.Resources.tabProperties[0]
        $tabs.id | Should Be $data.Resources.paraShapes[0].tabDefinitionId
        $tabs.properties.attributes.autoTabLeft | Should Be '1'
        $items=@($tabs.properties.children | Where-Object {$_.element -eq 'tabItem'})
        $items.Count | Should Be 2
        $items[0].attributes.pos | Should Be '11339'
        $items[0].attributes.type | Should Be RIGHT
        $items[0].attributes.leader | Should Be DOT
        $items[1].attributes.pos | Should Be '17008'
        $items[1].attributes.type | Should Be CENTER
        $items[1].attributes.leader | Should Be DASH
    }

    It 'preserves numbering marker text CDATA Unicode and UINT32 inheritance sentinels' {
        $data.Resources.numberings | Should Not BeNullOrEmpty
        $numbering=$data.Resources.numberings[0]
        $numbering.id | Should Be 7
        $numbering.properties.attributes.start | Should Be '3'
        $heads=@($numbering.properties.children)
        $heads.Count | Should Be 2
        $heads[0].text | Should Be '제 ^1. & 항'
        $heads[0].attributes.charPrIDRef | Should Be '4294967295'
        $heads[1].text | Should Be '(^2) > '
        $bullet=$data.Resources.bullets[0]
        $bullet.id | Should Be 11
        $bullet.properties.attributes.char | Should Be '●'
        $bullet.properties.children[0].text | Should Be '• '
        $data.Text | Should Not Match '제 \^1'
    }

    It 'retains character decorations per-language spacing ratio relative size and offsets' {
        $props=$data.Resources.charShapes[0].properties
        $props.attributes.symMark | Should Be DOT_ABOVE
        (Find-ReadbackProperty $props 'underline').attributes.type | Should Be BOTTOM
        (Find-ReadbackProperty $props 'underline').attributes.shape | Should Be DASH
        (Find-ReadbackProperty $props 'underline').attributes.color | Should Be '#001122'
        (Find-ReadbackProperty $props 'strikeout').attributes.shape | Should Be DOUBLE
        (Find-ReadbackProperty $props 'strikeout').attributes.color | Should Be '#334455'
        (Find-ReadbackProperty $props 'spacing').attributes.hangul | Should Be '-5'
        (Find-ReadbackProperty $props 'spacing').attributes.latin | Should Be '7'
        (Find-ReadbackProperty $props 'ratio').attributes.hangul | Should Be '90'
        (Find-ReadbackProperty $props 'ratio').attributes.latin | Should Be '110'
        (Find-ReadbackProperty $props 'relSz').attributes.hangul | Should Be '95'
        (Find-ReadbackProperty $props 'offset').attributes.hangul | Should Be '-3'
        (Find-ReadbackProperty $props 'outline').attributes.type | Should Be SOLID
        (Find-ReadbackProperty $props 'shadow').attributes.offsetX | Should Be '-2'
    }

    It 'retains paragraph break rules list links auto spacing and line-spacing units' {
        $props=$data.Resources.paraShapes[0].properties
        $props.attributes.textDir | Should Be RTL
        $props.attributes.suppressLineNumbers | Should Be '1'
        $breaks=(Find-ReadbackProperty $props 'breakSetting').attributes
        foreach($name in @('widowOrphan','keepWithNext','keepLines','pageBreakBefore')) {$breaks.$name | Should Be '1'}
        $breaks.breakNonLatinWord | Should Be BREAK_WORD
        $breaks.lineWrap | Should Be SQUEEZE
        $heading=(Find-ReadbackProperty $props 'heading').attributes
        $heading.type | Should Be NUMBER
        $heading.idRef | Should Be '7'
        $heading.level | Should Be '1'
        (Find-ReadbackProperty $data.Resources.paraShapes[1].properties 'heading').attributes.idRef | Should Be '11'
        (Find-ReadbackProperty $props 'autoSpacing').attributes.eAsianEng | Should Be '1'
        (Find-ReadbackProperty $props 'lineSpacing').attributes.unit | Should Be HWPUNIT
    }

    It 'exposes explicit body page and column breaks while defaulting omitted flags to false' {
        $data.Paragraphs[0].pageBreak | Should Be $true
        $data.Paragraphs[0].columnBreak | Should Be $false
        $data.Paragraphs[1].pageBreak | Should Be $false
        $data.Paragraphs[1].columnBreak | Should Be $true
        $data.Paragraphs[2].pageBreak | Should Be $false
        $data.Paragraphs[2].columnBreak | Should Be $false
        $data.Paragraphs[0].breakTypeRaw | Should BeNullOrEmpty
    }

    It 'preserves complete resource XML beyond the generic projection depth and namespace collisions' {
        $props=$data.Resources.charShapes[0].properties
        $props.namespaceUri | Should Be 'http://www.hancom.co.kr/hwpml/2011/head'
        $json=$props | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json
        [xml]$xml=$json.xml
        $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('e','urn:readback-extension')
        $feature=$xml.SelectSingleNode('//e:feature',$ns)
        $feature.GetAttribute('value') | Should Be unqualified
        $feature.GetAttribute('value','urn:readback-extension') | Should Be qualified
        $xml.SelectSingleNode('//e:e',$ns).InnerText | Should Be 'deep value'
    }

    It 'retains generic control parameter text as well as resource marker text' {
        $control=@($data.Controls | Where-Object {$_.ctrlId -eq 'fieldBegin'})[0]
        $parameters=Find-ReadbackProperty $control.properties 'parameters'
        (Find-ReadbackProperty $parameters 'stringParam').text | Should Be 'https://example.invalid/?a=1&b=2'
        $data.Fields.link | Should Be Linked
    }

    It 'preserves existing typed APIs original bytes and the rendering limitation' {
        $before=(Get-FileHash -LiteralPath $path).Hash
        $context=[pscustomobject]@{mode='silent'}
        $record=Get-HwpInspection -LiteralPath $path -ExecutionContext $context -Capabilities ([pscustomobject]@{}) -SessionFactory {throw 'Native session must never run for HWPX'}
        $record.Status | Should Be PASS_WITH_WARNINGS
        $record.Resources.styles | Should Not BeNullOrEmpty
        $record.Resources.styles[0].name | Should Be '브랜드 제목'
        $record.Resources.fonts[0].name | Should Be '테스트 글꼴'
        $char=$record.Resources.charShapes[0]
        $char.fontSizeRaw | Should Be 1250
        $char.fontSizePt | Should Be 12.5
        $char.resolvedFontNames.Hangul | Should Be '테스트 글꼴'
        $char.attributes.bold | Should Be $true
        $char.attributes.italic | Should Be $true
        $char.attributes.superscript | Should Be $true
        $char.attributes.kerning | Should Be $true
        $char.attributes.underlineTypeCode | Should BeNullOrEmpty
        $record.Resources.paraShapes[0].lineSpacing.type | Should Be FIXED
        $record.Resources.paraShapes[0].lineSpacing.value | Should Be 1400
        $record.Resources.paraShapes[0].indent.raw | Should Be -500
        $record.Paragraphs[0].text | Should Be "첫째`tSecond"
        $record.Paragraphs[0].charShapeRuns[0].charShapeId | Should Be 4
        $record.Layout.exactRenderingVerified | Should Be $false
        $record.PageCount | Should Be 0
        (Get-FileHash -LiteralPath $path).Hash | Should Be $before
    }

    It 'reads inherited default header namespaces' {
        $other=Join-Path $TestDrive 'default-ns.hwpx';New-AuthoringReadbackFixture $other -DefaultNamespace
        $read=Get-HwpxPackageInspection $other
        $read.Status | Should Be PASS_WITH_WARNINGS
        $read.Data.Resources.styles | Should Not BeNullOrEmpty
        $read.Data.Resources.styles[0].properties.namespaceUri | Should Be 'http://www.hancom.co.kr/hwpml/2011/head'
        $read.Data.Resources.numberings[0].properties.children[0].text | Should Be '제 ^1. & 항'
    }

    It 'reads text lineBreak text tab text inside hp:t in DOM order' {
        Set-ReadbackSectionFixture $path @'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
 <hp:p id="1" paraPrIDRef="9" styleIDRef="8"><hp:run charPrIDRef="4"><hp:t>A<hp:lineBreak/>B<hp:tab/>C</hp:t></hp:run><hp:run charPrIDRef="5"><hp:t>D</hp:t></hp:run></hp:p>
</hs:sec>
'@
        $before=(Get-FileHash -LiteralPath $path).Hash
        $read=Get-HwpxPackageInspection $path
        $read.Status | Should Be PASS_WITH_WARNINGS
        $read.Data.Text | Should Be "A`nB`tCD"
        $read.Data.Paragraphs[0].text | Should Be "A`nB`tCD"
        $read.Data.Paragraphs[0].rawCharacterCount | Should Be 6
        $read.Data.Paragraphs[0].charShapeRuns[1].start | Should Be 5
        (Get-FileHash -LiteralPath $path).Hash | Should Be $before
    }

    It 'does not flatten nested control text into the parent paragraph or its run offsets' {
        Set-ReadbackSectionFixture $path @'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
 <hp:p id="outer" paraPrIDRef="9" styleIDRef="8"><hp:run charPrIDRef="4">
  <hp:t>A<hp:lineBreak/>B<hp:tab/>C</hp:t>
  <hp:ctrl><hp:footNote><hp:subList><hp:p id="note" paraPrIDRef="9" styleIDRef="8"><hp:run charPrIDRef="4"><hp:t>Note<hp:lineBreak/>only<hp:tab/>here</hp:t></hp:run></hp:p></hp:subList></hp:footNote></hp:ctrl>
  <hp:ctrl><hp:fieldBegin id="200" name="value"><hp:parameters><hp:stringParam name="Command"><hp:t>CONTROL SECRET</hp:t></hp:stringParam></hp:parameters></hp:fieldBegin></hp:ctrl>
 </hp:run><hp:run charPrIDRef="5"><hp:t>D</hp:t><hp:ctrl><hp:fieldEnd beginIDRef="200"/></hp:ctrl></hp:run></hp:p>
</hs:sec>
'@
        $read=Get-HwpxPackageInspection $path
        $read.Status | Should Be PASS_WITH_WARNINGS
        $outer=@($read.Data.Paragraphs | Where-Object {$_.instanceId -eq 'outer'})[0]
        $note=@($read.Data.Paragraphs | Where-Object {$_.instanceId -eq 'note'})[0]
        $outer.text | Should Be "A`nB`tCD"
        $outer.charShapeRuns[1].start | Should Be 5
        $note.text | Should Be "Note`nonly`there"
        $read.Data.Text | Should Be "A`nB`tCD`r`nNote`nonly`there"
        $read.Data.Fields.value | Should Be D
        $read.Data.Text | Should Not Match 'CONTROL SECRET'
    }

    It 'uses DOM-order separators in field values and mixed legacy sibling text' {
        Set-ReadbackSectionFixture $path @'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
 <hp:p id="field" paraPrIDRef="9" styleIDRef="8"><hp:run charPrIDRef="4"><hp:ctrl><hp:fieldBegin id="100" name="mixed"/></hp:ctrl><hp:t>A<hp:lineBreak/>B<hp:tab/>C</hp:t><hp:tab/><hp:t><![CDATA[D & E]]></hp:t><hp:lineBreak/><hp:t xml:space="preserve"> F </hp:t><hp:ctrl><hp:fieldEnd beginIDRef="100"/></hp:ctrl></hp:run><hp:run charPrIDRef="5"><hp:t>Z</hp:t></hp:run></hp:p>
</hs:sec>
'@
        $read=Get-HwpxPackageInspection $path
        $read.Status | Should Be PASS_WITH_WARNINGS
        $read.Data.Fields.mixed | Should Be "A`nB`tC`tD & E`n F "
        $read.Data.Paragraphs[0].text | Should Be "A`nB`tC`tD & E`n F Z"
        $read.Data.Paragraphs[0].charShapeRuns[1].start | Should Be 15
    }

    It 'counts nested text containers once and keeps empty whitespace CDATA and leading separators' {
        Set-ReadbackSectionFixture $path @'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
 <hp:p id="nested" paraPrIDRef="9" styleIDRef="8"><hp:run charPrIDRef="4"><hp:t><hp:tab/>A<hp:t><![CDATA[B & C]]></hp:t><hp:t/>D<hp:lineBreak/><hp:lineBreak/></hp:t><hp:t xml:space="preserve"> </hp:t></hp:run><hp:run charPrIDRef="5"><hp:t>Z</hp:t></hp:run></hp:p>
</hs:sec>
'@
        $read=Get-HwpxPackageInspection $path
        $read.Status | Should Be PASS_WITH_WARNINGS
        $read.Data.Paragraphs[0].text | Should Be "`tAB & CD`n`n Z"
        $read.Data.Paragraphs[0].charShapeRuns[1].start | Should Be 11
    }

    foreach($withoutHeader in @($true,$false)) {
        It ('returns empty resource arrays when header is missing or empty: '+$withoutHeader) {
            $other=Join-Path $TestDrive ([guid]::NewGuid().ToString('n')+'.hwpx')
            New-AuthoringReadbackFixture $other -WithoutHeader:$withoutHeader -EmptyResources
            $read=Get-HwpxPackageInspection $other
            $read.Status | Should Be PASS_WITH_WARNINGS
            foreach($name in @('fonts','borderFills','charShapes','paraShapes','styles','tabProperties','numberings','bullets')) {
                ($read.Data.Resources.$name -is [array]) | Should Be $true
                $read.Data.Resources.$name.Count | Should Be 0
            }
        }
    }
}
