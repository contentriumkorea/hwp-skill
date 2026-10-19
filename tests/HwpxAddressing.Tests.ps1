# Independent XML fixtures: addresses must survive duplicate IDs and nested paragraphs.
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-AddressPart {
    param($Path,$Name='Contents/section0.xml')
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $stream=$zip.GetEntry($Name).Open(); $memory=[IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); return ,$memory.ToArray() }
        finally { $stream.Dispose(); $memory.Dispose() }
    } finally { $zip.Dispose() }
}
function Write-AddressPart {
    param($Path,$Name,$Text,[byte[]]$Bytes)
    if ($null -eq $Bytes) { $Bytes=[Text.Encoding]::UTF8.GetBytes($Text) }
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try {
        $old=$zip.GetEntry($Name); if ($null -ne $old) { $old.Delete() }
        $stream=$zip.CreateEntry($Name).Open()
        try { $stream.Write($Bytes,0,$Bytes.Length) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
}
function Read-AddressXml {
    param($Path,$Name='Contents/section0.xml')
    [xml][Text.Encoding]::UTF8.GetString((Read-AddressPart $Path $Name))
}
function New-AddressParagraph {
    param($Text)
    '<hp:p id="0" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0" merged="0"><hp:run charPrIDRef="0"><hp:t>'+ $Text +'</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>'
}
function New-AddressTable {
    param([int]$Rows=1,[int]$Columns=1)
    $s='<hp:tbl id="1" rowCnt="'+$Rows+'" colCnt="'+$Columns+'" cellSpacing="0" borderFillIDRef="1"><hp:sz width="'+($Columns*3000)+'" height="'+($Rows*2000)+'" widthRelTo="ABSOLUTE" heightRelTo="ABSOLUTE"/><hp:inMargin left="0" right="0" top="0" bottom="0"/>'
    for($r=0;$r -lt $Rows;$r++) {
        $s+='<hp:tr>'
        for($c=0;$c -lt $Columns;$c++) {
            $s+='<hp:tc name="" header="0" hasMargin="1" protect="0" editable="0" dirty="0" borderFillIDRef="1"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0">'+(New-AddressParagraph "CELL$r$c")+'</hp:subList><hp:cellAddr rowAddr="'+$r+'" colAddr="'+$c+'"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="3000" height="2000"/><hp:cellMargin left="100" right="100" top="100" bottom="100"/></hp:tc>'
        }
        $s+='</hp:tr>'
    }
    $s+'</hp:tbl>'
}
function New-AddressFixture {
    param($Path,[int]$Rows=1,[int]$Columns=1)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $Path
    $xml=Read-AddressXml $Path
    $text=$xml.OuterXml.Replace('</hs:sec>',('<hp:p id="0" paraPrIDRef="0"><hp:run charPrIDRef="0">'+(New-AddressTable $Rows $Columns)+'</hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p>'+(New-AddressParagraph 'TARGET')+(New-AddressParagraph 'OTHER')+'<!--preserve comment--><u:opaque xmlns:u="urn:address" key="keep"/></hs:sec>'))
    Write-AddressPart $Path 'Contents/section0.xml' $text
    Write-AddressPart $Path 'Custom/opaque.bin' -Bytes ([byte[]]@(0,1,255,4))
}
function Get-AddressInspection {
    param($Path)
    $result=Get-HwpxPackageInspection -LiteralPath $Path
    ($result.Errors -join '; ') | Should Be ''
    $result.Data
}
function Invoke-AddressEdit {
    param($Source,$Output,[object[]]$Operations)
    Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=$Operations}
}
function Assert-AddressBlocked {
    param($Source,$Output,[object[]]$Operations,$ErrorPattern)
    $hash=(Get-FileHash -LiteralPath $Source).Hash
    $result=Invoke-AddressEdit $Source $Output $Operations
    $result.Status | Should Be 'BLOCKED'
    if ($ErrorPattern) { ($result.Errors -join '; ') | Should Match $ErrorPattern }
    (Test-Path -LiteralPath $Output) | Should Be $false
    (Get-FileHash -LiteralPath $Source).Hash | Should Be $hash
    @(Get-ChildItem -LiteralPath (Split-Path $Output) -Filter '*.partial.hwpx' -Force).Count | Should Be 0
}

Describe 'Canonical HWPX inspect to edit addressing' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx'; $output=Join-Path $dir 'edited.hwpx'
        New-AddressFixture $source
    }
    It 'edits inspected TARGET after a table without formatting OTHER at the legacy index 3' {
        $data=Get-AddressInspection $source
        $p=@($data.Paragraphs | Where-Object text -CEQ 'TARGET')[0]
        $p.index | Should Be 3
        $hash=(Get-FileHash -LiteralPath $source).Hash
        $before=Read-AddressXml $source
        $result=Invoke-AddressEdit $source $output @(@{type='set-paragraph-format';address=$p.address;paragraphStyle=@{alignment='RIGHT'}})
        ($result.Errors -join '; ') | Should Be ''
        $after=Read-AddressXml $output
        $body=$after.SelectNodes('/*/*[local-name()="p"]')
        ($body[2].GetAttribute('paraPrIDRef') -ne '0') | Should Be $true
        $body[3].OuterXml | Should Be $before.SelectNodes('/*/*[local-name()="p"]')[3].OuterXml
        (Get-FileHash -LiteralPath $source).Hash | Should Be $hash
        [Convert]::ToBase64String((Read-AddressPart $output 'Custom/opaque.bin')) | Should Be 'AAH/BA=='
    }
    It 'retains explicit legacy direct paragraph and run indexes' {
        $result=Invoke-AddressEdit $source $output @(@{type='replace-run-text';sectionIndex=0;paragraphIndex=3;runIndex=0;expectedText='OTHER';text='LEGACY'})
        ($result.Errors -join '; ') | Should Be ''
        (Read-AddressXml $output).SelectNodes('/*/*[local-name()="p"]')[3].InnerText | Should Be 'LEGACY'
    }
    It 'edits a cell run and paragraph formats using JSON round tripped inspection addresses' {
        $data=Get-AddressInspection $source | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        $p=@($data.Paragraphs | Where-Object text -CEQ 'CELL00')[0]
        $run=$p.charShapeRuns[0]
        $run.text | Should Be 'CELL00'
        $result=Invoke-AddressEdit $source $output @(
            @{type='replace-run-text';address=$run.address;expectedText='CELL00';text='CHANGED & SAFE'},
            @{type='set-run-format';address=$run.address;textStyle=@{bold=$true}},
            @{type='set-paragraph-format';address=$p.address;paragraphStyle=@{alignment='CENTER'}}
        )
        ($result.Errors -join '; ') | Should Be ''
        $cell=(Read-AddressXml $output).SelectSingleNode('//*[local-name()="tc"]')
        $cell.SelectSingleNode('.//*[local-name()="t"]').InnerText | Should Be 'CHANGED & SAFE'
        ($cell.SelectSingleNode('.//*[local-name()="run"]').GetAttribute('charPrIDRef') -ne '0') | Should Be $true
        ($cell.SelectSingleNode('.//*[local-name()="p"]').GetAttribute('paraPrIDRef') -ne '0') | Should Be $true
        $cell.SelectNodes('.//*[local-name()="linesegarray"]').Count | Should Be 0
        (Read-AddressXml $output).SelectNodes('/*/*[local-name()="p"]')[1].SelectNodes('*[local-name()="linesegarray"]').Count | Should Be 0
    }
    It 'rejects stale addresses even when text still matches and no plan hash was supplied' {
        $data=Get-AddressInspection $source
        $run=@($data.Paragraphs | Where-Object text -CEQ 'TARGET')[0].charShapeRuns[0]
        Write-AddressPart $source 'Custom/opaque.bin' -Bytes ([byte[]]@(9))
        Assert-AddressBlocked $source $output @(@{type='replace-run-text';address=$run.address;expectedText='TARGET';text='WRONG'}) 'sourceSha256'
    }
    It 'rejects mixed address/index selectors and duplicate writes through address aliases' {
        $data=Get-AddressInspection $source
        $run=@($data.Paragraphs | Where-Object text -CEQ 'TARGET')[0].charShapeRuns[0]
        Assert-AddressBlocked $source $output @(@{type='replace-run-text';address=$run.address;sectionIndex=0;paragraphIndex=2;runIndex=0;expectedText='TARGET';text='WRONG'}) 'property|selector'
        Assert-AddressBlocked $source $output @(
            @{type='replace-run-text';address=$run.address;expectedText='TARGET';text='FIRST'},
            @{type='replace-run-text';sectionIndex=0;paragraphIndex=2;runIndex=0;expectedText='TARGET';text='SECOND'}
        ) 'Duplicate'
    }
    It 'rejects forged kind part and path values rather than resolving a different node' {
        $p=@((Get-AddressInspection $source).Paragraphs | Where-Object text -CEQ 'TARGET')[0]
        foreach($change in @(
            @{kind='run'}, @{part='Contents/header.xml'}, @{path=@(-1)}, @{path=@('2')},
            @{path=@(9999)}, @{path=@(2.5)}, @{path=@()}, @{path=@(0)*65}, @{version='2.0'}
        )) {
            $address=$p.address | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            foreach($key in $change.Keys) { $address.$key=$change[$key] }
            Assert-AddressBlocked $source $output @(@{type='set-paragraph-format';address=$address;paragraphStyle=@{alignment='RIGHT'}}) 'address'
        }
    }
    It 'blocks protected cell ancestors even when the addressed text itself is simple' {
        $xml=Read-AddressXml $source
        $xml.SelectSingleNode('//*[local-name()="tc"]').SetAttribute('protect','1')
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml
        $p=@((Get-AddressInspection $source).Paragraphs | Where-Object text -CEQ 'CELL00')[0]
        Assert-AddressBlocked $source $output @(@{type='replace-run-text';address=$p.charShapeRuns[0].address;expectedText='CELL00';text='NO'}) 'Protected'
    }
    It 'edits by part across reversed spine order and nested header footer and table paragraphs' {
        $section=Read-AddressXml $source
        $nested=New-AddressTable
        $text=$section.OuterXml.Replace('CELL00','SECOND CELL').Replace('TARGET','SECOND TARGET').Replace('OTHER','SECOND OTHER')
        $text=$text.Replace('SECOND CELL</hp:t></hp:run>',('SECOND CELL</hp:t></hp:run><hp:run charPrIDRef="0">'+$nested+'</hp:run>'))
        $text=$text.Replace('</hs:sec>',('<hp:p id="0" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:ctrl><hp:header id="1" applyPageType="BOTH"><hp:subList>'+(New-AddressParagraph 'HEADER')+'</hp:subList></hp:header><hp:footer id="2" applyPageType="BOTH"><hp:subList>'+(New-AddressParagraph 'FOOTER')+'</hp:subList></hp:footer></hp:ctrl></hp:run></hp:p></hs:sec>'))
        Write-AddressPart $source 'Contents/section1.xml' $text
        $header=Read-AddressXml $source 'Contents/header.xml'; $header.DocumentElement.SetAttribute('secCnt','2')
        Write-AddressPart $source 'Contents/header.xml' $header.OuterXml
        $hpf=[Text.Encoding]::UTF8.GetString((Read-AddressPart $source 'Contents/content.hpf'))
        $hpf=$hpf.Replace('</opf:manifest>','<opf:item id="section1" href="Contents/section1.xml" media-type="application/xml"/></opf:manifest>').Replace('<opf:spine>','<opf:spine><opf:itemref idref="section1" linear="yes"/>')
        Write-AddressPart $source 'Contents/content.hpf' $hpf
        $data=Get-AddressInspection $source
        $ops=@(foreach($text in @('SECOND TARGET','HEADER','FOOTER','CELL00')) {
            $p=@($data.Paragraphs | Where-Object { $_.text -ceq $text -and $_.section -ceq 'Contents/section1.xml' })[0]
            @{type='replace-run-text';address=$p.charShapeRuns[0].address;expectedText=$text;text=('NEW '+$text)}
        })
        $original=[Convert]::ToBase64String((Read-AddressPart $source))
        $result=Invoke-AddressEdit $source $output $ops
        ($result.Errors -join '; ') | Should Be ''
        [Convert]::ToBase64String((Read-AddressPart $output)) | Should Be $original
        $after=Get-AddressInspection $output
        foreach($text in @('NEW SECOND TARGET','NEW HEADER','NEW FOOTER','NEW CELL00')) { ($after.Paragraphs.text -ccontains $text) | Should Be $true }
    }
    It 'sets a simple table cell text preserving cell layout' {
        $data=Get-AddressInspection $source
        $cell=$data.Tables[0].cells[0]
        $result=Invoke-AddressEdit $source $output @(@{type='set-table-cell';address=$cell.address;expectedText='CELL00';text='CELL NEW'})
        ($result.Errors -join '; ') | Should Be ''
        $before=(Read-AddressXml $source).SelectSingleNode('//*[local-name()="tc"]')
        $after=(Read-AddressXml $output).SelectSingleNode('//*[local-name()="tc"]')
        foreach($name in @('cellAddr','cellSpan','cellSz','cellMargin')) { $after.SelectSingleNode('*[local-name()="'+$name+'"]').OuterXml | Should Be $before.SelectSingleNode('*[local-name()="'+$name+'"]').OuterXml }
        $after.SelectSingleNode('.//*[local-name()="t"]').InnerText | Should Be 'CELL NEW'
    }
}

Describe 'Bounded HWPX media and rectangular table edits' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx'; $output=Join-Path $dir 'edited.hwpx'
        New-AddressFixture $source 2 2
    }
    It 'inserts a blank row at the middle with explicit height and preserves original cells' {
        $data=Get-AddressInspection $source
        $result=Invoke-AddressEdit $source $output @(@{type='insert-table-row';address=$data.Tables[0].address;index=1;heightMm=10})
        ($result.Errors -join '; ') | Should Be ''
        $table=(Get-AddressInspection $output).Tables[0]
        $table.rowCount | Should Be 3
        $table.columnCount | Should Be 2
        ($table.cells.text -join '|') | Should Be 'CELL00|CELL01|||CELL10|CELL11'
        $table.cells[2].height | Should Be 2835
        $xml=Read-AddressXml $output
        $xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="sz"]').GetAttribute('height') | Should Be '6835'
        $xml.SelectNodes('//*[local-name()="tbl"]//*[local-name()="linesegarray"]').Count | Should Be 0
        $newIds=@($xml.SelectNodes('//*[local-name()="tr"][2]//*[local-name()="p"]') | ForEach-Object { $_.GetAttribute('id') })
        ($newIds -contains '0') | Should Be $false
        ($newIds | Select-Object -Unique).Count | Should Be 2
        $original=(Read-AddressXml $source).SelectNodes('//*[local-name()="tr"][2]/*[local-name()="tc"]')
        $moved=$xml.SelectNodes('//*[local-name()="tr"][3]/*[local-name()="tc"]')
        for($i=0;$i -lt 2;$i++) {
            $copy=$original[$i].CloneNode($true)
            $copy.SelectSingleNode('*[local-name()="cellAddr"]').SetAttribute('rowAddr','2')
            foreach($cache in @($copy.SelectNodes('.//*[local-name()="linesegarray"]'))) { $null=$cache.ParentNode.RemoveChild($cache) }
            $moved[$i].OuterXml | Should Be $copy.OuterXml
        }
    }
    It 'inserts a blank column at the beginning using legacy table addressing' {
        $result=Invoke-AddressEdit $source $output @(@{type='insert-table-column';sectionIndex=0;tableIndex=0;index=0;widthMm=5})
        ($result.Errors -join '; ') | Should Be ''
        $table=(Get-AddressInspection $output).Tables[0]
        $table.rowCount | Should Be 2; $table.columnCount | Should Be 3
        ($table.cells.text -join '|') | Should Be '|CELL00|CELL01||CELL10|CELL11'
        $table.cells[0].width | Should Be 1417
        (Read-AddressXml $output).SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="sz"]').GetAttribute('width') | Should Be '7417'
    }
    It 'rejects subtree replacement combined with addressed descendant edits in either order' {
        $data=Get-AddressInspection $source
        $run=@($data.Paragraphs | Where-Object text -CEQ 'CELL00')[0].charShapeRuns[0]
        $insert=@{type='insert-table-row';address=$data.Tables[0].address;index=1;heightMm=5}
        $edit=@{type='replace-run-text';address=$run.address;expectedText='CELL00';text='NEW'}
        Assert-AddressBlocked $source $output @($insert,$edit) 'Overlapping'
        Assert-AddressBlocked $source $output @($edit,$insert) 'Overlapping'
    }
    It 'rejects unknown cell metadata but supports insertion beside a horizontal merge' {
        $xml=Read-AddressXml $source
        $xml.SelectSingleNode('//*[local-name()="tc"]').SetAttribute('vendor-data','preserve')
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml
        Assert-AddressBlocked $source $output @(@{type='insert-table-row';sectionIndex=0;tableIndex=0;index=1;heightMm=10}) 'Unknown'
        $xml.SelectSingleNode('//*[local-name()="tc"]').RemoveAttribute('vendor-data')
        $row=$xml.SelectSingleNode('//*[local-name()="tr"]')
        $cells=$row.SelectNodes('*[local-name()="tc"]')
        $cells[0].SelectSingleNode('*[local-name()="cellSpan"]').SetAttribute('colSpan','2')
        $cells[0].SelectSingleNode('*[local-name()="cellSz"]').SetAttribute('width','6000')
        $null=$row.RemoveChild($cells[1])
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml
        $result=Invoke-AddressEdit $source $output @(@{type='insert-table-row';sectionIndex=0;tableIndex=0;index=1;heightMm=10})
        ($result.Errors -join '; ') | Should Be ''
        $table=(Get-AddressInspection $output).Tables[0]
        $table.rowCount | Should Be 3
        $table.cells[0].columnSpan | Should Be 2
    }
    It 'preflights invalid insertion indexes dimensions and inconsistent table extents' {
        foreach($case in @(@{index=3;heightMm=10},@{index=-1;heightMm=10},@{index=0.5;heightMm=10},@{index=1;heightMm=0},@{index=1;heightMm='10'},@{index=1;heightMm=[double]::NaN})) {
            $op=@{type='insert-table-row';sectionIndex=0;tableIndex=0;index=$case.index;heightMm=$case.heightMm}
            Assert-AddressBlocked $source $output @($op) 'index|heightMm'
        }
        $xml=Read-AddressXml $source
        $xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="sz"]').SetAttribute('width','1')
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml
        Assert-AddressBlocked $source $output @(@{type='insert-table-column';sectionIndex=0;tableIndex=0;index=1;widthMm=10}) 'size must match'
    }
    It 'appends a column and leaves body text edits after the table at their original addresses' {
        $data=Get-AddressInspection $source
        $run=@($data.Paragraphs | Where-Object text -CEQ 'TARGET')[0].charShapeRuns[0]
        $result=Invoke-AddressEdit $source $output @(
            @{type='insert-table-column';address=$data.Tables[0].address;index=2;widthMm=10},
            @{type='replace-run-text';address=$run.address;expectedText='TARGET';text='AFTER TABLE'}
        )
        ($result.Errors -join '; ') | Should Be ''
        $data=Get-AddressInspection $output
        ($data.Tables[0].cells.text -join '|') | Should Be 'CELL00|CELL01||CELL10|CELL11|'
        ($data.Paragraphs.text -contains 'AFTER TABLE') | Should Be $true
    }
    It 'blocks rich cell replacement instead of flattening its formatting or controls' {
        $xml=Read-AddressXml $source
        $sub=$xml.SelectSingleNode('//*[local-name()="tc"]/*[local-name()="subList"]')
        $null=$sub.AppendChild($sub.FirstChild.CloneNode($true))
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml
        $data=Get-AddressInspection $source
        Assert-AddressBlocked $source $output @(@{type='set-table-cell';address=$data.Tables[0].cells[0].address;expectedText="CELL00`nCELL00";text='FLATTEN'}) 'single text-only'
    }
    It 'replaces only the embedded image bytes while preserving picture layout XML byte for byte' {
        $imageBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'))
        Write-AddressPart $source 'BinData/photo.png' -Bytes $imageBytes
        $xml=Read-AddressXml $source
        $picture='<hp:p id="0" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:pic id="10" lock="0"><hp:sz width="1234" height="2345"/><hp:pos horzOffset="12" vertOffset="34"/><hc:img binaryItemIDRef="photo" xmlns:hc="http://www.hancom.co.kr/hwpml/2011/core"/><hp:imgClip left="1" right="2" top="3" bottom="4"/></hp:pic></hp:run></hp:p>'
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml.Replace('</hs:sec>',($picture+'</hs:sec>'))
        $hpf=[Text.Encoding]::UTF8.GetString((Read-AddressPart $source 'Contents/content.hpf'))
        Write-AddressPart $source 'Contents/content.hpf' $hpf.Replace('</opf:manifest>','<opf:item id="photo" href="BinData/photo.png" media-type="image/png"/></opf:manifest>')
        $replacement=Join-Path $dir 'replacement.png'
        # A real independent 1x1 PNG. File creation is a fixture, never production IO.
        [IO.File]::WriteAllBytes($replacement,[Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4l8AAAAASUVORK5CYII='))
        $data=Get-AddressInspection $source
        $pic=@($data.Controls | Where-Object ctrlId -CEQ 'pic')[0]
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $expected=[BitConverter]::ToString($sha.ComputeHash($imageBytes)).Replace('-','') } finally { $sha.Dispose() }
        $result=Invoke-AddressEdit $source $output @(@{type='replace-image';address=$pic.address;path=$replacement;expectedSha256=$expected})
        ($result.Errors -join '; ') | Should Be ''
        [Convert]::ToBase64String((Read-AddressPart $output)) | Should Be ([Convert]::ToBase64String((Read-AddressPart $source)))
        [Convert]::ToBase64String((Read-AddressPart $output 'Contents/content.hpf')) | Should Be ([Convert]::ToBase64String((Read-AddressPart $source 'Contents/content.hpf')))
        [Convert]::ToBase64String((Read-AddressPart $output 'BinData/photo.png')) | Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($replacement)))
        ($result.Data.ChangedParts -contains 'BinData/photo.png') | Should Be $true
        ($result.Data.ChangedParts -contains 'Contents/section0.xml') | Should Be $false
        $second=Join-Path $dir 'second.hwpx'
        Assert-AddressBlocked $source $second @(@{type='replace-image';address=$pic.address;path=$replacement;expectedSha256=('0'*64)}) 'expectedSha256'
        [IO.File]::WriteAllBytes($replacement,[byte[]]@(1,2,3,4))
        Assert-AddressBlocked $source $second @(@{type='replace-image';address=$pic.address;path=$replacement;expectedSha256=$expected}) 'signature'
        Assert-AddressBlocked $source $second @(@{type='replace-image';address=$pic.address;path='https://example.invalid/image.png';expectedSha256=$expected}) 'local filesystem'
        $xml=Read-AddressXml $source
        $node=$xml.SelectSingleNode('//*[local-name()="pic"]')
        $null=$node.ParentNode.AppendChild($node.CloneNode($true))
        Write-AddressPart $source 'Contents/section0.xml' $xml.OuterXml
        $pic=@((Get-AddressInspection $source).Controls | Where-Object ctrlId -CEQ 'pic')[0]
        Assert-AddressBlocked $source $second @(@{type='replace-image';address=$pic.address;path=$replacement;expectedSha256=$expected}) 'shared|reference'
    }
}
