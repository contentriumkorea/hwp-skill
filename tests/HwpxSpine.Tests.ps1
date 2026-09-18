Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Set-SpineTestManifest($Path,[switch]$Rename,[switch]$Invalid) {
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try {
        $entry=$zip.GetEntry('Contents/content.hpf'); $reader=[IO.StreamReader]::new($entry.Open())
        try{$xml=[xml]$reader.ReadToEnd()}finally{$reader.Dispose()}
        $spine=$xml.SelectSingleNode('//*[local-name()="spine"]')
        $refs=@($spine.ChildNodes | Where-Object {$_.GetAttribute('idref') -like 'section*'})
        $null=$spine.InsertBefore($refs[1],$refs[0])
        if($Invalid){$refs[1].SetAttribute('idref','missing')}
        if($Rename){
            $part=$zip.GetEntry('Contents/section1.xml'); $memory=[IO.MemoryStream]::new(); $stream=$part.Open()
            try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
            $part.Delete();$stream=$zip.CreateEntry('Contents/chapter-b.xml').Open()
            try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
            $xml.SelectSingleNode('//*[@id="section1"]').SetAttribute('href','Contents/chapter-b.xml')
        }
        $entry.Delete();$writer=[IO.StreamWriter]::new($zip.CreateEntry('Contents/content.hpf').Open(),[Text.UTF8Encoding]::new($false))
        try{$writer.Write($xml.OuterXml)}finally{$writer.Dispose()}
    }finally{$zip.Dispose()}
}

Describe 'HWPX logical reading order follows manifest spine' {
    BeforeEach {
        $script:spineSource=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.hwpx')
        $plan='{"version":"2.0","sections":[{"content":[{"type":"paragraph","text":"FIRST"}]},{"content":[{"type":"paragraph","text":"SECOND"}]}]}'|ConvertFrom-Json
        (Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $spineSource).Status | Should Be 'PASS_WITH_WARNINGS'
    }
    It 'reads section1 before section0 when the spine explicitly says so' {
        Set-SpineTestManifest $spineSource
        $r=Get-HwpInspection $spineSource
        $r.Status | Should Be 'PASS_WITH_WARNINGS'
        ($r.Sections.name -join '|') | Should Be 'Contents/section1.xml|Contents/section0.xml'
        ($r.Text.IndexOf('SECOND') -lt $r.Text.IndexOf('FIRST')) | Should Be $true
    }
    It 'reads nonstandard section filenames referenced by the spine' {
        Set-SpineTestManifest $spineSource -Rename
        $r=Get-HwpInspection $spineSource
        $r.Status | Should Be 'PASS_WITH_WARNINGS'
        ($r.Sections.name -join '|') | Should Be 'Contents/chapter-b.xml|Contents/section0.xml'
        $r.Text | Should Match 'SECOND'
    }
    It 'blocks a broken spine rather than guessing filename order' {
        Set-SpineTestManifest $spineSource -Invalid
        $r=Get-HwpInspection $spineSource
        $r.Status | Should Be 'BLOCKED'
        ($r.Errors -join '; ') | Should Match 'spine'
    }
}
