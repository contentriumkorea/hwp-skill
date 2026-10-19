Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-MiPart($Path,$Name='Contents/section0.xml') {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{$stream=$zip.GetEntry($Name).Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);return ,$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}}finally{$zip.Dispose()}
}
function Invoke-Mi($Source,$Output,$Operations) {Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=@($Operations)}}
function Write-MiSection($Path,[xml]$Xml) {
    $zip=[IO.Compression.ZipFile]::Open($Path,'Update')
    try{$zip.GetEntry('Contents/section0.xml').Delete();$stream=$zip.CreateEntry('Contents/section0.xml').Open();$bytes=[Text.Encoding]::UTF8.GetBytes($Xml.OuterXml);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
}

Describe 'Public file pipeline for model-based no-window edits' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'output.hwpx'
        $image=(Resolve-Path (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
        $plan=[pscustomobject]@{version='2.0';content=@(
            [pscustomobject]@{type='paragraph';runs=@([pscustomobject]@{text='before AB';textStyle=[pscustomobject]@{bold=$true}},[pscustomobject]@{text='CD after';textStyle=[pscustomobject]@{italic=$true}})},
            [pscustomobject]@{type='shape';shape='rectangle';widthMm=25.4;heightMm=12.7},
            [pscustomobject]@{type='image';path=$image;widthMm=25.4;heightMm=12.7}
        )}
        $generated=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $source
        ($generated.Errors -join '; ')|Should Be ''
        $data=(Get-HwpxPackageInspection -LiteralPath $source).Data
        $p=@($data.Paragraphs|Where-Object text -eq 'before ABCD after')[0]
        $shape=@($data.Controls|Where-Object ctrlId -eq 'rect')[0]
        $pic=@($data.Controls|Where-Object ctrlId -eq 'pic')[0]
        $sha=(Get-FileHash $source).Hash
    }
    It 'combines section settings object placement and cross-run text without losing assets' {
        $r=Invoke-Mi $source $output @(
            @{type='set-section-settings';sectionIndex=0;settings=@{startNumbers=@{page=7};visibility=@{hideFirstPageNum=$true};pageNumber=@{position='BOTTOM_CENTER';format='DIGIT';sideChar='-'}}},
            @{type='replace-paragraph-text';address=$p.address;expectedText='before ABCD after';find='ABCD';replacement='X'},
            @{type='set-object-format';address=$shape.address;placement=@{horizontalOffsetMm=12.7};altText='retained shape'}
        )
        ($r.Errors -join '; ')|Should Be ''
        $r.Status|Should Be PASS_WITH_WARNINGS
        [xml]$xml=[Text.Encoding]::UTF8.GetString((Read-MiPart $output))
        $node=$xml.SelectSingleNode('//*[local-name()="p" and contains(string(.),"before X after")]')
        $node.InnerText|Should BeExactly 'before X after'
        $node.SelectNodes('*[local-name()="run"]').Count|Should Be 2
        $xml.SelectSingleNode('//*[local-name()="startNum"]').GetAttribute('page')|Should Be '7'
        $xml.SelectSingleNode('//*[local-name()="pageNum"]').GetAttribute('pos')|Should Be 'BOTTOM_CENTER'
        $xml.SelectSingleNode('//*[local-name()="rect"]/*[local-name()="pos"]').GetAttribute('horzOffset')|Should Be '3600'
        [Convert]::ToBase64String((Read-MiPart $source 'BinData/image1.PNG'))|Should Be ([Convert]::ToBase64String((Read-MiPart $output 'BinData/image1.PNG')))
        (Get-FileHash $source).Hash|Should Be $sha
        @((Get-HwpxPackageInspection -LiteralPath $output).Data.Controls|Where-Object ctrlId -eq 'pic').Count|Should Be 1
    }
    It 'modifies generated picture crop and geometry through an inspected pic address' {
        $r=Invoke-Mi $source $output @(@{type='set-object-format';address=$pic.address;widthMm=50.8;crop=@{left=0.25};rotation=90;flipVertical=$true})
        ($r.Errors -join '; ')|Should Be ''
        [xml]$xml=[Text.Encoding]::UTF8.GetString((Read-MiPart $output))
        $node=$xml.SelectSingleNode('//*[local-name()="pic"]')
        $node.SelectSingleNode('*[local-name()="sz"]').GetAttribute('width')|Should Be '14400'
        $node.SelectSingleNode('*[local-name()="imgClip"]').GetAttribute('left')|Should Be '3600'
        $node.SelectSingleNode('*[local-name()="rotationInfo"]').GetAttribute('angle')|Should Be '90'
        (Get-FileHash $source).Hash|Should Be $sha
    }
    It 'atomically rejects stale addresses wrong guards overlapping writes and invalid object kinds' {
        foreach($operations in @(
            ,@(@{type='replace-paragraph-text';address=$p.address;expectedText='wrong';find='ABCD';replacement='X'}),
            ,@(@{type='set-object-format';address=$p.address;altText='wrong kind'}),
            ,@(@{type='replace-paragraph-text';address=$p.address;expectedText='before ABCD after';find='ABCD';replacement='X'},@{type='set-paragraph-breaks';address=$p.address;pageBreak=$true})
        )){
            $r=Invoke-Mi $source $output $operations
            $r.Status|Should Be BLOCKED
            Test-Path $output|Should Be $false
            (Get-FileHash $source).Hash|Should Be $sha
        }
    }
    It 'invalidates other paragraphs saved line caches when a floating picture changes wrapping' {
        [xml]$xml=[Text.Encoding]::UTF8.GetString((Read-MiPart $source))
        foreach($paragraph in $xml.SelectNodes('//*[local-name()="p"]')){
            $cache=$xml.CreateElement('hp','linesegarray','http://www.hancom.co.kr/hwpml/2011/paragraph')
            $line=$xml.CreateElement('hp','lineseg','http://www.hancom.co.kr/hwpml/2011/paragraph');$line.SetAttribute('textpos','0');$null=$cache.AppendChild($line);$null=$paragraph.AppendChild($cache)
        }
        Write-MiSection $source $xml
        $address=@((Get-HwpxPackageInspection -LiteralPath $source).Data.Controls|Where-Object ctrlId -eq 'pic')[0].address
        $r=Invoke-Mi $source $output @(@{type='set-object-format';address=$address;placement=@{treatAsChar=$false;textWrap='SQUARE';horizontalOffsetMm=5}})
        ($r.Errors -join '; ')|Should Be ''
        [xml]$after=[Text.Encoding]::UTF8.GetString((Read-MiPart $output))
        $after.SelectNodes('//*[local-name()="linesegarray"]').Count|Should Be 0
    }
    It 'crops an ordinary 40mm odd-width picture using its existing floor center convention' {
        $odd=Join-Path $dir 'odd.hwpx'
        $r=Invoke-HwpGenerate -NewDocument -Plan ([pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='image';path=$image;widthMm=40;heightMm=30})}) -OutputPath $odd
        ($r.Errors -join '; ')|Should Be ''
        $address=@((Get-HwpxPackageInspection -LiteralPath $odd).Data.Controls|Where-Object ctrlId -eq 'pic')[0].address
        $r=Invoke-Mi $odd $output @(@{type='set-object-format';address=$address;crop=@{left=0.1};flipHorizontal=$true})
        ($r.Errors -join '; ')|Should Be ''
        [xml]$after=[Text.Encoding]::UTF8.GetString((Read-MiPart $output))
        $after.SelectSingleNode('//*[local-name()="pic"]/*[local-name()="rotationInfo"]').GetAttribute('centerX')|Should Be '5669'
    }
    It 'retains the picture floor center convention across resize then reinspection and editing' {
        $resized=Join-Path $dir 'resized.hwpx'
        $r=Invoke-Mi $source $resized @(@{type='set-object-format';address=$pic.address;widthMm=40})
        ($r.Errors -join '; ')|Should Be ''
        [xml]$after=[Text.Encoding]::UTF8.GetString((Read-MiPart $resized))
        $after.SelectSingleNode('//*[local-name()="pic"]/*[local-name()="rotationInfo"]').GetAttribute('centerX')|Should Be '5669'
        $address=@((Get-HwpxPackageInspection -LiteralPath $resized).Data.Controls|Where-Object ctrlId -eq 'pic')[0].address
        $r=Invoke-Mi $resized $output @(@{type='set-object-format';address=$address;crop=@{right=0.1}})
        ($r.Errors -join '; ')|Should Be ''
    }
}
