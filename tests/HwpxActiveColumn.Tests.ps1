Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Describe 'Explicit column flow uses the current column' {
    It 'uses wide first then narrow second column and resets on page break' {
        $p='{"version":"2.0","document":{"columns":{"count":2,"gapMm":10,"widthsMm":[110,60]}},"content":[{"type":"table","rows":1,"columns":1,"widthMm":100,"cells":[]},{"type":"column-break"},{"type":"table","rows":1,"columns":1,"cells":[]},{"type":"page-break"},{"type":"table","rows":1,"columns":1,"cells":[]}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'columns.hwpx';$r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $z=[IO.Compression.ZipFile]::OpenRead($out)
        try{$reader=[IO.StreamReader]::new($z.GetEntry('Contents/section0.xml').Open());try{[xml]$x=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$z.Dispose()}
        $sizes=@($x.SelectNodes("//*[local-name()='tbl']/*[local-name()='sz']"))
        ([int]$sizes[0].GetAttribute('width')) | Should Be ([int][Math]::Round(100*283.4645669))
        ([int]$sizes[1].GetAttribute('width')) | Should Be ([int][Math]::Round(60*283.4645669))
        ([int]$sizes[2].GetAttribute('width')) | Should Be ([int][Math]::Round(110*283.4645669))
    }
}
