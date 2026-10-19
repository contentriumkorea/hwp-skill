Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Read-PtXml($Path,$Part='Contents/section0.xml') {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{$reader=[IO.StreamReader]::new($zip.GetEntry($Part).Open());try{[xml]$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
}
function Write-PtXml($Path,$Xml,$Part='Contents/section0.xml') {
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try{$zip.GetEntry($Part).Delete();$stream=$zip.CreateEntry($Part).Open();$bytes=[Text.Encoding]::UTF8.GetBytes($Xml.OuterXml);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
}
function Invoke-PtEdit($Source,$Output,$Ops){Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=@($Ops)}}
Describe 'Scoped paragraph tab resources' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'output.hwpx'
        Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
        $xml=Read-PtXml $source;$fragment=$xml.CreateDocumentFragment()
        $fragment.InnerXml='<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" id="110" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>Tab<hp:tab width="25" leader="0" type="0"/>value</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p><hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" id="111" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:t>Other</hp:t></hp:run></hp:p>'
        $null=$xml.DocumentElement.AppendChild($fragment);Write-PtXml $source $xml
        $header=Read-PtXml $source 'Contents/header.xml';$tabs=$header.SelectSingleNode('//*[local-name()="tabProperties"]')
        $fragment=$header.CreateDocumentFragment();$fragment.InnerXml='<hh:tabPr xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" id="11" autoTabLeft="1" autoTabRight="0"><hh:tabItem pos="7200" type="RIGHT" leader="DOT" unit="HWPUNIT"/></hh:tabPr>'
        $null=$tabs.AppendChild($fragment);$tabs.SetAttribute('itemCnt',[string]$tabs.SelectNodes('*').Count)
        $originalPara=$header.SelectSingleNode('//*[local-name()="paraPr" and @id="0"]');$originalPara.SetAttribute('tabPrIDRef','11')
        Write-PtXml $source $header 'Contents/header.xml';$sourceHash=(Get-FileHash $source).Hash
        $p=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs|Where-Object text -eq "Tab`tvalue")[0]
    }
    It 'clones shared paragraph and tab styles while preserving text inline tabs and other paragraphs' {
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$p.address;tabs=@(@{positionMm=25.4;alignment='LEFT';leader='DOT'},@{positionMm=50.8;alignment='DECIMAL';leader='SOLID'});autoTabRight=$true})
        ($r.Errors -join '; ')|Should Be ''
        $after=Read-PtXml $output;$newHeader=Read-PtXml $output 'Contents/header.xml'
        $newP=$after.SelectSingleNode('//*[local-name()="p" and @id="110"]');$newId=$newP.GetAttribute('paraPrIDRef')
        $newId|Should Not Be '0';$newPara=$newHeader.SelectSingleNode('//*[local-name()="paraPr" and @id="'+$newId+'"]')
        $newPara.GetAttribute('tabPrIDRef')|Should Be '12'
        $tab=$newHeader.SelectSingleNode('//*[local-name()="tabPr" and @id="12"]')
        $tab.GetAttribute('autoTabLeft')|Should Be '1';$tab.GetAttribute('autoTabRight')|Should Be '1'
        ($tab.SelectNodes('*')|ForEach-Object {$_.GetAttribute('pos')}) -join ','|Should Be '7200,14400'
        ($tab.SelectNodes('*')|ForEach-Object {$_.GetAttribute('type')}) -join ','|Should Be 'LEFT,DECIMAL'
        $newHeader.SelectSingleNode('//*[local-name()="paraPr" and @id="0"]').OuterXml|Should BeExactly $originalPara.OuterXml
        $newHeader.SelectSingleNode('//*[local-name()="tabPr" and @id="11"]').OuterXml|Should BeExactly $header.SelectSingleNode('//*[local-name()="tabPr" and @id="11"]').OuterXml
        $after.SelectSingleNode('//*[local-name()="p" and @id="111"]').GetAttribute('paraPrIDRef')|Should Be '0'
        $newP.SelectSingleNode('*[local-name()="run"]').OuterXml|Should BeExactly $xml.SelectSingleNode('//*[local-name()="p" and @id="110"]/*[local-name()="run"]').OuterXml
        $newP.SelectNodes('*[local-name()="linesegarray"]').Count|Should Be 0
        (Get-FileHash $source).Hash|Should Be $sourceHash
        $resources=(Get-HwpxPackageInspection -LiteralPath $output).Data.Resources
        $read=@($resources.tabProperties|Where-Object id -eq 12)[0]
        $read.autoTabLeft|Should Be $true;$read.autoTabRight|Should Be $true
        $read.stops[0].positionMm|Should Be 25.4
        $read.stops[1].alignment|Should Be DECIMAL;$read.stops[1].leader|Should Be SOLID
    }
    It 'clears explicit tabs without changing omitted automatic-tab flags' {
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$p.address;tabs=@()})
        ($r.Errors -join '; ')|Should Be ''
        $tab=(Read-PtXml $output 'Contents/header.xml').SelectSingleNode('//*[local-name()="tabPr" and @id="12"]')
        $tab.SelectNodes('*').Count|Should Be 0;$tab.GetAttribute('autoTabLeft')|Should Be '1'
    }
    It 'allocates distinct resources for multiple paragraphs in one atomic plan' {
        $q=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs|Where-Object text -eq 'Other')[0]
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$p.address;tabs=@(@{positionMm=25.4})},@{type='set-paragraph-tabs';address=$q.address;tabs=@(@{positionMm=50.8})})
        ($r.Errors -join '; ')|Should Be ''
        $h=Read-PtXml $output 'Contents/header.xml';$h.SelectNodes('//*[local-name()="tabPr" and (@id="12" or @id="13")]').Count|Should Be 2
    }
    It 'rejects invalid values before creating an output or changing the original' {
        foreach($case in @(
            @{tabs=@(@{positionMm=-1})},@{tabs=@(@{positionMm=$true})},@{tabs=@(@{positionMm='25.4'})},
            @{tabs=@(@{positionMm=1;alignment='left'})},@{tabs=@(@{positionMm=1;leader='UNKNOWN'})},
            @{tabs=@(@{positionMm=1;alignment=('LE'+[char]0xAD+'FT')})},@{tabs=@(@{positionMm=1;leader=('D'+[char]0xAD+'OT')})},
            @{tabs=@(@{positionMm=5},@{positionMm=4})},@{tabs=@(@{positionMm=5},@{positionMm=5.00001})},
            @{tabs=@(@{positionMm=5;unknown=0})}
        )){
            $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$p.address;tabs=$case.tabs})
            $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $sourceHash
        }
    }
    It 'rejects ambiguous source <Change> rather than replacing unknown metadata' -TestCases @(
        @{Change='unknown tab attribute'},@{Change='unknown tab child'},@{Change='duplicate tab ID'},
        @{Change='absent tab reference'},@{Change='wrong collection count'},@{Change='invalid automatic flag'}
    ) {
        param($Change)
        $h=Read-PtXml $source 'Contents/header.xml';$tab=$h.SelectSingleNode('//*[local-name()="tabPr" and @id="11"]');$collection=$tab.ParentNode
        switch($Change){
            'unknown tab attribute' {$tab.SetAttribute('unrecognized','1')}
            'unknown tab child' {$null=$tab.AppendChild($h.CreateElement('hh','future','http://www.hancom.co.kr/hwpml/2011/head'))}
            'duplicate tab ID' {$null=$collection.AppendChild($tab.CloneNode($true));$collection.SetAttribute('itemCnt',[string]$collection.SelectNodes('*').Count)}
            'absent tab reference' {$h.SelectSingleNode('//*[local-name()="paraPr" and @id="0"]').SetAttribute('tabPrIDRef','999')}
            'wrong collection count' {$collection.SetAttribute('itemCnt','999')}
            'invalid automatic flag' {$tab.SetAttribute('autoTabLeft','unknown')}
        }
        Write-PtXml $source $h 'Contents/header.xml';$sha=(Get-FileHash $source).Hash
        $address=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs|Where-Object text -eq "Tab`tvalue")[0].address
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$address;tabs=@()})
        $r.Status|Should Be BLOCKED;($r.Errors -join ' ')|Should Not Match 'sourceSha256'
        Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $sha
    }
    It 'bounds the number of stops and requires actual Boolean automatic-tab settings' {
        foreach($op in @(
            @{type='set-paragraph-tabs';address=$p.address;tabs=@(1..65|ForEach-Object {@{positionMm=$_}})},
            @{type='set-paragraph-tabs';address=$p.address;tabs=@();autoTabLeft='true'},
            @{type='set-paragraph-tabs';address=$p.address;tabs=@(@{positionMm=2001})}
        )){$r=Invoke-PtEdit $source $output @($op);$r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false}
    }
    It 'does not infer physical millimeters for character-unit or unitless stored tabs' {
        foreach($unit in @('CHAR','')){
            $h=Read-PtXml $source 'Contents/header.xml';$item=$h.SelectSingleNode('//*[local-name()="tabPr" and @id="11"]/*[local-name()="tabItem"]')
            if($unit){$item.SetAttribute('unit',$unit)}else{$item.RemoveAttribute('unit')};Write-PtXml $source $h 'Contents/header.xml'
            $read=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Resources.tabProperties|Where-Object id -eq 11)[0]
            $read.stops[0].positionMm|Should BeNullOrEmpty;$read.stops[0].positionRaw|Should Be '7200'
        }
    }
    It 'preflights a late failure before committing earlier prepared resources' {
        $q=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs|Where-Object text -eq 'Other')[0]
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$p.address;tabs=@(@{positionMm=1})},@{type='set-paragraph-tabs';address=$q.address;tabs=@(@{positionMm=-1})})
        $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $sourceHash
    }
    It 'keeps the original DOM and allocation when the prepared-resource budget is exhausted' {
        $module=Get-Module HwpHwpxScopedEdit
        & $module {
            param($Path)
            $stream=[IO.File]::OpenRead($Path);try{$package=Read-ScopedPackage $stream}finally{$stream.Dispose()}
            $xml=$package.Xml[$package.Sections[0]];$node=$xml.SelectSingleNode('//*[local-name()="p" and @id="110"]')
            $before=$package.Xml['Contents/header.xml'].OuterXml;$allocation=@{PreparedResourceCharacters=[long](16MB)}
            $caught=$null;try{$null=New-ScopedParagraphTabs $node @{type='set-paragraph-tabs';address=@{};tabs=@()} $package $allocation}catch{$caught=$_.Exception}
            $caught|Should Not BeNullOrEmpty;$caught.Message|Should Match '16 MiB'
            $allocation.Count|Should Be 1;$allocation.PreparedResourceCharacters|Should Be (16MB)
            $package.Xml['Contents/header.xml'].OuterXml|Should BeExactly $before
        } $source
    }
    It 'invalidates the section line cache after changing a tab layout' {
        $doc=Read-PtXml $source;$other=$doc.SelectSingleNode('//*[local-name()="p" and @id="111"]')
        $cache=$doc.CreateElement('hp','linesegarray','http://www.hancom.co.kr/hwpml/2011/paragraph');$null=$other.AppendChild($cache);Write-PtXml $source $doc
        $address=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs|Where-Object text -eq "Tab`tvalue")[0].address
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$address;tabs=@(@{positionMm=25.4})})
        ($r.Errors -join '; ')|Should Be ''
        (Read-PtXml $output).SelectNodes('//*[local-name()="linesegarray"]').Count|Should Be 0
    }
    It 'rejects linguistically similar unknown keys instead of silently ignoring them' {
        $tab=@{positionMm=25.4};$tab['lea'+[char]0xAD+'der']='DOT'
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$p.address;tabs=@($tab)})
        $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false
    }
    It 'keeps new resources inspectable when a sparse source already uses the largest Int32 ID' {
        $h=Read-PtXml $source 'Contents/header.xml';$h.SelectSingleNode('//*[local-name()="tabPr" and @id="11"]').SetAttribute('id','2147483647')
        $h.SelectSingleNode('//*[local-name()="paraPr" and @id="0"]').SetAttribute('tabPrIDRef','2147483647');Write-PtXml $source $h 'Contents/header.xml'
        $before=Get-HwpxPackageInspection -LiteralPath $source;($before.Errors -join '; ')|Should Be ''
        $address=@($before.Data.Paragraphs|Where-Object text -eq "Tab`tvalue")[0].address
        $r=Invoke-PtEdit $source $output @(@{type='set-paragraph-tabs';address=$address;tabs=@(@{positionMm=25.4})})
        ($r.Errors -join '; ')|Should Be ''
        $after=Get-HwpxPackageInspection -LiteralPath $output;($after.Errors -join '; ')|Should Be ''
        @($after.Data.Resources.tabProperties|Where-Object {$_.id -ne 2147483647 -and $_.stops.Count -eq 1 -and $_.stops[0].positionMm -eq 25.4}).Count|Should Be 1
    }
    It 'reads unqualified schema tab attributes separately from qualified extension attributes' {
        $h=Read-PtXml $source 'Contents/header.xml';$tab=$h.SelectSingleNode('//*[local-name()="tabPr" and @id="11"]');$node=$tab.SelectSingleNode('*')
        $a=$h.CreateAttribute('v','pos','urn:vendor');$a.Value='14400';$null=$node.Attributes.Prepend($a);Write-PtXml $source $h 'Contents/header.xml'
        $read=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Resources.tabProperties|Where-Object id -eq 11)[0]
        $read.stops[0].positionRaw|Should Be '7200';$read.stops[0].positionMm|Should Be 25.4
    }
}
