$script:convertModule=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInputConvert.psm1'
if(Test-Path -LiteralPath $script:convertModule){Import-Module $script:convertModule -Force}
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPortable.psm1')
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1')
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpDocumentModel.psm1')
. (Join-Path $PSScriptRoot 'fixtures/New-ConversionFixture.ps1')

function New-InputConversionFixture([string]$Path,[switch]$Protected) {
    $source=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
    $session=[Contentrium.HwpSkill.CompoundFileReader]::Open($source)
    try {
        $header=$session.ReadStream('','FileHeader',1048576)
        $compressed=([BitConverter]::ToUInt32($header,36) -band 1) -ne 0
        $doc=$session.ReadStream('','DocInfo',1048576)
        $body=$session.ReadStream('BodyText','Section0',1048576)
        if($compressed){$doc=[Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($doc,1048576);$body=[Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($body,1048576)}
        # Remove the complete field-bearing paragraph subtree, not its visible text alone.
        $records=@(Get-HwpPortableRecords $body)
        $paragraphs=@($records|Where-Object {$_.tagId -eq 0x42 -and $_.level -eq 0})
        $first=$paragraphs[4].offset;$last=$paragraphs[5].offset
        $stream=[IO.MemoryStream]::new()
        try{$stream.Write($body,0,$first);$stream.Write($body,$last,$body.Length-$last);$cleanBody=$stream.ToArray()}finally{$stream.Dispose()}
        [Array]::Copy([BitConverter]::GetBytes([uint32]$(if($Protected){2}else{0})),0,$header,36,4)
        Write-ConversionCompoundFile -Path $Path -RootStreams @{FileHeader=$header;DocInfo=$doc} -BodyStreams @{Section0=$cleanBody}
    }finally{$session.Dispose()}
}

Describe 'Bundled offline HWP input conversion' {
    BeforeEach {
        $source=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $case=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $case
        $output=Join-Path $case 'converted.hwpx'
        $before=(Get-FileHash -LiteralPath $source).Hash
    }
    It 'blocks a real conversion whose field display text changes without an engine warning' {
        $r=Invoke-HwpToHwpx -LiteralPath $source -OutputPath $output
        $r.Status | Should Be BLOCKED
        ($r.Errors -join ' ') | Should Match 'paragraph.*text|문단.*텍스트'
        Test-Path -LiteralPath $output | Should Be $false
        (Get-FileHash -LiteralPath $source).Hash | Should Be $before
        @(Get-ChildItem -LiteralPath $case -Force | Where-Object Name -Like '.hwp-convert-*').Count | Should Be 0
    }
    It 'describes the bundled input converter separately from unavailable HWP final output' {
        Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCapabilities.psm1')
        $snapshot=Get-HwpCapabilitySnapshot
        $snapshot.inputConversion.bundled | Should Be $true
        $snapshot.inputConversion.requiresCPython | Should Be '3.9+'
        $snapshot.finalConversion.available | Should Be $false
    }
    It 'does not overwrite an existing result' {
        [IO.File]::WriteAllText($output,'preserved')
        $r=Invoke-HwpToHwpx -LiteralPath $source -OutputPath $output
        $r.Status | Should Be BLOCKED
        [IO.File]::ReadAllText($output) | Should BeExactly 'preserved'
        (Get-FileHash -LiteralPath $source).Hash | Should Be $before
    }
    It 'converts a real HWP5 body and table without Hancom and produces editable HWPX' {
        $clean=Join-Path $case 'clean.hwp';New-InputConversionFixture $clean
        $before=(Get-FileHash -LiteralPath $clean).Hash
        $r=Invoke-HwpToHwpx -LiteralPath $clean -OutputPath $output
        ($r.Errors -join ';') | Should Be ''
        $r.Status | Should Be PASS_WITH_WARNINGS
        $actual=Get-HwpInspection -LiteralPath $output
        $actual.DetectedKind | Should Be 'HWPX-ZIP'
        $actual.tables[0].rowCount | Should Be 2
        $actual.tables[0].columnCount | Should Be 2
        $actual.paragraphs[0].text | Should BeExactly 'HWP 네이티브 통합 시험'
        $actual.paragraphs.Count | Should Be 13
        (Get-FileHash -LiteralPath $clean).Hash | Should Be $before
        $r.Data.NativeLayoutVerified | Should Be $false
    }
    It 'rejects protected HWP input before conversion' {
        $clean=Join-Path $case 'protected.hwp';New-InputConversionFixture $clean -Protected
        $r=Invoke-HwpToHwpx -LiteralPath $clean -OutputPath $output
        $r.Status | Should Be BLOCKED
        ($r.Errors -join ' ') | Should Match '보호|암호'
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'converts then edits through the public CLI using a fresh HWPX address' {
        $clean=Join-Path $case 'cli.hwp';New-InputConversionFixture $clean
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $shell=(Get-Process -Id $PID).Path
        $raw=& $shell -NoProfile -File $cli convert-hwpx -LiteralPath $clean -OutputPath $output
        $LASTEXITCODE | Should Be 0
        (($raw -join "`n")|ConvertFrom-Json).data.OutputPath | Should Be $output
        $inspection=Get-HwpInspection $output
        $p=@($inspection.paragraphs|Where-Object text -CEQ '기존 문구를 안전하게 변경합니다.')[0]
        $plan=@{version='2.0';operations=@(@{type='replace-run-text';address=$p.charShapeRuns[0].address;expectedText=$p.text;text='변환 후 변경한 문구입니다.'})}
        $planPath=Join-Path $case 'edit.json'
        [IO.File]::WriteAllText($planPath,($plan|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $edited=Join-Path $case 'edited.hwpx'
        $null=& $shell -NoProfile -File $cli edit-hwpx -LiteralPath $output -PlanPath $planPath -OutputPath $edited
        $LASTEXITCODE | Should Be 0
        (Get-HwpInspection $edited).text | Should Match '변환 후 변경한 문구입니다.'
        (Get-HwpInspection $clean).text | Should Match '기존 문구를 안전하게 변경합니다.'
    }
    It 'rejects extension and actual signature mismatch' {
        $mismatch=Join-Path $TestDrive 'not-hwp.hwp'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $mismatch
        $r=Invoke-HwpToHwpx -LiteralPath $mismatch -OutputPath $output
        $r.Status | Should Be BLOCKED
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'refuses output inside a linked directory' {
        $target=Join-Path $TestDrive 'target';$link=Join-Path $TestDrive 'linked'
        $null=New-Item -ItemType Directory -Path $target
        $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
        $null=New-Item -ItemType $kind -Path $link -Target $target
        $r=Invoke-HwpToHwpx -LiteralPath $source -OutputPath (Join-Path $link 'linked.hwpx')
        $r.Status | Should Be BLOCKED
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should Be 0
    }
}

Describe 'Independent HWP input style verification' {
    BeforeAll {
        $script:styleRoot=Join-Path $TestDrive 'unpromoted-style-candidate'
        $null=New-Item -ItemType Directory -Path $script:styleRoot
        $input=Join-Path $script:styleRoot 'source.hwp'
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') $input
        $script:styleCandidate=Join-Path $script:styleRoot 'candidate.hwpx'
        & python -I -S -B (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/convert_hwp.py') --input $input --output $script:styleCandidate --scratch $script:styleRoot --report (Join-Path $script:styleRoot 'report.json') | Out-Null
        if($LASTEXITCODE){throw 'Real engine style test setup failed.'}
    }
    BeforeEach {
        $s=(Get-HwpPortableInspection -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp')).Data
        $a=Get-HwpInspection -LiteralPath $script:styleCandidate
        # Isolate style comparison from the independently tested field-display defect.
        $s.Paragraphs[4].text=$a.Paragraphs[4].text
    }
    It 'rejects a changed font size in a used run' {
        $a.Resources.charShapes[0].fontSizeRaw=999
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'font'
    }
    It 'rejects changed language font names in a used run' {
        $a.Resources.charShapes[0].resolvedFontNames.Hangul='Different font'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'font'
    }
    It 'rejects changed paragraph line spacing' {
        $a.Resources.paraShapes[0].lineSpacing.value=200
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'spacing'
    }
    It 'rejects changed Korean word wrapping' {
        $s.Resources.paraShapes[0].breakNonLatinWordCode=0
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'word'
    }
    It 'rejects changed page binding' {
        $s.Sections[0].pageDefinitions[0].bindingMethodCode=2
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'binding'
    }
    It 'rejects a changed font on an empty paragraph used for spacing' {
        $empty=@($a.Paragraphs|Where-Object {$_.text.Length -eq 0})[0]
        $different=$a.Resources.charShapes[0].PSObject.Copy();$different.id=9000;$different.fontSizeRaw=999
        $a.Resources.charShapes+=@($different)
        $empty.charShapeRuns[0].charShapeId=9000
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'font'
    }
    It 'accepts the unchanged independently comparable style projection' {
        Assert-HwpInputConversionContent $s $a | Should Be $true
    }
    It 'compares paragraph Unicode code units rather than culture-equivalent text' {
        $s.Paragraphs[0].text='A'+[char]0xAD+'B';$a.Paragraphs[0].text='AB'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'text'
    }
    It 'compares cell Unicode code units rather than culture-equivalent text' {
        $s.Tables[0].cells[0].text='A'+[char]0xAD+'B';$a.Tables[0].cells[0].text='AB'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'text'
    }
    It 'compares font name signatures ordinally' {
        $s.Resources.charShapes[0].resolvedFontNames.Hangul='A'+[char]0xAD+'B'
        $a.Resources.charShapes[0].resolvedFontNames.Hangul='AB'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'font'
    }
    It 'rejects changed table cell padding' {
        $a.tables[0].cells[0].margins.left++
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'margin'
    }
    It 'rejects changed cell vertical alignment' {
        $a.tables[0].cells[0].verticalAlignment='BOTTOM'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'alignment'
    }
    It 'rejects changed table page splitting' {
        $a.tables[0].properties.pageBreak='NONE'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'splitting'
    }
    It 'rejects changed borders referenced by table cells' {
        $a.Resources.borderFills[2].borders.Left.color='#FF0000'
        {Assert-HwpInputConversionContent $s $a} | Should Throw 'border'
    }
    It 'does not promote a converted table outside the page writing area' {
        $copy=Join-Path $TestDrive 'too-wide.hwpx'
        Copy-Item -LiteralPath $script:styleCandidate -Destination $copy
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::Open($copy,[IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry=$zip.GetEntry('Contents/section0.xml');$reader=[IO.StreamReader]::new($entry.Open())
            try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $xml.SelectSingleNode('//*[local-name()="tbl"]/*[local-name()="sz"]').SetAttribute('width','100000')
            $entry.Delete();$entry=$zip.CreateEntry('Contents/section0.xml');$writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
            try{$writer.Write($xml.OuterXml)}finally{$writer.Dispose()}
        }finally{$zip.Dispose()}
        {& (Get-Module HwpInputConvert) {param($p) Assert-HwpConvertedTableBounds $p} $copy} | Should Throw 'writing area'
    }
}

Describe 'HWP raw run offsets for conversion' {
    It 'refuses source controls not covered by independent correspondence' {
        $record=[pscustomobject]@{tagId=0x47;payload=[Text.Encoding]::ASCII.GetBytes('daeh0000')}
        {& (Get-Module HwpInputConvert) {param($r) Assert-HwpInputRecordSubset @($r)} $record} | Should Throw 'correspondence'
    }
    It 'refuses multi-column source layouts rather than assuming a single column' {
        $payload=[byte[]]::new(16);[Array]::Copy([Text.Encoding]::ASCII.GetBytes('dloc'),0,$payload,0,4);$payload[4]=8
        $record=[pscustomobject]@{tagId=0x47;payload=$payload}
        {& (Get-Module HwpInputConvert) {param($r) Assert-HwpInputRecordSubset @($r)} $record} | Should Throw 'column'
    }
    It 'reads actual native cell alignment and within-cell page splitting' {
        $s=(Get-HwpPortableInspection -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp')).Data
        $s.Tables[0].properties.pageBreak | Should Be CELL
        $s.Tables[0].cells[0].verticalAlignment | Should Be CENTER
        $s.Tables[0].cells[0].listPropertiesRaw | Should Be 32
    }
    It 'reads interleaved native border records rather than grouped type and color arrays' {
        $s=(Get-HwpPortableInspection -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp')).Data
        foreach($side in @('Left','Right','Top','Bottom')){
            $s.Resources.borderFills[2].borders.$side.type | Should Be SOLID
            $s.Resources.borderFills[2].borders.$side.widthMm | Should Be 0.12
            $s.Resources.borderFills[2].borders.$side.color | Should Be '#000000'
        }
        $s.Resources.borderFills[1].borders.Left.type | Should Be NONE
    }
    It 'maps a run after an extended control to its visible UTF-16 offset' {
        $text=[Text.Encoding]::Unicode.GetBytes(([string][char]2)+([string][char]0)*7+'AB'+[char]13)
        $context=[pscustomobject]@{Index=0;Section='Section0';RecordLevel=0;Header=(ConvertFrom-HwpPortableParagraphHeaderPayload ([byte[]]::new(24)));TextDetail=(ConvertFrom-HwpPortableParagraphTextDetail $text);CharShapeRuns=@([pscustomobject]@{start=0;charShapeId=0},[pscustomobject]@{start=9;charShapeId=1});LineSegments=@()}
        $paragraph=Complete-HwpPortableParagraphModel $context
        $paragraph.charShapeRuns[1].textStart | Should Be 1
        $paragraph.charShapeRuns[1].start | Should Be 9
    }
}
