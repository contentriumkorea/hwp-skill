Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1')
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1')

# This is a deliberately separate, approximate HTML renderer, never a Hancom backend.
function ConvertTo-PreviewText([AllowNull()][string]$Text) {
    [Net.WebUtility]::HtmlEncode($Text)
}

function Get-PreviewAttribute($Node, [string]$Name, [string]$Default = '') {
    if ($null -ne $Node -and $Node.HasAttribute($Name)) { return $Node.GetAttribute($Name) }
    $Default
}

function Get-PreviewNumber($Value, [double]$Default = 0, [double]$Minimum = -10000000, [double]$Maximum = 10000000) {
    [double]$number = 0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and
        -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
        $number -ge $Minimum -and $number -le $Maximum) { return $number }
    $Default
}

function Format-PreviewNumber([double]$Number) {
    $Number.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-PreviewWarning($Context, [string]$Message) {
    if (-not $Context.Warnings.Contains($Message)) { $Context.Warnings.Add($Message) }
}

function Add-PreviewStyle($Context, [string]$Declarations) {
    if (-not $Context.StyleMap.ContainsKey($Declarations)) {
        $name = 's' + $Context.StyleMap.Count
        $Context.StyleMap[$Declarations] = $name
        $null = $Context.Css.Append('.' + $name + '{' + $Declarations + "}`n")
    }
    $Context.StyleMap[$Declarations]
}

function Read-PreviewXml($Entry) {
    # The public inspector checks package paths, duplicates and aggregate sizes first.
    if ($null -eq $Entry -or $Entry.Length -gt 16777216) { throw 'Missing or oversized preview XML part.' }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 16777216
    $stream = $Entry.Open()
    try {
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $xml = [Xml.XmlDocument]::new()
            $xml.XmlResolver = $null
            $xml.Load($reader)
            return ,$xml
        } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-PreviewCharacterStyle($Context, [string]$Id) {
    if (-not $Context.Characters.ContainsKey($Id)) { return '' }
    $shape = $Context.Characters[$Id]
    $css = 'font-size:' + (Format-PreviewNumber (Get-PreviewNumber $shape.FontSizePt 10 1 1000)) + 'pt;'
    # CSS string encoding is separate from HTML encoding. No document CSS is copied.
    $names = @($shape.ResolvedFontNames.Hangul, $shape.ResolvedFontNames.Latin) | Select-Object -Unique
    $families = @(
        foreach ($name in $names) {
            if ($name) {
                $encoded = -join @(([string]$name).ToCharArray() | ForEach-Object { '\' + ([int]$_).ToString('x') + ' ' })
                '"' + $encoded + '"'
            }
        }
    )
    if ($families.Count) { $css += 'font-family:' + ($families -join ',') + ',sans-serif;' }
    $css += if ($shape.Attributes.Bold) { 'font-weight:bold;' } else { 'font-weight:normal;' }
    $css += if ($shape.Attributes.Italic) { 'font-style:italic;' } else { 'font-style:normal;' }
    if ($shape.TextColor -match '^#[0-9a-fA-F]{6}$') { $css += 'color:' + $shape.TextColor + ';' }
    if ($shape.Attributes.Superscript) { $css += 'vertical-align:super;' }
    if ($shape.Attributes.Subscript) { $css += 'vertical-align:sub;' }
    if ($Context.CharacterXml.ContainsKey($Id)) {
        $node = $Context.CharacterXml[$Id]
        $underline = Get-PreviewAttribute ($node.SelectSingleNode("*[local-name()='underline']")) 'type'
        $decoration = @()
        if ($underline -eq 'BOTTOM') { $decoration += 'underline' }
        if ($underline -eq 'TOP') { $decoration += 'overline' }
        if ($underline -eq 'CENTER') { $decoration += 'line-through' }
        $strike = $node.SelectSingleNode("*[local-name()='strikeout']")
        if ($null -ne $strike -and (Get-PreviewAttribute $strike 'shape') -ne 'NONE') { $decoration += 'line-through' }
        if ($decoration.Count) { $css += 'text-decoration:' + (($decoration | Select-Object -Unique) -join ' ') + ';' }
    }
    $css
}

function Get-PreviewParagraphStyle($Context, $Node) {
    $css = ''
    $id = Get-PreviewAttribute $Node 'paraPrIDRef'
    if ($Context.Paragraphs.ContainsKey($id)) {
        $shape = $Context.Paragraphs[$id]
        $align = switch ($shape.Alignment) { 'CENTER' {'center'} 'RIGHT' {'right'} 'JUSTIFY' {'justify'} default {'left'} }
        $css += 'text-align:' + $align + ';'
        foreach ($pair in @(@('left','left'), @('right','right'), @('before','top'), @('after','bottom'))) {
            $css += 'margin-' + $pair[1] + ':' + (Format-PreviewNumber (Get-PreviewNumber $shape.Margins.($pair[0]).Millimeter)) + 'mm;'
        }
        $css += 'text-indent:' + (Format-PreviewNumber (Get-PreviewNumber $shape.Indent.Millimeter)) + 'mm;'
        if ($shape.LineSpacing.Type -eq 'PERCENT') {
            $css += 'line-height:' + (Format-PreviewNumber ((Get-PreviewNumber $shape.LineSpacing.Value 160 1 1000) / 100)) + ';'
        } elseif ($null -ne $shape.LineSpacing.Measurement) {
            $css += 'line-height:' + (Format-PreviewNumber $shape.LineSpacing.Measurement.Millimeter) + 'mm;'
            Add-PreviewWarning $Context 'Fixed/minimum line spacing is approximated by CSS line-height.'
        }
    }
    if ((Get-PreviewAttribute $Node 'pageBreak') -in @('1','true')) { $css += 'break-before:page;' }
    if ((Get-PreviewAttribute $Node 'columnBreak') -in @('1','true')) {
        Add-PreviewWarning $Context 'Column breaks and multi-column layout are not reproduced.'
    }
    $css
}

function Get-PreviewRasterMime([byte[]]$Bytes) {
    if ($Bytes.Length -lt 12) { return '' }
    $hex = [BitConverter]::ToString($Bytes, 0, 8)
    if ($hex -eq '89-50-4E-47-0D-0A-1A-0A') { return 'image/png' }
    if ($hex.StartsWith('FF-D8-FF')) { return 'image/jpeg' }
    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 6) -in @('GIF87a','GIF89a')) { return 'image/gif' }
    if ($Bytes[0] -eq 66 -and $Bytes[1] -eq 77) { return 'image/bmp' }
    if ([Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -eq 'RIFF' -and
        [Text.Encoding]::ASCII.GetString($Bytes, 8, 4) -eq 'WEBP') { return 'image/webp' }
    ''
}

function ConvertTo-PreviewImage($Context, $Node) {
    $ref = Get-PreviewAttribute ($Node.SelectSingleNode(".//*[local-name()='img']")) 'binaryItemIDRef'
    if (-not $Context.Images.ContainsKey($ref)) {
        Add-PreviewWarning $Context 'Missing, external, oversized or unsupported image omitted (only embedded PNG/JPEG/GIF/BMP/WebP are allowed).'
        return '<span class="unsupported">[Image unavailable]</span>'
    }
    $sz = $Node.SelectSingleNode("*[local-name()='sz']")
    $width = Get-PreviewNumber (Get-PreviewAttribute $sz 'width') 0 0
    $height = Get-PreviewNumber (Get-PreviewAttribute $sz 'height') 0 0
    $css = ''
    if ($width -gt 0) { $css += 'width:' + (Format-PreviewNumber ($width / 283.464566929)) + 'mm;' }
    if ($height -gt 0) { $css += 'height:' + (Format-PreviewNumber ($height / 283.464566929)) + 'mm;' }
    $pos = $Node.SelectSingleNode("*[local-name()='pos']")
    if ((Get-PreviewAttribute $pos 'treatAsChar' '1') -notin @('1','true')) {
        Add-PreviewWarning $Context 'Floating objects, offsets, wrapping and z-order are shown in document flow.'
    }
    $rotation = Get-PreviewAttribute ($Node.SelectSingleNode("*[local-name()='rotationInfo']")) 'angle' '0'
    $flip = $Node.SelectSingleNode("*[local-name()='flip']")
    $clip = $Node.SelectSingleNode("*[local-name()='imgClip']")
    $dim = $Node.SelectSingleNode("*[local-name()='imgDim']")
    if ($rotation -ne '0' -or (Get-PreviewAttribute $flip 'horizontal' '0') -ne '0' -or
        (Get-PreviewAttribute $flip 'vertical' '0') -ne '0' -or
        (Get-PreviewAttribute $clip 'left' '0') -ne '0' -or (Get-PreviewAttribute $clip 'top' '0') -ne '0' -or
        ($null -ne $clip -and $null -ne $dim -and
            ((Get-PreviewAttribute $clip 'right') -ne (Get-PreviewAttribute $dim 'dimwidth') -or
             (Get-PreviewAttribute $clip 'bottom') -ne (Get-PreviewAttribute $dim 'dimheight')))) {
        Add-PreviewWarning $Context 'Image crop, rotation, flips and transforms are not reproduced; the full raster is shown.'
    }
    $comment = $Node.SelectSingleNode("*[local-name()='shapeComment']")
    $alt = if ($null -ne $comment) { $comment.InnerText } else { 'Embedded image' }
    $Context.RenderedImageCharacters += $Context.Images[$ref].Length
    if ($Context.RenderedImageCharacters -gt 67108864) { throw 'Repeated embedded images exceed the 64 MiB preview safety limit.' }
    $Context.ImageCount++
    '<img class="' + (Add-PreviewStyle $Context $css) + '" src="' + $Context.Images[$ref] + '" alt="' + (ConvertTo-PreviewText $alt) + '">'
}

function ConvertTo-PreviewTable($Context, $Node, [int]$Depth) {
    $rows = [int](Get-PreviewNumber (Get-PreviewAttribute $Node 'rowCnt') 0 1 4096)
    $cols = [int](Get-PreviewNumber (Get-PreviewAttribute $Node 'colCnt') 0 1 4096)
    if ($rows -lt 1 -or $cols -lt 1 -or $rows * $cols -gt 4096) { throw 'Preview table exceeds the 4096-cell safety limit or has invalid dimensions.' }
    $cells = @{}
    $covered = @{}
    foreach ($tc in $Node.SelectNodes("*[local-name()='tr']/*[local-name()='tc']")) {
        $address = $tc.SelectSingleNode("*[local-name()='cellAddr']")
        $span = $tc.SelectSingleNode("*[local-name()='cellSpan']")
        $r = [int](Get-PreviewNumber (Get-PreviewAttribute $address 'rowAddr') -1 0 4095)
        $c = [int](Get-PreviewNumber (Get-PreviewAttribute $address 'colAddr') -1 0 4095)
        $rs = [int](Get-PreviewNumber (Get-PreviewAttribute $span 'rowSpan') 1 1 4096)
        $cs = [int](Get-PreviewNumber (Get-PreviewAttribute $span 'colSpan') 1 1 4096)
        if ($r -lt 0 -or $c -lt 0 -or $r + $rs -gt $rows -or $c + $cs -gt $cols) { throw 'Invalid preview table cell address/span.' }
        for ($y = $r; $y -lt $r + $rs; $y++) {
            for ($x = $c; $x -lt $c + $cs; $x++) {
                $key = "$y,$x"
                if ($covered.ContainsKey($key)) { throw 'Overlapping preview table cells.' }
                $covered[$key] = $true
            }
        }
        $cells["$r,$c"] = @{ Node=$tc; RowSpan=$rs; ColSpan=$cs }
    }
    if ($covered.Count -ne $rows * $cols) { throw 'Incomplete preview table grid.' }
    $sz = $Node.SelectSingleNode("*[local-name()='sz']")
    $width = Get-PreviewNumber (Get-PreviewAttribute $sz 'width') 0 0
    $css = if ($width -gt 0) { 'width:' + (Format-PreviewNumber ($width / 283.464566929)) + 'mm;' } else { '' }
    $html = [Text.StringBuilder]::new()
    $null = $html.Append('<table class="' + (Add-PreviewStyle $Context $css) + '"><tbody>')
    for ($r = 0; $r -lt $rows; $r++) {
        $null = $html.Append('<tr>')
        for ($c = 0; $c -lt $cols; $c++) {
            if (-not $cells.ContainsKey("$r,$c")) { continue }
            $cell = $cells["$r,$c"]
            $tc = $cell.Node
            $sub = $tc.SelectSingleNode("*[local-name()='subList']")
            $vertical = switch (Get-PreviewAttribute $sub 'vertAlign') { 'CENTER' {'middle'} 'BOTTOM' {'bottom'} default {'top'} }
            $cellCss = 'vertical-align:' + $vertical + ';'
            $size = $tc.SelectSingleNode("*[local-name()='cellSz']")
            $cw = Get-PreviewNumber (Get-PreviewAttribute $size 'width') 0 0
            if ($cw -gt 0) { $cellCss += 'width:' + (Format-PreviewNumber ($cw / 283.464566929)) + 'mm;' }
            $margin = $tc.SelectSingleNode("*[local-name()='cellMargin']")
            foreach ($side in @('left','right','top','bottom')) {
                $value = Get-PreviewNumber (Get-PreviewAttribute $margin $side) 283 0
                $cellCss += 'padding-' + $side + ':' + (Format-PreviewNumber ($value / 283.464566929)) + 'mm;'
            }
            $fillId = Get-PreviewAttribute $tc 'borderFillIDRef'
            if ($Context.Fills.ContainsKey($fillId)) {
                $fill = $Context.Fills[$fillId]
                $brush = $fill.SelectSingleNode(".//*[local-name()='winBrush']")
                $color = Get-PreviewAttribute $brush 'faceColor'
                if ($color -match '^#[0-9a-fA-F]{6}$') { $cellCss += 'background-color:' + $color + ';' }
                foreach ($side in @('left','right','top','bottom')) {
                    $border = $fill.SelectSingleNode("*[local-name()='$($side)Border']")
                    if ($null -eq $border) { continue }
                    $kind = switch (Get-PreviewAttribute $border 'type') { 'NONE' {'none'} 'DASH' {'dashed'} 'DOT' {'dotted'} 'DOUBLE' {'double'} default {'solid'} }
                    $thickness = (Get-PreviewAttribute $border 'width') -replace 'mm$', ''
                    $color = Get-PreviewAttribute $border 'color'
                    if ($color -notmatch '^#[0-9a-fA-F]{6}$') { $color = '#666666' }
                    $cellCss += 'border-' + $side + ':' + (Format-PreviewNumber (Get-PreviewNumber $thickness 0.12 0 10)) + 'mm ' + $kind + ' ' + $color + ';'
                }
            }
            if ((Get-PreviewAttribute $sub 'textDirection' 'HORIZONTAL') -ne 'HORIZONTAL') {
                Add-PreviewWarning $Context 'Vertical cell text is displayed horizontally.'
            }
            $null = $html.Append('<td rowspan="' + $cell.RowSpan + '" colspan="' + $cell.ColSpan + '" class="' + (Add-PreviewStyle $Context $cellCss) + '">')
            if ($null -ne $sub) {
                foreach ($p in $sub.SelectNodes("*[local-name()='p']")) { $null = $html.Append((ConvertTo-PreviewNode $Context $p ($Depth + 1))) }
            }
            $null = $html.Append('</td>')
        }
        $null = $html.Append('</tr>')
    }
    $null = $html.Append('</tbody></table>')
    $Context.TableCount++
    $html.ToString()
}

function ConvertTo-PreviewNode($Context, $Node, [int]$Depth = 0) {
    if ($Depth -gt 64) { throw 'Preview XML nesting exceeds the safety limit.' }
    if ($Node.NodeType -in @([Xml.XmlNodeType]::Text, [Xml.XmlNodeType]::CDATA)) { return (ConvertTo-PreviewText $Node.Value) }
    if ($Node.NodeType -ne [Xml.XmlNodeType]::Element) { return '' }
    switch ($Node.LocalName) {
        'tbl' { return (ConvertTo-PreviewTable $Context $Node $Depth) }
        'pic' { return (ConvertTo-PreviewImage $Context $Node) }
        'lineBreak' { return '<br>' }
        'tab' { return '&#9;' }
        'nbSpace' { return '&#160;' }
        'fwSpace' { return '&#12288;' }
        'hyphen' { return '-' }
        { $_ -in @('secPr','colPr','linesegarray','bookmark','fieldEnd') } { return '' }
        'ctrl' {
            $parts = foreach ($child in $Node.ChildNodes) { ConvertTo-PreviewNode $Context $child ($Depth + 1) }
            return ($parts -join '')
        }
        { $_ -in @('p','run','t') } {
            $parts = foreach ($child in $Node.ChildNodes) { ConvertTo-PreviewNode $Context $child ($Depth + 1) }
            $body = $parts -join ''
            if ($Node.LocalName -eq 't') { return $body }
            if ($Node.LocalName -eq 'run') {
                $css = Get-PreviewCharacterStyle $Context (Get-PreviewAttribute $Node 'charPrIDRef')
                # A div can contain tables; a span/p cannot. Inline display keeps run flow.
                return '<div class="run ' + (Add-PreviewStyle $Context $css) + '">' + $body + '</div>'
            }
            $Context.ParagraphCount++
            if (-not $body) { $body = '<br>' }
            $firstRun = $Node.SelectSingleNode("*[local-name()='run']")
            $paragraphCss = Get-PreviewCharacterStyle $Context (Get-PreviewAttribute $firstRun 'charPrIDRef')
            $paragraphCss += Get-PreviewParagraphStyle $Context $Node
            return '<div class="paragraph ' + (Add-PreviewStyle $Context $paragraphCss) + '">' + $body + '</div>'
        }
        default {
            Add-PreviewWarning $Context ('Unsupported object/control omitted: ' + $Node.LocalName + '.')
            return '<span class="unsupported">[Unsupported: ' + (ConvertTo-PreviewText $Node.LocalName) + ']</span>'
        }
    }
}

function Resolve-PreviewBrowser([string]$BrowserPath) {
    # The portable HTML path has no platform dependencies. Native process containment
    # is currently implemented/tested for Windows browsers only; other OSes keep HTML.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $null }
    $candidates = @()
    if ($BrowserPath) { $candidates = @($BrowserPath) }
    else {
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
            if ($root) {
                foreach ($relative in @('Microsoft/Edge/Application/msedge.exe','Google/Chrome/Application/chrome.exe','Chromium/Application/chrome.exe')) {
                    $candidates += Join-Path $root $relative
                }
            }
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -match '^(\\\\|//)' -or -not [IO.File]::Exists($candidate)) { continue }
        $file = Get-Item -LiteralPath $candidate
        if ($file.Name -notin @('msedge.exe','chrome.exe','chromium.exe')) { continue }
        if ($file.VersionInfo.ProductName -notmatch '^(Microsoft Edge|Google Chrome|Chromium)$') { continue }
        return $file.FullName
    }
    $null
}

function Initialize-PreviewProcessJob {
    if ($null -ne ('HwpxPreviewProcessJob' -as [type])) { return }
    # Edge's launcher can exit before its headless child prints. Start suspended and
    # assign a private kill-on-close job before any child can escape our timeout.
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public sealed class HwpxPreviewProcessJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFO {
        public int cb; public IntPtr reserved, desktop, title;
        public uint x,y,xSize,ySize,xCount,yCount,fill,flags;
        public ushort show,reservedSize; public IntPtr reserved2,input,output,error;
    }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION {
        public IntPtr process,thread; public uint processId,threadId;
    }
    [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT {
        public long processTime,jobTime; public uint flags;
        public UIntPtr minWorking,maxWorking; public uint activeLimit;
        public UIntPtr affinity; public uint priority,scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS {
        public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMIT {
        public BASIC_LIMIT basic; public IO_COUNTERS io;
        public UIntPtr processMemory,jobMemory,peakProcessMemory,peakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct ACCOUNTING {
        public long userTime,kernelTime,periodUser,periodKernel;
        public uint pageFaults,totalProcesses,activeProcesses,terminatedProcesses;
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job,int kind,ref EXTENDED_LIMIT info,int length);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool QueryInformationJobObject(IntPtr job,int kind,out ACCOUNTING info,int length,IntPtr returned);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern bool CreateProcess(string application,StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,
        uint flags,IntPtr environment,string directory,ref STARTUPINFO startup,out PROCESS_INFORMATION process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr job;
    public uint ProcessId { get; private set; }
    public HwpxPreviewProcessJob(string application,string arguments,string temporaryDirectory) {
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        IntPtr environment = IntPtr.Zero;
        try {
            if(!System.IO.Directory.Exists(temporaryDirectory)) throw new ArgumentException("Temporary directory does not exist.");
            SortedDictionary<string,string> variables = new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
            foreach(DictionaryEntry item in Environment.GetEnvironmentVariables()) variables[(string)item.Key]=(string)item.Value;
            variables["TEMP"]=temporaryDirectory; variables["TMP"]=temporaryDirectory;
            StringBuilder block = new StringBuilder();
            foreach(KeyValuePair<string,string> item in variables) block.Append(item.Key).Append('=').Append(item.Value).Append('\0');
            block.Append('\0');
            environment=Marshal.StringToHGlobalUni(block.ToString());
            job = CreateJobObject(IntPtr.Zero,null);
            if(job==IntPtr.Zero) throw new Win32Exception();
            EXTENDED_LIMIT limit = new EXTENDED_LIMIT();
            limit.basic.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if(!SetInformationJobObject(job,9,ref limit,Marshal.SizeOf(limit))) throw new Win32Exception();
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb=Marshal.SizeOf(startup); startup.flags=1; startup.show=0; // SW_HIDE
            if(!CreateProcess(application,new StringBuilder("\""+application+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,
                false,0x08000404,environment,null,ref startup,out process)) throw new Win32Exception();
            ProcessId=process.processId;
            if(!AssignProcessToJobObject(job,process.process)) throw new Win32Exception();
            if(ResumeThread(process.thread)==UInt32.MaxValue) throw new Win32Exception();
        } catch {
            if(process.process!=IntPtr.Zero) TerminateProcess(process.process,1);
            Dispose(); throw;
        } finally {
            if(environment!=IntPtr.Zero) Marshal.FreeHGlobal(environment);
            if(process.thread!=IntPtr.Zero) CloseHandle(process.thread);
            if(process.process!=IntPtr.Zero) CloseHandle(process.process);
        }
    }
    public uint ActiveProcesses {
        get {
            ACCOUNTING info;
            if(!QueryInformationJobObject(job,1,out info,Marshal.SizeOf(typeof(ACCOUNTING)),IntPtr.Zero)) throw new Win32Exception();
            return info.activeProcesses;
        }
    }
    public bool TerminateAndWait(int timeoutMilliseconds) {
        if(timeoutMilliseconds<0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
        if(job==IntPtr.Zero) return true;
        // Termination is asynchronous. Keep the job handle until every descendant
        // exits so profile deletion cannot race the browser's process rundown.
        if(!TerminateJobObject(job,1)) throw new Win32Exception();
        Stopwatch timer=Stopwatch.StartNew();
        while(ActiveProcesses!=0) {
            if(timer.ElapsedMilliseconds>=timeoutMilliseconds) return false;
            Thread.Sleep((int)Math.Min(20,Math.Max(1,timeoutMilliseconds-timer.ElapsedMilliseconds)));
        }
        return true;
    }
    public void Dispose() { if(job!=IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; } }
}
'@
}

function Test-PreviewPdfComplete([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $false }
    $stream = $null
    try {
        # Exclusive access prevents mistaking an actively written PDF for completion.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        if ($stream.Length -lt 12) { return $false }
        $head = [byte[]]::new(5)
        $null = $stream.Read($head, 0, 5)
        $tail = [byte[]]::new([Math]::Min(1024, $stream.Length))
        $null = $stream.Seek(-$tail.Length, [IO.SeekOrigin]::End)
        $null = $stream.Read($tail, 0, $tail.Length)
        return ([Text.Encoding]::ASCII.GetString($head) -eq '%PDF-' -and [Text.Encoding]::ASCII.GetString($tail) -match '%%EOF\s*$')
    } catch [IO.IOException] { return $false }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Invoke-PreviewBrowser([string]$Browser, [string]$HtmlPath, [string]$WorkDirectory) {
    $profile = Join-Path $WorkDirectory 'profile'
    $pdf = Join-Path $WorkDirectory 'printed.pdf'
    $args = @('--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check',
        '--disable-background-networking','--disable-component-update','--disable-sync','--disable-extensions',
        '--disable-default-apps','--disable-domain-reliability','--disable-breakpad',
        '--disable-features=Translate,MediaRouter,OptimizationHints,msEdgeSidebarV2',
        '--host-resolver-rules=MAP * ~NOTFOUND','--proxy-server=http://127.0.0.1:9','--proxy-bypass-list=<-loopback>',
        '--no-pdf-header-footer','--disable-print-preview','--timeout=25000','--virtual-time-budget=1000',
        ('--user-data-dir=' + $profile), ('--print-to-pdf=' + $pdf), ([Uri]$HtmlPath).AbsoluteUri)
    # Windows argv quoting (including trailing backslashes), without a shell.
    $arguments = (@($args | ForEach-Object { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }) -join ' ')
    Initialize-PreviewProcessJob
    $job = [HwpxPreviewProcessJob]::new($Browser, $arguments, $WorkDirectory)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($timer.ElapsedMilliseconds -lt 30000) {
            if (Test-PreviewPdfComplete $pdf) { return $pdf }
            if ($job.ActiveProcesses -eq 0) { break }
            [Threading.Thread]::Sleep(100)
        }
        if (Test-PreviewPdfComplete $pdf) { return $pdf }
        if ($timer.ElapsedMilliseconds -ge 30000) { throw 'Headless browser timed out after 30 seconds.' }
        throw 'Headless browser exited without a complete PDF.'
    } finally {
        # Includes descendants even after the launcher has exited; affects no existing browser.
        try {
            if (-not $job.TerminateAndWait(5000)) { throw 'Headless browser descendants did not terminate within 5 seconds.' }
        } finally { $job.Dispose() }
    }
}

function Write-PreviewNewFile([string]$Path, [string]$Text) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
}

function Remove-PreviewWorkDirectory([string]$Path, [string]$ExpectedParent) {
    if (-not $Path -or -not [IO.Directory]::Exists($Path)) { return $true }
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd([char[]]@('\','/'))
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd([char[]]@('\','/')) -ne $parent -or
        [IO.Path]::GetFileName($resolved) -notmatch '^\.hwpx-preview-[a-f0-9]{32}$') { return $false }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop; return $true }
        catch {
            if (-not [IO.Directory]::Exists($resolved)) { return $true }
            if ($timer.ElapsedMilliseconds -ge 5000) { return $false }
            [Threading.Thread]::Sleep([int][Math]::Min(100, [Math]::Max(1, 5000 - $timer.ElapsedMilliseconds)))
        }
    }
}

function Assert-PreviewLocalAncestors([string]$AbsolutePath, [int]$LinkDepth = 0) {
    if ($AbsolutePath -match '^[\\/]{2}') { throw 'Network/UNC paths are not allowed for preview input or output.' }
    if ($LinkDepth -gt 40) { throw 'Preview path exceeds the local symlink resolution limit.' }
    $root = [IO.Path]::GetPathRoot($AbsolutePath)
    $windowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    if ($windowsHost) {
        if ([IO.DriveInfo]::new($root).DriveType -eq [IO.DriveType]::Network) {
            throw 'Network/UNC paths are not allowed for preview input or output.'
        }
    } else {
        # Unix may legitimately use local OS links such as /var -> /private/var.
        # Refuse network mounts reported by the OS, including after link resolution.
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -ne [IO.DriveType]::Network) { continue }
            $mount = $drive.Name.TrimEnd('/')
            if ($AbsolutePath -ceq $mount -or $AbsolutePath.StartsWith($mount + '/', [StringComparison]::Ordinal)) {
                throw 'Network/UNC paths are not allowed for preview input or output.'
            }
        }
    }
    # Inspect from the root down, before ever following a potentially remote link.
    $current = $root
    $parts = @('') + @($AbsolutePath.Substring($root.Length).Split([char[]]@('\','/'),[StringSplitOptions]::RemoveEmptyEntries))
    foreach ($part in $parts) {
        if ($part) { $current = [IO.Path]::Combine($current,$part) }
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { break }
        catch [IO.DirectoryNotFoundException] { break }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            if ($windowsHost) { throw ('Preview paths cannot contain a Windows reparse point: ' + $current) }
            $link = if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                [IO.DirectoryInfo]::new($current)
            } else { [IO.FileInfo]::new($current) }
            if ($null -eq $link.PSObject.Methods['ResolveLinkTarget']) { throw 'Local Unix symlinks require .NET ResolveLinkTarget support.' }
            if ($link.LinkTarget -match '^[\\/]{2}') { throw 'Network/UNC paths are not allowed for preview input or output.' }
            $target = $link.ResolveLinkTarget($false)
            if ($null -eq $target) { throw ('Cannot resolve local preview symlink: ' + $current) }
            $remainder = $AbsolutePath.Substring($current.Length).TrimStart([char[]]@('\','/'))
            $canonical = if ($remainder) { [IO.Path]::Combine($target.FullName,$remainder) } else { $target.FullName }
            Assert-PreviewLocalAncestors ([IO.Path]::GetFullPath($canonical)) ($LinkDepth + 1)
            return
        }
    }
}

function Export-HwpxPreview {
    <#
    .SYNOPSIS
    Creates a local, approximate HWPX visual aid without Hancom, GUI automation or COM.
    .DESCRIPTION
    Returns Status, Data (HtmlPath, PdfPath, ReportPath, Fidelity, NativeLayoutVerified,
    InputSha256, InputSha256After, SourcePreserved, Counts), Warnings and Errors.
    Success is always PASS_WITH_WARNINGS. A missing/failed browser leaves PdfPath null.
    An explicitly supplied missing BrowserPath disables discovery for that invocation.
    Existing preview.html, preview.pdf or preview-report.json blocks the operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
        [string]$BrowserPath
    )
    $data = [pscustomobject][ordered]@{
        HtmlPath=$null; PdfPath=$null; ReportPath=$null; Fidelity='approximate'; NativeLayoutVerified=$false
        InputPath=$null; InputSha256=$null; InputSha256After=$null; SourcePreserved=$false
        BrowserPath=$null; BrowserMode='not-run'; BrowserTemporaryDirectory=$null; BrowserShutdownVerified=$null; Counts=$null
        HancomPageCount=$null; PixelMatchVerified=$false; AllLayoutChecksPassed=$false
    }
    $context = @{
        Warnings=[Collections.Generic.List[string]]::new(); Css=[Text.StringBuilder]::new(); StyleMap=@{}
        Characters=@{}; CharacterXml=@{}; Paragraphs=@{}; Fills=@{}; Images=@{}
        ParagraphCount=0; TableCount=0; ImageCount=0; RenderedImageCharacters=0
    }
    Add-PreviewWarning $context 'Approximate visual aid only: no pixel match, exact Hancom page count or complete layout verification. Fonts may be substituted; line wrapping, pagination and table splitting can differ.'
    $lock = $null
    $archive = $null
    $work = $null
    $reportWritten = $false
    $status = 'BLOCKED'
    try {
        # Reject explicit UNC/device/provider UNC forms before any path resolution or IO.
        foreach ($candidate in @($LiteralPath,$OutputDirectory)) {
            if ($candidate.TrimStart() -match '^(?:[\\/]{2}|[^:]+::[\\/]{2})') {
                throw 'Network/UNC paths are not allowed for preview input or output.'
            }
        }
        $output = [IO.Path]::GetFullPath($OutputDirectory)
        Assert-PreviewLocalAncestors $output
        $inputPath = Resolve-HwpLiteralPath -LiteralPath $LiteralPath
        Assert-PreviewLocalAncestors $inputPath
        $data.InputPath = $inputPath
        # Hold a read-only, write/delete-denying handle through inspection and rendering.
        $lock = [IO.File]::Open($inputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $data.InputSha256 = Get-HwpSha256 -LiteralPath $inputPath
        $kind = Get-HwpFileKind -LiteralPath $inputPath
        if ($kind.DetectedKind -ne 'HWPX-ZIP' -or -not $kind.ExtensionMatches) { throw 'Preview requires a genuine HWPX ZIP with the .hwpx extension.' }
        $htmlPath = Join-Path $output 'preview.html'
        $pdfPath = Join-Path $output 'preview.pdf'
        $reportPath = Join-Path $output 'preview-report.json'
        foreach ($path in @($htmlPath,$pdfPath,$reportPath)) {
            if (Test-Path -LiteralPath $path) { throw ('Existing output will not be overwritten: ' + $path) }
        }
        $inspection = Get-HwpxPackageInspection -LiteralPath $inputPath -MaximumUncompressedBytes 67108864 -MaximumXmlCharacters 16777216
        if ($inspection.Status -in @('BLOCKED','FAILED')) { throw ($inspection.Errors -join '; ') }
        foreach ($warning in $inspection.Warnings) { Add-PreviewWarning $context $warning }
        $archive = [IO.Compression.ZipArchive]::new($lock, [IO.Compression.ZipArchiveMode]::Read, $true)
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '(?i)(encrypt|drm|signature|(^|/)(scripts?|macros?)(/|\.))') {
                throw 'Protected, signed or active-content package is not previewed.'
            }
        }
        foreach ($shape in $inspection.Data.Resources.CharShapes) { $context.Characters[[string]$shape.Id] = $shape }
        foreach ($shape in $inspection.Data.Resources.ParaShapes) { $context.Paragraphs[[string]$shape.Id] = $shape }
        $headerEntry = $archive.GetEntry('Contents/header.xml')
        if ($null -ne $headerEntry) {
            $header = Read-PreviewXml $headerEntry
            foreach ($node in $header.SelectNodes("//*[local-name()='charPr']")) { $context.CharacterXml[$node.GetAttribute('id')] = $node }
            foreach ($node in $header.SelectNodes("//*[local-name()='borderFill']")) { $context.Fills[$node.GetAttribute('id')] = $node }
            foreach ($pair in @(@('heading','Lists/numbering are not generated; stored body text is shown.'), @('tabItem','Custom tab stops/leaders are approximated.'), @('shadow','Text shadows are not reproduced.'), @('outline','Text outlines are not reproduced.'))) {
                $nodes = @($header.SelectNodes("//*[local-name()='$($pair[0])']"))
                if (@($nodes | Where-Object { (Get-PreviewAttribute $_ 'type' 'NONE') -ne 'NONE' -or $pair[0] -eq 'tabItem' }).Count) { Add-PreviewWarning $context $pair[1] }
            }
        }
        $manifestEntry = $archive.GetEntry('Contents/content.hpf')
        if ($null -ne $manifestEntry) {
            $manifest = Read-PreviewXml $manifestEntry
            foreach ($item in $manifest.SelectNodes("//*[local-name()='item']")) {
                $href = $item.GetAttribute('href')
                if ($href -notmatch '^(\.\./)?BinData/[^:?#\\]+$' -or $href -match '/\.\.?/') { continue }
                $entryName = $href -replace '^\.\./', ''
                $imageEntry = $archive.GetEntry($entryName)
                if ($null -eq $imageEntry -or $imageEntry.Length -gt 16777216) { continue }
                $stream = $imageEntry.Open()
                $memory = [IO.MemoryStream]::new()
                try { $stream.CopyTo($memory); $bytes = $memory.ToArray() }
                finally { $stream.Dispose(); $memory.Dispose() }
                $mime = Get-PreviewRasterMime $bytes
                if ($mime) { $context.Images[$item.GetAttribute('id')] = 'data:' + $mime + ';base64,' + [Convert]::ToBase64String($bytes) }
            }
        }
        $null = $context.Css.Append(@'
*{box-sizing:border-box}body{margin:0;background:#e5e7eb;color:#111;font:10pt sans-serif}.notice{margin:12px;padding:12px;background:#fff5ce;font:12px sans-serif}.section{background:white;margin:18px auto;box-shadow:0 1px 6px #999}.section+.section{break-before:page}.paragraph{white-space:pre-wrap;overflow-wrap:anywhere;min-height:1em;margin:0;line-height:1.6}.run{display:inline}table{border-collapse:collapse;table-layout:fixed;max-width:100%;white-space:normal;text-indent:0}td{border:.12mm solid #666;overflow-wrap:anywhere}td .paragraph{min-height:1em}img{max-width:100%;object-fit:contain;vertical-align:middle}.unsupported{color:#873d00;background:#fff5ce} @media print{body{background:white}.notice{display:none}.section{margin:0!important;padding:0!important;min-height:0!important;width:auto!important;box-shadow:none}}
'@)
        $body = [Text.StringBuilder]::new()
        foreach ($section in $inspection.Data.Sections) {
            $xml = Read-PreviewXml ($archive.GetEntry($section.Name))
            $pages = @($section.PageDefinitions)
            $w = 210.0; $h = 297.0; $orientation = 'PORTRAIT'; $margins = @{top=15.0;right=15.0;bottom=15.0;left=15.0}
            if ($pages.Count) {
                $page = $pages[0]
                $w = Get-PreviewNumber $page.Width.Millimeter 210 10 2000
                $h = Get-PreviewNumber $page.Height.Millimeter 297 10 2000
                $orientation = $page.Orientation
                foreach ($side in @('top','right','bottom','left')) { $margins[$side] = Get-PreviewNumber $page.Margins.$side.Millimeter 15 0 1000 }
                if ($page.Margins.Gutter.Raw -gt 0) { Add-PreviewWarning $context 'Binding gutters and mirrored margins are not reproduced.' }
                if ($pages.Count -gt 1) { Add-PreviewWarning $context 'Multiple page definitions within a section use only the first definition.' }
            } else { Add-PreviewWarning $context 'Missing page definition: A4 portrait with 15 mm margins is assumed.' }
            if ($margins.left + $margins.right -ge $w -or $margins.top + $margins.bottom -ge $h) { throw 'Preview page margins leave no printable area.' }
            foreach ($pair in @(@('colPr','Column layout is approximated as one column.'), @('pageBorderFill','Page borders/backgrounds are not reproduced.'), @('header','Headers are omitted.'), @('footer','Footers are omitted.'), @('pageNum','Automatic page numbers are omitted.'), @('footNote','Footnotes are omitted.'), @('endNote','Endnotes are omitted.'), @('caption','Object captions are omitted.'), @('effects','Image/object effects are not reproduced.'))) {
                $nodes = @($xml.SelectNodes("//*[local-name()='$($pair[0])']"))
                if ($pair[0] -eq 'colPr') { $nodes = @($nodes | Where-Object { (Get-PreviewAttribute $_ 'colCount' '1') -ne '1' }) }
                if ($pair[0] -eq 'effects') { $nodes = @($nodes | Where-Object { $_.HasChildNodes }) }
                if ($nodes.Count) { Add-PreviewWarning $context $pair[1] }
            }
            $pageName = 'hwpx' + $section.Index
            $marginCss = (@('top','right','bottom','left') | ForEach-Object { (Format-PreviewNumber $margins[$_]) + 'mm' }) -join ' '
            $null = $context.Css.Append('@page ' + $pageName + '{size:' + (Format-PreviewNumber $w) + 'mm ' + (Format-PreviewNumber $h) + 'mm;margin:' + $marginCss + ";}`n")
            $style = 'page:' + $pageName + ';width:' + (Format-PreviewNumber $w) + 'mm;min-height:' + (Format-PreviewNumber $h) + 'mm;padding:' + $marginCss + ';'
            $null = $body.Append('<section class="section ' + (Add-PreviewStyle $context $style) + '" data-orientation="' + (ConvertTo-PreviewText $orientation) + '">')
            foreach ($node in $xml.DocumentElement.ChildNodes) {
                $null = $body.Append((ConvertTo-PreviewNode $context $node))
                if ($body.Length -gt 67108864) { throw 'Rendered HTML exceeds the 64 MiB preview safety limit.' }
            }
            $null = $body.Append('</section>')
        }
        $css = $context.Css.ToString()
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $styleHash = [Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($css))) } finally { $hash.Dispose() }
        $csp = "default-src 'none'; script-src 'none'; style-src 'sha256-$styleHash'; img-src data:; font-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"
        $html = '<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="' + (ConvertTo-PreviewText $csp) + '"><title>Approximate HWPX preview</title><style>' + $css + '</style></head><body><aside class="notice">Approximate HWPX visual aid. NativeLayoutVerified=false. Not a pixel match; pagination and fonts may differ from Hancom.</aside>' + $body.ToString() + '</body></html>'
        $status = 'FAILED'
        $null = [IO.Directory]::CreateDirectory($output)
        Write-PreviewNewFile $htmlPath $html
        $data.HtmlPath = $htmlPath
        $data.Counts = [pscustomobject]@{ Sections=@($inspection.Data.Sections).Count; Paragraphs=$context.ParagraphCount; Tables=$context.TableCount; Images=$context.ImageCount }
        $browser = Resolve-PreviewBrowser $BrowserPath
        if ($browser) {
            $data.BrowserPath = $browser
            $data.BrowserMode = 'headless'
            $work = Join-Path $output ('.hwpx-preview-' + [guid]::NewGuid().ToString('N'))
            $null = [IO.Directory]::CreateDirectory($work)
            $data.BrowserShutdownVerified = $false
            try {
                $printed = Invoke-PreviewBrowser $browser $htmlPath $work
                $data.BrowserShutdownVerified = $true
                [IO.File]::Move($printed, $pdfPath)
                $data.PdfPath = $pdfPath
            } catch { Add-PreviewWarning $context ('PDF unavailable: ' + $_.Exception.Message) }
            if (Remove-PreviewWorkDirectory $work $output) { $work = $null }
            else {
                $data.BrowserTemporaryDirectory = $work
                Add-PreviewWarning $context ('Temporary browser data could not be removed: ' + $work)
            }
        } else { Add-PreviewWarning $context 'No supported local Chromium/Edge browser found; HTML created, PDF not produced.' }
        $data.InputSha256After = Get-HwpSha256 -LiteralPath $inputPath
        $data.SourcePreserved = $data.InputSha256 -eq $data.InputSha256After
        if (-not $data.SourcePreserved) { throw 'Input SHA-256 changed during preview.' }
        $data.ReportPath = $reportPath
        $result = New-HwpResult -Status PASS_WITH_WARNINGS -Command preview-hwpx -Data $data -Warnings @($context.Warnings)
        Write-PreviewNewFile $reportPath ($result | ConvertTo-Json -Depth 12)
        $reportWritten = $true
        return $result
    } catch {
        $errorMessage = $_.Exception.Message
        if ($null -ne $lock) {
            try {
                $data.InputSha256After = Get-HwpSha256 -LiteralPath $data.InputPath
                $data.SourcePreserved = $data.InputSha256 -eq $data.InputSha256After
            } catch {
                $data.SourcePreserved = $false
                $status = 'FAILED'
                Add-PreviewWarning $context 'Could not recheck the input SHA-256.'
            }
        }
        if (-not $reportWritten) { $data.ReportPath = $null }
        return (New-HwpResult -Status $status -Command preview-hwpx -Data $data -Warnings @($context.Warnings) -Errors @($errorMessage))
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $lock) { $lock.Dispose() }
        # Cleanup after an unexpected exception. Normal cleanup is recorded in the report.
        if ($work -and -not $reportWritten) { $null = Remove-PreviewWorkDirectory $work $output }
    }
}

Export-ModuleMember -Function Export-HwpxPreview
