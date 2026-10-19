# Literal section/control fixtures, real shared paragraph/resource helpers, no generator oracle.
$script:HfModule=Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force -PassThru
$script:HfHelper=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxHeaderFooterEdit.ps1'
$script:HfTemplate=Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx'
function New-HfFixture {
    $package=& $script:HfModule {param($Path) $stream=[IO.File]::OpenRead($Path);try{Read-ScopedPackage $stream}finally{$stream.Dispose()}} $script:HfTemplate
    $xml=[xml]::new();$xml.PreserveWhitespace=$true
    $xml.LoadXml(@'
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:v="urn:retain"><hp:p id="1" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:secPr id="100" textDirection="HORIZONTAL"><hp:pagePr landscape="WIDELY" width="20000" height="30000" gutterType="LEFT_ONLY"><hp:margin left="1000" right="2000" gutter="500"/></hp:pagePr><hp:footNotePr><v:keep value="untouched"/></hp:footNotePr></hp:secPr><hp:ctrl><hp:colPr colCount="2"/></hp:ctrl><hp:t>Body <hp:tab width="17"/>text</hp:t><!--keep--></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p><hp:p id="200" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Unrelated paragraph</hp:t></hp:run></hp:p></hs:sec>
'@)
    $package.Xml[$package.Sections[0]]=$xml
    return @{Package=$package;Target=$xml.DocumentElement.FirstChild.FirstChild;Allocation=@{}}
}
function New-HfOp($Kind='header',$Apply='BOTH',$Expected='',$Paragraphs=@(@{text='New text'})) {
    @{type='set-header-footer';sectionIndex=0;kind=$Kind;applyTo=$Apply;expectedText=$Expected;paragraphs=$Paragraphs}
}
function Invoke-Hf($F,$Operation) {
    & $script:HfModule {param($Path,$F,$Operation) if(Test-Path -LiteralPath $Path){. $Path};New-ScopedHeaderFooter $F.Target $Operation $F.Package $F.Allocation} $script:HfHelper $F $Operation
}
function Get-Hf($Node,$Name){$Node.SelectSingleNode('.//*[local-name()="'+$Name+'"]')}
function Add-Hf($F,$Kind='header',$Apply='BOTH',[int]$Id=300) {
    $fragment=$F.Target.OwnerDocument.CreateDocumentFragment()
    $fragment.InnerXml=('<hp:ctrl xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:{0} id="{2}" applyPageType="{1}"><hp:subList id="{3}" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="TOP" linkListIDRef="0" linkListNextIDRef="0" textWidth="12345" textHeight="0" hasTextRef="0" hasNumRef="0" metatag="keep"><hp:p id="{4}" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="0"><hp:t>Old</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p></hp:subList></hp:{0}></hp:ctrl>' -f $Kind,$Apply,$Id,($Id+1),($Id+2))
    $node=$fragment.FirstChild.FirstChild;$null=$F.Target.InsertBefore($fragment,$F.Target.SelectSingleNode('*[local-name()="t"]'));return ,$node
}
function Convert-HfState($Value) {
    if($null -eq $Value){return $null}
    if($Value -is [Xml.XmlNode]){return $Value.OuterXml}
    if($Value -is [Collections.IDictionary]){$map=[ordered]@{};foreach($key in @($Value.Keys|Sort-Object)){$map[$key]=Convert-HfState $Value[$key]};return $map}
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){return ,@(foreach($item in $Value){Convert-HfState $item})}
    return $Value
}
function Assert-HfBlocked($F,$Operation) {
    $xml=$F.Target.OwnerDocument.OuterXml;$header=$F.Package.Xml['Contents/header.xml'].OuterXml
    $before=ConvertTo-Json -InputObject (Convert-HfState $F.Allocation) -Depth 40 -Compress
    $errorFound=$null;try{$null=Invoke-Hf $F $Operation}catch{$errorFound=$_}
    $errorFound|Should Not BeNullOrEmpty
    $errorFound.Exception.Message|Should Match '^Header/footer:'
    $F.Target.OwnerDocument.OuterXml|Should BeExactly $xml
    $F.Package.Xml['Contents/header.xml'].OuterXml|Should BeExactly $header
    (ConvertTo-Json -InputObject (Convert-HfState $F.Allocation) -Depth 40 -Compress)|Should BeExactly $before
}

Describe 'Private canonical header/footer prepared replacements' {
    It 'creates missing <Kind> <Apply> before text while preserving the section run' -TestCases @(
        @{Kind='header';Apply='BOTH'},@{Kind='header';Apply='EVEN'},@{Kind='header';Apply='ODD'},
        @{Kind='footer';Apply='BOTH'},@{Kind='footer';Apply='EVEN'},@{Kind='footer';Apply='ODD'}
    ) {
        param($Kind,$Apply)
        $f=New-HfFixture;$before=$f.Target.OwnerDocument.OuterXml;$head=$f.Package.Xml['Contents/header.xml'].OuterXml
        $copy=Invoke-Hf $f (New-HfOp $Kind $Apply)
        $copy -is [Xml.XmlElement]|Should Be $true;$copy.ParentNode|Should BeNullOrEmpty;$copy.LocalName|Should Be 'run'
        [object]::ReferenceEquals($copy.OwnerDocument,$f.Target.OwnerDocument)|Should Be $true
        $copy.FirstChild.LocalName|Should Be 'secPr'
        $control=Get-Hf $copy $Kind;$control.ParentNode.LocalName|Should Be 'ctrl'
        $control.ParentNode.NextSibling.LocalName|Should Be 't'
        $control.GetAttribute('applyPageType')|Should Be $Apply;$control.GetAttribute('id')|Should Be '201'
        $sub=Get-Hf $control 'subList';$sub.GetAttribute('id')|Should Be '202';$sub.GetAttribute('textWidth')|Should Be '16500'
        $sub.GetAttribute('textDirection')|Should Be 'HORIZONTAL';$sub.GetAttribute('lineWrap')|Should Be 'BREAK';$sub.GetAttribute('vertAlign')|Should Be 'TOP'
        (Get-Hf $sub 'p').GetAttribute('id')|Should Be '203';(Get-Hf $sub 't').InnerText|Should Be 'New text'
        foreach($name in @('secPr','colPr')){(Get-Hf $copy $name).OuterXml|Should BeExactly (Get-Hf $f.Target $name).OuterXml}
        $copy.SelectSingleNode('*[local-name()="t"]').OuterXml|Should BeExactly $f.Target.SelectSingleNode('*[local-name()="t"]').OuterXml
        $copy.LastChild.OuterXml|Should Be '<!--keep-->'
        $f.Target.OwnerDocument.OuterXml|Should BeExactly $before;$f.Package.Xml['Contents/header.xml'].OuterXml|Should BeExactly $head
        $f.Allocation.HeaderFooterPreparedCharacters|Should Be $copy.OuterXml.Length
    }
    It 'updates only the exact even policy and preserves odd footer and opaque siblings' {
        $f=New-HfFixture;$even=Add-Hf $f header EVEN 300;$odd=Add-Hf $f header ODD 400;$footer=Add-Hf $f footer BOTH 500
        $sub=Get-Hf $even 'subList';$sub.SetAttribute('textWidth','7777')
        $opaque=$f.Target.OwnerDocument.CreateElement('v','metadata','urn:retain');$opaque.SetAttribute('retain','yes');$null=$even.ParentNode.AppendChild($opaque)
        $before=$f.Target.OwnerDocument.OuterXml
        $copy=Invoke-Hf $f (New-HfOp header EVEN Old @(@{text='First'},@{runs=@(@{text='Second'},@{text=' & third'})}))
        $new=$copy.SelectSingleNode('*[local-name()="ctrl"]/*[local-name()="header" and @applyPageType="EVEN"]')
        $new.GetAttribute('id')|Should Be '300';(Get-Hf $new 'subList').GetAttribute('id')|Should Be '301'
        (Get-Hf $new 'subList').GetAttribute('textWidth')|Should Be '7777';(Get-Hf $new 'subList').GetAttribute('metatag')|Should Be 'keep'
        $new.SelectNodes('.//*[local-name()="p"]').Count|Should Be 2;$new.SelectNodes('.//*[local-name()="linesegarray"]').Count|Should Be 0
        $new.InnerText|Should Be 'FirstSecond & third'
        $copy.SelectSingleNode('*[local-name()="ctrl"]/*[local-name()="header" and @applyPageType="ODD"]').OuterXml|Should BeExactly $odd.OuterXml
        (Get-Hf $copy 'footer').OuterXml|Should BeExactly $footer.OuterXml;(Get-Hf $copy 'metadata').OuterXml|Should BeExactly $opaque.OuterXml
        $f.Target.OwnerDocument.OuterXml|Should BeExactly $before
    }
    It 'adds odd alongside even without touching the even definition' {
        $f=New-HfFixture;$even=Add-Hf $f header EVEN
        $copy=Invoke-Hf $f (New-HfOp header ODD)
        $copy.SelectNodes('.//*[local-name()="header"]').Count|Should Be 2
        $copy.SelectSingleNode('.//*[local-name()="header" and @applyPageType="EVEN"]').OuterXml|Should BeExactly $even.OuterXml
    }
    It 'does not reuse source IDs even when incoming cursors are below the source maximum' {
        $f=New-HfFixture;$f.Allocation.ObjectId=[long]1;$f.Allocation.NextParagraphId=[long]2
        $copy=Invoke-Hf $f (New-HfOp);$node=Get-Hf $copy header
        $node.GetAttribute('id')|Should Be '201';(Get-Hf $node subList).GetAttribute('id')|Should Be '202'
        (Get-Hf $node p).GetAttribute('id')|Should Be '203'
    }
    It 'keeps new control list and paragraph IDs disjoint from pending IDs in both namespaces' {
        $f=New-HfFixture;$f.Allocation.ObjectId=[long]700;$f.Allocation.NextParagraphId=[long]900
        $copy=Invoke-Hf $f (New-HfOp);$node=Get-Hf $copy header
        $node.GetAttribute('id')|Should Be '900';(Get-Hf $node subList).GetAttribute('id')|Should Be '901'
        (Get-Hf $node p).GetAttribute('id')|Should Be '902'
        $f.Allocation.ObjectId|Should Be 903;$f.Allocation.NextParagraphId|Should Be 903
    }
    It 'clears text explicitly while retaining the control its list and the other kind' {
        $f=New-HfFixture;$null=Add-Hf $f header;$footer=Add-Hf $f footer BOTH 500
        $copy=Invoke-Hf $f (New-HfOp header BOTH Old @(@{text=''}));$node=Get-Hf $copy header
        $node.GetAttribute('id')|Should Be '300';$node.SelectNodes('.//*[local-name()="p"]').Count|Should Be 1
        $node.InnerText|Should Be '';(Get-Hf $copy footer).OuterXml|Should BeExactly $footer.OuterXml
    }
    It 'guards text with LF CRLF tabs and explicit empty paragraphs' {
        $f=New-HfFixture;$old=Add-Hf $f footer
        (Get-Hf $old 't').InnerXml='Old<hp:lineBreak xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"/>line<hp:tab xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" width="0" leader="0" type="0"/>end'
        $copy=Invoke-Hf $f (New-HfOp footer BOTH "Old`r`nline`tend" @(@{text="A`nB`tC & <D>"},@{text=''}))
        $node=Get-Hf $copy footer;$node.SelectNodes('.//*[local-name()="lineBreak"]').Count|Should Be 1;$node.SelectNodes('.//*[local-name()="tab"]').Count|Should Be 1
        $node.SelectNodes('.//*[local-name()="p"]').Count|Should Be 2
        $node.SelectNodes('.//*[local-name()="t"]')[1].InnerText|Should Be ''
    }
    It 'stages real rich paragraph character and font resources without mutating the header' {
        $f=New-HfFixture;$head=$f.Package.Xml['Contents/header.xml'].OuterXml
        $paragraphs=@(@{paragraphStyle=@{alignment='CENTER'};textStyle=@{fontFamily='Header Test Font';bold=$true};runs=@(@{text='Bold'},@{text='Plain';textStyle=@{bold=$false}})})
        $copy=Invoke-Hf $f (New-HfOp header BOTH '' $paragraphs)
        $resources=@($f.Allocation.Resources);@($resources|Where-Object Kind -eq font).Count|Should Be 7
        $p=Get-Hf (Get-Hf $copy header) p;$para=@($resources|Where-Object {$_.Kind -eq 'paraPr' -and $_.Id -eq $p.GetAttribute('paraPrIDRef')})[0]
        (Get-Hf $para.Node align).GetAttribute('horizontal')|Should Be 'CENTER'
        $runs=$p.SelectNodes('*[local-name()="run"]')
        $bold=@($resources|Where-Object {$_.Kind -eq 'charPr' -and $_.Id -eq $runs[0].GetAttribute('charPrIDRef')})[0]
        $plain=@($resources|Where-Object {$_.Kind -eq 'charPr' -and $_.Id -eq $runs[1].GetAttribute('charPrIDRef')})[0]
        $bold.Node.SelectNodes('*[local-name()="bold"]').Count|Should Be 1;$plain.Node.SelectNodes('*[local-name()="bold"]').Count|Should Be 0
        $f.Package.Xml['Contents/header.xml'].OuterXml|Should BeExactly $head
        [object]::ReferenceEquals($para.Collection.OwnerDocument,$f.Package.Xml['Contents/header.xml'])|Should Be $true
    }
    It 'matches the pinned official HeaderFooterType and ParaListType stored attributes' {
        $catalog=Get-Content (Join-Path $PSScriptRoot '../skills/hwp-skill/references/hwpx-model-catalog.json') -Raw|ConvertFrom-Json
        $catalog.source.commit|Should Be '1453388472c703a4b299a0834f425cdac16644b9'
        $allowedHeader=@($catalog.classes.CHeaderFooterType.writeAttributes|ForEach-Object name)
        $allowedList=@($catalog.classes.CParaListType.writeAttributes|ForEach-Object name)
        $policies=@($catalog.enums.g_ApplyPageTypeList)
        foreach($kind in @('header','footer')){foreach($policy in $policies){
            $copy=Invoke-Hf (New-HfFixture) (New-HfOp $kind $policy);$node=Get-Hf $copy $kind
            foreach($attr in $node.Attributes){($allowedHeader -ccontains $attr.LocalName)|Should Be $true}
            foreach($attr in (Get-Hf $node subList).Attributes){($allowedList -ccontains $attr.LocalName)|Should Be $true}
        }}
    }
}

Describe 'Header/footer rejection is atomic across XML resources and allocation' {
    It 'rejects an ordinally different <Kind> guard containing ignored character <Code>' -TestCases @(
        @{Kind='header';Code=0xAD},@{Kind='footer';Code=0xAD},
        @{Kind='header';Code=0x200B},@{Kind='footer';Code=0x200B}
    ) {
        param($Kind,$Code)
        $f=New-HfFixture;$node=Add-Hf $f $Kind;(Get-Hf $node t).InnerText='AB'
        Assert-HfBlocked $f (New-HfOp $Kind BOTH ('A'+[char]$Code+'B'))
    }
    It 'requires an actually empty missing <Kind> guard rather than an ignorable character' -TestCases @(@{Kind='header'},@{Kind='footer'}) {
        param($Kind)
        Assert-HfBlocked (New-HfFixture) (New-HfOp $Kind BOTH ([string][char]0xAD))
    }
    It 'accepts exact ignorable characters and normalizes paragraph and inline line endings only' {
        $f=New-HfFixture;$node=Add-Hf $f header;$sub=Get-Hf $node subList;$t=Get-Hf $sub t
        $t.InnerText='A'+[char]0xAD+'B'+[char]0x200B
        $second=(Get-Hf $sub p).CloneNode($true);$second.SetAttribute('id','303')
        (Get-Hf $second t).InnerXml='C<hp:lineBreak xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"/>D'
        $null=$sub.AppendChild($second)
        $expected='A'+[char]0xAD+'B'+[char]0x200B+"`r`nC`rD"
        $copy=Invoke-Hf $f (New-HfOp header BOTH $expected)
        (Get-Hf $copy header).InnerText|Should Be 'New text'
        # Replacing the source's real soft hyphen by nothing must be rejected too.
        Assert-HfBlocked $f (New-HfOp header BOTH ('AB'+[char]0x200B+"`nC`nD"))
    }
    It 'rejects bad input <Name>' -TestCases @(
        @{Name='unknown key';Changes=@{unknown=1}},@{Name='wrong type';Changes=@{type='set-header'}},
        @{Name='wrong kind';Changes=@{kind='Header'}},@{Name='wrong policy';Changes=@{applyTo='ALL'}},
        @{Name='uppercase type';Changes=@{type='SET-HEADER-FOOTER'}},@{Name='uppercase kind';Changes=@{kind='HEADER'}},
        @{Name='lowercase policy';Changes=@{applyTo='both'}},@{Name='uppercase key';Changes=@{ApplyTo='BOTH'}},
        @{Name='section Boolean';Changes=@{sectionIndex=$true}},@{Name='section fractional';Changes=@{sectionIndex=0.5}},
        @{Name='section NaN';Changes=@{sectionIndex=[double]::NaN}},@{Name='section outside';Changes=@{sectionIndex=1}},
        @{Name='guard null';Changes=@{expectedText=$null}},@{Name='guard Boolean';Changes=@{expectedText=$false}},
        @{Name='guard stale';Changes=@{expectedText='not empty'}},@{Name='guard oversized';Changes=@{expectedText=('x'*(1MB+1))}},
        @{Name='empty paragraphs';Changes=@{paragraphs=@()}},@{Name='null paragraphs';Changes=@{paragraphs=$null}},
        @{Name='many paragraphs';Changes=@{paragraphs=@(1..1025|ForEach-Object {@{text=''}})}},
        @{Name='ambiguous paragraph';Changes=@{paragraphs=@(@{text='a';runs=@(@{text='b'})})}},
        @{Name='unknown paragraph';Changes=@{paragraphs=@(@{text='a';unknown=1})}},
        @{Name='invalid XML';Changes=@{paragraphs=@(@{text="bad$([char]1)"})}},
        @{Name='long run';Changes=@{paragraphs=@(@{text=('x'*(1MB+1))})}}
    ) {
        param($Name,$Changes)
        $op=New-HfOp
        foreach($key in $Changes.Keys){
            foreach($original in @($op.Keys)){if($original -ieq $key -and $original -cne $key){$op.Remove($original)}}
            $op[$key]=$Changes[$key]
        }
        Assert-HfBlocked (New-HfFixture) $op
    }
    It 'requires all operation keys and exactly the canonical attached section run' {
        foreach($key in @('type','sectionIndex','kind','applyTo','expectedText','paragraphs')){$op=New-HfOp;$op.Remove($key);Assert-HfBlocked (New-HfFixture) $op}
        foreach($change in @('wrongRun','detached','duplicateSecPr','secPrOrder','locked')){
            $f=New-HfFixture
            switch($change){
                'wrongRun' {$f.Target=$f.Target.OwnerDocument.DocumentElement.LastChild.FirstChild}
                'detached' {$clone=$f.Target.CloneNode($true);$f.Target=$clone}
                'duplicateSecPr' {$null=$f.Target.AppendChild((Get-Hf $f.Target secPr).CloneNode($true))}
                'secPrOrder' {$p=Get-Hf $f.Target secPr;$null=$f.Target.RemoveChild($p);$null=$f.Target.AppendChild($p)}
                'locked' {$f.Target.ParentNode.SetAttribute('lock','1')}
            };Assert-HfBlocked $f (New-HfOp)
        }
    }
    It 'rejects duplicate conflicting foreign and noncanonical definitions anywhere in the section' {
        foreach($change in @('duplicate','mixed','elsewhere','foreign','nested')){
            $f=New-HfFixture;$node=Add-Hf $f header EVEN
            switch($change){
                'duplicate' {$null=Add-Hf $f header EVEN 400}
                'mixed' {$null=Add-Hf $f header BOTH 400}
                'elsewhere' {$ctrl=$node.ParentNode;$null=$f.Target.RemoveChild($ctrl);$null=$f.Target.OwnerDocument.DocumentElement.LastChild.FirstChild.AppendChild($ctrl)}
                'foreign' {$foreign=$node.OwnerDocument.CreateElement('v','header','urn:retain');$foreign.SetAttribute('applyPageType','ODD');$null=$f.Target.AppendChild($foreign)}
                'nested' {$ctrl=$node.ParentNode;$null=$f.Target.RemoveChild($ctrl);$null=(Get-Hf $f.Target secPr).AppendChild($ctrl)}
            };Assert-HfBlocked $f (New-HfOp header ODD)
        }
        $f=New-HfFixture;$null=Add-Hf $f header BOTH;Assert-HfBlocked $f (New-HfOp header EVEN)
        $f=New-HfFixture;$null=Add-Hf $f header EVEN;Assert-HfBlocked $f (New-HfOp header BOTH)
    }
    It 'rejects field note object and unknown paragraph metadata instead of erasing it' {
        foreach($change in @('field','note','object','paragraphAttribute','runAttribute','textAttribute','unknownChild','linked','badWidth')){
            $f=New-HfFixture;$node=Add-Hf $f;$sub=Get-Hf $node subList;$p=Get-Hf $sub p;$run=Get-Hf $p run;$t=Get-Hf $run t
            switch($change){
                'field' {$null=$run.AppendChild($t.OwnerDocument.CreateElement('hp','fieldBegin',$t.NamespaceURI))}
                'note' {$null=$run.AppendChild($t.OwnerDocument.CreateElement('hp','footNote',$t.NamespaceURI))}
                'object' {$null=$run.AppendChild($t.OwnerDocument.CreateElement('hp','pic',$t.NamespaceURI))}
                'paragraphAttribute' {$p.SetAttribute('unknown','keep')}
                'runAttribute' {$run.SetAttribute('unknown','keep')}
                'textAttribute' {$t.SetAttribute('unknown','keep')}
                'unknownChild' {$null=$sub.AppendChild($t.OwnerDocument.CreateElement('v','opaque','urn:retain'))}
                'linked' {$sub.SetAttribute('linkListIDRef','17')}
                'badWidth' {$sub.SetAttribute('textWidth','NaN')}
            };Assert-HfBlocked $f (New-HfOp header BOTH Old)
        }
    }
    It 'rolls back staged fonts styles ID sets caches and counters after a later failure' {
        $f=New-HfFixture;$null=Invoke-Hf $f (New-HfOp header BOTH '' @(@{text='Prepared';textStyle=@{bold=$true}}))
        $resourceList=$f.Allocation.Resources;$ids=$f.Allocation.charPr;$cache=$f.Allocation.FormatCache
        Assert-HfBlocked $f (New-HfOp header BOTH '' @(@{text='First';textStyle=@{fontFamily='Must Roll Back';italic=$true}},@{runs=@(@{text='Second';textStyle=@{fontSizePt=[double]::NaN}})}))
        [object]::ReferenceEquals($resourceList,$f.Allocation.Resources)|Should Be $true
        [object]::ReferenceEquals($ids,$f.Allocation.charPr)|Should Be $true
        [object]::ReferenceEquals($cache,$f.Allocation.FormatCache)|Should Be $true
    }
    It 'enforces cumulative 16 MiB XML and text budgets without partial allocation changes' {
        $f=New-HfFixture;$f.Allocation.HeaderFooterPreparedCharacters=[long](16MB-1);Assert-HfBlocked $f (New-HfOp)
        $f=New-HfFixture;$f.Allocation.CellTextCharacters=[long](16MB-1);Assert-HfBlocked $f (New-HfOp)
        $f=New-HfFixture;$f.Allocation.ObjectId=[long]4294967295;Assert-HfBlocked $f (New-HfOp)
        $f=New-HfFixture;$f.Allocation.NextParagraphId=[long]4294967296;Assert-HfBlocked $f (New-HfOp)
    }
    It 'rejects a prepared run larger than 16 MiB even when replacement text fits its separate budget' {
        $f=New-HfFixture;$chunk='x'*1MB
        $paragraphs=@(1..16|ForEach-Object {@{text=$chunk}})
        Assert-HfBlocked $f (New-HfOp header BOTH '' $paragraphs)
    }
}
