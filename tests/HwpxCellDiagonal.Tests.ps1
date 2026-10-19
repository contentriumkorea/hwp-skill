# Independent fixtures and private-helper tests: dispatcher integration belongs to the parent.
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
$script:CdModule=Get-Module HwpHwpxScopedEdit
$script:CdHelper=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxCellDiagonal.ps1'
function Read-CdPackage($Path) {
    & $script:CdModule {param($Path) $stream=[IO.File]::OpenRead($Path);try{Read-ScopedPackage $stream}finally{$stream.Dispose()}} $Path
}

function Test-CdPublicPipeline {
Describe 'Public cell diagonal pipeline integration' {
    BeforeEach {
        $directory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $directory
        $f=New-CdFixture $directory
    }
    It 'commits and inspects <Direction> while preserving other cells original styles and binary parts' -TestCases @(
        @{Direction='SLASH';Slash='CENTER';Back='NONE'},@{Direction='BACK_SLASH';Slash='NONE';Back='CENTER'},
        @{Direction='CROSS';Slash='CENTER';Back='CENTER'},@{Direction='NONE';Slash='NONE';Back='NONE'}
    ) {
        param($Direction,$Slash,$Back)
        $hash=(Get-FileHash $f.Source).Hash;$before=Read-CdPackage $f.Source
        $op=New-CdOperation $f $Direction
        $result=Invoke-HwpxScopedEdit -LiteralPath $f.Source -OutputPath $f.Output -Plan @{version='2.0';operations=@($op)}
        ($result.Errors -join '; ')|Should Be ''
        $after=Read-CdPackage $f.Output;$header=$after.Xml['Contents/header.xml'];$section=$after.Xml['Contents/section0.xml']
        $cell=$section.SelectSingleNode('//*[local-name()="tc" and @name="Keep"]');$cell.GetAttribute('borderFillIDRef')|Should Be '3'
        $cell.SetAttribute('borderFillIDRef','2');$cell.OuterXml|Should BeExactly $f.Cell.OuterXml
        $section.SelectSingleNode('//*[local-name()="tc" and @name="Other"]').OuterXml|Should BeExactly $f.Cell.NextSibling.OuterXml
        $border=$header.SelectSingleNode('//*[local-name()="borderFill" and @id="3"]')
        $border.SelectSingleNode('*[local-name()="slash"]').GetAttribute('type')|Should BeExactly $Slash
        $border.SelectSingleNode('*[local-name()="backSlash"]').GetAttribute('type')|Should BeExactly $Back
        $header.SelectSingleNode('//*[local-name()="borderFill" and @id="2"]').OuterXml|Should BeExactly $before.Xml['Contents/header.xml'].SelectSingleNode('//*[local-name()="borderFill" and @id="2"]').OuterXml
        $header.SelectSingleNode('//*[local-name()="borderFills"]').GetAttribute('itemCnt')|Should Be '3'
        foreach($part in $before.Parts.Keys){if($part -cin @('Contents/header.xml','Contents/section0.xml') -or $part -match '^Preview/'){continue};[Convert]::ToBase64String($after.Parts[$part].Bytes)|Should BeExactly ([Convert]::ToBase64String($before.Parts[$part].Bytes))}
        $inspection=Get-HwpxPackageInspection -LiteralPath $f.Output;($inspection.Errors -join '; ')|Should Be ''
        (Get-FileHash $f.Source).Hash|Should Be $hash
    }
    It 'rejects duplicate and nested subtree conflicts in both operation orders without output' {
        $inspection=Get-HwpxPackageInspection -LiteralPath $f.Source
        $run=@($inspection.Data.Paragraphs|Where-Object text -eq 'Keep text')[0].charShapeRuns[0]
        $diagonal=New-CdOperation $f
        $child=@{type='set-run-style';address=$run.address;charPrIDRef='0'}
        $hash=(Get-FileHash $f.Source).Hash
        foreach($ops in @(@($diagonal,$diagonal),@($diagonal,$child),@($child,$diagonal))){
            $result=Invoke-HwpxScopedEdit -LiteralPath $f.Source -OutputPath $f.Output -Plan @{version='2.0';operations=$ops}
            $result.Status|Should Be 'BLOCKED';($result.Errors -join ' ')|Should Match 'Duplicate target property|Overlapping subtree'
            Test-Path $f.Output|Should Be $false;(Get-FileHash $f.Source).Hash|Should Be $hash
        }
    }
    It 'blocks a late invalid operation without committing an earlier diagonal or prepared resource' {
        $other=@((Get-HwpxPackageInspection -LiteralPath $f.Source).Data.Tables[0].cells|Where-Object text -eq 'Other')[0]
        $first=New-CdOperation $f;$second=New-CdOperation $f;$second.address=$other.address;$second.line.widthMm=0.13
        $hash=(Get-FileHash $f.Source).Hash
        $result=Invoke-HwpxScopedEdit -LiteralPath $f.Source -OutputPath $f.Output -Plan @{version='2.0';operations=@($first,$second)}
        $result.Status|Should Be 'BLOCKED';($result.Errors -join ' ')|Should Match 'thickness'
        Test-Path $f.Output|Should Be $false;(Get-FileHash $f.Source).Hash|Should Be $hash
        @(Get-ChildItem -LiteralPath (Split-Path $f.Output) -Filter '*.partial.hwpx' -Force).Count|Should Be 0
    }
}
}
function Write-CdPart($Path,$Part,[xml]$Xml) {
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try{$zip.GetEntry($Part).Delete();$stream=$zip.CreateEntry($Part).Open();$bytes=[Text.Encoding]::UTF8.GetBytes($Xml.OuterXml);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
}
function New-CdFixture($Directory) {
    $source=Join-Path $Directory 'source.hwpx';$output=Join-Path $Directory 'output.hwpx'
    Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
    $package=Read-CdPackage $source;$header=$package.Xml['Contents/header.xml'];$section=$package.Xml['Contents/section0.xml']
    $border=$header.SelectSingleNode('//*[local-name()="borderFill" and @id="2"]')
    $fragment=$header.CreateDocumentFragment()
    $fragment.InnerXml='<hh:borderFill xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" xmlns:v="urn:vendor" id="2" threeD="0" shadow="0" centerLine="NONE" breakCellSeparateLine="0" v:keep="resource"><hh:slash type="NONE" Crooked="0" isCounter="0" v:type="opaque"/><hh:backSlash type="NONE" Crooked="0" isCounter="0"/><hh:leftBorder type="DASH" width="0.2 mm" color="#123456"/><hh:rightBorder type="SOLID" width="0.3 mm" color="#234567"/><hh:topBorder type="DOT" width="0.4 mm" color="#345678"/><hh:bottomBorder type="SOLID" width="0.5 mm" color="#456789"/><hh:diagonal type="SOLID" width="0.1 mm" color="#000000" v:keep="line"><v:future value="opaque"/></hh:diagonal><hc:fillBrush xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"><hc:winBrush faceColor="#EEFFAA" hatchColor="#999999" alpha="0"/></hc:fillBrush><!--keep--><v:future value="resource"/></hh:borderFill>'
    $null=$border.ParentNode.ReplaceChild($fragment.FirstChild,$border)
    $fragment=$section.CreateDocumentFragment()
    $fragment.InnerXml='<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:v="urn:vendor" id="100" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:tbl id="100000" rowCnt="1" colCnt="2" cellSpacing="0" borderFillIDRef="2" lock="0"><hp:tr><hp:tc name="Keep" borderFillIDRef="2" protect="0" editable="0" v:keep="cell"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER"><hp:p id="101" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Keep text</hp:t></hp:run></hp:p></hp:subList><hp:cellAddr rowAddr="0" colAddr="0"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="3000" height="2000"/><hp:cellMargin left="100" right="100" top="100" bottom="100"/><v:future value="cell"/></hp:tc><hp:tc name="Other" borderFillIDRef="2" protect="0"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER"><hp:p id="102" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Other</hp:t></hp:run></hp:p></hp:subList><hp:cellAddr rowAddr="0" colAddr="1"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="3000" height="2000"/></hp:tc></hp:tr></hp:tbl></hp:run></hp:p>'
    $null=$section.DocumentElement.AppendChild($fragment)
    Write-CdPart $source 'Contents/header.xml' $header;Write-CdPart $source 'Contents/section0.xml' $section
    $package=Read-CdPackage $source;$package.SourceSha256=(Get-FileHash $source).Hash
    $cell=$package.Xml['Contents/section0.xml'].SelectSingleNode('//*[local-name()="tc" and @name="Keep"]')
    $address=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells|Where-Object text -eq 'Keep text')[0].address
    return @{Source=$source;Output=$output;Package=$package;Cell=$cell;Address=$address;Allocation=@{}}
}
function New-CdOperation($Fixture,$Direction='SLASH') {
    $op=@{type='set-cell-diagonal';address=$Fixture.Address;direction=$Direction}
    if($Direction -cne 'NONE'){$op.line=@{type='SOLID';widthMm=0.12;color='#000000'}}
    return $op
}
function Invoke-CdHelper($Fixture,$Operation) {
    & $script:CdModule {
        param($Helper,$Fixture,$Operation)
        if(Test-Path -LiteralPath $Helper){. $Helper}
        New-ScopedCellDiagonal $Fixture.Cell $Operation $Fixture.Package $Fixture.Allocation
    } $script:CdHelper $Fixture $Operation
}
function Assert-CdRejected($Fixture,$Operation) {
    $header=$Fixture.Package.Xml['Contents/header.xml'].OuterXml;$section=$Fixture.Cell.OwnerDocument.OuterXml
    $hash=(Get-FileHash $Fixture.Source).Hash;$keys=$Fixture.Allocation.Count
    # A missing helper must fail the test, not satisfy an expected throw.
    Test-Path -LiteralPath $script:CdHelper|Should Be $true
    $caught=$null;try{$null=Invoke-CdHelper $Fixture $Operation}catch{$caught=$_.Exception}
    $caught|Should Not BeNullOrEmpty
    $Fixture.Allocation.Count|Should Be $keys
    $Fixture.Package.Xml['Contents/header.xml'].OuterXml|Should BeExactly $header
    $Fixture.Cell.OwnerDocument.OuterXml|Should BeExactly $section
    (Get-FileHash $Fixture.Source).Hash|Should Be $hash
    Test-Path $Fixture.Output|Should Be $false
}

Describe 'Scoped cell diagonal preparation from pinned Hancom storage' {
    BeforeEach {
        $directory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $directory
        $f=New-CdFixture $directory
    }
    It 'prepares <Direction> with independent literal slash flags and preserves all unrelated XML' -TestCases @(
        @{Direction='SLASH';Slash='CENTER';BackSlash='NONE'},
        @{Direction='BACK_SLASH';Slash='NONE';BackSlash='CENTER'},
        @{Direction='CROSS';Slash='CENTER';BackSlash='CENTER'},
        @{Direction='NONE';Slash='NONE';BackSlash='NONE'}
    ) {
        param($Direction,$Slash,$BackSlash)
        $header=$f.Package.Xml['Contents/header.xml'];$before=$header.OuterXml;$cellBefore=$f.Cell.OuterXml
        $source=$header.SelectSingleNode('//*[local-name()="borderFill" and @id="2"]')
        $result=Invoke-CdHelper $f (New-CdOperation $f $Direction)
        $result -is [Xml.XmlElement]|Should Be $true;$result.GetAttribute('borderFillIDRef')|Should Be '3'
        $result.SetAttribute('borderFillIDRef','2');$result.OuterXml|Should BeExactly $cellBefore
        $header.OuterXml|Should BeExactly $before;$f.Cell.OuterXml|Should BeExactly $cellBefore
        $f.Allocation.Resources.Count|Should Be 1;$resource=$f.Allocation.Resources[0]
        $resource.Id|Should Be '3';$resource.Kind|Should Be 'borderFill';$resource.CountAttribute|Should Be 'itemCnt'
        [object]::ReferenceEquals($resource.Collection,$source.ParentNode)|Should Be $true
        $resource.Node.SelectSingleNode('*[local-name()="slash"]').GetAttribute('type')|Should BeExactly $Slash
        $resource.Node.SelectSingleNode('*[local-name()="backSlash"]').GetAttribute('type')|Should BeExactly $BackSlash
        foreach($name in @('leftBorder','rightBorder','topBorder','bottomBorder','fillBrush','future')){
            $resource.Node.SelectSingleNode('*[local-name()="'+$name+'"]').OuterXml|Should BeExactly $source.SelectSingleNode('*[local-name()="'+$name+'"]').OuterXml
        }
        $diagonal=$resource.Node.SelectSingleNode('*[local-name()="diagonal"]')
        if($Direction -ceq 'NONE'){$diagonal.OuterXml|Should BeExactly $source.SelectSingleNode('*[local-name()="diagonal"]').OuterXml}
        else{$diagonal.GetAttribute('type')|Should BeExactly 'SOLID';$diagonal.GetAttribute('width')|Should BeExactly '0.12 mm';$diagonal.GetAttribute('color')|Should BeExactly '#000000'}
        $diagonal.GetAttribute('keep','urn:vendor')|Should BeExactly 'line'
        $diagonal.FirstChild.OuterXml|Should BeExactly '<v:future value="opaque" xmlns:v="urn:vendor" />'
        $resource.Node.GetAttribute('keep','urn:vendor')|Should BeExactly 'resource'
    }
    It 'clears both existing straight diagonals without resetting line style or safe legacy flags' {
        $border=$f.Package.Xml['Contents/header.xml'].SelectSingleNode('//*[local-name()="borderFill" and @id="2"]')
        foreach($name in @('slash','backSlash')){$node=$border.SelectSingleNode('*[local-name()="'+$name+'"]');$node.SetAttribute('type','CENTER');$node.RemoveAttribute('Crooked');$node.SetAttribute('isCrooked','0');$node.SetAttribute('isCounter','false')}
        $line=$border.SelectSingleNode('*[local-name()="diagonal"]');$line.SetAttribute('type','DOT');$line.SetAttribute('width','0.7 mm');$line.SetAttribute('color','#ABCDEF')
        $null=Invoke-CdHelper $f (New-CdOperation $f 'NONE');$copy=$f.Allocation.Resources[0].Node
        foreach($name in @('slash','backSlash')){$node=$copy.SelectSingleNode('*[local-name()="'+$name+'"]');$node.GetAttribute('type')|Should BeExactly 'NONE';$node.GetAttribute('isCrooked')|Should BeExactly '0';$node.HasAttribute('Crooked')|Should Be $false;$node.GetAttribute('isCounter')|Should BeExactly 'false'}
        $copy.SelectSingleNode('*[local-name()="diagonal"]').OuterXml|Should BeExactly $line.OuterXml
    }
    It 'uses official line types and exact millimeter widths independent of culture' {
        $old=[Threading.Thread]::CurrentThread.CurrentCulture
        try{[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $op=New-CdOperation $f;$op.line=@{type='DOUBLE_SLIM';widthMm=[decimal]1.0;color='#aBcDeF'}
            $null=Invoke-CdHelper $f $op;$line=$f.Allocation.Resources[0].Node.SelectSingleNode('*[local-name()="diagonal"]')
            $line.GetAttribute('type')|Should BeExactly 'DOUBLE_SLIM';$line.GetAttribute('width')|Should BeExactly '1.0 mm';$line.GetAttribute('color')|Should BeExactly '#aBcDeF'
        }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$old}
    }
    It 'allocates distinct IDs across pending ordinary border edits and diagonal edits' {
        & $script:CdModule {param($f) $null=New-ScopedBorderResource $f.Package.Xml['Contents/header.xml'] $f.Cell @{borderColor='#112233'} $f.Allocation} $f
        $first=Invoke-CdHelper $f (New-CdOperation $f)
        $second=Invoke-CdHelper $f (New-CdOperation $f 'CROSS')
        $first.GetAttribute('borderFillIDRef')|Should Be '4';$second.GetAttribute('borderFillIDRef')|Should Be '5'
        ($f.Allocation.Resources|ForEach-Object Id) -join ','|Should Be '3,4,5'
    }
    It 'reserves its new ID for a following ordinary border edit' {
        $null=Invoke-CdHelper $f (New-CdOperation $f)
        $resource=& $script:CdModule {param($f) New-ScopedBorderResource $f.Package.Xml['Contents/header.xml'] $f.Cell @{borderColor='#112233'} $f.Allocation} $f
        $resource.Id|Should Be '4';($f.Allocation.Resources|ForEach-Object Id) -join ','|Should Be '3,4'
    }
    It 'emits every supported line style and width from the shipped catalog without the ignored snapshot' {
        $catalog=Get-Content (Join-Path $PSScriptRoot '../skills/hwp-skill/references/hwpx-model-catalog.json') -Raw|ConvertFrom-Json
        $catalog.source.commit|Should BeExactly '1453388472c703a4b299a0834f425cdac16644b9'
        ($catalog.classes.CSlashType.writeAttributes.name -join ',')|Should BeExactly 'type,Crooked,isCounter'
        ($catalog.enums.g_SlashTypeList -join ',')|Should BeExactly 'NONE,CENTER,CENTER_BELOW,CENTER_ABOVE,ALL'
        foreach($type in $catalog.enums.g_LineTypeList2){
            if($type -ceq 'NONE'){continue}
            $op=New-CdOperation $f;$op.line.type=$type;$null=Invoke-CdHelper $f $op
            $f.Allocation.Resources[$f.Allocation.Resources.Count-1].Node.SelectSingleNode('*[local-name()="diagonal"]').GetAttribute('type')|Should BeExactly $type
        }
        foreach($width in $catalog.enums.g_LineWithList){
            $op=New-CdOperation $f;$op.line.widthMm=[decimal]::Parse($width.Replace(' mm',''),[Globalization.CultureInfo]::InvariantCulture)
            $null=Invoke-CdHelper $f $op
            $f.Allocation.Resources[$f.Allocation.Resources.Count-1].Node.SelectSingleNode('*[local-name()="diagonal"]').GetAttribute('width')|Should BeExactly $width
        }
    }
    It 'keeps IDs readable with a sparse existing Int32 maximum and reserves pending IDs' {
        $header=$f.Package.Xml['Contents/header.xml'];$header.SelectSingleNode('//*[local-name()="borderFill" and @id="1"]').SetAttribute('id','2147483647')
        $first=Invoke-CdHelper $f (New-CdOperation $f);$second=Invoke-CdHelper $f (New-CdOperation $f)
        $first.GetAttribute('borderFillIDRef')|Should Be '1';$second.GetAttribute('borderFillIDRef')|Should Be '3'
    }
    It 'serializes and reopens actual input and output packages while preserving original parts and cells' {
        $hash=(Get-FileHash $f.Source).Hash;$before=$f.Cell.OuterXml
        $other=$f.Cell.NextSibling.OuterXml;$result=Invoke-CdHelper $f (New-CdOperation $f 'CROSS')
        $resource=$f.Allocation.Resources[0];$null=$resource.Collection.AppendChild($resource.Node);$resource.Collection.SetAttribute('itemCnt','3')
        $null=$f.Cell.ParentNode.ReplaceChild($result,$f.Cell)
        Copy-Item $f.Source $f.Output;Write-CdPart $f.Output 'Contents/header.xml' $f.Package.Xml['Contents/header.xml'];Write-CdPart $f.Output 'Contents/section0.xml' $f.Package.Xml['Contents/section0.xml']
        $read=Read-CdPackage $f.Output;$source=Read-CdPackage $f.Source
        $read.Xml['Contents/section0.xml'].SelectSingleNode('//*[local-name()="tc" and @name="Other"]').OuterXml|Should BeExactly $other
        $read.Xml['Contents/section0.xml'].SelectSingleNode('//*[local-name()="tc" and @name="Keep"]').GetAttribute('borderFillIDRef')|Should Be '3'
        $read.Xml['Contents/header.xml'].SelectSingleNode('//*[local-name()="borderFill" and @id="2"]').OuterXml|Should BeExactly $source.Xml['Contents/header.xml'].SelectSingleNode('//*[local-name()="borderFill" and @id="2"]').OuterXml
        foreach($part in $source.Parts.Keys){if($part -cin @('Contents/header.xml','Contents/section0.xml')){continue};[Convert]::ToBase64String($read.Parts[$part].Bytes)|Should BeExactly ([Convert]::ToBase64String($source.Parts[$part].Bytes))}
        (Get-FileHash $f.Source).Hash|Should Be $hash
        $inspection=Get-HwpxPackageInspection -LiteralPath $f.Output;($inspection.Errors -join '; ')|Should Be ''
    }
    It 'rejects invalid operation variant <Variant> without staging or mutating the original' -TestCases @(
        @{Variant='lowercase direction'},@{Variant='soft hyphen direction'},@{Variant='newline direction'},@{Variant='numeric direction'},@{Variant='absent direction'},
        @{Variant='wrong type'},@{Variant='soft hyphen key'},@{Variant='unknown key'},@{Variant='missing line'},@{Variant='null line'},@{Variant='line on NONE'},
        @{Variant='lowercase line type'},@{Variant='soft hyphen line type'},@{Variant='unsupported line type'},@{Variant='absent line color'},@{Variant='unknown line key'},
        @{Variant='string width'},@{Variant='Boolean width'},@{Variant='NaN width'},@{Variant='infinite width'},@{Variant='unlisted width'},@{Variant='overprecision width'},
        @{Variant='bad color'},@{Variant='newline color'},@{Variant='null direction'},@{Variant='missing address'}
    ) {
        param($Variant)
        $op=New-CdOperation $f
        switch($Variant){
            'lowercase direction'{$op.direction='slash'} 'soft hyphen direction'{$op.direction='SL'+[char]0xAD+'ASH'} 'newline direction'{$op.direction="SLASH`n"}
            'numeric direction'{$op.direction=1} 'absent direction'{$op.Remove('direction')} 'wrong type'{$op.type='SET-CELL-DIAGONAL'}
            'soft hyphen key'{$op['direc'+[char]0xAD+'tion']=$op.direction;$op.Remove('direction')} 'unknown key'{$op.extra=1}
            'missing line'{$op.Remove('line')} 'null line'{$op.line=$null} 'line on NONE'{$op.direction='NONE'}
            'lowercase line type'{$op.line.type='solid'} 'soft hyphen line type'{$op.line.type='SO'+[char]0xAD+'LID'} 'unsupported line type'{$op.line.type='DOUBLE'}
            'absent line color'{$op.line.Remove('color')} 'unknown line key'{$op.line.extra=1}
            'string width'{$op.line.widthMm='0.12'} 'Boolean width'{$op.line.widthMm=$true} 'NaN width'{$op.line.widthMm=[double]::NaN}
            'infinite width'{$op.line.widthMm=[double]::PositiveInfinity} 'unlisted width'{$op.line.widthMm=0.13} 'overprecision width'{$op.line.widthMm=[decimal]::Parse('0.1200000000000000000000000001',[Globalization.CultureInfo]::InvariantCulture)}
            'bad color'{$op.line.color='black'} 'newline color'{$op.line.color="#000000`n"} 'null direction'{$op.direction=$null} 'missing address'{$op.Remove('address')}
        }
        Assert-CdRejected $f $op
    }
    It 'rejects ambiguous or complex stored variant <Variant> before allocating resources' -TestCases @(
        @{Variant='crooked'},@{Variant='counter'},@{Variant='both crooked names'},@{Variant='missing crooked'},@{Variant='invalid counter'},@{Variant='curved extension'},
        @{Variant='complex slash'},@{Variant='lowercase slash'},@{Variant='soft hyphen slash'},@{Variant='duplicate slash'},@{Variant='missing slash'},
        @{Variant='duplicate diagonal'},@{Variant='wrong count'},@{Variant='duplicate ID'},@{Variant='missing reference'},@{Variant='newline ID'},
        @{Variant='protected cell'},@{Variant='foreign target'},@{Variant='wrong target'},@{Variant='bad stored width'},@{Variant='conflicting pending ID'}
    ) {
        param($Variant)
        $header=$f.Package.Xml['Contents/header.xml'];$border=$header.SelectSingleNode('//*[local-name()="borderFill" and @id="2"]');$slash=$border.SelectSingleNode('*[local-name()="slash"]')
        switch($Variant){
            'crooked'{$slash.SetAttribute('Crooked','1')} 'counter'{$slash.SetAttribute('isCounter','1')} 'both crooked names'{$slash.SetAttribute('isCrooked','0')}
            'missing crooked'{$slash.RemoveAttribute('Crooked')} 'invalid counter'{$slash.SetAttribute('isCounter','False')} 'curved extension'{$slash.SetAttribute('curved','1')}
            'complex slash'{$slash.SetAttribute('type','CENTER_BELOW')} 'lowercase slash'{$slash.SetAttribute('type','center')} 'soft hyphen slash'{$slash.SetAttribute('type','CE'+[char]0xAD+'NTER')}
            'duplicate slash'{$null=$border.AppendChild($slash.CloneNode($true))} 'missing slash'{$null=$border.RemoveChild($slash)}
            'duplicate diagonal'{$null=$border.AppendChild($border.SelectSingleNode('*[local-name()="diagonal"]').CloneNode($true))}
            'wrong count'{$border.ParentNode.SetAttribute('itemCnt','3')} 'duplicate ID'{$null=$border.ParentNode.AppendChild($border.CloneNode($true));$border.ParentNode.SetAttribute('itemCnt','3')}
            'missing reference'{$f.Cell.SetAttribute('borderFillIDRef','999')} 'newline ID'{$f.Cell.SetAttribute('borderFillIDRef',"2`n")}
            'protected cell'{$f.Cell.SetAttribute('protect','1')} 'foreign target'{$doc=[xml]$f.Cell.OuterXml;$f.Cell=$doc.DocumentElement}
            'wrong target'{$f.Cell=$f.Cell.ParentNode} 'bad stored width'{$border.SelectSingleNode('*[local-name()="diagonal"]').SetAttribute('width','thin')}
            'conflicting pending ID'{$f.Allocation.Resources=[Collections.Generic.List[object]]::new();$f.Allocation.Resources.Add(@{Kind='borderFill';Id='2';Node=$border.CloneNode($true);Collection=$border.ParentNode;CountAttribute='itemCnt'})}
        }
        Assert-CdRejected $f (New-CdOperation $f)
    }
    It 'fails before changing an exhausted shared resource budget' {
        $f.Allocation.PreparedResourceCharacters=[long](16MB)
        Assert-CdRejected $f (New-CdOperation $f)
        $f.Allocation.PreparedResourceCharacters|Should Be (16MB)
    }
    It 'rejects nonordinal address and unsupported native diagonal metadata <Variant>' -TestCases @(
        @{Variant='address kind'},@{Variant='address version'},@{Variant='native slash child'},@{Variant='unknown native line attribute'}
    ) {
        param($Variant)
        $op=New-CdOperation $f
        $border=$f.Package.Xml['Contents/header.xml'].SelectSingleNode('//*[local-name()="borderFill" and @id="2"]')
        switch($Variant){
            'address kind'{$op.address.kind='t'+[char]0xAD+'c'}
            'address version'{$op.address.version='1.'+[char]0xAD+'0'}
            'native slash child'{$node=$border.SelectSingleNode('*[local-name()="slash"]');$null=$node.AppendChild($node.OwnerDocument.CreateElement('hh','curve','http://www.hancom.co.kr/hwpml/2011/head'))}
            'unknown native line attribute'{$border.SelectSingleNode('*[local-name()="diagonal"]').SetAttribute('curved','1')}
        }
        Assert-CdRejected $f $op
    }
    It 'rejects excessive subtree depth before cloning unknown extension content' {
        $node=$f.Cell;for($i=0;$i -lt 65;$i++){$next=$node.OwnerDocument.CreateElement('v','deep','urn:vendor');$null=$node.AppendChild($next);$node=$next}
        Assert-CdRejected $f (New-CdOperation $f)
    }
}

Test-CdPublicPipeline

Describe 'Public border IDs at the Int32 boundary' {
    BeforeEach {
        $directory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $directory
        $f=New-CdFixture $directory
        $header=$f.Package.Xml['Contents/header.xml'];$section=$f.Package.Xml['Contents/section0.xml']
        $header.SelectSingleNode('//*[local-name()="borderFill" and @id="2"]').SetAttribute('id','2147483647')
        foreach($node in $section.SelectNodes('//*[@borderFillIDRef="2"]')){$node.SetAttribute('borderFillIDRef','2147483647')}
        Write-CdPart $f.Source 'Contents/header.xml' $header;Write-CdPart $f.Source 'Contents/section0.xml' $section
    }
    It 'keeps positive readable unique resource IDs through <Order> and public reinspection' -TestCases @(
        @{Order='diagonal then ordinary';OrdinaryId='3';DiagonalId='2';Count=4},
        @{Order='ordinary then diagonal';OrdinaryId='2';DiagonalId='3';Count=4},
        @{Order='ordinary alone';OrdinaryId='2';DiagonalId='2147483647';Count=3}
    ) {
        param($Order,$OrdinaryId,$DiagonalId,$Count)
        $hash=(Get-FileHash $f.Source).Hash;$before=Read-CdPackage $f.Source
        $inspection=Get-HwpxPackageInspection -LiteralPath $f.Source;($inspection.Errors -join '; ')|Should Be ''
        $cells=$inspection.Data.Tables[0].cells
        $diagonalCell=@($cells|Where-Object text -eq 'Keep text')[0]
        $ordinaryCell=@($cells|Where-Object text -eq 'Other')[0]
        $diagonal=@{type='set-cell-diagonal';address=$diagonalCell.address;direction='CROSS';line=@{type='SOLID';widthMm=0.12;color='#000000'}}
        $ordinary=@{type='set-cell-format';address=$ordinaryCell.address;style=@{borderColor='#112233'}}
        $ops=switch($Order){
            'diagonal then ordinary' {@($diagonal,$ordinary)}
            'ordinary then diagonal' {@($ordinary,$diagonal)}
            'ordinary alone' {@($ordinary)}
        }
        $result=Invoke-HwpxScopedEdit -LiteralPath $f.Source -OutputPath $f.Output -Plan @{version='2.0';operations=@($ops)}
        ($result.Errors -join '; ')|Should Be ''
        $after=Read-CdPackage $f.Output;$h=$after.Xml['Contents/header.xml'];$s=$after.Xml['Contents/section0.xml']
        $resources=$h.SelectNodes('//*[local-name()="borderFill"]');$resources.Count|Should Be $Count
        $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($resource in $resources){
            $id=$resource.GetAttribute('id');[long]$id|Should BeGreaterThan 0;[long]$id|Should BeLessOrEqual ([int]::MaxValue)
            $ids.Add($id)|Should Be $true
        }
        $h.SelectSingleNode('//*[local-name()="borderFills"]').GetAttribute('itemCnt')|Should Be ([string]$Count)
        foreach($node in $s.SelectNodes('//*[@borderFillIDRef]')){$ids.Contains($node.GetAttribute('borderFillIDRef'))|Should Be $true}
        $ordinaryNode=$s.SelectSingleNode('//*[local-name()="tc" and @name="Other"]')
        $diagonalNode=$s.SelectSingleNode('//*[local-name()="tc" and @name="Keep"]')
        $ordinaryNode.GetAttribute('borderFillIDRef')|Should BeExactly $OrdinaryId
        $diagonalNode.GetAttribute('borderFillIDRef')|Should BeExactly $DiagonalId
        $ordinaryBorder=$h.SelectSingleNode('//*[local-name()="borderFill" and @id="'+$OrdinaryId+'"]')
        foreach($side in @('leftBorder','rightBorder','topBorder','bottomBorder')){$ordinaryBorder.SelectSingleNode('*[local-name()="'+$side+'"]').GetAttribute('color')|Should BeExactly '#112233'}
        $diagonalBorder=$h.SelectSingleNode('//*[local-name()="borderFill" and @id="'+$DiagonalId+'"]')
        $expectedFlag=if($Order -ceq 'ordinary alone'){'NONE'}else{'CENTER'}
        foreach($name in @('slash','backSlash')){
            $ordinaryBorder.SelectSingleNode('*[local-name()="'+$name+'"]').GetAttribute('type')|Should BeExactly 'NONE'
            $diagonalBorder.SelectSingleNode('*[local-name()="'+$name+'"]').GetAttribute('type')|Should BeExactly $expectedFlag
        }
        foreach($node in @($ordinaryNode,$diagonalNode)){
            $node.SetAttribute('borderFillIDRef','2147483647')
            $node.OuterXml|Should BeExactly $before.Xml['Contents/section0.xml'].SelectSingleNode('//*[local-name()="tc" and @name="'+$node.GetAttribute('name')+'"]').OuterXml
        }
        foreach($id in @('1','2147483647')){$h.SelectSingleNode('//*[local-name()="borderFill" and @id="'+$id+'"]').OuterXml|Should BeExactly $before.Xml['Contents/header.xml'].SelectSingleNode('//*[local-name()="borderFill" and @id="'+$id+'"]').OuterXml}
        $reopened=Get-HwpxPackageInspection -LiteralPath $f.Output;($reopened.Errors -join '; ')|Should Be ''
        $readIds=@($reopened.Data.Resources.borderFills|ForEach-Object {[string]$_.id})
        foreach($id in @($OrdinaryId,$DiagonalId)){$readIds -ccontains $id|Should Be $true}
        (Get-FileHash $f.Source).Hash|Should Be $hash
    }
}
