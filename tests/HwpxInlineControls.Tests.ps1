Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Describe 'OWPML inline control parent contract' {
    It 'nests line breaks and tabs inside text elements in body cell shape and caption' {
        $p='{"version":"2.0","content":[{"type":"paragraph","text":"A\tB\nC"},{"type":"table","rows":1,"columns":1,"caption":"cap\nnext","cells":[{"row":1,"column":1,"text":"X\tY\nZ"}]},{"type":"shape","shape":"text-box","widthMm":40,"heightMm":25,"text":"shape\nnext"}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'inline.hwpx';$result=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $result.Status | Should Be PASS_WITH_WARNINGS
        $z=[IO.Compression.ZipFile]::OpenRead($out)
        try {$r=[IO.StreamReader]::new($z.GetEntry('Contents/section0.xml').Open());try {[xml]$x=$r.ReadToEnd()}finally{$r.Dispose()}}finally{$z.Dispose()}
        @($x.SelectNodes("//*[local-name()='run']/*[local-name()='lineBreak' or local-name()='tab']")).Count | Should Be 0
        @($x.SelectNodes("//*[local-name()='t']/*[local-name()='lineBreak']")).Count | Should Be 4
        @($x.SelectNodes("//*[local-name()='t']/*[local-name()='tab']")).Count | Should Be 2
        ($x.OuterXml.Contains("`t")) | Should Be $false
        $result.After.Text.Contains("A`tB`nC") | Should Be $true
        $result.After.Text.Contains("X`tY`nZ") | Should Be $true
    }
}
