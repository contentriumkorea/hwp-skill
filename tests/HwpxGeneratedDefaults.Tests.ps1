Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Describe 'Generated defaults preserve document-wide meaning' {
    It 'inherits margins in omitted cells and sequences captions and notes across sections' {
        $p='{"version":"2.0","sections":[{"content":[{"type":"table","rows":1,"columns":2,"caption":"first","style":{"cellMargins":{"leftMm":5}},"cells":[{"row":1,"column":1,"text":"A"}]},{"type":"footnote","text":"first note"}]},{"content":[{"type":"table","rows":1,"columns":1,"caption":"second","cells":[]},{"type":"footnote","text":"second note"}]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'defaults.hwpx';$r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $z=[IO.Compression.ZipFile]::OpenRead($out)
        try{
            $reader=[IO.StreamReader]::new($z.GetEntry('Contents/section0.xml').Open());try{[xml]$a=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $reader=[IO.StreamReader]::new($z.GetEntry('Contents/section1.xml').Open());try{[xml]$b=$reader.ReadToEnd()}finally{$reader.Dispose()}
        }finally{$z.Dispose()}
        foreach($margin in $a.SelectNodes("//*[local-name()='tc']/*[local-name()='cellMargin']")){
            $margin.GetAttribute('left') | Should Be '1417'
        }
        $b.SelectSingleNode("//*[local-name()='autoNum' and @numType='TABLE']").GetAttribute('num') | Should Be '2'
        $b.SelectSingleNode("//*[local-name()='autoNum' and @numType='FOOTNOTE']").GetAttribute('num') | Should Be '2'
    }
}
