Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-TfXml($Path) {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {$reader=[IO.StreamReader]::new($zip.GetEntry('Contents/section0.xml').Open());try {[xml]$reader.ReadToEnd()}finally {$reader.Dispose()}}finally {$zip.Dispose()}
}
function Write-TfXml($Path,[xml]$Xml) {
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try {$zip.GetEntry('Contents/section0.xml').Delete();$stream=$zip.CreateEntry('Contents/section0.xml').Open();$bytes=[Text.Encoding]::UTF8.GetBytes($Xml.OuterXml);try {$stream.Write($bytes,0,$bytes.Length)}finally {$stream.Dispose()}}finally {$zip.Dispose()}
}
function New-TfFixture($Path) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $Path
    $xml=Read-TfXml $Path;$fragment=$xml.CreateDocumentFragment()
    $fragment.InnerXml=@'
<hp:p xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" id="100" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:tbl id="1000" rowCnt="1" colCnt="2" pageBreak="NONE" repeatHeader="0" cellSpacing="0" borderFillIDRef="2" lock="0"><hp:sz width="24000" height="2000" widthRelTo="ABSOLUTE" heightRelTo="ABSOLUTE" protect="0"/><hp:pos treatAsChar="1" flowWithText="1" horzRelTo="COLUMN" vertRelTo="PARA" horzAlign="LEFT" horzOffset="0"/><hp:outMargin left="0" right="0" top="0" bottom="0"/><hp:inMargin left="100" right="100" top="100" bottom="100"/><hp:tr><hp:tc header="0" hasMargin="1" protect="0" editable="0" borderFillIDRef="2"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="TOP" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0"><hp:p id="101" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>Left</hp:t></hp:run></hp:p></hp:subList><hp:cellAddr rowAddr="0" colAddr="0"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="12000" height="2000"/><hp:cellMargin left="100" right="100" top="100" bottom="100"/></hp:tc><hp:tc header="0" hasMargin="1" protect="0" editable="0" borderFillIDRef="2"><hp:subList id="" textDirection="HORIZONTAL" lineWrap="BREAK" vertAlign="TOP" linkListIDRef="0" linkListNextIDRef="0" textWidth="0" textHeight="0" hasTextRef="0" hasNumRef="0"><hp:p id="102" paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0"><hp:t>Right</hp:t></hp:run></hp:p></hp:subList><hp:cellAddr rowAddr="0" colAddr="1"/><hp:cellSpan rowSpan="1" colSpan="1"/><hp:cellSz width="12000" height="2000"/><hp:cellMargin left="100" right="100" top="100" bottom="100"/></hp:tc></hp:tr></hp:tbl></hp:run></hp:p>
'@
    $null=$xml.DocumentElement.AppendChild($fragment);Write-TfXml $Path $xml
}
function Invoke-TfEdit($Source,$Output,$Operations) {Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=@($Operations)}}
function Assert-TfBlocked($Source,$Output,$Operations) {
    $hash=(Get-FileHash -LiteralPath $Source).Hash
    $result=Invoke-TfEdit $Source $Output $Operations
    $result.Status | Should Be BLOCKED
    $result.Errors.Count | Should BeGreaterThan 0
    Test-Path -LiteralPath $Output | Should Be $false
    (Get-FileHash -LiteralPath $Source).Hash | Should Be $hash
    @(Get-ChildItem -LiteralPath (Split-Path $Output) -Filter '*.partial.hwpx' -Force).Count | Should Be 0
}

Describe 'Tables stay in their writing area and allow long cells to continue' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'output.hwpx';New-TfFixture $source
    }
    It 'writes a long single cell as a splittable table without losing paragraphs' {
        $paragraphs=@(1..80 | ForEach-Object {[pscustomobject]@{type='paragraph';text=('Content '+$_)}})
        $plan=[pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='table';rows=1;columns=1;cells=@([pscustomobject]@{row=1;column=1;paragraphs=$paragraphs})})}
        $result=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output
        ($result.Errors -join ';') | Should Be ''
        $table=(Read-TfXml $output).SelectSingleNode('//*[local-name()="tbl"]')
        $table.GetAttribute('pageBreak') | Should Be CELL
        $table.SelectSingleNode('*[local-name()="pos"]').GetAttribute('treatAsChar') | Should Be '0'
        $table.SelectNodes('*[local-name()="tr"]/*[local-name()="tc"]').Count | Should Be 1
        $table.SelectNodes('.//*[local-name()="p"]').Count | Should Be 80
        $table.InnerText.Contains('Content 80') | Should Be $true
    }
    It 'keeps the default full-width table including outside margins inside the body' {
        $plan='{"version":"2.0","content":[{"type":"table","rows":1,"columns":2,"cells":[]}]}' | ConvertFrom-Json
        $null=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output
        $xml=Read-TfXml $output;$page=$xml.SelectSingleNode('//*[local-name()="pagePr"]');$margin=$page.FirstChild
        $body=[long]$page.GetAttribute('width')-[long]$margin.GetAttribute('left')-[long]$margin.GetAttribute('right')
        $table=$xml.SelectSingleNode('//*[local-name()="tbl"]');$outside=$table.SelectSingleNode('*[local-name()="outMargin"]')
        $occupied=[long]$table.SelectSingleNode('*[local-name()="sz"]').GetAttribute('width')+[long]$outside.GetAttribute('left')+[long]$outside.GetAttribute('right')
        ($occupied -le $body) | Should Be $true
    }
    It 'unsets inline treatment when enabling in-cell pagination on an existing table' {
        $result=Invoke-TfEdit $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;pageBreak='CELL'})
        ($result.Errors -join ';') | Should Be ''
        $table=(Read-TfXml $output).SelectSingleNode('//*[local-name()="tbl"]')
        $table.GetAttribute('pageBreak') | Should Be CELL
        $table.SelectSingleNode('*[local-name()="pos"]').GetAttribute('treatAsChar') | Should Be '0'
        $table.InnerText | Should Be LeftRight
    }
    It 'blocks a width increase beyond the section before writing an output' {
        Assert-TfBlocked $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(100,100)})
    }
    It 'blocks an inserted column that pushes a table outside the body' {
        Assert-TfBlocked $source $output @(@{type='insert-table-column';sectionIndex=0;tableIndex=0;index=1;widthMm=180})
    }
    It 'blocks a page shrink that leaves an existing table wider than the body' {
        Assert-TfBlocked $source $output @(@{type='set-page';sectionIndex=0;margins=@{leftMm=80;rightMm=80}})
    }
    It 'validates the final page and table sizes together rather than rejecting a repaired intermediate width' {
        $result=Invoke-TfEdit $source $output @(@{type='set-page';sectionIndex=0;margins=@{leftMm=80;rightMm=80}},@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(20,20)})
        ($result.Errors -join ';') | Should Be ''
        Test-Path -LiteralPath $output | Should Be $true
    }
    It 'accounts for the outside margin as well as the declared table width on resize' {
        $xml=Read-TfXml $source;$xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="outMargin"]').SetAttribute('left','5000');Write-TfXml $source $xml
        Assert-TfBlocked $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(85,85)})
    }
    It 'uses the narrowest column when automatic flow cannot establish an unequal column position' {
        Assert-TfBlocked $source $output @(@{type='set-columns';sectionIndex=0;count=2;gapMm=10;widthsMm=@(110,60)},@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(35,35)})
    }
    It 'blocks resizing a nested table beyond the parent cell inner width' {
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0]
        $nested=Join-Path $dir 'nested.hwpx'
        $result=Invoke-TfEdit $source $nested @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=20;cells=@(@{row=1;column=1;text='Nested'})}})
        ($result.Errors -join ';') | Should Be ''
        $inner=@((Get-HwpxPackageInspection -LiteralPath $nested).Data.Tables)[1]
        Assert-TfBlocked $nested $output @(@{type='set-table-format';address=$inner.address;columnWidthsMm=@(60)})
    }
    It 'checks existing nested tables when the outer cell is narrowed' {
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0];$nested=Join-Path $dir 'nested.hwpx'
        $null=Invoke-TfEdit $source $nested @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=35;cells=@()}})
        Assert-TfBlocked $nested $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(30,30)})
    }
    It 'rejects an explicitly indivisible table taller than the page before generating it' {
        $plan='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"pageBreak":"NONE","rowHeightsMm":[300],"cells":[]}]}' | ConvertFrom-Json
        (Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output).Status | Should Be BLOCKED
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'blocks a tall indivisible stored table but permits cell pagination without changing its text' {
        Assert-TfBlocked $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;rowHeightsMm=@(300)})
        $result=Invoke-TfEdit $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;rowHeightsMm=@(300);pageBreak='CELL'})
        ($result.Errors -join ';') | Should Be ''
        (Read-TfXml $output).SelectSingleNode('//*[local-name()="tbl"]').InnerText | Should Be LeftRight
    }
    It 'reports inline treatment and outside margins so callers can diagnose clipping' {
        $xml=Read-TfXml $source;$xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="outMargin"]').SetAttribute('left','123');Write-TfXml $source $xml
        $table=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0]
        $table.properties.treatAsChar | Should Be $true
        $table.outerMargins.left | Should Be 123
        $null=Invoke-TfEdit $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;pageBreak='CELL'})
        (Get-HwpxPackageInspection -LiteralPath $output).Data.Tables[0].properties.treatAsChar | Should Be $false
    }
    It 'rejects a left-aligned negative offset even when the table itself is narrow' {
        $xml=Read-TfXml $source;$pos=$xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="pos"]');$pos.SetAttribute('treatAsChar','0');$pos.SetAttribute('horzOffset','-100');Write-TfXml $source $xml
        Assert-TfBlocked $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(40,40)})
    }
    It 'does not promise multi-page support for an all-vertical table taller than the page' {
        Assert-TfBlocked $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;rowHeightsMm=@(300);pageBreak='CELL';textDirection='VERTICALALL'})
    }
    It 'uses a flow table rather than an indivisible inline object for new nested tables too' {
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0]
        $result=Invoke-TfEdit $source $output @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=20;cells=@()}})
        ($result.Errors -join ';') | Should Be ''
        $tables=(Read-TfXml $output).SelectNodes('//*[local-name()="tbl"]')
        $tables[1].SelectSingleNode('*[local-name()="pos"]').GetAttribute('treatAsChar') | Should Be '0'
    }
    It 'accepts a fitted landscape table after applying the complete plan' {
        $result=Invoke-TfEdit $source $output @(@{type='set-page';sectionIndex=0;orientation='LANDSCAPE'},@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(120,120)})
        ($result.Errors -join ';') | Should Be ''
        Test-Path -LiteralPath $output | Should Be $true
    }
    It 'rejects a tall single cell in cell-boundary-only pagination when generating' {
        $plan='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"pageBreak":"TABLE","rowHeightsMm":[300],"cells":[]}]}' | ConvertFrom-Json
        (Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output).Status | Should Be BLOCKED
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'rejects stale unequal column widths after a page shrink' {
        $columns=Join-Path $dir 'columns.hwpx'
        $null=Invoke-TfEdit $source $columns @(@{type='set-columns';sectionIndex=0;count=2;gapMm=10;widthsMm=@(80,90)},@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(35,35)})
        Assert-TfBlocked $columns $output @(@{type='set-page';sectionIndex=0;margins=@{leftMm=80;rightMm=80}})
    }
    It 'checks the containing table when cell formatting makes all cells vertical' {
        $tall=Join-Path $dir 'horizontal-tall.hwpx'
        $null=Invoke-TfEdit $source $tall @(@{type='set-table-format';sectionIndex=0;tableIndex=0;rowHeightsMm=@(300);pageBreak='CELL'})
        $data=(Get-HwpxPackageInspection -LiteralPath $tall).Data
        $ops=@($data.Tables[0].cells | ForEach-Object {@{type='set-cell-format';address=$_.address;textDirection='VERTICALALL'}})
        Assert-TfBlocked $tall $output $ops
    }
    It 'uses the emitted default row minima to reject a 35-row indivisible table' {
        $plan='{"version":"2.0","content":[{"type":"table","rows":35,"columns":1,"pageBreak":"NONE","cells":[]}]}' | ConvertFrom-Json
        (Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output).Status | Should Be BLOCKED
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'uses the emitted default row minima for a vertically merged indivisible cell' {
        $plan='{"version":"2.0","content":[{"type":"table","rows":35,"columns":1,"pageBreak":"TABLE","cells":[{"row":1,"column":1,"rowSpan":35,"text":"Merged"}]}]}' | ConvertFrom-Json
        (Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output).Status | Should Be BLOCKED
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'rejects an oversized nested table when the enclosing table cannot paginate' {
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0]
        Assert-TfBlocked $source $output @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=20;rowHeightsMm=@(300);pageBreak='CELL';cells=@()}})
    }
    It 'accounts for the anchor paragraph margins of an inline table' {
        $paragraph=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs | Where-Object {$_.address.path.Count -eq 1})[-1]
        Assert-TfBlocked $source $output @(@{type='set-paragraph-format';address=$paragraph.address;paragraphStyle=@{leftMarginMm=80;rightMarginMm=80}})
    }
    It 'does not require unknown geometry merely to change a cell border color' {
        $xml=Read-TfXml $source;$table=$xml.SelectSingleNode('//*[local-name()="tbl"]');$null=$table.RemoveChild($table.SelectSingleNode('*[local-name()="sz"]'));Write-TfXml $source $xml
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0]
        $result=Invoke-TfEdit $source $output @(@{type='set-cell-format';address=$cell.address;style=@{borderColor='#112233'}})
        ($result.Errors -join ';') | Should Be ''
        (Read-TfXml $output).SelectSingleNode('//*[local-name()="tbl"]').InnerText | Should Be LeftRight
        (Read-TfXml $output).SelectNodes('//*[local-name()="tbl"]/*[local-name()="sz"]').Count | Should Be 0
    }
    It 'rejects native-incompatible or parity-dependent floating alignment <Alignment>' -TestCases @(@{Alignment='UNKNOWN'},@{Alignment='INSIDE'},@{Alignment='OUTSIDE'}) {
        param($Alignment)
        $xml=Read-TfXml $source;$pos=$xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="pos"]');$pos.SetAttribute('treatAsChar','0');$pos.SetAttribute('horzAlign',$Alignment);Write-TfXml $source $xml
        Assert-TfBlocked $source $output @(@{type='set-table-format';sectionIndex=0;tableIndex=0;columnWidthsMm=@(40,40)})
    }
    It 'includes enclosing cell padding in an indivisible nested table minimum height' {
        $xml=Read-TfXml $source;$table=$xml.SelectSingleNode('//*[local-name()="tbl"]');$table.SelectSingleNode('*[local-name()="sz"]').SetAttribute('height','15000')
        foreach($size in $table.SelectNodes('*[local-name()="tr"]/*[local-name()="tc"]/*[local-name()="cellSz"]')){$size.SetAttribute('height','15000')}
        $margin=$table.SelectSingleNode('*[local-name()="tr"]/*[local-name()="tc"][1]/*[local-name()="cellMargin"]');$margin.SetAttribute('top','5669');$margin.SetAttribute('bottom','5669');Write-TfXml $source $xml
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0]
        Assert-TfBlocked $source $output @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=20;rowHeightsMm=@(230);pageBreak='CELL';cells=@()}})
    }
    It 'accumulates separate nested table paragraphs inside an indivisible parent' {
        $cell=(Get-HwpxPackageInspection -LiteralPath $source).Data.Tables[0].cells[0];$first=Join-Path $dir 'first-nested.hwpx'
        $result=Invoke-TfEdit $source $first @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=20;rowHeightsMm=@(180);cells=@()}})
        ($result.Errors -join ';') | Should Be ''
        $cell=(Get-HwpxPackageInspection -LiteralPath $first).Data.Tables[0].cells[0]
        Assert-TfBlocked $first $output @(@{type='insert-cell-table';address=$cell.address;expectedText=$cell.text;placement='append';table=@{rows=1;columns=1;widthMm=20;rowHeightsMm=@(180);cells=@()}})
    }
    It 'preserves a valid hanging indent instead of treating it as an unsigned value' {
        $paragraph=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Paragraphs | Where-Object {$_.address.path.Count -eq 1})[-1]
        $hash=(Get-FileHash -LiteralPath $source).Hash
        $result=Invoke-TfEdit $source $output @(@{type='set-paragraph-format';address=$paragraph.address;paragraphStyle=@{leftMarginMm=20;indentMm=-5}})
        ($result.Errors -join ';') | Should Be ''
        Test-Path -LiteralPath $output | Should Be $true
        (Get-FileHash -LiteralPath $source).Hash | Should Be $hash
    }
}
