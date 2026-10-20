Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1')
Import-Module (Join-Path $PSScriptRoot 'HwpInputConvert.psm1')
$script:PdfPreview=Import-Module (Join-Path $PSScriptRoot 'HwpPreview.psm1') -PassThru

function Get-PdfUnusedPreviewWarnings($Inspection) {
    $numbering=$false
    foreach($id in @($Inspection.Paragraphs|ForEach-Object {$_.paraShapeId}|Select-Object -Unique)){
        $shapes=@($Inspection.Resources.paraShapes|Where-Object {$_.id -eq $id})
        if($shapes.Count -ne 1){throw 'Ambiguous used paragraph style during PDF reflow.'}
        $xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.LoadXml($shapes[0].properties.xml)
        $heading=$xml.DocumentElement.SelectSingleNode('*[local-name()="heading"]')
        if($null -ne $heading -and $heading.GetAttribute('type') -cne 'NONE'){$numbering=$true}
    }
    if(-not $numbering){'Lists/numbering are not generated; stored body text is shown.'}
    $visible=$false
    foreach($section in $Inspection.Sections){foreach($border in $section.pageBorders){
        $signature=& (Get-Module HwpInputConvert) {param($resources,$id) Get-HwpConversionBorderSignature $resources $id $false} $Inspection.Resources.borderFills ([long]$border.attributes.borderFillIDRef)
        if($signature -cne 'NONE'){$visible=$true}
    }}
    if(-not $visible){'Page borders/backgrounds are not reproduced.'}
}

function Export-HwpxPdf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LiteralPath,[Parameter(Mandatory)][string]$OutputPath,
        [ValidateSet('auto','stored-layout','reflow')][string]$PdfMode='auto',
        [string]$BrowserPath,[string[]]$FontDirectories=@(),[string]$WorkDirectory)
    $sourceStream=$null;$workspace='';$owned=$false;$result=$null
    $data=[pscustomobject]@{OutputPath=$null;OutputSha256=$null;SourcePath=$null;SourceSha256=$null;SourcePreserved=$false;Mode=$null;Fidelity=$null;PageCount=$null;NativeLayoutVerified=$false;BrowserShutdownVerified=$null;TemporaryPath=''}
    $warnings=@('PDF is rendered without Hancom. Identical Hancom pagination, typography and printing are not verified.')
    try{
        foreach($path in @($LiteralPath,$OutputPath,$WorkDirectory)+$FontDirectories){if($path -and $path.TrimStart() -match '^(?:[\\/]{2}|[^:]+::[\\/]{2})'){throw 'PDF conversion requires local paths, not UNC/network paths.'}}
        $kind=Get-HwpFileKind -LiteralPath $LiteralPath
        if(-not $kind.ExtensionMatches -or $kind.DetectedKind -cne 'HWPX-ZIP'){throw 'PDF input must be a genuine HWPX file.'}
        $output=[IO.Path]::GetFullPath($OutputPath);Assert-HwpConversionPath $output
        if([IO.Path]::GetExtension($output).ToLowerInvariant() -cne '.pdf'){throw 'PDF output must use .pdf.'}
        if(Test-Path -LiteralPath $output){throw 'PDF conversion never overwrites an existing file.'}
        $directory=[IO.Path]::GetDirectoryName($output)
        if(-not (Test-Path -LiteralPath $directory -PathType Container)){throw 'PDF output directory does not exist.'}
        foreach($font in $FontDirectories){Assert-HwpConversionPath $font;if(-not (Test-Path -LiteralPath $font -PathType Container)){throw 'Font directory does not exist.'}}
        $data.SourcePath=$kind.Path
        $sourceStream=[IO.File]::Open($kind.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($sourceStream.Length -gt 100MB){throw 'PDF input exceeds 100 MiB.'}
        $data.SourceSha256=Get-HwpSha256 $kind.Path
        $workRoot=if($WorkDirectory){[IO.Path]::GetFullPath($WorkDirectory)}else{$directory}
        Assert-HwpConversionPath $workRoot
        if(-not (Test-Path -LiteralPath $workRoot -PathType Container)){throw 'PDF working directory does not exist.'}
        $workspace=Join-Path $workRoot ('.hwpx-pdf-'+[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $workspace -ErrorAction Stop;$owned=$true
        $data.TemporaryPath=$workspace;Assert-HwpConversionPath $workspace
        $snapshot=Join-Path $workspace 'source.hwpx'
        $copy=[IO.File]::Open($snapshot,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$sourceStream.CopyTo($copy)}finally{$copy.Dispose()}
        if((Get-HwpSha256 $snapshot) -cne $data.SourceSha256){throw 'Source changed while snapshotting.'}
        $inspection=Get-HwpxPackageInspection -LiteralPath $snapshot -MaximumUncompressedBytes 67108864 -MaximumXmlCharacters 16777216
        if($inspection.Status -notin @('PASS','PASS_WITH_WARNINGS')){throw ($inspection.Errors -join ';')}
        $archive=[IO.Compression.ZipFile]::OpenRead($snapshot)
        try{foreach($entry in $archive.Entries){if($entry.FullName -match '(?i)(encrypt|drm|signature|(^|/)(scripts?|macros?)(/|\.))'){throw 'Protected, signed or active-content HWPX is not converted.'}}}finally{$archive.Dispose()}
        $mode=$PdfMode
        if($mode -ceq 'auto'){$mode=if($inspection.Data.Layout.LineSegmentCount -gt 0){'stored-layout'}else{'reflow'}}
        $data.Mode=$mode
        if($mode -ceq 'stored-layout'){
            $data.Fidelity='stored-layout';$candidate=Join-Path $workspace 'candidate.pdf'
            $fontArgs=@(foreach($font in $FontDirectories){'--font-dir';[IO.Path]::GetFullPath($font)})
            $worker=Invoke-HwpInputWorker -InputPath $snapshot -OutputPath $candidate -Workspace $workspace -WorkerName convert_pdf.py -ExtraArguments $fontArgs
            $expected=$worker.outputSha256;$data.PageCount=$worker.pages
        }else{
            if($FontDirectories.Count){throw 'Explicit font directories require stored-layout mode; reflow uses the browser font system.'}
            $data.Fidelity='approximate'
            $preview=Export-HwpxPreview -LiteralPath $snapshot -OutputDirectory (Join-Path $workspace 'reflow') -BrowserPath $BrowserPath
            if($preview.Status -notin @('PASS','PASS_WITH_WARNINGS') -or -not $preview.Data.PdfPath){throw ('Headless PDF reflow unavailable: '+($preview.Errors -join ';')+' '+($preview.Warnings -join ';'))}
            $unused=@(Get-PdfUnusedPreviewWarnings $inspection.Data)
            $renderWarnings=@($preview.Warnings|Where-Object {$_ -cnotin $unused})
            $warnings+=$renderWarnings
            $loss=@($renderWarnings|Where-Object {$_ -match '(?i)omitt|unsupported|not reproduced|vertical cell|missing page|multiple page|one column|lists/numbering|tab stops'})
            if($loss.Count){throw ('PDF reflow would omit or change unsupported content: '+($loss -join ';'))}
            if($preview.Data.BrowserShutdownVerified -ne $true){throw 'Headless browser shutdown is not verified.'}
            $data.BrowserShutdownVerified=$true;$candidate=$preview.Data.PdfPath;$expected=Get-HwpSha256 $candidate
        }
        if(-not (& $script:PdfPreview {param($p) Test-PreviewPdfComplete $p} $candidate)){throw 'PDF completion markers are missing.'}
        if((Get-HwpSha256 $snapshot) -cne $data.SourceSha256 -or (Get-HwpSha256 $kind.Path) -cne $data.SourceSha256){throw 'Source changed during PDF conversion.'}
        Write-HwpConversionCandidate -Candidate $candidate -Output $output -ExpectedSha256 $expected
        $data.OutputPath=$output;$data.OutputSha256=$expected;$data.SourcePreserved=$true
        $result=New-HwpResult -Status PASS_WITH_WARNINGS -Command convert-pdf -Data $data -Warnings $warnings
    }catch{
        if($null -ne $sourceStream){try{$data.SourcePreserved=(Get-HwpSha256 $data.SourcePath) -ceq $data.SourceSha256}catch{}}
        $result=New-HwpResult -Status BLOCKED -Command convert-pdf -Data $data -Errors @($_.Exception.Message) -Warnings $warnings
    }finally{
        if($null -ne $sourceStream){$sourceStream.Dispose()}
        if($owned -and (Test-Path -LiteralPath $workspace)){
            try{Assert-HwpConversionPath $workspace;if(@(Get-ChildItem -LiteralPath $workspace -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Linked workspace; cleanup refused.'};[IO.Directory]::Delete($workspace,$true);$data.TemporaryPath=''}
            catch{if($null -ne $result){$result.Warnings+=@('Temporary PDF workspace retained: '+$workspace)}}
        }
    }
    return $result
}
Export-ModuleMember -Function Export-HwpxPdf
