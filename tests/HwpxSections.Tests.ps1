Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force

Describe 'HWPX V2 구역별 용지 설정' {
    It '세로 가로 세로를 세 구역으로 작성하고 표 폭을 구역별로 계산한다' {
        $p = '{"version":"2.0","document":{"page":{"paperSize":"A4","margins":{"leftMm":20,"rightMm":20}}},"sections":[{"content":[{"type":"paragraph","text":"첫 세로"}]},{"document":{"page":{"orientation":"LANDSCAPE"}},"content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"text":"가로 표"}]}]},{"document":{"page":{"paperSize":"A5","orientation":"PORTRAIT"}},"content":[{"type":"paragraph","text":"마지막 세로"}]}]}' | ConvertFrom-Json
        $before = $p | ConvertTo-Json -Depth 30 -Compress
        $out = Join-Path $TestDrive 'sections.hwpx'
        $r = Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be 'PASS_WITH_WARNINGS'
        @($r.After.Sections).Count | Should Be 3
        ($r.After.Sections.PageDefinitions.Orientation -join ',') | Should Be 'PORTRAIT,LANDSCAPE,PORTRAIT'
        [Math]::Round($r.After.Sections[2].PageDefinitions[0].Width.Millimeter) | Should Be 148
        $archive = [IO.Compression.ZipFile]::OpenRead($out)
        try {
            $reader = [IO.StreamReader]::new($archive.GetEntry('Contents/section1.xml').Open())
            try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
            [Math]::Round([int]$xml.SelectSingleNode("//*[local-name()='tbl']/*[local-name()='sz']").GetAttribute('width') / 283.4645669) | Should Be 257
            $reader = [IO.StreamReader]::new($archive.GetEntry('Contents/content.hpf').Open())
            try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
            @($manifest.SelectNodes("//*[local-name()='spine']/*[starts-with(@idref,'section')]")).Count | Should Be 3
        } finally { $archive.Dispose() }
        ($p | ConvertTo-Json -Depth 30 -Compress) | Should Be $before
    }
    It '기준 치수와 가로 방향을 분리한 사용자 용지를 지원한다' {
        $p = '{"version":"2.0","document":{"page":{"paperWidthMm":120,"paperHeightMm":200,"orientation":"LANDSCAPE"}},"content":[{"type":"paragraph","text":"사용자 용지"}]}' | ConvertFrom-Json
        $r = Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath (Join-Path $TestDrive 'custom.hwpx')
        $r.Status | Should Be 'PASS_WITH_WARNINGS'
        [Math]::Round($r.After.Sections[0].PageDefinitions[0].Width.Millimeter) | Should Be 200
    }
    It 'content와 sections를 동시에 지정하면 파일을 만들지 않는다' {
        $p = '{"version":"2.0","content":[{"type":"paragraph","text":"A"}],"sections":[{"content":[{"type":"paragraph","text":"B"}]}]}' | ConvertFrom-Json
        $out = Join-Path $TestDrive 'invalid.hwpx'
        (Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out).Status | Should Be 'BLOCKED'
        Test-Path -LiteralPath $out | Should Be $false
    }
}
