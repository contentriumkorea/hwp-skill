Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Describe 'Embedded image layout and basic vector objects' {
    It 'keeps legacy landscape image bounds when paper dimensions are omitted' {
        $image=(Resolve-Path (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
        $p=[pscustomobject]@{version='1.0';document=[pscustomobject]@{page=[pscustomobject]@{orientation='LANDSCAPE'}};content=@([pscustomobject]@{type='image';path=$image;widthMm=250;heightMm=30})}
        (Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath (Join-Path $TestDrive 'legacy-landscape.hwpx')).Status | Should Be PASS_WITH_WARNINGS
    }
    It 'rejects truncated image payloads even when both display dimensions are supplied' {
        $assets=@(
            @{name='truncated.png';bytes=[byte[]]@(137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1)},
            @{name='truncated.tif';bytes=[byte[]]@(73,73,42,0)}
        )
        foreach($asset in $assets){
            $path=Join-Path $TestDrive $asset.name;[IO.File]::WriteAllBytes($path,$asset.bytes)
            $p=[pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='image';path=$path;widthMm=10;heightMm=10})}
            $out=Join-Path $TestDrive ($asset.name+'.hwpx')
            (Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out).Status | Should Be BLOCKED
            (Test-Path -LiteralPath $out) | Should Be $false
        }
    }
    It 'embeds exact image bytes with aspect, position, clipping, rotation and alt text' {
        $img=(Resolve-Path (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
        $p=[pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='image';path=$img;widthMm=60;rotation=90;flipHorizontal=$true;altText='blue & safe';crop=[pscustomobject]@{left=0.1;right=0.1;top=0;bottom=0};placement=[pscustomobject]@{treatAsChar=$false;horizontalAlignment='RIGHT';horizontalOffsetMm=5;textWrap='SQUARE'}})}
        $out=Join-Path $TestDrive 'picture.hwpx';$r=Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath $out
        $r.Status | Should Be PASS_WITH_WARNINGS
        $zip=[IO.Compression.ZipFile]::OpenRead($out)
        try {
            $reader=[IO.StreamReader]::new($zip.GetEntry('Contents/section0.xml').Open());try {[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $pic=$xml.SelectSingleNode("//*[local-name()='pic']")
            $pic.SelectSingleNode("*[local-name()='pos']").GetAttribute('treatAsChar') | Should Be '0'
            $pic.SelectSingleNode("*[local-name()='rotationInfo']").GetAttribute('angle') | Should Be '90'
            $pic.SelectSingleNode("*[local-name()='shapeComment']").InnerText | Should Be 'blue & safe'
            $pic.SelectSingleNode("*[local-name()='imgClip']").GetAttribute('left') | Should Not Be '0'
            $data=$zip.GetEntry('BinData/image1.PNG').Open();$ms=[IO.MemoryStream]::new();try {$data.CopyTo($ms);[Convert]::ToBase64String($ms.ToArray()) | Should Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($img)))}finally{$data.Dispose();$ms.Dispose()}
        }finally{$zip.Dispose()}
    }
    It 'creates rectangle ellipse line and editable textbox objects' {
        $blocks=@('rectangle','ellipse','line','text-box'|ForEach-Object {[pscustomobject]@{type='shape';shape=$_;widthMm=40;heightMm=20;text='shape'}})
        $r=Invoke-HwpGenerate -NewDocument -Plan ([pscustomobject]@{version='2.0';content=$blocks}) -OutputPath (Join-Path $TestDrive 'shapes.hwpx')
        $r.Status | Should Be PASS_WITH_WARNINGS
        @($r.After.Controls|Where-Object {$_.CtrlId -eq 'rect'}).Count | Should Be 2
        @($r.After.Controls|Where-Object {$_.CtrlId -eq 'ellipse'}).Count | Should Be 1
        @($r.After.Controls|Where-Object {$_.CtrlId -eq 'line'}).Count | Should Be 1
    }
    It 'rejects fully cropped image and missing assets before creating a file' {
        $p='{"version":"2.0","content":[{"type":"image","path":"missing.png","crop":{"left":0.6,"right":0.5}}]}'|ConvertFrom-Json
        (Invoke-HwpGenerate -NewDocument -Plan $p -OutputPath (Join-Path $TestDrive 'bad.hwpx')).Status | Should Be BLOCKED
        Test-Path (Join-Path $TestDrive 'bad.hwpx') | Should Be $false
    }
}
