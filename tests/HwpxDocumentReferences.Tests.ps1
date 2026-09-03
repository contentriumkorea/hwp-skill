Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Describe 'V2 references across a complete document' {
    It 'writes real fields notes headers page numbers and linked contents without GUI' {
        $p='{"version":"2.0","document":{"header":{"text":"Header","applyPageType":"ODD"},"footer":{"text":"Footer"},"pageNumber":{"position":"BOTTOM_CENTER","start":7},"hideFirstHeader":true},"content":[{"type":"bookmark","name":"intro","text":"Intro"},{"type":"toc","entries":[{"text":"Introduction","target":"#intro"}]},{"type":"field","name":"customer","value":"contentrium"},{"type":"hyperlink","text":"Website","target":"https://example.com/?a=1&b=2"},{"type":"footnote","text":"Footnote"},{"type":"endnote","text":"Endnote"}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'references.hwpx';$r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $r.After.Fields.customer | Should Be contentrium
        @($r.After.Controls|Where-Object {$_.CtrlId -eq 'head'}).Count | Should Be 1
        @($r.After.Controls|Where-Object {$_.CtrlId -eq 'fn'}).Count | Should Be 1
        $z=[IO.Compression.ZipFile]::OpenRead($out);try {$reader=[IO.StreamReader]::new($z.GetEntry('Contents/section0.xml').Open());try {[xml]$x=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$z.Dispose()}
        $x.SelectSingleNode("//*[local-name()='startNum']").GetAttribute('page') | Should Be '7'
        $x.SelectSingleNode("//*[local-name()='visibility']").GetAttribute('hideFirstHeader') | Should Be '1'
        @($x.SelectNodes("//*[local-name()='fieldBegin']")).Count | Should Be 3
        @($x.SelectNodes("//*[local-name()='fieldEnd']")).Count | Should Be 3
    }
    It 'rejects missing internal targets and unsafe schemes before writing' {
        foreach ($target in @('#missing','file:///C:/secret','javascript:alert(1)')) {
            $p=[pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='hyperlink';text='bad';target=$target})}
            (Test-HwpNewDocumentPlan $p).Status | Should Be BLOCKED
        }
    }
}
