# Independent XML fixtures: the table writer never supplies these test inputs.
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-TuPart($Path,$Name='Contents/section0.xml') {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{$stream=$zip.GetEntry($Name).Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);return ,$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}}finally{$zip.Dispose()}
}
function Read-TuXml($Path,$Name='Contents/section0.xml'){[xml][Text.Encoding]::UTF8.GetString((Read-TuPart $Path $Name))}
function Write-TuXml($Path,[xml]$Xml){
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try{$zip.GetEntry('Contents/section0.xml').Delete();$stream=$zip.CreateEntry('Contents/section0.xml').Open();$bytes=[Text.Encoding]::UTF8.GetBytes($Xml.OuterXml);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
}
function Get-TuCell([xml]$Xml,[int]$Row,[int]$Column){$Xml.SelectSingleNode(('//*[local-name()="tbl"][1]/*[local-name()="tr"]/*[local-name()="tc"][*[local-name()="cellAddr"][@rowAddr="{0}" and @colAddr="{1}"]]' -f $Row,$Column))}
function New-TuFixture($Path,[switch]$Merged){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $Path
    $builder=[Text.StringBuilder]::new()
    $null=$builder.Append('<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" id="100" paraPrIDRef="0"><hp:run charPrIDRef="0"><hp:tbl id="100000" rowCnt="4" colCnt="4" cellSpacing="0" borderFillIDRef="2" lock="0"><hp:sz width="12000" height="8000" widthRelTo="ABSOLUTE" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" horzAlign="LEFT"/><hp:inMargin left="100" right="100" top="100" bottom="100"/><hp:outMargin left="0" right="0" top="0" bottom="0"/>')
    for($r=0;$r -lt 4;$r++){$null=$builder.Append('<hp:tr>');for($c=0;$c -lt 4;$c++){
        $text=if($r -eq 3){if($c -eq 0){'TOTAL'}else{''}}elseif($c -eq 1 -or $c -eq 2){[string]($r*20+$c*10)}else{'Label'+$r+$c}
        $null=$builder.Append(('<hp:tc name="" header="0" hasMargin="1" protect="0" editable="0" dirty="0" borderFillIDRef="2"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="CENTER" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0"><hp:p id="{0}" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>{1}</hp:t></hp:run><hp:linesegarray><hp:lineseg textpos="0"/></hp:linesegarray></hp:p></hp:subList><hp:cellAddr rowAddr="{2}" colAddr="{3}"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="3000" height="2000"/><hp:cellMargin left="100" right="100" top="100" bottom="100"/></hp:tc>' -f (101+$r*4+$c),$text,$r,$c))
    };$null=$builder.Append('</hp:tr>')}
    $null=$builder.Append('</hp:tbl></hp:run></hp:p>')
    $xml=Read-TuXml $Path;$fragment=$xml.CreateDocumentFragment();$fragment.InnerXml=$builder.ToString();$null=$xml.DocumentElement.AppendChild($fragment)
    if($Merged){
        $cell=Get-TuCell $xml 0 0;$cell.SelectSingleNode('.//*[local-name()="t"]').InnerText='100'
        $span=$cell.SelectSingleNode('*[local-name()="cellSpan"]');$span.SetAttribute('rowSpan','2');$span.SetAttribute('colSpan','2')
        $size=$cell.SelectSingleNode('*[local-name()="cellSz"]');$size.SetAttribute('width','6000');$size.SetAttribute('height','4000')
        foreach($pair in @(@(0,1),@(1,0),@(1,1))){$drop=Get-TuCell $xml $pair[0] $pair[1];$null=$drop.ParentNode.RemoveChild($drop)}
    }
    Write-TuXml $Path $xml
}
function Get-TuInspection($Path){$result=Get-HwpxPackageInspection -LiteralPath $Path;($result.Errors -join '; ')|Should Be '';return $result.Data}
function Invoke-TuEdit($Source,$Output,[object[]]$Operations){Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=$Operations}}
function Assert-TuBlocked($Source,$Output,[object[]]$Operations){
    $hash=(Get-FileHash -LiteralPath $Source).Hash
    $result=Invoke-TuEdit $Source $Output $Operations
    $result.Status|Should Be 'BLOCKED';$result.Errors.Count|Should BeGreaterThan 0
    Test-Path -LiteralPath $Output|Should Be $false
    (Get-FileHash -LiteralPath $Source).Hash|Should Be $hash
    @(Get-ChildItem -LiteralPath (Split-Path $Output) -Filter '*.partial.hwpx' -Force).Count|Should Be 0
}

Describe 'Cell pictures and real nested tables without native applications' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'edited.hwpx';New-TuFixture $source
    }
    It 'embeds image bytes in BinData and appends an inline picture inside the inspected cell' {
        $data=Get-TuInspection $source;$cell=$data.Tables[0].cells[5];$image=Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'
        $hash=(Get-FileHash $source).Hash
        $result=Invoke-TuEdit $source $output @(@{type='insert-cell-image';address=$cell.address;expectedText=$cell.text;placement='append';path=$image;widthMm=5;altText='Cell picture'})
        ($result.Errors -join '; ')|Should Be ''
        $xml=Read-TuXml $output;$tc=Get-TuCell $xml 1 1
        $tc.SelectNodes('.//*[local-name()="pic"]').Count|Should Be 1
        $tc.SelectNodes('*[local-name()="subList"]/*[local-name()="p"]').Count|Should Be 2
        $tc.SelectSingleNode('.//*[local-name()="shapeComment"]').InnerText|Should Be 'Cell picture'
        $id=$tc.SelectSingleNode('.//*[local-name()="img"]').GetAttribute('binaryItemIDRef')
        $hpf=Read-TuXml $output 'Contents/content.hpf';$item=$hpf.SelectSingleNode('//*[local-name()="item" and @id="'+$id+'"]')
        $item.GetAttribute('media-type')|Should Be 'image/png'
        [Convert]::ToBase64String((Read-TuPart $output $item.GetAttribute('href')))|Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($image)))
        (Get-FileHash $source).Hash|Should Be $hash
        (Get-TuInspection $output).Tables.Count|Should Be 1
    }
    It 'creates nested tables with rich text images further nesting and independent style overrides' {
        $data=Get-TuInspection $source;$cell=$data.Tables[0].cells[5]
        $table=@{rows=2;columns=2;style=@{fillColor='#EDF3F8';cellPaddingMm=0.2};textStyle=@{fontFamily='Nested Font';bold=$true};cells=@(
            @{row=1;column=1;paragraphs=@(@{runs=@(@{text='Bold'},@{text='Plain';textStyle=@{bold=$false}})})},
            @{row=1;column=2;content=@(@{type='image';path=(Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png');widthMm=3})},
            @{row=2;column=1;colSpan=2;content=@(@{type='paragraph';text='Inner caption'},@{type='table';table=@{rows=1;columns=1;cells=@(@{row=1;column=1;text='Deep cell'})}})}
        )}
        $result=Invoke-TuEdit $source $output @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=$table})
        ($result.Errors -join '; ')|Should Be ''
        $after=Get-TuInspection $output
        $after.Tables.Count|Should Be 3
        $after.Text|Should Match 'Deep cell'
        $xml=Read-TuXml $output;$tc=Get-TuCell $xml 1 1
        $tc.SelectNodes('.//*[local-name()="tbl"]').Count|Should Be 2
        $inner=$tc.SelectSingleNode('.//*[local-name()="tbl"]')
        (($inner.SelectNodes('*')|Select-Object -First 4|ForEach-Object {$_.LocalName}) -join ',')|Should Be 'sz,pos,outMargin,inMargin'
        $tc.SelectNodes('.//*[local-name()="pic"]').Count|Should Be 1
        $header=Read-TuXml $output 'Contents/header.xml'
        $runs=$tc.SelectNodes('.//*[local-name()="t" and text()="Bold"]|.//*[local-name()="t" and text()="Plain"]')
        $header.SelectSingleNode('//*[local-name()="charPr" and @id="'+$runs[0].ParentNode.GetAttribute('charPrIDRef')+'"]').SelectNodes('*[local-name()="bold"]').Count|Should Be 1
        $header.SelectSingleNode('//*[local-name()="charPr" and @id="'+$runs[1].ParentNode.GetAttribute('charPrIDRef')+'"]').SelectNodes('*[local-name()="bold"]').Count|Should Be 0
        $ids=@($xml.SelectNodes('//*[local-name()="p"]')|ForEach-Object {$_.GetAttribute('id')})
        @($ids|Select-Object -Unique).Count|Should Be $ids.Count
    }
    It 'preserves an existing picture when adding a nested table to the same cell in another pass' {
        $cell=(Get-TuInspection $source).Tables[0].cells[5]
        $result=Invoke-TuEdit $source $output @(@{type='insert-cell-image';address=$cell.address;expectedText=$cell.text;placement='append';path=(Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png');widthMm=3})
        ($result.Errors -join '; ')|Should Be ''
        $cell=(Get-TuInspection $output).Tables[0].cells[5];$second=Join-Path $dir 'second.hwpx'
        $result=Invoke-TuEdit $output $second @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='prepend';table=@{rows=1;columns=1;cells=@(@{row=1;column=1;text='Nested'})}})
        ($result.Errors -join '; ')|Should Be ''
        $xml=Read-TuXml $second;(Get-TuCell $xml 1 1).SelectNodes('.//*[local-name()="pic"]').Count|Should Be 1
    }
    It 'rejects oversized images invalid nesting wrong guards and later invalid operations atomically' {
        $cell=(Get-TuInspection $source).Tables[0].cells[5];$image=Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'
        foreach($op in @(
            @{type='insert-cell-image';address=$cell.address;expectedText=$cell.text;placement='append';path=$image;widthMm=100},
            @{type='insert-cell-image';address=$cell.address;expectedText='wrong';placement='append';path=$image},
            @{type='insert-cell-image';address=$cell.address;expectedText=$cell.text;placement='append';path='https://example.invalid/image.png'},
            @{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=100;cells=@()}},
            @{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;cells=@(@{row=1;column=1;text='A'},@{row=1;column=1;text='B'})}}
        )){Assert-TuBlocked $source $output @($op)}
        $valid=@{type='insert-cell-image';address=$cell.address;expectedText=$cell.text;placement='append';path=$image;widthMm=3}
        Assert-TuBlocked $source $output @($valid,@{type='unsupported'})
    }
}

Describe 'Merged table track edits preserve anchor content and occupancy' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'merged.hwpx';$output=Join-Path $dir 'edited.hwpx';New-TuFixture $source -Merged
    }
    It 'extends the spanning anchor across an inserted interior row or column' {
        foreach($axis in @('row','column')){
            $table=(Get-TuInspection $source).Tables[0];$op=@{type=('insert-table-'+$axis);address=$table.address;index=1}
            if($axis -eq 'row'){$op.heightMm=5}else{$op.widthMm=5}
            $destination=Join-Path $dir ($axis+'.hwpx');$result=Invoke-TuEdit $source $destination @($op)
            ($result.Errors -join '; ')|Should Be ''
            $after=(Get-TuInspection $destination).Tables[0];$cell=$after.cells[0]
            $cell.text|Should Be '100'
            if($axis -eq 'row'){$after.rowCount|Should Be 5;$cell.rowSpan|Should Be 3;$cell.height|Should Be 5417}else{$after.columnCount|Should Be 5;$cell.columnSpan|Should Be 3;$cell.width|Should Be 7417}
            $after.grid.Count|Should Be $after.rowCount
        }
    }
    It 'moves an anchor out of a deleted first row or column without deleting its content' {
        foreach($axis in @('row','column')){
            $table=(Get-TuInspection $source).Tables[0]
            $expected=@(for($n=0;$n -lt 4;$n++){$slot=if($axis -eq 'row'){$table.grid[0][$n]}else{$table.grid[$n][0]};$table.cells[$slot.cellIndex].text})
            $destination=Join-Path $dir ($axis+'.hwpx');$result=Invoke-TuEdit $source $destination @(@{type=('delete-table-'+$axis);address=$table.address;index=0;expectedTexts=$expected})
            ($result.Errors -join '; ')|Should Be ''
            $after=(Get-TuInspection $destination).Tables[0];$cell=$after.cells[0]
            $cell.text|Should Be '100';$cell.rowAddress|Should Be 0;$cell.columnAddress|Should Be 0
            if($axis -eq 'row'){$after.rowCount|Should Be 3;$cell.rowSpan|Should Be 1;$cell.columnSpan|Should Be 2}else{$after.columnCount|Should Be 3;$cell.rowSpan|Should Be 2;$cell.columnSpan|Should Be 1}
        }
    }
    It 'rejects an inaccurate merged-track guard and preserves the original' {
        $table=(Get-TuInspection $source).Tables[0]
        Assert-TuBlocked $source $output @(@{type='delete-table-row';address=$table.address;index=1;expectedTexts=@('wrong','100','40','Label13')})
    }
    It 'retains an embedded picture when its spanning anchor moves out of a deleted row' {
        $table=(Get-TuInspection $source).Tables[0];$cell=$table.cells[0];$withImage=Join-Path $dir 'with-image.hwpx'
        $result=Invoke-TuEdit $source $withImage @(@{type='insert-cell-image';address=$cell.address;expectedText=$cell.text;placement='append';path=(Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png');widthMm=3})
        ($result.Errors -join '; ')|Should Be ''
        $table=(Get-TuInspection $withImage).Tables[0];$expected=@(for($n=0;$n -lt 4;$n++){$table.cells[$table.grid[0][$n].cellIndex].text})
        $result=Invoke-TuEdit $withImage $output @(@{type='delete-table-row';address=$table.address;index=0;expectedTexts=$expected})
        ($result.Errors -join '; ')|Should Be ''
        (Get-TuCell (Read-TuXml $output) 0 0).SelectNodes('.//*[local-name()="pic"]').Count|Should Be 1
    }
    It 'requires explicit hidden track sizes in a staggered merged grid and preserves both anchors' {
        New-TuFixture $source
        $xml=Read-TuXml $source
        foreach($definition in @(@{r=0;c=0;rs=3;cs=2;text='100'},@{r=1;c=2;rs=3;cs=2;text='200'})){
            $anchor=Get-TuCell $xml $definition.r $definition.c
            $anchor.SelectSingleNode('.//*[local-name()="t"]').InnerText=$definition.text
            $span=$anchor.SelectSingleNode('*[local-name()="cellSpan"]');$span.SetAttribute('rowSpan',[string]$definition.rs);$span.SetAttribute('colSpan',[string]$definition.cs)
            $size=$anchor.SelectSingleNode('*[local-name()="cellSz"]');$size.SetAttribute('width',[string]($definition.cs*3000));$size.SetAttribute('height',[string]($definition.rs*2000))
            for($r=$definition.r;$r -lt $definition.r+$definition.rs;$r++){for($c=$definition.c;$c -lt $definition.c+$definition.cs;$c++){if($r -eq $definition.r -and $c -eq $definition.c){continue};$drop=Get-TuCell $xml $r $c;$null=$drop.ParentNode.RemoveChild($drop)}}
        }
        Write-TuXml $source $xml;$table=(Get-TuInspection $source).Tables[0]
        $op=@{type='insert-table-row';address=$table.address;index=2;heightMm=5}
        Assert-TuBlocked $source $output @($op)
        $op.rowHeightsMm=@(1..4|ForEach-Object {2000*25.4/7200})
        $result=Invoke-TuEdit $source $output @($op)
        ($result.Errors -join '; ')|Should Be ''
        $after=(Get-TuInspection $output).Tables[0]
        $after.rowCount|Should Be 5
        @($after.cells|Where-Object {$_.text -eq '100' -and $_.rowSpan -eq 4}).Count|Should Be 1
        @($after.cells|Where-Object {$_.text -eq '200' -and $_.rowSpan -eq 4}).Count|Should Be 1
    }
}

Describe 'Verified decimal table formulas' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'numbers.hwpx';$output=Join-Path $dir 'calculated.hwpx';New-TuFixture $source
    }
    It 'calculates sums and dependencies independent of target order and reports verified values' {
        $table=(Get-TuInspection $source).Tables[0]
        $result=Invoke-TuEdit $source $output @(@{type='calculate-table';address=$table.address;calculations=@(
            @{row=3;column=3;expectedText='';expression='=B4+C4';format=@{decimalPlaces=0;groupSeparator=$true;suffix=' units'}},
            @{row=3;column=1;expectedText='';expression='SUM(B1:B3)'},
            @{row=3;column=2;expectedText='';expression='SUM(C1:C3)';textStyle=@{bold=$true}}
        )})
        ($result.Errors -join '; ')|Should Be ''
        $cells=(Get-TuInspection $output).Tables[0].cells
        $cells[13].text|Should Be '90';$cells[14].text|Should Be '120';$cells[15].text|Should Be '210 units'
        $result.Data.CalculationResults.Count|Should Be 3
    }
    It 'uses decimal rounding arithmetic averages min max count and parentheses' {
        $table=(Get-TuInspection $source).Tables[0]
        $result=Invoke-TuEdit $source $output @(@{type='calculate-table';address=$table.address;calculations=@(
            @{row=3;column=1;expectedText='';expression='ROUND(1.005,2)'},
            @{row=3;column=2;expectedText='';expression='AVERAGE(B1:B3)+MIN(C1:C3)+MAX(B1:B3)+COUNT(C1:C3)'},
            @{row=3;column=3;expectedText='';expression='-(B1-C1)*(2+1)/3'}
        )})
        ($result.Errors -join '; ')|Should Be ''
        $cells=(Get-TuInspection $output).Tables[0].cells
        $cells[13].text|Should Be '1.01';$cells[14].text|Should Be '103';$cells[15].text|Should Be '10'
    }
    It 'counts a merged range anchor once rather than repeating its number' {
        New-TuFixture $source -Merged;$table=(Get-TuInspection $source).Tables[0]
        $result=Invoke-TuEdit $source $output @(@{type='calculate-table';address=$table.address;calculations=@(@{row=3;column=3;expectedText='';expression='SUM(A1:B2)'})})
        ($result.Errors -join '; ')|Should Be ''
        (Get-TuInspection $output).Tables[0].cells[-1].text|Should Be '100'
    }
    It 'parses grouped numeric cells and formats decimal totals without binary rounding' {
        $xml=Read-TuXml $source;(Get-TuCell $xml 0 1).SelectSingleNode('.//*[local-name()="t"]').InnerText='1,234.50';Write-TuXml $source $xml
        $table=(Get-TuInspection $source).Tables[0]
        $result=Invoke-TuEdit $source $output @(@{type='calculate-table';address=$table.address;calculations=@(@{row=3;column=3;expectedText='';expression='B1+0.1';format=@{decimalPlaces=2;groupSeparator=$true}})})
        ($result.Errors -join '; ')|Should Be ''
        (Get-TuInspection $output).Tables[0].cells[-1].text|Should Be '1,234.60'
    }
    It 'rejects cycles division by zero scripts out-of-range references and nonnumeric inputs' {
        $table=(Get-TuInspection $source).Tables[0]
        foreach($formula in @('1/0','SUM(B1:B99)','A1+1','SUM(B1:B3); Get-Process','[IO.File]::Delete("anything")','ROUND(1,99)','SUM(B1:B3)+')){
            Assert-TuBlocked $source $output @(@{type='calculate-table';address=$table.address;calculations=@(@{row=3;column=1;expectedText='';expression=$formula})})
        }
        Assert-TuBlocked $source $output @(@{type='calculate-table';address=$table.address;calculations=@(@{row=3;column=1;expectedText='';expression='C4'},@{row=3;column=2;expectedText='';expression='B4'})})
    }
}

Describe 'Upgraded operations through fresh public CLI processes' {
    It 'builds a nested picture cell then calculates totals using PowerShell 7 and Windows 5.1' {
        foreach($shellName in @('pwsh','powershell')){
            $shell=Get-Command $shellName -ErrorAction SilentlyContinue;if($null -eq $shell){continue}
            $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
            $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'nested.hwpx';New-TuFixture $source
            $data=Get-TuInspection $source;$cell=$data.Tables[0].cells[3];$planPath=Join-Path $dir 'plan.json'
            $op=@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;cells=@(@{row=1;column=1;content=@(@{type='image';path=(Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png');widthMm=3})})}}
            [IO.File]::WriteAllText($planPath,(@{version='2.0';operations=@($op)}|ConvertTo-Json -Depth 25),[Text.UTF8Encoding]::new($false))
            $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
            $raw=& $shell.Source -NoProfile -File $cli edit-hwpx -LiteralPath $source -OutputPath $output -PlanPath $planPath -ApproveAdvanced
            $LASTEXITCODE|Should Be 0
            (($raw -join "`n")|ConvertFrom-Json).status|Should Be 'PASS_WITH_WARNINGS'
            $table=(Get-TuInspection $output).Tables[0];$second=Join-Path $dir 'calculated.hwpx'
            $op=@{type='calculate-table';address=$table.address;calculations=@(@{row=3;column=3;expression='SUM(B1:C3)';expectedText=''})}
            [IO.File]::WriteAllText($planPath,(@{version='2.0';operations=@($op)}|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            $raw=& $shell.Source -NoProfile -File $cli edit-hwpx -LiteralPath $output -OutputPath $second -PlanPath $planPath
            $LASTEXITCODE|Should Be 0
            (($raw -join "`n")|ConvertFrom-Json).status|Should Be 'PASS_WITH_WARNINGS'
            (Get-TuInspection $second).Tables[0].cells[-1].text|Should Be '210'
        }
    }
}
