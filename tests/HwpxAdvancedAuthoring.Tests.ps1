Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
function Read-AuthoringXml($Path,$Name='Contents/section0.xml') {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {$r=[IO.StreamReader]::new($zip.GetEntry($Name).Open()); try {[xml]$r.ReadToEnd()} finally {$r.Dispose()}} finally {$zip.Dispose()}
}
Describe 'V2 requested layout properties survive package creation' {
    It 'applies columns, gutter, border and column breaks' {
        $p='{"version":"2.0","document":{"page":{"paperSize":"A4","gutterType":"TOP_ONLY","margins":{"gutterMm":5},"border":{"borderColor":"#FF0000","borderType":"DOUBLE"}},"columns":{"count":2,"gapMm":10}},"content":[{"type":"table","rows":1,"columns":1,"cells":[]},{"type":"column-break"},{"type":"paragraph","text":"second"}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'columns.hwpx'
        $result=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $result.Status | Should Be PASS_WITH_WARNINGS
        $xml=Read-AuthoringXml $out
        $xml.SelectSingleNode("//*[local-name()='colPr']").GetAttribute('colCount') | Should Be '2'
        $xml.SelectSingleNode("//*[local-name()='pagePr']").GetAttribute('gutterType') | Should Be TOP_ONLY
        [Math]::Round([int]$xml.SelectSingleNode("//*[local-name()='tbl']/*[local-name()='sz']").GetAttribute('width')/283.4645669) | Should Be 85
        @($xml.SelectNodes("//*[local-name()='p' and @columnBreak='1']")).Count | Should Be 1
        $borderId=$xml.SelectSingleNode("//*[local-name()='pageBorderFill']").GetAttribute('borderFillIDRef')
        $h=Read-AuthoringXml $out 'Contents/header.xml'
        $h.SelectSingleNode("//*[local-name()='borderFill' and @id='$borderId']/*[local-name()='leftBorder']").GetAttribute('color') | Should Be '#FF0000'
    }
    It 'rejects exhausted columns before output' {
        $p='{"version":"2.0","document":{"columns":{"count":3,"gapMm":100}},"content":[{"type":"paragraph","text":"bad"}]}'|ConvertFrom-Json
        (Test-HwpNewDocumentPlan $p).Status | Should Be BLOCKED
    }
    It 'preserves styled runs and merged table geometry' {
        $p='{"version":"2.0","document":{"textStyle":{"bold":true}},"content":[{"type":"paragraph","runs":[{"text":"bold"},{"text":"normal","textStyle":{"bold":false,"underline":"BOTTOM","strikeout":true,"letterSpacingPercent":5}}],"paragraphStyle":{"keepWithNext":true,"keepLines":true,"pageBreakBefore":true}},{"type":"table","rows":2,"columns":2,"widthMm":100,"columnWidthsMm":[30,70],"repeatHeader":true,"cells":[{"row":1,"column":1,"colSpan":2,"text":"merged","verticalAlignment":"TOP","style":{"fillColor":"#EEF2FF"}},{"row":2,"column":1,"text":"L"},{"row":2,"column":2,"text":"R"}]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'rich.hwpx'; $r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $xml=Read-AuthoringXml $out
        @($xml.SelectNodes("//*[local-name()='tc']")).Count | Should Be 3
        $xml.SelectSingleNode("//*[local-name()='cellSpan' and @colSpan='2']") | Should Not BeNullOrEmpty
        $xml.SelectSingleNode("//*[local-name()='tbl']").GetAttribute('repeatHeader') | Should Be '1'
        $runs=@($xml.SelectNodes("/*/*[local-name()='p'][2]/*[local-name()='run']"))
        $runs.Count | Should Be 2
        $h=Read-AuthoringXml $out 'Contents/header.xml'
        $id=$runs[1].GetAttribute('charPrIDRef')
        $h.SelectSingleNode("//*[local-name()='charPr' and @id='$id']/*[local-name()='bold']") | Should BeNullOrEmpty
        $h.SelectSingleNode("//*[local-name()='charPr' and @id='$id']/*[local-name()='underline']").GetAttribute('type') | Should Be BOTTOM
        @($r.After.Tables[0].Grid).Count | Should Be 2
    }
    It 'blocks overlapping merged cells' {
        $p='{"version":"2.0","content":[{"type":"table","rows":1,"columns":2,"cells":[{"row":1,"column":1,"colSpan":2,"text":"A"},{"row":1,"column":2,"text":"B"}]}]}'|ConvertFrom-Json
        (Test-HwpNewDocumentPlan $p).Status | Should Be BLOCKED
    }
    It 'writes fixed spacing tab resources list headings and multiple cell paragraphs' {
        $p='{"version":"2.0","content":[{"type":"paragraph","text":"item\tvalue","paragraphStyle":{"lineSpacing":{"type":"FIXED","valuePt":14},"tabs":[{"positionMm":40,"alignment":"RIGHT","leader":"DOT"}],"list":{"type":"NUMBER","level":1,"start":3}}},{"type":"paragraph","text":"bullet","paragraphStyle":{"list":{"type":"BULLET","character":"●"}}},{"type":"table","rows":1,"columns":1,"caption":"summary","cells":[{"row":1,"column":1,"paragraphs":[{"type":"paragraph","text":"first"},{"type":"paragraph","runs":[{"text":"second","textStyle":{"italic":true}}]}]}]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'paragraphs.hwpx';$r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $xml=Read-AuthoringXml $out;$head=Read-AuthoringXml $out 'Contents/header.xml'
        $head.SelectSingleNode("//*[local-name()='lineSpacing' and @type='FIXED' and @value='1400']") | Should Not BeNullOrEmpty
        $head.SelectSingleNode("//*[local-name()='tabItem' and @type='RIGHT' and @leader='DOT']") | Should Not BeNullOrEmpty
        $head.SelectSingleNode("//*[local-name()='heading' and @type='BULLET']") | Should Not BeNullOrEmpty
        @($xml.SelectNodes("//*[local-name()='tc']/*[local-name()='subList']/*[local-name()='p']")).Count | Should Be 2
        $xml.SelectSingleNode("//*[local-name()='caption']") | Should Not BeNullOrEmpty
        @($xml.SelectNodes("//*[local-name()='linesegarray']")).Count | Should Be 0
    }
    It 'keeps named styles and side-specific borders as real resources' {
        $p='{"version":"2.0","document":{"styles":[{"name":"Brand Heading","textStyle":{"fontSizePt":22,"bold":true},"paragraphStyle":{"alignment":"CENTER"}}]},"content":[{"type":"paragraph","styleName":"Brand Heading","text":"styled"},{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"text":"border","style":{"borders":{"left":{"type":"DOUBLE","color":"#123456","widthMm":0.3}},"cellMargins":{"leftMm":4,"rightMm":2,"topMm":1,"bottomMm":3}}}]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'named.hwpx';$r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $xml=Read-AuthoringXml $out;$head=Read-AuthoringXml $out 'Contents/header.xml'
        $named=$head.SelectSingleNode("//*[local-name()='style' and @name='Brand Heading']")
        $named | Should Not BeNullOrEmpty
        $xml.SelectSingleNode("/*/*[local-name()='p'][2]").GetAttribute('styleIDRef') | Should Be $named.GetAttribute('id')
        $tc=$xml.SelectSingleNode("//*[local-name()='tc']");$id=$tc.GetAttribute('borderFillIDRef')
        $head.SelectSingleNode("//*[local-name()='borderFill' and @id='$id']/*[local-name()='leftBorder']").GetAttribute('color') | Should Be '#123456'
        [Math]::Round([int]$tc.SelectSingleNode("*[local-name()='cellMargin']").GetAttribute('left')/283.4645669) | Should Be 4
    }
}
