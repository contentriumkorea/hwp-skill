Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
function Read-InheritanceXml($Path,$Name) {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {$r=[IO.StreamReader]::new($zip.GetEntry($Name).Open());try {[xml]$r.ReadToEnd()}finally{$r.Dispose()}}finally{$zip.Dispose()}
}
Describe 'Style inheritance across sections and cells' {
    It 'reuses identical document style resources across sections and applies named cell styles' {
        $p='{"version":"2.0","document":{"styles":[{"name":"Shared","textStyle":{"bold":true,"fontSizePt":22}}]},"sections":[{"content":[{"type":"paragraph","styleName":"Shared","text":"first"}]},{"content":[{"type":"paragraph","styleName":"Shared","text":"second"},{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"paragraphs":[{"type":"paragraph","styleName":"Shared","text":"cell"}]}]}]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'styles.hwpx';$result=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $result.Status | Should Be PASS_WITH_WARNINGS
        $h=Read-InheritanceXml $out 'Contents/header.xml';$s=Read-InheritanceXml $out 'Contents/section1.xml'
        $named=@($h.SelectNodes("//*[local-name()='style' and @name='Shared']"))
        $named.Count | Should Be 1
        $cell=$s.SelectSingleNode("//*[local-name()='tc']/*[local-name()='subList']/*[local-name()='p']")
        $cell.GetAttribute('styleIDRef') | Should Be $named[0].GetAttribute('id')
        $id=$cell.FirstChild.GetAttribute('charPrIDRef')
        $h.SelectSingleNode("//*[local-name()='charPr' and @id='$id']").GetAttribute('height') | Should Be '2200'
    }
    It 'merges side overrides and lets percent spacing replace inherited fixed spacing' {
        $p='{"version":"2.0","document":{"paragraphStyle":{"lineSpacing":{"type":"FIXED","valuePt":20}},"tableStyle":{"borders":{"left":{"type":"DOUBLE","color":"#FF0000"},"right":{"color":"#0000FF"}}}},"content":[{"type":"paragraph","text":"percent","paragraphStyle":{"lineSpacingPercent":180}},{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"text":"border","style":{"borders":{"left":{"widthMm":0.5}}}}]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'inherit.hwpx';$result=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $result.Status | Should Be PASS_WITH_WARNINGS
        $h=Read-InheritanceXml $out 'Contents/header.xml';$s=Read-InheritanceXml $out 'Contents/section0.xml'
        $paragraphId=$s.SelectSingleNode("/*/*[local-name()='p'][2]").GetAttribute('paraPrIDRef')
        $h.SelectSingleNode("//*[local-name()='paraPr' and @id='$paragraphId']//*[local-name()='lineSpacing']").GetAttribute('type') | Should Be 'PERCENT'
        $id=$s.SelectSingleNode("//*[local-name()='tc']").GetAttribute('borderFillIDRef')
        $h.SelectSingleNode("//*[local-name()='borderFill' and @id='$id']/*[local-name()='leftBorder']").GetAttribute('color') | Should Be '#FF0000'
        $h.SelectSingleNode("//*[local-name()='borderFill' and @id='$id']/*[local-name()='rightBorder']").GetAttribute('color') | Should Be '#0000FF'
    }
}
