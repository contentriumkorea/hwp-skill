param([switch]$RunHeadlessBrowser)
$pdfModule=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPdfConvert.psm1'
if(Test-Path -LiteralPath $pdfModule){Import-Module $pdfModule -Force}
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-PdfTestSource([string]$Path){
    $plan=@{version='2.0';document=@{textStyle=@{fontFamily='Arial';fontSizePt=12}};sections=@(@{content=@(@{type='paragraph';text='PDF conversion keeps this text.'},@{type='table';rows=2;columns=2;widthMm=100;cells=@(@{row=1;column=1;text='Item'},@{row=1;column=2;text='Amount'},@{row=2;column=1;text='Video'},@{row=2;column=2;text='1200000'})})})}
    $r=Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $Path
    if($r.Status -notin @('PASS','PASS_WITH_WARNINGS')){throw ($r.Errors -join ';')}
}
Describe 'Headless HWPX PDF conversion' {
    BeforeEach {
        $case=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $case
        $source=Join-Path $case 'source.hwpx';Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') -Destination $source
        $output=Join-Path $case 'output.pdf';$hash=(Get-FileHash -LiteralPath $source).Hash
    }
    It 'renders a genuine HWPX directly to a complete PDF without Hancom' {
        $r=Export-HwpxPdf -LiteralPath $source -OutputPath $output -PdfMode stored-layout
        ($r.Errors -join ';')|Should Be ''
        $r.Status|Should Be PASS_WITH_WARNINGS
        $r.Data.Mode|Should Be stored-layout
        $r.Data.NativeLayoutVerified|Should Be $false
        $r.Data.PageCount|Should Be 1
        [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($output)).StartsWith('%PDF-')|Should Be $true
        (Get-FileHash -LiteralPath $source).Hash|Should Be $hash
        @(Get-ChildItem -LiteralPath $case -Force|Where-Object Name -Like '.hwpx-pdf-*').Count|Should Be 0
    }
    It 'refuses to overwrite an existing PDF' {
        [IO.File]::WriteAllText($output,'preserved')
        $r=Export-HwpxPdf -LiteralPath $source -OutputPath $output
        $r.Status|Should Be BLOCKED
        [IO.File]::ReadAllText($output)|Should BeExactly 'preserved'
    }
    It 'sets child-only TEMP and TMP for the headless process job' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $previewModule=Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPreview.psm1') -PassThru
        & $previewModule { Initialize-PreviewProcessJob }
        $beforeTemp=$env:TEMP;$beforeTmp=$env:TMP
        $probe=Join-Path $case 'child-environment.json'
        $script="[IO.File]::WriteAllText('$($probe.Replace("'","''"))',(@{Temp=`$env:TEMP;Tmp=`$env:TMP}|ConvertTo-Json -Compress))"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $job=[HwpxPreviewProcessJob]::new((Get-Process -Id $PID).Path,('-NoProfile -NonInteractive -EncodedCommand '+$encoded),$case)
        try{
            $timer=[Diagnostics.Stopwatch]::StartNew()
            while($job.ActiveProcesses -gt 0 -and $timer.ElapsedMilliseconds -lt 15000){Start-Sleep -Milliseconds 50}
            $job.ActiveProcesses|Should Be 0
            $observed=Get-Content -LiteralPath $probe -Raw|ConvertFrom-Json
            $observed.Temp|Should BeExactly $case
            $observed.Tmp|Should BeExactly $case
            $env:TEMP|Should BeExactly $beforeTemp
            $env:TMP|Should BeExactly $beforeTmp
        }finally{$null=$job.TerminateAndWait(5000);$job.Dispose()}
    }
    It 'runs PDF conversion through the public CLI' {
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
        $shell=(Get-Process -Id $PID).Path
        $raw=& $shell -NoProfile -File $cli convert-pdf -LiteralPath $source -OutputPath $output -PdfMode stored-layout
        $LASTEXITCODE|Should Be 0
        (($raw -join "`n")|ConvertFrom-Json).data.OutputPath|Should Be $output
    }
    It 'blocks a non-HWPX source signature' {
        $bad=Join-Path $case 'renamed.hwpx';Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp') -Destination $bad
        (Export-HwpxPdf -LiteralPath $bad -OutputPath $output).Status|Should Be BLOCKED
        Test-Path -LiteralPath $output|Should Be $false
    }
    It 'does not invent stored coordinates for a new authored document' {
        $new=Join-Path $case 'authored.hwpx';New-PdfTestSource $new
        $r=Export-HwpxPdf -LiteralPath $new -OutputPath $output -PdfMode stored-layout
        $r.Status|Should Be BLOCKED
        Test-Path -LiteralPath $output|Should Be $false
    }
    It 'returns no final PDF when reflow has no supported browser' {
        $r=Export-HwpxPdf -LiteralPath $source -OutputPath $output -PdfMode reflow -BrowserPath (Join-Path $case 'missing/msedge.exe')
        $r.Status|Should Be BLOCKED
        Test-Path -LiteralPath $output|Should Be $false
    }
    It 'blocks output through a linked directory' {
        $target=Join-Path $case 'target';$link=Join-Path $case 'linked';$null=New-Item -ItemType Directory -Path $target
        $kind=if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){'Junction'}else{'SymbolicLink'}
        $null=New-Item -ItemType $kind -Path $link -Target $target
        (Export-HwpxPdf -LiteralPath $source -OutputPath (Join-Path $link 'out.pdf')).Status|Should Be BLOCKED
        @(Get-ChildItem -LiteralPath $target).Count|Should Be 0
    }
    It 'rejects active-content packages before rendering' {
        $z=[IO.Compression.ZipFile]::Open($source,[IO.Compression.ZipArchiveMode]::Update)
        try{$e=$z.CreateEntry('Scripts/code.js');$w=[IO.StreamWriter]::new($e.Open());try{$w.Write('not executed')}finally{$w.Dispose()}}finally{$z.Dispose()}
        $r=Export-HwpxPdf -LiteralPath $source -OutputPath $output
        $r.Status|Should Be BLOCKED
        ($r.Errors -join ';')|Should Match 'active-content'
        Test-Path -LiteralPath $output|Should Be $false
    }
    It 'does not silently substitute a missing font in direct layout mode' {
        $native=Join-Path $PSScriptRoot 'fixtures/source/pdf-stored-layout.hwpx'
        $fontRoot=Join-Path $case 'empty-fonts';$null=New-Item -ItemType Directory -Path $fontRoot
        $r=Export-HwpxPdf -LiteralPath $native -OutputPath $output -PdfMode stored-layout -FontDirectories @($fontRoot)
        $r.Status|Should Be BLOCKED
        ($r.Errors -join ';')|Should Match 'font'
        Test-Path -LiteralPath $output|Should Be $false
    }
    It 'does not hide a partial invalid cache with automatic reflow' {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/pdf-stored-layout.hwpx') -Destination $source -Force
        $z=[IO.Compression.ZipFile]::Open($source,[IO.Compression.ZipArchiveMode]::Update)
        try{
            $e=$z.GetEntry('Contents/section0.xml');$reader=[IO.StreamReader]::new($e.Open());try{[xml]$xml=$reader.ReadToEnd()}finally{$reader.Dispose()}
            $cache=$xml.SelectSingleNode('//*[local-name()="p"]/*[local-name()="linesegarray"]');$null=$cache.ParentNode.RemoveChild($cache)
            $e.Delete();$e=$z.CreateEntry('Contents/section0.xml');$w=[IO.StreamWriter]::new($e.Open(),[Text.UTF8Encoding]::new($false));try{$w.Write($xml.OuterXml)}finally{$w.Dispose()}
        }finally{$z.Dispose()}
        $r=Export-HwpxPdf -LiteralPath $source -OutputPath $output -BrowserPath (Join-Path $case 'missing/msedge.exe')
        $r.Status|Should Be BLOCKED
        $r.Data.Mode|Should Be stored-layout
        ($r.Errors -join ';')|Should Match 'cache|layout'
        Test-Path -LiteralPath $output|Should Be $false
    }
    It 'renders cached Korean with available fonts or safely refuses a missing requested font' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $native=Join-Path $PSScriptRoot 'fixtures/source/pdf-stored-layout.hwpx'
        $r=Export-HwpxPdf -LiteralPath $native -OutputPath $output
        $r.Data.Mode|Should Be stored-layout
        $r.Data.SourcePreserved|Should Be $true
        if($r.Status -ceq 'BLOCKED'){
            # CI has no Hancom fonts; only the documented no-fallback refusal is valid.
            ($r.Errors -join ';')|Should Match 'PDF_RENDER_FAILED: font face ".+" not resolved .+\(no fallback\)'
            Test-Path -LiteralPath $output|Should Be $false
            Write-Host ('Verified missing-font refusal: '+($r.Errors -join ';'))
        }else{
            ($r.Errors -join ';')|Should Be ''
            $r.Status|Should Be PASS_WITH_WARNINGS
            $r.Data.PageCount|Should Be 1
            (Get-Item -LiteralPath $output).Length|Should BeGreaterThan 5000
        }
    }
    It 'converts an authored document through real headless reflow with explicit fidelity' -Skip:(-not $RunHeadlessBrowser) {
        $new=Join-Path $case 'authored.hwpx';New-PdfTestSource $new
        $r=Export-HwpxPdf -LiteralPath $new -OutputPath $output -WorkDirectory ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../tmp')))
        ($r.Errors -join ';')|Should Be ''
        $r.Data.Mode|Should Be reflow
        $r.Data.Fidelity|Should Be approximate
        $r.Data.BrowserShutdownVerified|Should Be $true
        Test-Path -LiteralPath $output|Should Be $true
    }
}
