Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Describe 'Do not silently accept unwritten authoring options' {
    It 'validates raw plans at the direct writer entry point too' {
        Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpx.psm1') -Force
        $p='{"version":"2.0","content":[{"type":"paragraph","text":"x","unsupported":true}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'direct-bad.hwpx'
        (Invoke-HwpxGenerateDocument -Plan $p -OutputPath $out).Status | Should Be BLOCKED
        Test-Path -LiteralPath $out | Should Be $false
    }
    It 'rejects unsupported border widths and ignored shape/page/list settings' {
        foreach ($json in @(
            '{"version":"2.0","document":{"tableStyle":{"borderWidthMm":0.11}},"content":[{"type":"paragraph","text":"x"}]}',
            '{"version":"2.0","document":{"page":{"border":{"cellPaddingMm":3}}},"content":[{"type":"paragraph","text":"x"}]}',
            '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":40,"heightMm":20,"style":{"borders":{"left":{"color":"#FF0000"}}}}]}',
            '{"version":"2.0","content":[{"type":"paragraph","text":"x","paragraphStyle":{"list":{"type":"BULLET","start":5}}}]}',
            '{"version":"2.0","content":[{"type":"paragraph","text":"x","paragraphStyle":{"list":{"type":"NUMBER","character":"X"}}}]}')) {
            (Test-HwpNewDocumentPlan ($json|ConvertFrom-Json)).Status | Should Be BLOCKED
        }
    }
    It 'serializes whole millimeter border enums and omits stale preview images' {
        $p='{"version":"2.0","document":{"page":{"border":{"borderWidthMm":1}}},"content":[{"type":"paragraph","text":"border"}]}'|ConvertFrom-Json
        $out=Join-Path $TestDrive 'width.hwpx'
        (Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out).Status | Should Be PASS_WITH_WARNINGS
        $z=[IO.Compression.ZipFile]::OpenRead($out)
        try {
            $z.GetEntry('Preview/PrvImage.png') | Should BeNullOrEmpty
            $r=[IO.StreamReader]::new($z.GetEntry('Contents/header.xml').Open())
            try {[xml]$h=$r.ReadToEnd()}finally{$r.Dispose()}
            $h.SelectSingleNode("//*[local-name()='leftBorder' and @width='1.0 mm']") | Should Not BeNullOrEmpty
        }finally{$z.Dispose()}
    }
    It 'rejects image-derived inline overflow before output' {
        $image=(Resolve-Path (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
        $p=[pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='image';path=$image;heightMm=500})}
        $out=Join-Path $TestDrive 'oversize.hwpx'
        (Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out).Status | Should Be BLOCKED
        Test-Path -LiteralPath $out | Should Be $false
    }
}
