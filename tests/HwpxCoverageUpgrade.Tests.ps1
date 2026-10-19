Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-CuXml($Path,$Name='Contents/section0.xml') {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{$reader=[IO.StreamReader]::new($zip.GetEntry($Name).Open());try{[xml]$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
}
function Write-CuXml($Path,[xml]$Xml) {
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try{$zip.GetEntry('Contents/section0.xml').Delete();$stream=$zip.CreateEntry('Contents/section0.xml').Open();$bytes=[Text.Encoding]::UTF8.GetBytes($Xml.OuterXml);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
}
function New-CuFixture($Path) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $Path
    $xml=Read-CuXml $Path;$fragment=$xml.CreateDocumentFragment();$fragment.InnerXml='<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" id="100" paraPrIDRef="0" styleIDRef="0" pageBreak="0" columnBreak="0"><hp:run charPrIDRef="0"><hp:t>Alpha</hp:t></hp:run><hp:run charPrIDRef="0"><hp:t>Beta</hp:t></hp:run></hp:p>';$null=$xml.DocumentElement.AppendChild($fragment)
    $b=[Text.StringBuilder]::new();$null=$b.Append('<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" id="200" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:tbl id="1000" rowCnt="4" colCnt="2" cellSpacing="0" borderFillIDRef="2" lock="0"><hp:sz width="12000" height="8000" widthRelTo="ABSOLUTE" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" horzAlign="LEFT"/><hp:outMargin left="0" right="0" top="0" bottom="0"/><hp:inMargin left="0" right="0" top="0" bottom="0"/>')
    $values=@('Item','Price','x','20','y','3','z','20')
    for($r=0;$r -lt 4;$r++){$null=$b.Append('<hp:tr>');for($c=0;$c -lt 2;$c++){
        $null=$b.Append(('<hp:tc name="" header="0" hasMargin="1" protect="0" editable="0" dirty="0" borderFillIDRef="2"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0"><hp:p id="{0}" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>{1}</hp:t></hp:run></hp:p></hp:subList><hp:cellAddr rowAddr="{2}" colAddr="{3}"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="6000" height="2000"/><hp:cellMargin left="10" right="10" top="10" bottom="10"/></hp:tc>' -f (201+$r*2+$c),$values[$r*2+$c],$r,$c))
    };$null=$b.Append('</hp:tr>')};$null=$b.Append('</hp:tbl></hp:run></hp:p>');$fragment=$xml.CreateDocumentFragment();$fragment.InnerXml=$b.ToString();$null=$xml.DocumentElement.AppendChild($fragment);Write-CuXml $Path $xml
}
function Get-CuData($Path){$r=Get-HwpxPackageInspection -LiteralPath $Path;($r.Errors -join '; ')|Should Be '';return $r.Data}
function Invoke-CuEdit($Source,$Output,$Operations){Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=@($Operations)}}
function Assert-CuBlocked($Source,$Output,$Operations){$sha=(Get-FileHash $Source).Hash;$r=Invoke-CuEdit $Source $Output $Operations;$r.Status|Should Be BLOCKED;Test-Path $Output|Should Be $false;(Get-FileHash $Source).Hash|Should Be $sha}

Describe 'Additional no-window document and table operations' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'out.hwpx';New-CuFixture $source
    }
    It 'stably sorts numeric rows while retaining header and the original file' {
        $table=(Get-CuData $source).Tables[0];$sha=(Get-FileHash $source).Hash
        $r=Invoke-CuEdit $source $output @(@{type='sort-table-rows';address=$table.address;startRow=1;endRow=3;column=1;dataType='NUMBER';direction='ASC'})
        ($r.Errors -join '; ')|Should Be ''; $after=(Get-CuData $output).Tables[0]
        ($after.cells|Where-Object columnAddress -eq 0|ForEach-Object {$_.text}) -join ','|Should Be 'Item,y,x,z'
        (Get-FileHash $source).Hash|Should Be $sha
        (Read-CuXml $output).SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="sz"]').GetAttribute('height')|Should Be '8000'
    }
    It 'sorts descending ordinal text and refuses nonnumeric numeric sort keys' {
        $t=(Get-CuData $source).Tables[0]
        $r=Invoke-CuEdit $source $output @(@{type='sort-table-rows';address=$t.address;startRow=1;endRow=3;column=0;dataType='TEXT';direction='DESC'})
        ($r.Errors -join '; ')|Should Be '';((Get-CuData $output).Tables[0].cells|Where-Object columnAddress -eq 0|ForEach-Object {$_.text}) -join ','|Should Be 'Item,z,y,x'
        Assert-CuBlocked $source (Join-Path $dir 'bad.hwpx') @(@{type='sort-table-rows';address=$t.address;startRow=0;endRow=3;column=1;dataType='NUMBER';direction='ASC'})
    }
    It 'repeats multiple header rows without cutting a vertical merge' {
        $t=(Get-CuData $source).Tables[0]
        $r=Invoke-CuEdit $source $output @(@{type='set-table-format';address=$t.address;headerRows=2})
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-CuXml $output;$xml.SelectSingleNode('//*[local-name()="tbl"]').GetAttribute('repeatHeader')|Should Be '1'
        $xml.SelectNodes('//*[local-name()="tc" and @header="1"]').Count|Should Be 4
    }
    It 'sets cell writing direction and line wrapping without changing its text' {
        $cell=(Get-CuData $source).Tables[0].cells[2]
        $r=Invoke-CuEdit $source $output @(@{type='set-cell-format';address=$cell.address;textDirection='VERTICAL';lineWrap='SQUEEZE'})
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-CuXml $output;$sub=$xml.SelectSingleNode('(//*[local-name()="tc"])[3]/*[local-name()="subList"]')
        $sub.GetAttribute('textDirection')|Should Be 'VERTICAL';$sub.GetAttribute('lineWrap')|Should Be 'SQUEEZE'
        (Get-CuData $output).Tables[0].cells[2].text|Should Be 'x'
    }
    It 'replaces one rich body paragraph with tabs linebreaks and independent run formatting' {
        $p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'AlphaBeta'|Select-Object -First 1
        $r=Invoke-CuEdit $source $output @(@{type='set-paragraph-content';address=$p.address;expectedText='AlphaBeta';paragraph=@{runs=@(@{text="New`t";textStyle=@{bold=$true}},@{text="body`nnext";textStyle=@{italic=$true}})}})
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-CuXml $output;$p=$xml.SelectSingleNode('//*[local-name()="p" and @id="100"]')
        $p.SelectNodes('*[local-name()="run"]').Count|Should Be 2
        $p.SelectNodes('.//*[local-name()="lineBreak"]').Count|Should Be 1;$p.SelectNodes('.//*[local-name()="tab"]').Count|Should Be 1
        $xml.SelectNodes('//*[local-name()="secPr"]').Count|Should Be 1
        (Read-CuXml $output 'Contents/header.xml').SelectNodes('//*[local-name()="charPr"]/*[local-name()="bold" or local-name()="italic"]').Count|Should BeGreaterThan 1
    }
    It 'sets explicit paragraph page and column breaks while preserving runs' {
        $p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'AlphaBeta'|Select-Object -First 1
        $r=Invoke-CuEdit $source $output @(@{type='set-paragraph-breaks';address=$p.address;pageBreak=$true;columnBreak=$false})
        ($r.Errors -join '; ')|Should Be ''
        $node=(Read-CuXml $output).SelectSingleNode('//*[local-name()="p" and @id="100"]');$node.GetAttribute('pageBreak')|Should Be '1';$node.GetAttribute('columnBreak')|Should Be '0';$node.InnerText|Should Be 'AlphaBeta'
    }
    It 'edits canonical section columns with explicit widths and preserves other section settings' {
        $r=Invoke-CuEdit $source $output @(@{type='set-columns';sectionIndex=0;count=2;gapMm=5;widthsMm=@(80,95)})
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-CuXml $output;$col=$xml.SelectSingleNode('//*[local-name()="colPr"]');$col.GetAttribute('colCount')|Should Be '2';$col.GetAttribute('sameSz')|Should Be '0';$col.GetAttribute('sameGap')|Should Be '1417'
        $col.SelectNodes('*[local-name()="colSz"]').Count|Should Be 2
        $xml.SelectSingleNode('//*[local-name()="pagePr"]').OuterXml|Should Be ((Read-CuXml $source).SelectSingleNode('//*[local-name()="pagePr"]').OuterXml)
    }
    It 'clones a page-border resource and updates only the selected page kind' {
        $r=Invoke-CuEdit $source $output @(@{type='set-page-border';sectionIndex=0;applyTo='ODD';style=@{borderType='SOLID';borderColor='#123456';borderWidthMm=0.2};offsetMm=@{left=3;right=3;top=4;bottom=4}})
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-CuXml $output;$node=$xml.SelectSingleNode('//*[local-name()="pageBorderFill" and @type="ODD"]');$node.GetAttribute('borderFillIDRef')|Should Not Be '1';$node.SelectSingleNode('*[local-name()="offset"]').GetAttribute('left')|Should Be '850'
        $xml.SelectSingleNode('//*[local-name()="pageBorderFill" and @type="EVEN"]').GetAttribute('borderFillIDRef')|Should Be '1'
        $header=Read-CuXml $output 'Contents/header.xml';$header.SelectSingleNode('//*[local-name()="borderFill" and @id="1"]/*[local-name()="leftBorder"]').GetAttribute('type')|Should Be ((Read-CuXml $source 'Contents/header.xml').SelectSingleNode('//*[local-name()="borderFill" and @id="1"]/*[local-name()="leftBorder"]').GetAttribute('type'))
    }
    It 'preflights guards limits and unsupported values before writing any result' {
        $p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'AlphaBeta'|Select-Object -First 1
        foreach($op in @(
            @{type='set-paragraph-content';address=$p.address;expectedText='wrong';paragraph=@{text='replacement'}},
            @{type='set-paragraph-breaks';address=$p.address;pageBreak='true'},
            @{type='set-columns';sectionIndex=0;count=2;gapMm=5;widthsMm=@(300,300)},
            @{type='set-page-border';sectionIndex=0;applyTo='INVALID';style=@{borderType='SOLID'}}
        )){Assert-CuBlocked $source $output @($op)}
    }
    It 'preserves embedded pictures and their exact bytes when sorting a different key column' {
        $cell=(Get-CuData $source).Tables[0].cells[2];$picture=Join-Path $dir 'picture.hwpx'
        $r=Invoke-CuEdit $source $picture @(@{type='insert-cell-image';address=$cell.address;expectedText='x';placement='append';path=(Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png');widthMm=3})
        ($r.Errors -join '; ')|Should Be '';$table=(Get-CuData $picture).Tables[0]
        $r=Invoke-CuEdit $picture $output @(@{type='sort-table-rows';address=$table.address;startRow=1;endRow=3;column=1;dataType='NUMBER';direction='ASC'})
        ($r.Errors -join '; ')|Should Be '';(Read-CuXml $output).SelectSingleNode('(//*[local-name()="tr"])[3]').SelectNodes('.//*[local-name()="pic"]').Count|Should Be 1
        $a=[IO.Compression.ZipFile]::OpenRead($picture);$b=[IO.Compression.ZipFile]::OpenRead($output)
        try{foreach($part in @($a.Entries|Where-Object FullName -like 'BinData/*')){$ma=[IO.MemoryStream]::new();$mb=[IO.MemoryStream]::new();$sa=$part.Open();$sb=$b.GetEntry($part.FullName).Open();try{$sa.CopyTo($ma);$sb.CopyTo($mb);[Convert]::ToBase64String($mb.ToArray())|Should Be ([Convert]::ToBase64String($ma.ToArray()))}finally{$sa.Dispose();$sb.Dispose();$ma.Dispose();$mb.Dispose()}}}finally{$a.Dispose();$b.Dispose()}
    }
    It 'rejects sorting across vertical merges and header boundaries through a merged cell' {
        $xml=Read-CuXml $source;$cell=$xml.SelectSingleNode('(//*[local-name()="tc"])[3]');$cell.SelectSingleNode('*[local-name()="cellSpan"]').SetAttribute('rowSpan','2');$cell.SelectSingleNode('*[local-name()="cellSz"]').SetAttribute('height','4000')
        $drop=$xml.SelectSingleNode('(//*[local-name()="tc"])[5]');$null=$drop.ParentNode.RemoveChild($drop);Write-CuXml $source $xml
        $table=(Get-CuData $source).Tables[0]
        Assert-CuBlocked $source $output @(@{type='sort-table-rows';address=$table.address;startRow=1;endRow=3;column=1;dataType='NUMBER';direction='ASC'})
        Assert-CuBlocked $source $output @(@{type='set-table-format';address=$table.address;headerRows=2})
    }
    It 'does not replace paragraphs that contain bookmarks fields or unknown metadata' {
        foreach($markup in @('<hp:ctrl><hp:bookmark name="keep"/></hp:ctrl>','<hp:vendor/>')) {
            New-CuFixture $source;$xml=Read-CuXml $source;$p=$xml.SelectSingleNode('//*[local-name()="p" and @id="100"]');$fragment=$xml.CreateDocumentFragment();$fragment.InnerXml='<hp:run xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" charPrIDRef="0">'+$markup+'</hp:run>';$null=$p.AppendChild($fragment);Write-CuXml $source $xml
            $p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'AlphaBeta'|Select-Object -First 1
            Assert-CuBlocked $source $output @(@{type='set-paragraph-content';address=$p.address;expectedText='AlphaBeta';paragraph=@{text='new'}})
        }
    }
    It 'invalidates all section line caches for columns and page-border edits' {
        $xml=Read-CuXml $source;$p=$xml.SelectSingleNode('//*[local-name()="p" and @id="100"]');$cache=$xml.CreateElement('hp','linesegarray','http://www.hancom.co.kr/hwpml/2011/paragraph');$null=$p.AppendChild($cache);Write-CuXml $source $xml
        foreach($op in @(@{type='set-columns';sectionIndex=0;count=2;gapMm=5},@{type='set-page-border';sectionIndex=0;applyTo='BOTH';style=@{borderColor='#123456'}})){
            $out=Join-Path $dir ($op.type+'.hwpx');$r=Invoke-CuEdit $source $out @($op);($r.Errors -join '; ')|Should Be '';(Read-CuXml $out).SelectNodes('//*[local-name()="linesegarray"]').Count|Should Be 0
        }
    }
    It 'rejects unknown column transitions rather than adding an unrelated column definition' {
        $xml=Read-CuXml $source;$existing=$xml.SelectSingleNode('//*[local-name()="colPr"]');if($existing){$null=$existing.ParentNode.RemoveChild($existing)}
        $p=$xml.SelectSingleNode('//*[local-name()="p" and @id="100"]');$fragment=$xml.CreateDocumentFragment();$fragment.InnerXml='<hp:run xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" charPrIDRef="0"><hp:colPr id="" type="NEWSPAPER" layout="LEFT" colCount="1" sameSz="1" sameGap="0"/></hp:run>';$null=$p.AppendChild($fragment);Write-CuXml $source $xml
        Assert-CuBlocked $source $output @(@{type='set-columns';sectionIndex=0;count=2;gapMm=5})
    }
    It 'runs new operations through the public CLI in fresh PowerShell 7 and Windows PowerShell processes' {
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        foreach($shell in @('pwsh','powershell')) {
            if(-not (Get-Command $shell -ErrorAction SilentlyContinue)){continue}
            $table=(Get-CuData $source).Tables[0];$plan=Join-Path $dir ($shell+'.json');$out=Join-Path $dir ($shell+'.hwpx')
            $json=ConvertTo-Json -InputObject @{version='2.0';operations=@(@{type='sort-table-rows';address=$table.address;startRow=1;endRow=3;column=1;dataType='NUMBER';direction='ASC'},@{type='set-columns';sectionIndex=0;count=2;gapMm=5})} -Depth 15
            [IO.File]::WriteAllText($plan,$json,[Text.UTF8Encoding]::new($true))
            $raw=& $shell -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $out -ApproveAdvanced
            $LASTEXITCODE|Should Be 0;$result=($raw -join "`n")|ConvertFrom-Json;($result.Errors -join '; ')|Should Be '';Test-Path $out|Should Be $true
            ((Get-CuData $out).Tables[0].cells|Where-Object columnAddress -eq 0|ForEach-Object {$_.text}) -join ','|Should Be 'Item,y,x,z'
        }
    }
    It 'inserts editable blank and rich paragraphs next to an inspected anchor without dropping section controls' {
        $p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'AlphaBeta'|Select-Object -First 1
        $r=Invoke-CuEdit $source $output @(@{type='insert-paragraphs';address=$p.address;placement='after';paragraphs=@(@{text='';textStyle=@{fontSizePt=6}},@{runs=@(@{text='New';textStyle=@{bold=$true}},@{text=' paragraph'})})})
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-CuXml $output;$p=$xml.SelectSingleNode('//*[local-name()="p" and @id="100"]');$p.NextSibling.InnerText|Should Be '';$p.NextSibling.NextSibling.InnerText|Should Be 'New paragraph'
        $xml.SelectNodes('//*[local-name()="secPr"]').Count|Should Be 1;$xml.SelectNodes('//*[local-name()="tbl"]').Count|Should Be 1
        $ids=@($xml.SelectNodes('//*[local-name()="p"]')|ForEach-Object {$_.GetAttribute('id')});@($ids|Select-Object -Unique).Count|Should Be $ids.Count
        $after=Get-CuData $output;$new=$after.Paragraphs|Where-Object text -eq 'New paragraph'|Select-Object -First 1
        $deleted=Join-Path $dir 'deleted.hwpx';$r=Invoke-CuEdit $output $deleted @(@{type='delete-paragraph';address=$new.address;expectedText='New paragraph'})
        ($r.Errors -join '; ')|Should Be '';(Get-CuData $deleted).Text|Should Not Match 'New paragraph';(Get-CuData $deleted).Text|Should Match 'AlphaBeta'
    }
    It 'refuses paragraph deletion with the wrong text or embedded structural controls' {
        $data=Get-CuData $source;$p=$data.Paragraphs|Where-Object text -eq 'AlphaBeta'|Select-Object -First 1
        Assert-CuBlocked $source $output @(@{type='delete-paragraph';address=$p.address;expectedText='wrong'})
        $p=$data.Paragraphs|Where-Object {$_.address.path.Count -eq 1}|Select-Object -First 1
        Assert-CuBlocked $source $output @(@{type='delete-paragraph';address=$p.address;expectedText=$p.text})
    }
    It 'does not insert into linked text lists or delete the last paragraph of a cell' {
        $cell=(Get-CuData $source).Tables[0].cells[2];$p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'x'|Select-Object -First 1
        Assert-CuBlocked $source $output @(@{type='delete-paragraph';address=$p.address;expectedText='x'})
        $xml=Read-CuXml $source;$sub=$xml.SelectSingleNode('(//*[local-name()="tc"])[3]/*[local-name()="subList"]');$sub.SetAttribute('linkListIDRef','7');Write-CuXml $source $xml
        $p=(Get-CuData $source).Paragraphs|Where-Object text -eq 'x'|Select-Object -First 1
        Assert-CuBlocked $source $output @(@{type='insert-paragraphs';address=$p.address;placement='after';paragraphs=@(@{text='new'})})
    }
    It 'does not enable a single header row through a vertical merge with the compatibility flag' {
        $xml=Read-CuXml $source;$cell=$xml.SelectSingleNode('(//*[local-name()="tc"])[1]');$cell.SelectSingleNode('*[local-name()="cellSpan"]').SetAttribute('rowSpan','2');$cell.SelectSingleNode('*[local-name()="cellSz"]').SetAttribute('height','4000')
        $drop=$xml.SelectSingleNode('(//*[local-name()="tc"])[3]');$null=$drop.ParentNode.RemoveChild($drop);Write-CuXml $source $xml
        $t=(Get-CuData $source).Tables[0]
        Assert-CuBlocked $source $output @(@{type='set-table-format';address=$t.address;repeatHeader=$true})
    }
    It 'requires a new inspection pass between a page-width change and column layout' {
        Assert-CuBlocked $source $output @(@{type='set-page';sectionIndex=0;orientation='LANDSCAPE'},@{type='set-columns';sectionIndex=0;count=2;gapMm=5;widthsMm=@(80,95)})
    }
}
