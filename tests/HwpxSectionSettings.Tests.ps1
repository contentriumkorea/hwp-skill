# Hand-authored fixtures independent of the HWPX generator and public dispatch.
$script:SsModule=Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force -PassThru
$script:SsPath=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxSectionSettings.ps1'
function New-SsFixture {
    $xml=[xml]::new();$xml.PreserveWhitespace=$true
    $xml.LoadXml(@'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:v="urn:vendor"><hp:p id="1" paraPrIDRef="0" pageBreak="1"><hp:run charPrIDRef="7"><hp:secPr id="keep" textDirection="HORIZONTAL" spaceColumns="1134" tabStop="8000" tabStopVal="4000" tabStopUnit="HWPUNIT" outlineShapeIDRef="1" memoShapeIDRef="2" textVerticalWidthHead="0" masterPageCnt="0"><hp:grid lineGrid="10" charGrid="20" wonggojiFormat="0"/><hp:startNum pageStartsOn="BOTH" page="3" pic="4" tbl="5" equation="6"/><hp:visibility hideFirstHeader="0" hideFirstFooter="1" hideFirstMasterPage="0" border="SHOW_ALL" fill="SHOW_FIRST" hideFirstPageNum="0" hideFirstEmptyLine="1" showLineNumber="0"/><hp:pagePr landscape="WIDELY" width="59528" height="84186"><hp:margin left="100"/></hp:pagePr><hp:footNotePr><v:keep flag="opaque"/></hp:footNotePr><v:extension keep="yes"/></hp:secPr><hp:ctrl><hp:colPr colCount="2" sameSz="1"/></hp:ctrl><hp:t>keep &amp; text<hp:tab width="91"/></hp:t><!--keep comment--></hp:run></hp:p><hp:p id="2" paraPrIDRef="0"><hp:run charPrIDRef="8"><hp:t>other paragraph</hp:t></hp:run></hp:p></hs:sec>
'@)
    $sections=[Collections.Generic.List[string]]::new();$sections.Add('Contents/section0.xml')
    return @{Target=$xml.DocumentElement.FirstChild.FirstChild;Package=@{Sections=$sections;Xml=@{'Contents/section0.xml'=$xml}};Allocation=@{}}
}
function Get-SsNode($Node,[string]$Name) { $Node.SelectSingleNode('.//*[local-name()="'+$Name+'"]') }
function New-SsOperation($Settings=@{textDirection='VERTICAL'}) { @{type='set-section-settings';sectionIndex=0;settings=$Settings} }
function Invoke-SsSettings($F,$Op) { & $script:SsModule {param($T,$O,$P,$A,$Path) if(Test-Path -LiteralPath $Path){. $Path}; New-ScopedSectionSettings $T $O $P $A} $F.Target $Op $F.Package $F.Allocation $script:SsPath }
function Add-SsPageNum($F,[string]$Attributes='pos="BOTTOM_CENTER" formatType="DIGIT" sideChar="-"') {
    $fragment=$F.Target.OwnerDocument.CreateDocumentFragment();$fragment.InnerXml='<hp:ctrl xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:pageNum '+$Attributes+'/></hp:ctrl>'
    $null=$F.Target.AppendChild($fragment)
}
function Assert-SsFailure($F,$Op,[string]$Pattern='*') {
    $xml=$F.Target.OwnerDocument.OuterXml;$allocation=ConvertTo-Json -InputObject $F.Allocation -Depth 10 -Compress
    $failure=$null;try{$null=Invoke-SsSettings $F $Op}catch{$failure=$_.Exception}
    ($null -ne $failure)|Should Be $true
    $failure.Message|Should BeLike $Pattern
    [string]::Equals($F.Target.OwnerDocument.OuterXml,$xml,[StringComparison]::Ordinal)|Should Be $true
    (ConvertTo-Json -InputObject $F.Allocation -Depth 10 -Compress)|Should BeExactly $allocation
}

Describe 'Prepared section settings with no native host' {
    It 'returns one detached run and preserves controls, text, metadata and omitted settings' {
        $f=New-SsFixture;$before=$f.Target.OwnerDocument.OuterXml
        $p=Invoke-SsSettings $f (New-SsOperation)
        $p -is [Xml.XmlElement]|Should Be $true;$p.LocalName|Should BeExactly 'run';($null -eq $p.ParentNode)|Should Be $true
        $p.GetAttribute('charPrIDRef')|Should BeExactly '7'
        (Get-SsNode $p 'secPr').GetAttribute('textDirection')|Should BeExactly 'VERTICAL'
        foreach($name in @('grid','startNum','visibility','pagePr','footNotePr','extension','ctrl','t')){(Get-SsNode $p $name).OuterXml|Should BeExactly (Get-SsNode $f.Target $name).OuterXml}
        $p.LastChild.OuterXml|Should BeExactly '<!--keep comment-->'
        $f.Target.OwnerDocument.OuterXml|Should BeExactly $before
    }
    It 'writes all start numbers including unsigned 32-bit maxima without narrowing' {
        $f=New-SsFixture;$p=Invoke-SsSettings $f (New-SsOperation @{startNumbers=@{pageStartsOn='ODD';page=[uint32]::MaxValue;pic=0;tbl=9;equation=[long]4294967295}})
        $n=Get-SsNode $p 'startNum'
        foreach($pair in @(@('pageStartsOn','ODD'),@('page','4294967295'),@('pic','0'),@('tbl','9'),@('equation','4294967295'))){$n.GetAttribute($pair[0])|Should BeExactly $pair[1]}
    }
    It 'writes only supplied start-number attributes' {
        $f=New-SsFixture;$p=Invoke-SsSettings $f (New-SsOperation @{startNumbers=@{page=12}});$n=Get-SsNode $p 'startNum'
        $n.GetAttribute('page')|Should BeExactly '12';$n.GetAttribute('pic')|Should BeExactly '4';$n.GetAttribute('pageStartsOn')|Should BeExactly 'BOTH'
    }
    It 'serializes every visibility Boolean as zero or one while preserving omissions' {
        $f=New-SsFixture;$p=Invoke-SsSettings $f (New-SsOperation @{visibility=@{hideFirstHeader=$true;hideFirstFooter=$false;hideFirstMasterPage=$true;hideFirstPageNum=$true;hideFirstEmptyLine=$false;showLineNumber=$true;border='HIDE_FIRST';fill='SHOW_ALL'}})
        $n=Get-SsNode $p 'visibility'
        foreach($key in @('hideFirstHeader','hideFirstMasterPage','hideFirstPageNum','showLineNumber')){$n.GetAttribute($key)|Should BeExactly '1'}
        foreach($key in @('hideFirstFooter','hideFirstEmptyLine')){$n.GetAttribute($key)|Should BeExactly '0'}
        $n.GetAttribute('border')|Should BeExactly 'HIDE_FIRST';$n.GetAttribute('fill')|Should BeExactly 'SHOW_ALL'
        $q=Invoke-SsSettings $f (New-SsOperation @{visibility=@{showLineNumber=$true}})
        (Get-SsNode $q 'visibility').GetAttribute('hideFirstFooter')|Should BeExactly '1'
    }
    It 'writes grid values and preserves omitted grid fields' {
        $f=New-SsFixture;$p=Invoke-SsSettings $f (New-SsOperation @{grid=@{lineGrid=[long]4294967295;wonggojiFormat=$true}})
        $n=Get-SsNode $p 'grid';$n.GetAttribute('lineGrid')|Should BeExactly '4294967295';$n.GetAttribute('charGrid')|Should BeExactly '20';$n.GetAttribute('wonggojiFormat')|Should BeExactly '1'
    }
    It 'supports each supplied text direction, page-start and visibility enum exactly' {
        foreach($value in @('HORIZONTAL','VERTICAL','VERTICALALL')){(Get-SsNode (Invoke-SsSettings (New-SsFixture) (New-SsOperation @{textDirection=$value})) 'secPr').GetAttribute('textDirection')|Should BeExactly $value}
        foreach($value in @('BOTH','EVEN','ODD')){(Get-SsNode (Invoke-SsSettings (New-SsFixture) (New-SsOperation @{startNumbers=@{pageStartsOn=$value}})) 'startNum').GetAttribute('pageStartsOn')|Should BeExactly $value}
        foreach($value in @('HIDE_FIRST','SHOW_FIRST','SHOW_ALL')){(Get-SsNode (Invoke-SsSettings (New-SsFixture) (New-SsOperation @{visibility=@{border=$value;fill=$value}})) 'visibility').GetAttribute('border')|Should BeExactly $value}
    }
    It 'creates a separate canonical page-number control without changing existing controls' {
        $f=New-SsFixture;$old=(Get-SsNode $f.Target 'ctrl').OuterXml
        $p=Invoke-SsSettings $f (New-SsOperation @{pageNumber=@{position='OUTSIDE_BOTTOM';format='ROMAN_CAPITAL';sideChar=' &<> '}})
        $n=Get-SsNode $p 'pageNum';$n.ParentNode.LocalName|Should BeExactly 'ctrl'
        [object]::ReferenceEquals($n.ParentNode.ParentNode,$p)|Should Be $true
        $n.GetAttribute('pos')|Should BeExactly 'OUTSIDE_BOTTOM';$n.GetAttribute('formatType')|Should BeExactly 'ROMAN_CAPITAL';$n.GetAttribute('sideChar')|Should BeExactly ' &<> '
        $n.HasAttribute('position')|Should Be $false;$n.HasAttribute('format')|Should Be $false
        (Get-SsNode $p 'ctrl').OuterXml|Should BeExactly $old
        $f.Target.SelectNodes('.//*[local-name()="pageNum"]').Count|Should Be 0
    }
    It 'uses official page-number constructor defaults only when creating absent controls' {
        $p=Invoke-SsSettings (New-SsFixture) (New-SsOperation @{pageNumber=@{sideChar=''}});$n=Get-SsNode $p 'pageNum'
        $n.GetAttribute('pos')|Should BeExactly 'TOP_LEFT';$n.GetAttribute('formatType')|Should BeExactly 'DIGIT';$n.GetAttribute('sideChar')|Should BeExactly ''
    }
    It 'updates the existing sole page number and preserves its siblings and omitted attributes' {
        $f=New-SsFixture;Add-SsPageNum $f
        $ctrl=(Get-SsNode $f.Target 'pageNum').ParentNode;$sibling=$ctrl.OwnerDocument.CreateElement('hp','pageHiding',$f.Target.NamespaceURI);$sibling.SetAttribute('hideHeader','0');$null=$ctrl.AppendChild($sibling)
        $p=Invoke-SsSettings $f (New-SsOperation @{pageNumber=@{position='TOP_RIGHT'}});$n=Get-SsNode $p 'pageNum'
        $p.SelectNodes('.//*[local-name()="pageNum"]').Count|Should Be 1
        $n.GetAttribute('pos')|Should BeExactly 'TOP_RIGHT';$n.GetAttribute('formatType')|Should BeExactly 'DIGIT';$n.GetAttribute('sideChar')|Should BeExactly '-'
        (Get-SsNode $p 'pageHiding').OuterXml|Should BeExactly $sibling.OuterXml
    }
    It 'supports every page number position and format' {
        foreach($value in @('NONE','TOP_LEFT','TOP_CENTER','TOP_RIGHT','BOTTOM_LEFT','BOTTOM_CENTER','BOTTOM_RIGHT','OUTSIDE_TOP','OUTSIDE_BOTTOM','INSIDE_TOP','INSIDE_BOTTOM')){$n=Get-SsNode (Invoke-SsSettings (New-SsFixture) (New-SsOperation @{pageNumber=@{position=$value}})) 'pageNum';$n.GetAttribute('pos')|Should BeExactly $value}
        foreach($value in @('DIGIT','CIRCLED_DIGIT','ROMAN_CAPITAL','ROMAN_SMALL','LATIN_CAPITAL','LATIN_SMALL','HANGUL_SYLLABLE','HANGUL_JAMO','IDEOGRAPH','2DIGIT')){$n=Get-SsNode (Invoke-SsSettings (New-SsFixture) (New-SsOperation @{pageNumber=@{format=$value}})) 'pageNum';$n.GetAttribute('formatType')|Should BeExactly $value}
    }
    It 'does not inspect unrelated page numbers when pageNumber is omitted' {
        $f=New-SsFixture;Add-SsPageNum $f;$n=Get-SsNode $f.Target 'pageNum';$null=$f.Target.OwnerDocument.DocumentElement.LastChild.FirstChild.AppendChild($n.ParentNode)
        $p=Invoke-SsSettings $f (New-SsOperation @{grid=@{charGrid=30}})
        (Get-SsNode $p 'grid').GetAttribute('charGrid')|Should BeExactly '30'
    }
    It 'rejects page numbers elsewhere, nested page numbers and duplicates atomically' {
        foreach($mode in @('otherRun','nested','duplicate')){
            $f=New-SsFixture;Add-SsPageNum $f;$n=Get-SsNode $f.Target 'pageNum'
            if($mode -eq 'otherRun'){$null=$f.Target.OwnerDocument.DocumentElement.LastChild.FirstChild.AppendChild($n.ParentNode)}
            elseif($mode -eq 'nested'){$wrapper=$f.Target.OwnerDocument.CreateElement('hp','wrapper',$f.Target.NamespaceURI);$null=$wrapper.AppendChild($n.ParentNode);$null=$f.Target.AppendChild($wrapper)}
            else{Add-SsPageNum $f}
            Assert-SsFailure $f (New-SsOperation @{pageNumber=@{position='NONE'}}) '*pageNum*'
        }
    }
    It 'requires canonical run location, sole direct secPr and matching sectionIndex' {
        $f=New-SsFixture;$op=New-SsOperation;$op.sectionIndex=1;Assert-SsFailure $f $op '*section*'
        $f=New-SsFixture;$f.Target=$f.Target.OwnerDocument.DocumentElement.LastChild.FirstChild;Assert-SsFailure $f (New-SsOperation) '*secPr*'
        $f=New-SsFixture;$sec=Get-SsNode $f.Target 'secPr';$null=$f.Target.AppendChild($sec.CloneNode($true));Assert-SsFailure $f (New-SsOperation) '*secPr*'
        $f=New-SsFixture;$sec=Get-SsNode $f.Target 'secPr';$null=$f.Target.OwnerDocument.DocumentElement.LastChild.FirstChild.AppendChild($sec.CloneNode($true));Assert-SsFailure $f (New-SsOperation) '*secPr*'
        $f=New-SsFixture;$f.Target=$f.Target.CloneNode($true);Assert-SsFailure $f (New-SsOperation) '*target*'
    }
    It 'rejects empty objects, unknown keys, wrong type and missing operation keys' {
        Assert-SsFailure (New-SsFixture) (New-SsOperation @{}) '*empty*'
        foreach($group in @('grid','startNumbers','visibility','pageNumber')){Assert-SsFailure (New-SsFixture) (New-SsOperation @{$group=@{}}) '*empty*';Assert-SsFailure (New-SsFixture) (New-SsOperation @{$group=@{unknown=1}}) '*Unrecognized*'}
        Assert-SsFailure (New-SsFixture) (New-SsOperation @{unknown=1}) '*Unrecognized*'
        foreach($key in @('type','sectionIndex','settings')){$op=New-SsOperation;$op.Remove($key);Assert-SsFailure (New-SsFixture) $op '*Missing*'}
        $op=New-SsOperation;$op.extra=1;Assert-SsFailure (New-SsFixture) $op '*Unrecognized*'
        $op=New-SsOperation;$op.type='set-page';Assert-SsFailure (New-SsFixture) $op '*type*'
    }
    It 'rejects coercion, uint32 overflow, invalid enums and linguistic lookalikes' {
        foreach($value in @(-1,[long]4294967296,'12',$true,1.5,$null)){Assert-SsFailure (New-SsFixture) (New-SsOperation @{startNumbers=@{page=$value}}) '*uint32*';Assert-SsFailure (New-SsFixture) (New-SsOperation @{grid=@{charGrid=$value}}) '*uint32*'}
        foreach($value in @('true',1,0,$null)){Assert-SsFailure (New-SsFixture) (New-SsOperation @{visibility=@{showLineNumber=$value}}) '*Boolean*';Assert-SsFailure (New-SsFixture) (New-SsOperation @{grid=@{wonggojiFormat=$value}}) '*Boolean*'}
        foreach($value in @('vertical','DIAGONAL',('VERTICAL'+[char]0x200B),1,$null)){Assert-SsFailure (New-SsFixture) (New-SsOperation @{textDirection=$value}) '*enum*'}
        Assert-SsFailure (New-SsFixture) (New-SsOperation @{pageNumber=@{format='ARABIC'}}) '*enum*'
        Assert-SsFailure (New-SsFixture) (New-SsOperation @{visibility=@{fill='ALL'}}) '*enum*'
    }
    It 'rejects linguistic lookalikes in stored flags, ancestor protection and operation keys' {
        $f=New-SsFixture;(Get-SsNode $f.Target 'grid').SetAttribute('wonggojiFormat',('false'+[char]0x200B))
        Assert-SsFailure $f (New-SsOperation @{grid=@{lineGrid=1}}) '*Boolean*'
        $f=New-SsFixture;$f.Target.ParentNode.SetAttribute('lock',('false'+[char]0x200B));Assert-SsFailure $f (New-SsOperation) '*Protected*'
        $op=New-SsOperation;$op[('settings'+[char]0x200B)]=@{textDirection='HORIZONTAL'};Assert-SsFailure (New-SsFixture) $op '*Unrecognized*'
        Assert-SsFailure (New-SsFixture) (New-SsOperation @{grid=@{('lineGrid'+[char]0x200B)=3}}) '*Unrecognized*'
    }
    It 'rejects protected ancestors and unknown flags without modifying originals' {
        foreach($name in @('run','secPr','grid','visibility','startNum')){
            $f=New-SsFixture;$node=if($name -eq 'run'){$f.Target}else{Get-SsNode $f.Target $name};$node.SetAttribute('protect','1')
            Assert-SsFailure $f (New-SsOperation @{textDirection='VERTICAL';grid=@{lineGrid=4};visibility=@{border='SHOW_ALL'};startNumbers=@{page=1}}) '*metadata*'
        }
        $f=New-SsFixture;$f.Target.ParentNode.SetAttribute('lock','true');Assert-SsFailure $f (New-SsOperation) '*Protected*'
        $f=New-SsFixture;(Get-SsNode $f.Target 'visibility').SetAttribute('showLineNumber','maybe');Assert-SsFailure $f (New-SsOperation @{visibility=@{showLineNumber=$true}}) '*Boolean*'
    }
    It 'rejects ambiguous or missing setting nodes and unknown leaf metadata' {
        foreach($pair in @(@('grid','grid','lineGrid'),@('startNum','startNumbers','page'),@('visibility','visibility','hideFirstHeader'))){
            $f=New-SsFixture;$node=Get-SsNode $f.Target $pair[0];$null=$node.ParentNode.AppendChild($node.CloneNode($true));$value=if($pair[2] -eq 'hideFirstHeader'){$true}else{1};Assert-SsFailure $f (New-SsOperation @{$pair[1]=@{$pair[2]=$value}}) '*Ambiguous*'
        }
        $f=New-SsFixture;$node=Get-SsNode $f.Target 'grid';$null=$node.ParentNode.RemoveChild($node);Assert-SsFailure $f (New-SsOperation @{grid=@{lineGrid=1}}) '*missing*'
        $f=New-SsFixture;$node=Get-SsNode $f.Target 'grid';$null=$node.AppendChild($node.OwnerDocument.CreateComment('unknown'));Assert-SsFailure $f (New-SsOperation @{grid=@{lineGrid=1}}) '*metadata*'
        $f=New-SsFixture;Add-SsPageNum $f 'pos="BOTTOM_CENTER" formatType="DIGIT" sideChar="-" lock="1"';Assert-SsFailure $f (New-SsOperation @{pageNumber=@{position='NONE'}}) '*metadata*'
    }
    It 'validates sideChar XML and UTF16, accepts supplementary characters and enforces its bound' {
        foreach($bad in @([string][char]0,[string][char]0xD800,12,('x'*257))){Assert-SsFailure (New-SsFixture) (New-SsOperation @{pageNumber=@{sideChar=$bad}})}
        $face=[char]::ConvertFromUtf32(0x1F600);$p=Invoke-SsSettings (New-SsFixture) (New-SsOperation @{pageNumber=@{sideChar=$face}})
        (Get-SsNode $p 'pageNum').GetAttribute('sideChar')|Should BeExactly $face
    }
    It 'fails atomically when a later setting is invalid and bounds cumulative prepared memory' {
        Assert-SsFailure (New-SsFixture) (New-SsOperation @{grid=@{lineGrid=40};pageNumber=@{position='INVALID'}})
        $f=New-SsFixture;$f.Allocation.SectionSettingsPreparedCharacters=[long](16MB);Assert-SsFailure $f (New-SsOperation) '*16 MiB*'
    }
    It 'bounds clone depth and counts newly created control nodes in the output node budget' {
        $f=New-SsFixture;$extension=Get-SsNode $f.Target 'extension'
        $extension.InnerXml=('<v:n xmlns:v="urn:vendor">'*65)+('</v:n>'*65)
        Assert-SsFailure $f (New-SsOperation) '*depth 64*'
        $f=New-SsFixture;$current=$f.Target.SelectNodes('.//node()').Count+1
        $fragment=$f.Target.OwnerDocument.CreateDocumentFragment();$fragment.InnerXml='<!--x-->'*(65535-$current);$null=$f.Target.AppendChild($fragment)
        Assert-SsFailure $f (New-SsOperation @{pageNumber=@{position='NONE'}}) '*65536*'
    }
}
