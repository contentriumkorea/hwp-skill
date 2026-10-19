Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
$namedModule=Get-Module HwpHwpxScopedEdit
& $namedModule {
    param($Root)
    $script:NsTestRoot=$Root
} (Split-Path $PSScriptRoot -Parent)

InModuleScope HwpHwpxScopedEdit {
    $helper=Join-Path $script:NsTestRoot 'skills/hwp-skill/scripts/lib/HwpHwpxNamedStyle.ps1'
    if(Test-Path $helper){. $helper}
    function New-NsPublicFixture($Package,$Directory) {
        $source=Join-Path $Directory 'source.hwpx'
        Copy-Item (Join-Path $script:NsTestRoot 'skills/hwp-skill/templates/default.hwpx') $source
        $zip=[IO.Compression.ZipFile]::Open($source,'Update')
        try{
            foreach($part in @('Contents/header.xml',$Package.Sections[0])){
                $zip.GetEntry($part).Delete();$stream=$zip.CreateEntry($part).Open()
                try{$bytes=[Text.Encoding]::UTF8.GetBytes($Package.Xml[$part].OuterXml);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
            }
            $stream=$zip.CreateEntry('Vendor/untouched.bin').Open()
            try{$bytes=[byte[]]@(0,255,17,35);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
        }finally{$zip.Dispose()}
        return $source
    }
    function Read-NsPublicXml($Path,$Part) {
        $zip=[IO.Compression.ZipFile]::OpenRead($Path)
        try{$reader=[IO.StreamReader]::new($zip.GetEntry($Part).Open());try{[xml]$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
    }
    Describe 'Prepared named paragraph styles' {
        BeforeEach {
            $path=Join-Path $script:NsTestRoot 'skills/hwp-skill/templates/default.hwpx'
            $stream=[IO.File]::OpenRead($path)
            try{$package=Read-ScopedPackage $stream}finally{$stream.Dispose()}
            $package.SourceSha256='a'*64
            $header=$package.Xml['Contents/header.xml'];$ns=New-ScopedNamespaces $header
            $ref=$header.SelectSingleNode('/hh:head/hh:refList',$ns)
            foreach($entry in @(@{Kind='charPr';Collection='charProperties'},@{Kind='paraPr';Collection='paraProperties'})){
                $collection=$ref.SelectSingleNode(('hh:'+$entry.Collection),$ns)
                foreach($item in @($collection.SelectNodes(('hh:'+$entry.Kind+'[@id!="0"]'),$ns))){$null=$collection.RemoveChild($item)}
                $clone=$collection.SelectSingleNode(('hh:'+$entry.Kind+'[@id="0"]'),$ns).CloneNode($true)
                $clone.SetAttribute('id','11')
                if($entry.Kind -ceq 'charPr'){$clone.SetAttribute('height','2400')}else{$clone.SelectSingleNode('hh:align',$ns).SetAttribute('horizontal','CENTER')}
                $vendor=$header.CreateAttribute('v','retained','urn:named-test');$vendor.Value='resource';$null=$clone.Attributes.Append($vendor)
                $null=$collection.AppendChild($clone);$collection.SetAttribute('itemCnt',[string]$collection.SelectNodes('*').Count)
            }
            $styles=$ref.SelectSingleNode('hh:styles',$ns)
            foreach($item in @($styles.SelectNodes('hh:style[@id!="0"]',$ns))){$null=$styles.RemoveChild($item)}
            $fragment=$header.CreateDocumentFragment()
            $fragment.InnerXml='<hh:style xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" id="11" type="PARA" name="Named" engName="Named English" paraPrIDRef="11" charPrIDRef="11" nextStyleIDRef="11" langID="1042" lockForm="0"/>'
            $style=$fragment.FirstChild;$null=$styles.AppendChild($fragment);$styles.SetAttribute('itemCnt',[string]$styles.SelectNodes('*').Count)
            $section=$package.Xml[$package.Sections[0]]
            $fragment=$section.CreateDocumentFragment()
            $fragment.InnerXml='<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:v="urn:named-test" id="110" paraPrIDRef="0" styleIDRef="0" pageBreak="1" v:keep="paragraph"><hp:run charPrIDRef="0" v:keep="run"><hp:t>A<hp:tab width="25" leader="0" type="0"/>B<hp:lineBreak/>C</hp:t></hp:run><hp:run charPrIDRef="11"><hp:t>D</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>'
            $target=$fragment.FirstChild;$null=$section.DocumentElement.AppendChild($fragment)
            $address=@{version='1.0';sourceSha256=$package.SourceSha256;part=$package.Sections[0];path=@($section.DocumentElement.SelectNodes('*').Count-1);kind='p'}
            $op=@{type='apply-named-style';address=$address;styleId='11'};$allocation=@{}
            $originalHeader=$header.OuterXml;$originalSection=$section.OuterXml
        }
        It 'applies both named references to every direct run without allocating or changing content and metadata' {
            $copy=New-ScopedNamedStyle $target $op $package $allocation
            $copy.GetAttribute('styleIDRef')|Should Be '11';$copy.GetAttribute('paraPrIDRef')|Should Be '11'
            @($copy.SelectNodes('hp:run',$ns)|Where-Object {$_.GetAttribute('charPrIDRef') -cne '11'}).Count|Should Be 0
            $copy.SetAttribute('styleIDRef','0');$copy.SetAttribute('paraPrIDRef','0');$copy.SelectSingleNode('hp:run',$ns).SetAttribute('charPrIDRef','0')
            $copy.OuterXml|Should BeExactly $target.OuterXml
            $allocation.ContainsKey('Resources')|Should Be $false
            $header.OuterXml|Should BeExactly $originalHeader;$section.OuterXml|Should BeExactly $originalSection
        }
        It 'clones from named resources rather than target local formatting and remaps a self next style' {
            $op.textStyle=@{bold=$true};$op.paragraphStyle=@{lineSpacingPercent=180};$op.name='Cloned';$op.englishName='Clone English'
            $copy=New-ScopedNamedStyle $target $op $package $allocation
            $resources=@($allocation.Resources);$resources.Count|Should Be 3
            $newStyle=@($resources|Where-Object Kind -eq 'style')[0]
            $copy.GetAttribute('styleIDRef')|Should Be $newStyle.Id;$newStyle.Id|Should Be '12'
            $newStyle.Node.GetAttribute('nextStyleIDRef')|Should Be '12';$newStyle.Node.GetAttribute('name')|Should Be 'Cloned';$newStyle.Node.GetAttribute('engName')|Should Be 'Clone English'
            $char=@($resources|Where-Object Kind -eq 'charPr')[0];$para=@($resources|Where-Object Kind -eq 'paraPr')[0]
            $char.Node.GetAttribute('height')|Should Be '2400';$char.Node.SelectNodes('hh:bold',$ns).Count|Should Be 1
            $para.Node.SelectSingleNode('hh:align',$ns).GetAttribute('horizontal')|Should Be CENTER
            $char.Node.GetAttribute('retained','urn:named-test')|Should Be resource;$para.Node.GetAttribute('retained','urn:named-test')|Should Be resource
            $copy.GetAttribute('paraPrIDRef')|Should Be $para.Id
            @($copy.SelectNodes('hp:run',$ns)|Where-Object {$_.GetAttribute('charPrIDRef') -cne $char.Id}).Count|Should Be 0
            $header.OuterXml|Should BeExactly $originalHeader;$section.OuterXml|Should BeExactly $originalSection
        }
        It 'clones only the named definition for name overrides and preserves an external next style' {
            $style.SetAttribute('nextStyleIDRef','0');$op.englishName=''
            $copy=New-ScopedNamedStyle $target $op $package $allocation
            $allocation.Resources.Count|Should Be 1;$resource=$allocation.Resources[0]
            $resource.Kind|Should Be style;$resource.Node.GetAttribute('nextStyleIDRef')|Should Be '0'
            $resource.Node.GetAttribute('name')|Should Be Named;$resource.Node.GetAttribute('engName')|Should BeExactly ''
            $copy.GetAttribute('paraPrIDRef')|Should Be '11'
        }
        It 'keeps nested control paragraphs and control metadata untouched while applying only outer run refs' {
            $control=$section.CreateDocumentFragment();$control.InnerXml='<hp:ctrl xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:header id="32"><hp:subList><hp:p id="120" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>Nested</hp:t></hp:run></hp:p></hp:subList></hp:header></hp:ctrl>'
            $run=$target.SelectSingleNode('hp:run',$ns);$null=$run.AppendChild($control);$before=$run.SelectSingleNode('hp:ctrl',$ns).OuterXml
            $copy=New-ScopedNamedStyle $target $op $package $allocation
            $copy.SelectSingleNode('hp:run/hp:ctrl',$ns).OuterXml|Should BeExactly $before
        }
        It 'compares the optional visible-text guard ordinally and accepts normalized newlines' {
            $op.expectedText="A`tB`r`nCD";$copy=New-ScopedNamedStyle $target $op $package $allocation
            $copy.GetAttribute('styleIDRef')|Should Be '11'
            $op.expectedText="A`tB`nC"+[char]0xAD+'D';$before=$allocation.Count
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be $before
        }
        It 'rejects a visible-text guard on control-bearing runs rather than guessing their text' {
            $null=$target.SelectSingleNode('hp:run',$ns).AppendChild($section.CreateElement('hp','ctrl',$script:ScopedHp));$op.expectedText="A`tB`nCD"
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 0
        }
        It 'rejects invalid or nonordinal operation input <Case>' -TestCases @(
            @{Case='type case'},@{Case='soft type'},@{Case='key case'},@{Case='soft key'},@{Case='boolean ID'},@{Case='leading zero'},@{Case='trailing newline'},@{Case='unreadable ID'},
            @{Case='null text'},@{Case='empty override'},@{Case='soft format key'},@{Case='soft enum'},@{Case='blank name'},@{Case='long name'},@{Case='invalid XML name'},@{Case='stale address'},@{Case='wrong target'}
        ) {
            param($Case)
            switch($Case){
                'type case'{$op.type='Apply-named-style'};'soft type'{$op.type='apply-named-sty'+[char]0xAD+'le'}
                'key case'{$op.StyleId=$op.styleId;$op.Remove('styleId');$op['StyleId']='11'}
                'soft key'{$op['na'+[char]0xAD+'me']='ignored'};'boolean ID'{$op.styleId=$true};'leading zero'{$op.styleId='011'};'trailing newline'{$op.styleId="11`n"};'unreadable ID'{$op.styleId='2147483648'}
                'null text'{$op.expectedText=$null};'empty override'{$op.textStyle=@{}};'soft format key'{$op.textStyle=@{('bo'+[char]0xAD+'ld')=$true}};'soft enum'{$op.paragraphStyle=@{alignment=('LE'+[char]0xAD+'FT')}}
                'blank name'{$op.name=' '};'long name'{$op.name='x'*257};'invalid XML name'{$op.name='bad'+[char]1};'stale address'{$address.sourceSha256='b'*64};'wrong target'{$address.path=@(0)}
            }
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 0;$header.OuterXml|Should BeExactly $originalHeader;$section.OuterXml|Should BeExactly $originalSection
        }
        It 'rejects unsafe source metadata <Case>' -TestCases @(
            @{Case='CHAR'},@{Case='soft PARA'},@{Case='missing char'},@{Case='missing para'},@{Case='missing next'},@{Case='duplicate ID'},@{Case='collection count'},@{Case='unknown attribute'},@{Case='qualified reference'},@{Case='unknown child'},@{Case='locked style'}
        ) {
            param($Case)
            switch($Case){
                'CHAR'{$style.SetAttribute('type','CHAR')};'soft PARA'{$style.SetAttribute('type','PA'+[char]0xAD+'RA')}
                'missing char'{$style.SetAttribute('charPrIDRef','999')};'missing para'{$style.SetAttribute('paraPrIDRef','999')};'missing next'{$style.SetAttribute('nextStyleIDRef','999')}
                'duplicate ID'{$null=$styles.AppendChild($style.CloneNode($true));$styles.SetAttribute('itemCnt',[string]$styles.SelectNodes('*').Count)}
                'collection count'{$styles.SetAttribute('itemCnt','999')};'unknown attribute'{$style.SetAttribute('future','yes')}
                'qualified reference'{$a=$header.CreateAttribute('v','charPrIDRef','urn:vendor');$a.Value='999';$null=$style.Attributes.Prepend($a)}
                'unknown child'{$null=$style.AppendChild($header.CreateElement('hh','future',$script:ScopedHh))};'locked style'{$style.SetAttribute('lockForm','1')}
            }
            $before=$header.OuterXml;$op.name='Clone'
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 0;$header.OuterXml|Should BeExactly $before;$section.OuterXml|Should BeExactly $originalSection
        }
        It 'leaves an existing allocation unchanged after a late format failure or budget failure' {
            $op.textStyle=@{bold=$true};$op.paragraphStyle=@{alignment='INVALID'}
            $ids=Get-ScopedStyleIds $header 'charPr';$idCount=$ids.Count;$resources=[Collections.Generic.List[object]]::new()
            $allocation=@{charPr=$ids;Resources=$resources;PreparedResourceCharacters=[long]0;FormatCache=@{}}
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $ids.Count|Should Be $idCount;$resources.Count|Should Be 0;$allocation.FormatCache.Count|Should Be 0;$allocation.Count|Should Be 4
            $op.Remove('paragraphStyle');$allocation.PreparedResourceCharacters=[long](16MB)
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $resources.Count|Should Be 0;$allocation.PreparedResourceCharacters|Should Be (16MB);$allocation.Count|Should Be 4
            $header.OuterXml|Should BeExactly $originalHeader
        }
        It 'does not rebase an existing cached high-ID resource before a later paragraph override fails' {
            $collection=$ref.SelectSingleNode('hh:charProperties',$ns)
            $high=$collection.SelectSingleNode('hh:charPr[@id="0"]',$ns).CloneNode($true);$high.SetAttribute('id','2147483647')
            $null=$collection.AppendChild($high);$collection.SetAttribute('itemCnt',[string]$collection.SelectNodes('*').Count)
            $op.textStyle=@{bold=$true};$op.paragraphStyle=@{keepLines='not Boolean'}
            $cached=New-ScopedFormatResource $header $style 'charPr' $op.textStyle $allocation
            $cached.Id|Should Be '2147483648'
            $nodeBefore=$cached.Node.OuterXml;$headerBefore=$header.OuterXml;$keysBefore=$allocation.Count
            $resourcesBefore=$allocation.Resources;$cacheBefore=$allocation.FormatCache;$idsBefore=$allocation.charPr
            $idsTextBefore=(@($idsBefore|Sort-Object) -join ',');$preparedBefore=$allocation.PreparedResourceCharacters;$clonedBefore=$allocation.ClonedResourceCharacters
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $cached.Id|Should Be '2147483648';$cached.Node.OuterXml|Should BeExactly $nodeBefore
            [object]::ReferenceEquals($allocation.Resources,$resourcesBefore)|Should Be $true
            [object]::ReferenceEquals($allocation.FormatCache,$cacheBefore)|Should Be $true
            [object]::ReferenceEquals($allocation.charPr,$idsBefore)|Should Be $true
            [object]::ReferenceEquals($allocation.Resources[0],$cached)|Should Be $true
            [object]::ReferenceEquals(@($allocation.FormatCache.Values)[0],$cached)|Should Be $true
            $allocation.Resources.Count|Should Be 1;$allocation.FormatCache.Count|Should Be 1;$allocation.Count|Should Be $keysBefore
            (@($allocation.charPr|Sort-Object) -join ',')|Should BeExactly $idsTextBefore
            $allocation.PreparedResourceCharacters|Should Be $preparedBefore;$allocation.ClonedResourceCharacters|Should Be $clonedBefore
            $header.OuterXml|Should BeExactly $headerBefore;$section.OuterXml|Should BeExactly $originalSection
        }
        It 'rejects a textColor with a trailing LF before staging or creating a public output' {
            $op.textStyle=@{textColor="#112233`n"}
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 0;$header.OuterXml|Should BeExactly $originalHeader;$section.OuterXml|Should BeExactly $originalSection
            $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $dir
            $source=New-NsPublicFixture $package $dir;$hash=(Get-FileHash $source).Hash;$output=Join-Path $dir 'color.hwpx'
            $inspection=Get-HwpxPackageInspection -LiteralPath $source
            $p=@($inspection.Data.Paragraphs|Where-Object {$_.text -eq "A`tB`nCD" -or $_.text -eq "A`tB`r`nCD"})[0]
            $op.address=$p.address
            $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{version='2.0';operations=@($op)}
            $result.Status|Should Be BLOCKED;Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $hash
            @(Get-ChildItem $dir -Filter '*.partial.hwpx' -Force).Count|Should Be 0
            $op.textStyle.textColor='#aBc123'
            $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{version='2.0';operations=@($op)}
            ($result.Errors -join '; ')|Should Be ''
            (Read-NsPublicXml $output 'Contents/header.xml').SelectSingleNode('//*[local-name()="charPr" and @id="12"]').GetAttribute('textColor')|Should BeExactly '#aBc123'
            (Get-FileHash $source).Hash|Should Be $hash
        }
        It 'reserves unique inspectable style and format IDs across prepared operations at the Int32 boundary' {
            $style.SetAttribute('id','2147483647');$style.SetAttribute('nextStyleIDRef','2147483647');$op.styleId='2147483647'
            foreach($kind in @('charPr','paraPr')){$node=$ref.SelectSingleNode(('.//hh:'+$kind+'[@id="11"]'),$ns);$node.SetAttribute('id','2147483647');$style.SetAttribute(($kind+'IDRef'),'2147483647')}
            $op.textStyle=@{fontSizePt=32};$op.paragraphStyle=@{alignment='RIGHT'}
            $a=New-ScopedNamedStyle $target $op $package $allocation;$b=New-ScopedNamedStyle $target $op $package $allocation
            $a.GetAttribute('styleIDRef')|Should Not Be $b.GetAttribute('styleIDRef')
            foreach($resource in $allocation.Resources){[long]$resource.Id|Should BeLessOrEqual ([int]::MaxValue)}
            @($allocation.Resources|Where-Object Kind -eq style).Count|Should Be 2
            @($allocation.Resources|Where-Object Kind -eq charPr).Count|Should Be 1
        }
        It 'bounds paragraph clones and cumulative paragraph preparations before changing allocation' {
            $allocation=@{NamedStylePreparedCharacters=[long](16MB)}
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 1
            $allocation=@{};$run=$target.SelectSingleNode('hp:run',$ns)
            for($i=0;$i -lt 4096;$i++){$null=$target.AppendChild($run.CloneNode($true))}
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 0
        }
        It 'rejects a reserved but absent format definition instead of preparing a dangling named style' {
            $style.SetAttribute('charPrIDRef','999')
            $allocation=@{charPr=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)};$null=$allocation.charPr.Add('999')
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 1
        }
        It 'bounds resource subtree depth before cloning unknown resource metadata' {
            $node=$ref.SelectSingleNode('hh:charProperties/hh:charPr[@id="11"]',$ns)
            for($i=0;$i -lt 66;$i++){$node=$node.AppendChild($header.CreateElement('v','retained','urn:named-test'))}
            $op.textStyle=@{bold=$true}
            {New-ScopedNamedStyle $target $op $package $allocation}|Should Throw
            $allocation.Count|Should Be 0
        }
        It 'applies and clones through the public file pipeline preserving source resources assets and inspectability' {
            $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $dir
            $source=New-NsPublicFixture $package $dir;$hash=(Get-FileHash $source).Hash
            $inspection=Get-HwpxPackageInspection -LiteralPath $source;($inspection.Errors -join '; ')|Should Be ''
            $p=@($inspection.Data.Paragraphs|Where-Object {$_.text -eq "A`tB`nCD" -or $_.text -eq "A`tB`r`nCD"})[0]
            $output=Join-Path $dir 'applied.hwpx'
            $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{version='2.0';operations=@(@{type='apply-named-style';address=$p.address;styleId=11})}
            ($result.Errors -join '; ')|Should Be ''
            $after=Read-NsPublicXml $output 'Contents/section0.xml';$applied=$after.SelectSingleNode('//*[local-name()="p" and @id="110"]')
            $applied.GetAttribute('styleIDRef')|Should Be '11';$applied.GetAttribute('paraPrIDRef')|Should Be '11'
            $applied.SelectNodes('*[local-name()="run"]/*[local-name()="t"]/*').Count|Should Be 2
            $after.SelectNodes('//*[local-name()="linesegarray"]').Count|Should Be 0
            (Read-NsPublicXml $output 'Contents/header.xml').OuterXml|Should BeExactly $header.OuterXml
            $inspection=Get-HwpxPackageInspection -LiteralPath $output;($inspection.Errors -join '; ')|Should Be ''
            $p=@($inspection.Data.Paragraphs|Where-Object {$_.text -eq "A`tB`nCD" -or $_.text -eq "A`tB`r`nCD"})[0]
            $cloned=Join-Path $dir 'cloned.hwpx'
            $result=Invoke-HwpxScopedEdit -LiteralPath $output -OutputPath $cloned -Plan @{version='2.0';operations=@(@{type='apply-named-style';address=$p.address;styleId=11;textStyle=@{fontSizePt=32};paragraphStyle=@{alignment='RIGHT'};name='Independent'})}
            ($result.Errors -join '; ')|Should Be ''
            $inspection=Get-HwpxPackageInspection -LiteralPath $cloned;($inspection.Errors -join '; ')|Should Be ''
            @($inspection.Data.Resources.styles|Where-Object name -eq Independent).Count|Should Be 1
            $newHeader=Read-NsPublicXml $cloned 'Contents/header.xml'
            $newHeader.SelectSingleNode('//*[local-name()="style" and @id="11"]').OuterXml|Should BeExactly $style.OuterXml
            foreach($kind in @('charPr','paraPr')){
                $newHeader.SelectSingleNode(('//*[local-name()="'+$kind+'" and @id="11"]')).OuterXml|Should BeExactly $header.SelectSingleNode(('//*[local-name()="'+$kind+'" and @id="11"]')).OuterXml
            }
            $zip=[IO.Compression.ZipFile]::OpenRead($cloned)
            try{$stream=$zip.GetEntry('Vendor/untouched.bin').Open();try{$data=[byte[]]::new(4);$stream.Read($data,0,4)|Should Be 4;[BitConverter]::ToString($data)|Should Be '00-FF-11-23'}finally{$stream.Dispose()}}finally{$zip.Dispose()}
            (Get-FileHash $source).Hash|Should Be $hash
        }
        It 'blocks a late public operation without creating output or committing prepared clones' {
            $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $dir
            $source=New-NsPublicFixture $package $dir;$hash=(Get-FileHash $source).Hash
            $inspection=Get-HwpxPackageInspection -LiteralPath $source
            $p=@($inspection.Data.Paragraphs|Where-Object {$_.text -eq "A`tB`nCD" -or $_.text -eq "A`tB`r`nCD"})[0]
            $q=@($inspection.Data.Paragraphs|Where-Object {$_.address.path[0] -ne $p.address.path[0]})[0]
            $output=Join-Path $dir 'blocked.hwpx'
            $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{version='2.0';operations=@(
                @{type='apply-named-style';address=$p.address;styleId=11;textStyle=@{bold=$true}},
                @{type='apply-named-style';address=$q.address;styleId=11;paragraphStyle=@{alignment='INVALID'}}
            )}
            $result.Status|Should Be BLOCKED;Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $hash
            @(Get-ChildItem $dir -Filter '*.partial.hwpx' -Force).Count|Should Be 0
        }
        It 'roundtrips sparse Int32 boundary IDs and shares prepared format clones across distinct public targets' {
            $style.SetAttribute('id','2147483647');$style.SetAttribute('nextStyleIDRef','2147483647')
            foreach($kind in @('charPr','paraPr')){
                $node=$ref.SelectSingleNode(('.//hh:'+$kind+'[@id="11"]'),$ns);$node.SetAttribute('id','2147483647')
                $style.SetAttribute(($kind+'IDRef'),'2147483647')
            }
            $target.SelectNodes('hp:run',$ns)[1].SetAttribute('charPrIDRef','2147483647')
            $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $dir
            $source=New-NsPublicFixture $package $dir;$output=Join-Path $dir 'boundary.hwpx'
            $inspection=Get-HwpxPackageInspection -LiteralPath $source;($inspection.Errors -join '; ')|Should Be ''
            $p=@($inspection.Data.Paragraphs|Where-Object {$_.text -eq "A`tB`nCD" -or $_.text -eq "A`tB`r`nCD"})[0]
            $q=@($inspection.Data.Paragraphs|Where-Object {$_.address.path[0] -ne $p.address.path[0]})[0]
            $ops=@($p,$q)|ForEach-Object {@{type='apply-named-style';address=$_.address;styleId='2147483647';textStyle=@{fontSizePt=32};paragraphStyle=@{alignment='RIGHT'}}}
            $result=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{version='2.0';operations=@($ops)}
            ($result.Errors -join '; ')|Should Be ''
            $inspection=Get-HwpxPackageInspection -LiteralPath $output;($inspection.Errors -join '; ')|Should Be ''
            $h=Read-NsPublicXml $output 'Contents/header.xml'
            foreach($kind in @('charPr','paraPr')){$h.SelectNodes(('//*[local-name()="'+$kind+'"]')).Count|Should Be 3}
            $h.SelectNodes('//*[local-name()="style"]').Count|Should Be 4
            $s=Read-NsPublicXml $output 'Contents/section0.xml';$first=$s.DocumentElement.SelectNodes('*')[0];$last=$s.SelectSingleNode('//*[local-name()="p" and @id="110"]')
            $first.GetAttribute('styleIDRef')|Should Not Be $last.GetAttribute('styleIDRef')
            $first.GetAttribute('paraPrIDRef')|Should Be $last.GetAttribute('paraPrIDRef')
            $s.SelectNodes('//*[local-name()="linesegarray"]').Count|Should Be 0
            @($inspection.Data.Resources.styles|Where-Object {$_.id -lt 2147483647 -and $_.id -ne 0}).Count|Should Be 2
        }
    }
}
