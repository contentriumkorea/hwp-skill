Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpPortable.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpDocumentModel.psm1') -ErrorAction Stop

function Test-HwpConversionTextEqual {
    param([AllowEmptyString()][string]$Left,[AllowEmptyString()][string]$Right)
    return [string]::Equals($Left,$Right,[StringComparison]::Ordinal)
}

function Assert-HwpInputRecordSubset {
    param($Records)
    foreach($record in $Records){
        if($record.tagId -notin @(0x42,0x43,0x44,0x45,0x47,0x48,0x49,0x4A,0x4B,0x4D)){throw 'Source record has no independent conversion preservation check.'}
        if($record.tagId -eq 0x47){
            if($record.payload.Length -lt 8){throw 'Source control header is truncated.'}
            $id=[Text.Encoding]::ASCII.GetString($record.payload,0,4)
            if($id -cnotin @('dces','dloc',' lbt')){throw 'Source control needs independent correspondence before conversion.'}
            if($id -ceq 'dloc' -and (([BitConverter]::ToUInt16($record.payload,4) -shr 2) -band 0xFF) -ne 1){throw 'Multi-column source conversion is not independently verified.'}
            if($id -ceq 'dces' -and [BitConverter]::ToUInt32($record.payload,4) -ne 0){throw 'Advanced source section flags are not independently verified.'}
        }
    }
}

function Assert-HwpInputStructure {
    param([string]$Path,$Source)
    $session=[Contentrium.HwpSkill.CompoundFileReader]::Open($Path)
    try{
        foreach($section in $Source.Sections){
            $bytes=$session.ReadStream('BodyText',$section.name,134217728)
            if($Source.Compressed){$bytes=[Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($bytes,536870912)}
            Assert-HwpInputRecordSubset @(Get-HwpPortableRecords $bytes)
        }
    }finally{$session.Dispose()}
}

function Assert-HwpConversionPath {
    param([string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while(-not [string]::IsNullOrWhiteSpace($current)){
        $item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'Conversion paths cannot traverse symbolic links or junctions.'
        }
        $parent=[IO.Directory]::GetParent($current)
        if($null -eq $parent){break};$current=$parent.FullName
    }
}

function Assert-HwpConvertedTableBounds {
    param([string]$Path)
    $scoped=Import-Module (Join-Path $PSScriptRoot 'HwpHwpxScopedEdit.psm1') -PassThru -ErrorAction Stop
    & $scoped {
        param($file)
        $stream=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try{
            $package=Read-ScopedPackage $stream
            foreach($part in $package.Sections){
                $ns=New-ScopedNamespaces $package.Xml[$part]
                foreach($table in $package.Xml[$part].SelectNodes('//hp:tbl',$ns)){Assert-ScopedTableBounds $table $package}
            }
        }finally{$stream.Dispose()}
    } $Path
}

function Assert-HwpInputConversionContent {
    param($Source,$Actual)
    if($Actual.Status -notin @('PASS','PASS_WITH_WARNINGS') -or $Actual.DetectedKind -cne 'HWPX-ZIP'){
        throw 'Converted package is not readable HWPX.'
    }
    if(@($Source.Paragraphs).Count -ne @($Actual.Paragraphs).Count){throw 'Converted paragraph count differs.'}
    for($i=0;$i -lt @($Source.Paragraphs).Count;$i++){
        if(-not (Test-HwpConversionTextEqual $Source.Paragraphs[$i].text $Actual.Paragraphs[$i].text)){
            throw "Converted paragraph $i text differs from the HWP source."
        }
    }
    Assert-HwpInputStyles $Source $Actual
    if(@($Source.Sections).Count -ne @($Actual.Sections).Count){throw 'Converted section count differs.'}
    for($i=0;$i -lt @($Source.Sections).Count;$i++){
        $a=@($Source.Sections[$i].pageDefinitions);$b=@($Actual.Sections[$i].pageDefinitions)
        if($a.Count -ne 1 -or $b.Count -ne 1){throw 'Conversion requires one unambiguous page definition per section.'}
        if($a[0].orientation -cne $b[0].orientation -or $a[0].width.raw -ne $b[0].width.raw -or $a[0].height.raw -ne $b[0].height.raw){throw 'Converted page dimensions or orientation differ.'}
        if($a[0].bindingMethodCode -ne 0 -or $b[0].gutterType -cne 'LEFT_ONLY'){throw 'Advanced page binding is not independently verified for conversion.'}
        foreach($side in @('left','right','top','bottom','header','footer','gutter')){
            if($a[0].margins.$side.raw -ne $b[0].margins.$side.raw){throw "Converted page $side margin differs."}
        }
    }
    if(@($Source.Tables).Count -ne @($Actual.Tables).Count){throw 'Converted table count differs.'}
    for($i=0;$i -lt @($Source.Tables).Count;$i++){
        $a=$Source.Tables[$i];$b=$Actual.Tables[$i]
        if($a.rowCount -ne $b.rowCount -or $a.columnCount -ne $b.columnCount -or @($a.cells).Count -ne @($b.cells).Count){throw 'Converted table dimensions differ.'}
        if($a.cellSpacing -ne $b.cellSpacing){throw 'Converted table cell spacing differs.'}
        if($a.properties.pageBreak -cne $b.properties.pageBreak -or $a.properties.repeatHeader -ne $b.properties.repeatHeader){throw 'Converted table page splitting or header repetition differs.'}
        if(@($a.validZones).Count -gt 0){throw 'Table valid-zone styling is not independently verified for conversion.'}
        foreach($side in @('left','right','top','bottom')){if($a.innerMargins.$side -ne $b.innerMargins.$side){throw 'Converted table inner margin differs.'}}
        if(-not (Test-HwpConversionTextEqual (Get-HwpConversionBorderSignature $Source.Resources.borderFills $a.borderFillId $true) (Get-HwpConversionBorderSignature $Actual.Resources.borderFills $b.borderFillId $false))){throw 'Converted table border differs.'}
        foreach($cell in $a.cells){
            $matches=@($b.cells|Where-Object {$_.rowAddress -eq $cell.rowAddress -and $_.columnAddress -eq $cell.columnAddress})
            if($matches.Count -ne 1){throw 'Converted table cell address is missing or ambiguous.'}
            $found=$matches[0]
            foreach($name in @('rowSpan','columnSpan','width','height')){if($cell.$name -ne $found.$name){throw "Converted table cell $name differs."}}
            if(-not (Test-HwpConversionTextEqual $cell.text $found.text)){throw 'Converted table cell text differs.'}
            if($cell.lineWrapCode -ne 0){throw 'Advanced native cell wrapping is not independently verified.'}
            if($cell.verticalAlignment -cne $found.verticalAlignment -or $cell.textDirection -cne $found.textDirection -or $found.lineWrap -cne 'BREAK'){throw 'Converted cell alignment, direction or wrapping differs.'}
            foreach($side in @('left','right','top','bottom')){if($cell.margins.$side -ne $found.margins.$side){throw 'Converted table cell margin differs.'}}
            if(-not (Test-HwpConversionTextEqual (Get-HwpConversionBorderSignature $Source.Resources.borderFills $cell.borderFillId $true) (Get-HwpConversionBorderSignature $Actual.Resources.borderFills $found.borderFillId $false))){throw 'Converted table cell border differs.'}
        }
    }
    # A hash inventory alone cannot prove source picture-to-asset correspondence.
    if(@($Source.Controls|Where-Object {$_.ctrlId -ne 'tbl'}).Count -gt 0 -or @($Source.BinaryAssets).Count -gt 0){
        throw 'Source pictures, equations or binary assets need verified object correspondence; conversion is not promoted.'
    }
    return $true
}

function Get-HwpConversionBorderSignature {
    param($Resources,[long]$Id,[bool]$Native)
    if($Id -eq 0){return 'NONE'}
    $shape=Get-HwpConversionResource $Resources $Id
    if($Native -and ($shape.slashCode -ne 0 -or $shape.backSlashCode -ne 0)){throw 'HWP diagonal borders require further verified conversion mapping.'}
    $sig=[ordered]@{threeD=[bool]$shape.threeD;shadow=[bool]$shape.shadow;center=[bool]$shape.centerLine}
    $empty=-not ($shape.threeD -or $shape.shadow -or $shape.centerLine)
    foreach($side in @('Left','Right','Top','Bottom')){
        $line=$shape.borders.$side
        if($Native -and $line.typeCode -notin @(0,1,2,8)){throw 'This HWP border pattern is not independently verified for conversion.'}
        $sig[$side]=[string]$line.type
        if($line.type -cne 'NONE'){$empty=$false;$sig[$side+'Width']=$line.widthMm;$sig[$side+'Color']=([string]$line.color).ToUpperInvariant()}
    }
    if($Native -and ($shape.fill.typeRaw -notin @(0,1) -or ($null -ne $shape.fill.solid -and $shape.fill.solid.patternType -ne -1))){throw 'Advanced HWP fill is not independently verified for conversion.'}
    if($null -ne $shape.fill.gradient -or $null -ne $shape.fill.image){throw 'Advanced HWPX fill cannot be certified for conversion.'}
    $background=if($null -eq $shape.fill.solid){'NONE'}else{([string]$shape.fill.solid.backgroundColor).ToUpperInvariant()}
    $sig['background']=$background
    if($background -cne 'NONE'){$empty=$false}
    if($empty){return 'NONE'}
    return ($sig|ConvertTo-Json -Compress)
}

function Get-HwpConversionResource {
    param($Resources,[long]$Id)
    $matches=@($Resources|Where-Object {$_.id -eq $Id})
    if($matches.Count -ne 1){throw 'Missing or ambiguous font/paragraph resource during conversion verification.'}
    return $matches[0]
}

function Get-HwpConversionCharSignature {
    param($Shape,[bool]$Native,$Resources)
    $result=[ordered]@{size=$Shape.fontSizeRaw;color=([string]$Shape.textColor).ToUpperInvariant();shade=([string]$Shape.shadeColor).ToUpperInvariant()}
    foreach($name in @('bold','italic','emboss','engrave','superscript','subscript','useFontSpace','kerning')){$result[$name]=[bool]$Shape.attributes.$name}
    foreach($lang in @('Hangul','Latin','Hanja','Japanese','Other','Symbol','User')){$result['font'+$lang]=[string]$Shape.resolvedFontNames.$lang}
    $result['border']=Get-HwpConversionBorderSignature $Resources.borderFills $Shape.borderFillId $Native
    if($Native){
        $unknownMask=[uint32]::MaxValue -bxor [uint32]0x4201FFFF
        if(([uint32]$Shape.attributesRaw -band $unknownMask) -ne 0 -or $Shape.attributes.outlineCode -ne 0 -or $Shape.attributes.shadowCode -ne 0){throw 'Advanced font effects are not independently verified for HWP conversion.'}
        foreach($name in @('ratios','spacings','relativeSizes','offsets')){
            foreach($lang in @('Hangul','Latin','Hanja','Japanese','Other','Symbol','User')){$result[$name+$lang]=[int]$Shape.$name.$lang}
        }
        $type=@('NONE','BOTTOM','CENTER','TOP')[[int]$Shape.attributes.underlineTypeCode]
        $result['underline']=$type
        if($type -cne 'NONE'){$result['underlineShape']=@('SOLID','DASH','DOT','DASH_DOT','DASH_DOT_DOT','LONG_DASH','CIRCLE','DOUBLE','THIN_THICK','THICK_THIN','THIN_THICK_THIN','WAVE','DOUBLE_WAVE','THICK_3D','THICK_3D_REVERSE','SOLID_3D')[[int]$Shape.attributes.underlineShapeCode];$result['underlineColor']=([string]$Shape.underlineColor).ToUpperInvariant()}
    }else{
        foreach($pair in @(@('ratios','ratio'),@('spacings','spacing'),@('relativeSizes','relSz'),@('offsets','offset'))){
            $nodes=@($Shape.properties.children|Where-Object element -CEQ $pair[1])
            if($nodes.Count -ne 1){throw 'Converted language font geometry is missing.'}
            foreach($lang in @('Hangul','Latin','Hanja','Japanese','Other','Symbol','User')){$result[$pair[0]+$lang]=[int]$nodes[0].attributes.($lang.ToLowerInvariant())}
        }
        $underline=@($Shape.properties.children|Where-Object element -CEQ 'underline')
        if($underline.Count -ne 1){throw 'Converted underline style cannot be verified.'}
        $result['underline']=[string]$underline[0].attributes.type
        if($result['underline'] -cne 'NONE'){$result['underlineShape']=[string]$underline[0].attributes.shape;$result['underlineColor']=([string]$underline[0].attributes.color).ToUpperInvariant()}
    }
    return ($result|ConvertTo-Json -Depth 4 -Compress)
}

function Assert-HwpInputStyles {
    param($Source,$Actual)
    $nativeChars=@{};$xmlChars=@{}
    foreach($p in $Source.Paragraphs){foreach($r in $p.charShapeRuns){$nativeChars[[long]$r.charShapeId]=$null}}
    foreach($id in @($nativeChars.Keys)){$nativeChars[$id]=Get-HwpConversionCharSignature (Get-HwpConversionResource $Source.Resources.charShapes $id) $true $Source.Resources}
    foreach($p in $Actual.Paragraphs){foreach($r in $p.charShapeRuns){$xmlChars[[long]$r.charShapeId]=$null}}
    foreach($id in @($xmlChars.Keys)){$xmlChars[$id]=Get-HwpConversionCharSignature (Get-HwpConversionResource $Actual.Resources.charShapes $id) $false $Actual.Resources}
    for($i=0;$i -lt @($Source.Paragraphs).Count;$i++){
        $a=$Source.Paragraphs[$i];$b=$Actual.Paragraphs[$i]
        if(([int]$a.breakTypeRaw -band 4) -ne $(if($b.pageBreak){4}else{0}) -or ([int]$a.breakTypeRaw -band 8) -ne $(if($b.columnBreak){8}else{0})){throw 'Converted paragraph page/column break differs.'}
        $s=Get-HwpConversionResource $Source.Resources.paraShapes $a.paraShapeId
        $t=Get-HwpConversionResource $Actual.Resources.paraShapes $b.paraShapeId
        if(-not (Test-HwpConversionTextEqual (Get-HwpConversionBorderSignature $Source.Resources.borderFills $s.borderFillId $true) (Get-HwpConversionBorderSignature $Actual.Resources.borderFills $t.borderFillId $false))){throw 'Converted paragraph border differs.'}
        if($s.alignment -cne $t.alignment -or $s.indent.point -ne $t.indent.point){throw 'Converted paragraph alignment or indent differs.'}
        foreach($side in @('left','right','before','after')){if($s.margins.$side.point -ne $t.margins.$side.point){throw 'Converted paragraph margin differs.'}}
        $lineType=if($s.lineSpacing.type -ceq 'MINIMUM'){'AT_LEAST'}else{$s.lineSpacing.type}
        $lineValue=if($lineType -ceq 'PERCENT'){$t.lineSpacing.value}else{$t.lineSpacing.measurement.raw}
        if($lineType -cne $t.lineSpacing.type -or $s.lineSpacing.value -ne $lineValue){throw 'Converted paragraph line spacing differs.'}
        $shapeXml=[Xml.XmlDocument]::new();$shapeXml.XmlResolver=$null;$shapeXml.LoadXml($t.properties.xml)
        $breaks=$shapeXml.DocumentElement.SelectSingleNode('*[local-name()="breakSetting"]')
        foreach($flag in @('widowOrphan','keepWithNext','keepLines','pageBreakBefore')){
            if($null -eq $breaks -or [bool]$s.$flag -ne ($breaks.GetAttribute($flag) -cin @('1','true'))){throw 'Converted paragraph break setting differs.'}
        }
        if($s.breakNonLatinWordCode -notin @(0,1) -or $breaks.GetAttribute('breakNonLatinWord') -cne @('BREAK_WORD','KEEP_WORD')[[int]$s.breakNonLatinWordCode]){throw 'Converted Korean word wrapping differs.'}
        # Non-default Latin wrapping/automatic spacing needs a separate verified mapping.
        if($s.breakLatinWordCode -ne 0 -or $breaks.GetAttribute('breakLatinWord') -cne 'KEEP_WORD'){throw 'Advanced Latin word wrapping is not independently verified.'}
        $auto=$shapeXml.DocumentElement.SelectSingleNode('*[local-name()="autoSpacing"]')
        if($null -eq $auto -or [bool]$s.autoSpacing.eAsianEnglish -ne ($auto.GetAttribute('eAsianEng') -cin @('1','true')) -or [bool]$s.autoSpacing.eAsianNumber -ne ($auto.GetAttribute('eAsianNum') -cin @('1','true'))){throw 'Converted paragraph automatic spacing differs.'}
        if([bool]$s.snapToGrid -ne ($shapeXml.DocumentElement.GetAttribute('snapToGrid') -cin @('1','true'))){throw 'Converted paragraph grid setting differs.'}
        $left=@($a.charShapeRuns);$right=@($b.charShapeRuns)
        if($left.Count -eq 0 -or $right.Count -eq 0 -or $left[0].textStart -ne 0 -or $right[0].start -ne 0){throw 'Missing initial font run during conversion verification.'}
        if($a.text.Length -eq 0){
            if(-not (Test-HwpConversionTextEqual $nativeChars[[long]$left[0].charShapeId] $xmlChars[[long]$right[0].charShapeId])){throw 'Converted empty paragraph font properties differ.'}
            continue
        }
        $positions=[Collections.Generic.SortedSet[long]]::new()
        foreach($r in $left){if($null -eq $r.textStart){throw 'Invalid raw font run offset.'};$null=$positions.Add([long]$r.textStart)}
        foreach($r in $right){$null=$positions.Add([long]$r.start)}
        $li=0;$ri=0
        foreach($position in $positions){
            if($position -ge $a.text.Length){continue}
            while($li+1 -lt $left.Count -and $left[$li+1].textStart -le $position){$li++}
            while($ri+1 -lt $right.Count -and $right[$ri+1].start -le $position){$ri++}
            if(-not (Test-HwpConversionTextEqual $nativeChars[[long]$left[$li].charShapeId] $xmlChars[[long]$right[$ri].charShapeId])){throw "Converted paragraph $i font properties differ."}
        }
    }
}

function Invoke-HwpInputWorker {
    param([string]$InputPath,[string]$OutputPath,[string]$Workspace,[ValidateRange(1,120)][int]$TimeoutSeconds=60,
        [ValidateSet('convert_hwp.py','convert_pdf.py')][string]$WorkerName='convert_hwp.py',[string[]]$ExtraArguments=@())
    $python=$null
    foreach($name in @('python3','python')){
        $candidate=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if($null -ne $candidate -and $candidate.Source -notmatch '[\\/]WindowsApps[\\/]'){$python=$candidate;break}
    }
    if($null -eq $python){throw 'Offline HWP conversion requires CPython 3.9+; Hancom will not be started.'}
    $report=Join-Path $Workspace 'worker.json'
    $arguments=@('-I','-S','-B',(Join-Path $PSScriptRoot ('../'+$WorkerName)),'--input',$InputPath,'--output',$OutputPath,'--scratch',$Workspace,'--report',$report)+$ExtraArguments
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$python.Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.WorkingDirectory=$Workspace
    $start.EnvironmentVariables['TEMP']=$Workspace;$start.EnvironmentVariables['TMP']=$Workspace
    if($start.PSObject.Properties.Name -contains 'ArgumentList'){
        foreach($arg in $arguments){$start.ArgumentList.Add($arg)}
    }else{
        $quoted=@(foreach($arg in $arguments){'"'+([regex]::Replace(([regex]::Replace($arg,'(\\*)"','$1$1\"')),'(\\+)$','$1$1'))+'"'})
        $start.Arguments=$quoted -join ' '
    }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        $null=$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){$process.Kill();$process.WaitForExit();throw 'HWP conversion timed out; source preserved.'}
        $outText=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if(-not (Test-Path -LiteralPath $report -PathType Leaf) -or (Get-Item -LiteralPath $report).Length -gt 2MB){throw 'HWP worker did not provide a bounded verification report.'}
        $r=[IO.File]::ReadAllText($report,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
        if($process.ExitCode -ne 0 -or $r.status -cne 'PASS'){throw ('HWP conversion refused: '+[string]$r.error)}
        if(@($r.warnings).Count -ne 0){throw 'HWP conversion reported unsupported content.'}
        return $r
    }finally{$process.Dispose()}
}

function Write-HwpConversionCandidate {
    param([string]$Candidate,[string]$Output,[string]$ExpectedSha256)
    Assert-HwpConversionPath $Output
    $capture=[IO.File]::Open($Candidate,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($capture.Length -gt 100MB){throw 'Conversion candidate exceeds its bound.'}
        $bytes=[byte[]]::new([int]$capture.Length);$offset=0
        while($offset -lt $bytes.Length){$read=$capture.Read($bytes,$offset,$bytes.Length-$offset);if($read -eq 0){throw 'Conversion candidate truncated before commit.'};$offset+=$read}
        if($capture.ReadByte() -ne -1){throw 'Conversion candidate grew before commit.'}
    }finally{$capture.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$byteHash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($byteHash -cne $ExpectedSha256){throw 'Conversion candidate bytes changed before commit.'}
    $destination=$null;$created=$false
    try{
        $destination=[IO.File]::Open($Output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $created=$true
        $destination.Write($bytes,0,$bytes.Length);$destination.Flush($true)
    }catch{
        if($null -ne $destination){$destination.Dispose();$destination=$null}
        if($created){Assert-HwpConversionPath $Output;[IO.File]::Delete($Output)}
        throw
    }finally{if($null -ne $destination){$destination.Dispose()}}
}

function Invoke-HwpToHwpx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $workspace='';$workspaceOwned=$false;$sourceStream=$null;$result=$null
    try {
        $kind=Get-HwpFileKind -LiteralPath $LiteralPath
        if(-not $kind.ExtensionMatches -or $kind.DetectedKind -cne 'HWP-BINARY'){throw 'Conversion input must be an HWP/HWT 5.x compound file, not a renamed file.'}
        $output=[IO.Path]::GetFullPath($OutputPath)
        if([IO.Path]::GetExtension($output).ToLowerInvariant() -cne '.hwpx'){throw 'Conversion output must use .hwpx.'}
        if(Test-Path -LiteralPath $output){throw 'Conversion never overwrites an existing result.'}
        $directory=[IO.Path]::GetDirectoryName($output)
        if(-not (Test-Path -LiteralPath $directory -PathType Container)){throw 'Conversion output directory does not exist.'}
        Assert-HwpConversionPath $output
        $sourceStream=[IO.File]::Open($kind.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if($sourceStream.Length -gt 100MB){throw 'HWP conversion input exceeds 100 MiB.'}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$sourceHash=([BitConverter]::ToString($sha.ComputeHash($sourceStream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $sourceStream.Position=0
        $workspace=Join-Path $directory ('.hwp-convert-'+[guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $workspace -ErrorAction Stop
        $workspaceOwned=$true
        Assert-HwpConversionPath $workspace
        $snapshot=Join-Path $workspace 'source.hwp'
        $copy=[IO.File]::Open($snapshot,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$sourceStream.CopyTo($copy)}finally{$copy.Dispose()}
        if((Get-HwpSha256 $snapshot) -cne $sourceHash){throw 'HWP input changed while taking its read-only snapshot.'}
        $source=Get-HwpPortableInspection -LiteralPath $snapshot -ExpectedSha256 $sourceHash -MaximumFileBytes 104857600
        if($source.Status -notin @('PASS','PASS_WITH_WARNINGS')){throw ($source.Errors -join ' ')}
        $candidate=Join-Path $workspace 'candidate.hwpx'
        $worker=Invoke-HwpInputWorker -InputPath $snapshot -OutputPath $candidate -Workspace $workspace
        $actual=Get-HwpInspection -LiteralPath $candidate
        if($actual.Sha256 -cne $worker.outputSha256){throw 'Converted candidate differs from worker output.'}
        $null=Assert-HwpInputConversionContent -Source $source.Data -Actual $actual
        Assert-HwpInputStructure $snapshot $source.Data
        Assert-HwpConvertedTableBounds $candidate
        if((Get-HwpSha256 $kind.Path) -cne $sourceHash -or (Get-HwpSha256 $snapshot) -cne $sourceHash){throw 'HWP source changed during conversion.'}
        Assert-HwpConversionPath $output
        if((Get-HwpSha256 $candidate) -cne $actual.Sha256){throw 'HWPX candidate changed during verification.'}
        Write-HwpConversionCandidate -Candidate $candidate -Output $output -ExpectedSha256 $actual.Sha256
        $result=New-HwpResult -Status PASS_WITH_WARNINGS -Command convert-hwpx -Data ([pscustomobject]@{
            SourcePath=$kind.Path;SourceSha256=$sourceHash;OutputPath=$output;OutputSha256=$actual.Sha256
            Engine='HwpForge 0.16.11';Offline=$true;NativeLayoutVerified=$false;TemporaryPath=$workspace
        }) -Warnings @('HWP 원본을 보존하고 HWPX 작업본을 만들었습니다. 실제 한컴 조판·인쇄는 검증하지 않았습니다.')
    }catch{
        $result=New-HwpResult -Status BLOCKED -Command convert-hwpx -Data ([pscustomobject]@{TemporaryPath=$workspace}) -Errors @($_.Exception.Message)
    }finally{
        if($null -ne $sourceStream){$sourceStream.Dispose()}
        if($workspaceOwned -and $workspace -and (Test-Path -LiteralPath $workspace)){
            try {
                Assert-HwpConversionPath $workspace
                if(@(Get-ChildItem -LiteralPath $workspace -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Workspace contains a link; cleanup refused.'}
                [IO.Directory]::Delete($workspace,$true)
                if($null -ne $result){$result.Data.TemporaryPath=''}
            }catch{
                if($null -ne $result){$result.Warnings+=@('Temporary conversion workspace could not be safely removed: '+$workspace)}
            }
        }
    }
    return $result
}

Export-ModuleMember -Function @('Invoke-HwpToHwpx','Assert-HwpInputConversionContent','Assert-HwpConversionPath','Invoke-HwpInputWorker','Write-HwpConversionCandidate')
