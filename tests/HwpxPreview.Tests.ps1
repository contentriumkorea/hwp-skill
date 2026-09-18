param([switch]$RunHeadlessBrowser)

Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPreview.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:PreviewTestRoot = Join-Path $PSScriptRoot ('output/preview-tests-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($script:PreviewTestRoot)
$script:MissingPreviewBrowser = Join-Path $script:PreviewTestRoot 'missing/msedge.exe'

function New-PreviewTestPlan {
    $image = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
    $plan = @'
{"version":"2.0","document":{"textStyle":{"fontFamily":"Arial","fontSizePt":12},"page":{"paperSize":"A4","margins":{"leftMm":20,"rightMm":21,"topMm":22,"bottomMm":23}}},"sections":[{"content":[{"type":"paragraph","runs":[{"text":"Preview title","textStyle":{"fontSizePt":18,"bold":true,"italic":true,"textColor":"#123456","underline":"BOTTOM"}},{"text":" and body"}],"paragraphStyle":{"alignment":"CENTER"}},{"type":"paragraph","text":"line one\nline two\tend"},{"type":"table","rows":3,"columns":3,"widthMm":120,"cells":[{"row":1,"column":1,"rowSpan":2,"colSpan":2,"text":"MERGED ONCE","style":{"fillColor":"#EEF2FF"}},{"row":1,"column":3,"text":"R1C3"},{"row":2,"column":3,"text":"R2C3"},{"row":3,"column":1,"text":"R3C1"},{"row":3,"column":2,"text":"R3C2"},{"row":3,"column":3,"text":"R3C3"}]},{"type":"image","path":"IMAGE","widthMm":30,"heightMm":20,"altText":"sample & safe"}]},{"document":{"page":{"orientation":"LANDSCAPE"}},"content":[{"type":"paragraph","text":"LANDSCAPE BODY"}]},{"document":{"page":{"paperSize":"A5","orientation":"PORTRAIT"}},"content":[{"type":"paragraph","text":"A5 BODY"}]}]}
'@ | ConvertFrom-Json
    $plan.Sections[0].Content[3].Path = $image
    $plan
}

function New-PreviewTestDocument {
    param($Plan = (New-PreviewTestPlan))
    $path = Join-Path $script:PreviewTestRoot ([guid]::NewGuid().ToString('N') + '.hwpx')
    $generated = Invoke-HwpGenerate -NewDocument -Plan $Plan -OutputPath $path
    if ($generated.Status -ne 'PASS_WITH_WARNINGS') { throw ('Test HWPX generation failed: ' + ($generated | ConvertTo-Json -Depth 8)) }
    $path
}

function New-PreviewTestOutput {
    Join-Path $script:PreviewTestRoot ([guid]::NewGuid().ToString('N'))
}

function Update-PreviewTestPart {
    param([string]$Path, [string]$Part, [scriptblock]$Transform)
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $zip.GetEntry($Part)
        $old = ''
        if ($entry) {
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $old = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $entry.Delete()
        }
        $replacement = & $Transform $old
        $entry = $zip.CreateEntry($Part)
        $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write([string]$replacement) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}

Describe 'Actual generated HWPX to approximate HTML preview' {
    $script:PreviewSource = New-PreviewTestDocument
    $script:PreviewSourceHash = (Get-FileHash -LiteralPath $script:PreviewSource -Algorithm SHA256).Hash
    $script:PreviewResult = Export-HwpxPreview -LiteralPath $script:PreviewSource -OutputDirectory (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser

    It 'returns honest structured data and preserves the source SHA-256' {
        $script:PreviewResult.Errors -join ';' | Should Be ''
        $script:PreviewResult.Status | Should Be PASS_WITH_WARNINGS
        $script:PreviewResult.Data.Fidelity | Should Be approximate
        $script:PreviewResult.Data.NativeLayoutVerified | Should Be $false
        $script:PreviewResult.Data.PixelMatchVerified | Should Be $false
        $script:PreviewResult.Data.AllLayoutChecksPassed | Should Be $false
        $script:PreviewResult.Data.HancomPageCount | Should BeNullOrEmpty
        $script:PreviewResult.Data.InputSha256 | Should Be $script:PreviewSourceHash
        $script:PreviewResult.Data.InputSha256After | Should Be $script:PreviewSourceHash
        $script:PreviewResult.Data.SourcePreserved | Should Be $true
        (Get-FileHash -LiteralPath $script:PreviewSource -Algorithm SHA256).Hash | Should Be $script:PreviewSourceHash
        $report = Get-Content -LiteralPath $script:PreviewResult.Data.ReportPath -Raw | ConvertFrom-Json
        $report.Data.Fidelity | Should Be approximate
        $report.Data.NativeLayoutVerified | Should Be $false
    }
    It 'renders ordered body paragraphs, inline styles and real line/tab breaks' {
        $html = Get-Content -LiteralPath $script:PreviewResult.Data.HtmlPath -Raw
        $html | Should Match 'Preview title'
        $html | Should Match ' and body'
        $html | Should Match 'line one<br>line two&#9;end'
        $html | Should Match 'font-size:18pt;'
        $html | Should Match 'font-weight:bold;'
        $html | Should Match 'font-style:italic;'
        $html | Should Match 'color:#123456;'
        $html | Should Match 'text-decoration:underline;'
        $html | Should Match 'text-align:center;'
        $html.IndexOf('Preview title') | Should BeLessThan $html.IndexOf('LANDSCAPE BODY')
        $html.IndexOf('LANDSCAPE BODY') | Should BeLessThan $html.IndexOf('A5 BODY')
    }
    It 'renders real merged cells exactly once with rowspan and colspan' {
        $html = Get-Content -LiteralPath $script:PreviewResult.Data.HtmlPath -Raw
        $html | Should Match '<td rowspan="2" colspan="2"'
        ([regex]::Matches($html,'<td ')).Count | Should Be 6
        ([regex]::Matches($html,'MERGED ONCE')).Count | Should Be 1
        foreach ($text in @('R1C3','R2C3','R3C1','R3C2','R3C3')) { $html | Should Match $text }
        $html | Should Match 'background-color:#EEF2FF;'
        $script:PreviewResult.Data.Counts.Tables | Should Be 1
    }
    It 'embeds the exact raster bytes in a data URI with escaped alt text' {
        $html = Get-Content -LiteralPath $script:PreviewResult.Data.HtmlPath -Raw
        $match = [regex]::Match($html,'src="data:image/png;base64,([^"]+)"')
        $match.Success | Should Be $true
        $original = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'))
        $match.Groups[1].Value | Should Be ([Convert]::ToBase64String($original))
        $html | Should Match 'alt="sample &amp; safe"'
        $size = [regex]::Match($html,'width:(30[.0-9]*)mm;height:([0-9.]+)mm;')
        $size.Success | Should Be $true
        [Math]::Abs([double]::Parse($size.Groups[2].Value,[Globalization.CultureInfo]::InvariantCulture) - 20) | Should BeLessThan 0.01
        $script:PreviewResult.Data.Counts.Images | Should Be 1
    }
    It 'uses each section effective orientation, size and margins in named page CSS' {
        $html = Get-Content -LiteralPath $script:PreviewResult.Data.HtmlPath -Raw
        ([regex]::Matches($html,'<section ')).Count | Should Be 3
        $html | Should Match '@page hwpx0\{size:210[.0-9]*mm 297[.0-9]*mm;'
        $html | Should Match '@page hwpx1\{size:297[.0-9]*mm 210[.0-9]*mm;'
        $html | Should Match '@page hwpx2\{size:148[.0-9]*mm 210[.0-9]*mm;'
        $html | Should Match 'data-orientation="LANDSCAPE"'
        $margins = [regex]::Match($html,'@page hwpx0\{[^}]*margin:([0-9.]+)mm ([0-9.]+)mm ([0-9.]+)mm ([0-9.]+)mm;')
        $margins.Success | Should Be $true
        $expected = @(22,21,23,20)
        for ($i=0; $i -lt 4; $i++) {
            [Math]::Abs([double]::Parse($margins.Groups[$i+1].Value,[Globalization.CultureInfo]::InvariantCulture) - $expected[$i]) | Should BeLessThan 0.01
        }
        $html | Should Match 'page:hwpx1;'
        $script:PreviewResult.Data.Counts.Sections | Should Be 3
    }
    It 'emits a strict hash-authorized stylesheet CSP and no executable assets' {
        $html = Get-Content -LiteralPath $script:PreviewResult.Data.HtmlPath -Raw
        $policy = [Net.WebUtility]::HtmlDecode([regex]::Match($html,'http-equiv="Content-Security-Policy" content="([^"]+)"').Groups[1].Value)
        $style = [regex]::Match($html,'(?s)<style>(.*?)</style>').Groups[1].Value
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $digest = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($style))) } finally { $sha.Dispose() }
        $policy.Contains("style-src 'sha256-$digest'") | Should Be $true
        $policy | Should Match "default-src 'none'"
        $policy | Should Match "script-src 'none'"
        $policy | Should Match "connect-src 'none'"
        $policy | Should Match 'img-src data:'
        $html | Should Not Match '<script|<iframe|<object|<link|\sstyle=|\son\w+=|\shref='
        $html | Should Not Match 'src="(?:https?:|file:|//)'
        $policy | Should Not Match 'unsafe-inline|unsafe-eval'
    }
    It 'returns HTML plus warning and a null PDF path for an explicitly missing browser' {
        Test-Path -LiteralPath $script:PreviewResult.Data.HtmlPath | Should Be $true
        Test-Path -LiteralPath $script:PreviewResult.Data.ReportPath | Should Be $true
        $script:PreviewResult.Data.PdfPath | Should BeNullOrEmpty
        $script:PreviewResult.Data.BrowserMode | Should Be 'not-run'
        $script:PreviewResult.Warnings -join ' ' | Should Match 'No supported local Chromium/Edge'
        Test-Path -LiteralPath (Join-Path (Split-Path $script:PreviewResult.Data.HtmlPath) 'preview.pdf') | Should Be $false
        $report = Get-Content -LiteralPath $script:PreviewResult.Data.ReportPath -Raw | ConvertFrom-Json
        $report.Data.PdfPath | Should BeNullOrEmpty
    }
}

Describe 'Untrusted HWPX content and output preservation' {
    It 'escapes injected body, image alt text and CSS font strings without losing literal text' {
        $hostile = '<script>alert("x")</script><img src="https://example.invalid/a" onerror="alert(1)">& literal'
        $plan = New-PreviewTestPlan
        $plan.Sections[0].Content[0].Runs[0].Text = $hostile
        $plan.Sections[0].Content[3].AltText = $hostile
        $path = New-PreviewTestDocument $plan
        Update-PreviewTestPart $path 'Contents/header.xml' {
            param($old)
            [xml]$xml = $old
            foreach ($font in $xml.SelectNodes("//*[local-name()='font']")) { $font.SetAttribute('face', '");}body{background:url(https://example.invalid/)}/*</style><script>bad</script>') }
            $xml.OuterXml
        }
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $html = Get-Content -LiteralPath $result.Data.HtmlPath -Raw
        $html.Contains([Net.WebUtility]::HtmlEncode($hostile)) | Should Be $true
        $html | Should Not Match '<script|onerror="|background:url\(|<img src="https:'
        ([regex]::Matches($html,'</style>')).Count | Should Be 1
        $html | Should Match 'font-family:"\\22 '
    }
    It 'omits external image references without fetching or placing their URL in HTML' {
        $path = New-PreviewTestDocument
        Update-PreviewTestPart $path 'Contents/content.hpf' { param($old) $old -replace 'href="BinData/[^"]+"','href="https://example.invalid/private.png"' }
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $html = Get-Content -LiteralPath $result.Data.HtmlPath -Raw
        $html | Should Not Match 'example.invalid|<img '
        $result.Warnings -join ' ' | Should Match 'external.*image omitted'
    }
    It 'omits SVG payloads even when the manifest calls them PNG images' {
        $path = New-PreviewTestDocument
        Update-PreviewTestPart $path 'BinData/image1.PNG' { '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' }
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        (Get-Content -LiteralPath $result.Data.HtmlPath -Raw) | Should Not Match '<img |<svg|<script'
        $result.Warnings -join ' ' | Should Match 'unsupported image omitted'
    }
    It 'reports unsupported objects and features rather than claiming full layout support' {
        $plan = New-PreviewTestPlan
        $plan.Sections[0].Content[3] | Add-Member NoteProperty rotation 90
        $path = New-PreviewTestDocument $plan
        Update-PreviewTestPart $path 'Contents/section0.xml' {
            param($old)
            [xml]$xml = $old
            $run = $xml.SelectSingleNode("//*[local-name()='run']")
            $equation = $xml.CreateElement('hp','equation',$run.NamespaceURI)
            $equation.InnerText = '<not-html>'
            $null = $run.AppendChild($equation)
            $ole = $xml.CreateElement('hp','ole',$run.NamespaceURI)
            $null = $run.AppendChild($ole)
            $column = $xml.SelectSingleNode("//*[local-name()='colPr']")
            if ($column) { $column.SetAttribute('colCount','2') }
            $xml.OuterXml
        }
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $result.Warnings -join ' ' | Should Match 'equation'
        $result.Warnings -join ' ' | Should Match 'ole'
        $result.Warnings -join ' ' | Should Match 'rotation'
        $result.Warnings -join ' ' | Should Match 'Column layout'
        (Get-Content -LiteralPath $result.Data.HtmlPath -Raw) | Should Match '\[Unsupported: equation\]'
    }
    It 'blocks path traversal and duplicate ZIP entries before writing output' {
        foreach ($part in @('../outside.xml','CONTENTS/SECTION0.XML')) {
            $path = New-PreviewTestDocument
            Update-PreviewTestPart $path $part { '<malicious/>' }
            $output = New-PreviewTestOutput
            $result = Export-HwpxPreview $path $output -BrowserPath $script:MissingPreviewBrowser
            $result.Status | Should Be BLOCKED
            $result.Data.SourcePreserved | Should Be $true
            Test-Path -LiteralPath $output | Should Be $false
        }
    }
    It 'blocks DTD/entity processing in body and manifest XML' {
        foreach ($part in @('Contents/section0.xml','Contents/content.hpf')) {
            $path = New-PreviewTestDocument
            Update-PreviewTestPart $path $part {
                param($old)
                ($old -replace '<\?xml[^>]+\?>','') -replace '^', '<!DOCTYPE bad [<!ENTITY xxe SYSTEM "file:///C:/Windows/win.ini">]>'
            }
            $output = New-PreviewTestOutput
            $result = Export-HwpxPreview $path $output -BrowserPath $script:MissingPreviewBrowser
            $result.Status | Should Be BLOCKED
            Test-Path -LiteralPath $output | Should Be $false
        }
    }
    It 'blocks signed or script-bearing packages' {
        foreach ($part in @('META-INF/signatures.xml','Scripts/default.js')) {
            $path = New-PreviewTestDocument
            Update-PreviewTestPart $path $part { '<protected/>' }
            $output = New-PreviewTestOutput
            $result = Export-HwpxPreview $path $output -BrowserPath $script:MissingPreviewBrowser
            $result.Status | Should Be BLOCKED
            $result.Errors -join ' ' | Should Match 'Protected, signed or active-content'
            Test-Path -LiteralPath $output | Should Be $false
        }
    }
    It 'preserves existing HTML, PDF and report files and creates nothing else' {
        foreach ($name in @('preview.html','preview.pdf','preview-report.json')) {
            $output = New-PreviewTestOutput
            $null = [IO.Directory]::CreateDirectory($output)
            $existing = Join-Path $output $name
            [IO.File]::WriteAllText($existing,'original sentinel')
            $result = Export-HwpxPreview $script:PreviewSource $output -BrowserPath $script:MissingPreviewBrowser
            $result.Status | Should Be BLOCKED
            [IO.File]::ReadAllText($existing) | Should Be 'original sentinel'
            @(Get-ChildItem -LiteralPath $output -Force).Count | Should Be 1
            $result.Data.HtmlPath | Should BeNullOrEmpty
            $result.Data.SourcePreserved | Should Be $true
        }
    }
    It 'rejects malformed merged table grids without silently inventing cells' {
        $path = New-PreviewTestDocument
        Update-PreviewTestPart $path 'Contents/section0.xml' { param($old) $old -replace 'rowSpan="2"','rowSpan="3"' }
        $output = New-PreviewTestOutput
        $result = Export-HwpxPreview $path $output -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be BLOCKED
        $result.Errors -join ' ' | Should Match 'Overlapping'
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'returns structured failure for a missing input without creating output' {
        $output = New-PreviewTestOutput
        $result = Export-HwpxPreview (Join-Path $script:PreviewTestRoot 'not-a-document.hwpx') $output -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be BLOCKED
        $result.Errors.Count | Should BeGreaterThan 0
        $result.Data.Fidelity | Should Be approximate
        Test-Path -LiteralPath $output | Should Be $false
    }
    It 'preserves non-ASCII body text and applies explicit page breaks and blank-paragraph sizing' {
        $plan = '{"version":"2.0","content":[{"type":"paragraph","text":"\uD55C\uAE00 \u6587\u5B57"},{"type":"paragraph","text":"","textStyle":{"fontSizePt":6}},{"type":"page-break"},{"type":"paragraph","text":"AFTER PAGE BREAK"}]}' | ConvertFrom-Json
        $path = New-PreviewTestDocument $plan
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $html = [IO.File]::ReadAllText($result.Data.HtmlPath)
        ([Net.WebUtility]::HtmlDecode($html)).Contains($plan.Content[0].Text) | Should Be $true
        $html | Should Match 'font-size:6pt;'
        $html | Should Match 'break-before:page;'
        $html | Should Match 'AFTER PAGE BREAK'
    }
    It 'does not start a browser when an explicit non-browser executable is supplied' {
        $path = Join-Path $script:PreviewTestRoot 'not-a-browser.exe'
        [IO.File]::WriteAllText($path,'not executable')
        $result = Export-HwpxPreview $script:PreviewSource (New-PreviewTestOutput) -BrowserPath $path
        $result.Status | Should Be PASS_WITH_WARNINGS
        $result.Data.BrowserMode | Should Be 'not-run'
        $result.Data.PdfPath | Should BeNullOrEmpty
    }
}

Describe 'Headless browser failure contract' {
    It 'keeps HTML and reports a browser timeout without inventing a PDF' {
        Mock -ModuleName HwpPreview Resolve-PreviewBrowser { 'C:\synthetic\msedge.exe' }
        Mock -ModuleName HwpPreview Invoke-PreviewBrowser { throw 'Headless browser timed out after 30 seconds.' }
        $result = Export-HwpxPreview $script:PreviewSource (New-PreviewTestOutput)
        $result.Status | Should Be PASS_WITH_WARNINGS
        Test-Path -LiteralPath $result.Data.HtmlPath | Should Be $true
        $result.Data.PdfPath | Should BeNullOrEmpty
        $result.Warnings -join ' ' | Should Match 'PDF unavailable:.*timed out'
        (Get-Content -LiteralPath $result.Data.ReportPath -Raw | ConvertFrom-Json).Data.PdfPath | Should BeNullOrEmpty
    }
}

Describe 'Preview retained cleanup reporting' {
    It 'keeps completed renderer output and reports a retained directory in both result and report' {
        $source = New-PreviewTestDocument
        Mock -ModuleName HwpPreview Resolve-PreviewBrowser { 'C:\synthetic\msedge.exe' }
        Mock -ModuleName HwpPreview Invoke-PreviewBrowser {
            param($Browser,$HtmlPath,$WorkDirectory)
            # Synthetic renderer output; actual PDF generation is covered by the opt-in test.
            $path = Join-Path $WorkDirectory 'printed.pdf'
            [IO.File]::WriteAllText($path,'%PDF-1.4 synthetic renderer fixture %%EOF')
            $path
        }
        Mock -ModuleName HwpPreview Remove-PreviewWorkDirectory { $false }
        $result = Export-HwpxPreview $source (New-PreviewTestOutput)
        $result.Status | Should Be PASS_WITH_WARNINGS
        [IO.File]::Exists($result.Data.PdfPath) | Should Be $true
        [IO.File]::ReadAllText($result.Data.PdfPath) | Should Be '%PDF-1.4 synthetic renderer fixture %%EOF'
        $retained = $result.Data.BrowserTemporaryDirectory
        $retained | Should Not BeNullOrEmpty
        [IO.Directory]::Exists($retained) | Should Be $true
        $result.Warnings -join ' ' | Should Match ([regex]::Escape('Temporary browser data could not be removed: ' + $retained))
        $report = [IO.File]::ReadAllText($result.Data.ReportPath) | ConvertFrom-Json
        $report.Data.PdfPath | Should Be $result.Data.PdfPath
        $report.Data.BrowserTemporaryDirectory | Should Be $retained
        $report.Warnings -join ' ' | Should Match ([regex]::Escape($retained))
    }
}

Describe 'Preview local path boundary' {
    $script:PreviewBoundarySource = New-PreviewTestDocument
    It 'rejects raw UNC outputs before resolving or accessing any filesystem path' {
        Mock -ModuleName HwpPreview Resolve-HwpLiteralPath { throw 'Unexpected filesystem access before network-path rejection.' }
        foreach ($path in @('\\server.invalid\share\preview','//server.invalid/share/preview','\\?\UNC\server.invalid\share\preview','FileSystem::\\server.invalid\share\preview')) {
            $result = Export-HwpxPreview $script:PreviewBoundarySource $path -BrowserPath $script:MissingPreviewBrowser
            $result.Status | Should Be BLOCKED
            $result.Errors -join ' ' | Should Match 'Network/UNC paths are not allowed'
            $result.Errors -join ' ' | Should Not Match 'Unexpected filesystem access'
            $result.Data.HtmlPath | Should BeNullOrEmpty
        }
    }
    It 'rejects raw UNC inputs before the shared input resolver can access them' {
        Mock -ModuleName HwpPreview Resolve-HwpLiteralPath { throw 'Unexpected filesystem access before network-path rejection.' }
        foreach ($path in @('\\server.invalid\share\input.hwpx','//server.invalid/share/input.hwpx','FileSystem::\\server.invalid\share\input.hwpx')) {
            $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
            $result.Status | Should Be BLOCKED
            $result.Errors -join ' ' | Should Match 'Network/UNC paths are not allowed'
            $result.Errors -join ' ' | Should Not Match 'Unexpected filesystem access'
        }
    }
}

Describe 'Preview output ancestor boundary' {
    It 'rejects a Windows output ancestor junction before creating files in its target' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $root = New-PreviewTestOutput
        $target = Join-Path $root 'target'
        $link = Join-Path $root 'link'
        $null = [IO.Directory]::CreateDirectory($target)
        $null = New-Item -ItemType Junction -Path $link -Target $target
        $source = New-PreviewTestDocument
        $result = Export-HwpxPreview $source (Join-Path $link 'preview') -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be BLOCKED
        $result.Errors -join ' ' | Should Match 'reparse point'
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should Be 0
    }
    It 'allows local Unix directory symlinks for both input and output like macOS var folders' -Skip:([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $source = New-PreviewTestDocument
        $root = New-PreviewTestOutput
        $target = Join-Path $root 'target'
        $outputLink = Join-Path $root 'output-link'
        $sourceLink = Join-Path $root 'source-link'
        $null = [IO.Directory]::CreateDirectory($target)
        $null = New-Item -ItemType SymbolicLink -Path $outputLink -Target $target
        $null = New-Item -ItemType SymbolicLink -Path $sourceLink -Target $script:PreviewTestRoot
        $aliasSource = Join-Path $sourceLink ([IO.Path]::GetFileName($source))
        $result = Export-HwpxPreview $aliasSource (Join-Path $outputLink 'preview') -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $result.Data.SourcePreserved | Should Be $true
        [IO.File]::Exists((Join-Path $target 'preview/preview.html')) | Should Be $true
        $result.Data.PdfPath | Should BeNullOrEmpty
    }
}

Describe 'Preview follows manifest section order' {
    It 'renders section1 before section0 when that is the manifest spine order' {
        $path = New-PreviewTestDocument
        Update-PreviewTestPart $path 'Contents/content.hpf' {
            param($old)
            [xml]$xml = $old
            $spine = $xml.SelectSingleNode("//*[local-name()='spine']")
            $first = $spine.SelectSingleNode("*[@idref='section0']")
            $second = $spine.SelectSingleNode("*[@idref='section1']")
            $null = $spine.RemoveChild($second)
            $null = $spine.InsertBefore($second,$first)
            $xml.OuterXml
        }
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $html = [IO.File]::ReadAllText($result.Data.HtmlPath)
        $html.IndexOf('LANDSCAPE BODY') | Should BeLessThan $html.IndexOf('Preview title')
        $html.IndexOf('Preview title') | Should BeLessThan $html.IndexOf('A5 BODY')
        [regex]::Match($html,'<section[^>]*data-orientation="([^"]+)"').Groups[1].Value | Should Be LANDSCAPE
    }
    It 'renders a manifest section with a nonstandard XML filename' {
        $path = New-PreviewTestDocument
        $zip = [IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Update)
        try {
            $entry = $zip.GetEntry('Contents/section1.xml')
            $stream = $entry.Open()
            $memory = [IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
            $entry.Delete()
            $stream = $zip.CreateEntry('Contents/appendix-landscape.xml').Open()
            try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        } finally { $zip.Dispose() }
        Update-PreviewTestPart $path 'Contents/content.hpf' { param($old) $old.Replace('Contents/section1.xml','Contents/appendix-landscape.xml') }
        $result = Export-HwpxPreview $path (New-PreviewTestOutput) -BrowserPath $script:MissingPreviewBrowser
        $result.Status | Should Be PASS_WITH_WARNINGS
        $result.Data.Counts.Sections | Should Be 3
        $html = [IO.File]::ReadAllText($result.Data.HtmlPath)
        ([regex]::Matches($html,'LANDSCAPE BODY')).Count | Should Be 1
        $html.IndexOf('Preview title') | Should BeLessThan $html.IndexOf('LANDSCAPE BODY')
        $html.IndexOf('LANDSCAPE BODY') | Should BeLessThan $html.IndexOf('A5 BODY')
    }
}

Describe 'Preview cleanup synchronization' {
    It 'waits through a transient profile lock lasting longer than one second' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        if ($null -eq ('PreviewTestDelayedFileLock' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public sealed class PreviewTestDelayedFileLock : IDisposable {
    FileStream stream;
    Timer timer;
    public PreviewTestDelayedFileLock(string path) {
        stream = new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None);
        timer = new Timer(_ => stream.Dispose(),null,1800,Timeout.Infinite);
    }
    public void Dispose() { timer.Dispose(); stream.Dispose(); }
}
'@
        }
        $work = Join-Path $script:PreviewTestRoot ('.hwpx-preview-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($work)
        $fileLock = [PreviewTestDelayedFileLock]::new((Join-Path $work 'held.lock'))
        try {
            $removed = & (Get-Module HwpPreview) { param($p,$parent) Remove-PreviewWorkDirectory $p $parent } $work $script:PreviewTestRoot
            $removed | Should Be $true
            [IO.Directory]::Exists($work) | Should Be $false
        } finally { $fileLock.Dispose() }
    }
    It 'returns within the retry budget and retains a profile locked for the entire attempt' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $work = Join-Path $script:PreviewTestRoot ('.hwpx-preview-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($work)
        $fileLock = [IO.File]::Open((Join-Path $work 'persistent.lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        try {
            $removed = & (Get-Module HwpPreview) { param($p,$parent) Remove-PreviewWorkDirectory $p $parent } $work $script:PreviewTestRoot
            $removed | Should Be $false
            $timer.Elapsed.TotalSeconds | Should BeLessThan 10
            [IO.Directory]::Exists($work) | Should Be $true
        } finally { $fileLock.Dispose() }
    }
}

Describe 'Opt-in local Edge real headless print (no UI or COM)' {
    It 'prints three consecutive PDFs with verified shutdown, no UI and truthful cleanup results' -Skip:(-not $RunHeadlessBrowser) {
        Import-Module (Join-Path $PSScriptRoot 'WindowActivityMonitor.psm1') -Force
        $browser = Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'
        Test-Path -LiteralPath $browser | Should Be $true
        $monitor = New-HwpSilentActivityMonitor
        $monitor.Start()
        try {
            $results = @(for ($i=0; $i -lt 3; $i++) {
                Export-HwpxPreview $script:PreviewSource (New-PreviewTestOutput) -BrowserPath $browser
            })
        }
        finally { $monitor.Stop() }
        try {
            foreach ($result in $results) {
                $result.Status | Should Be PASS_WITH_WARNINGS
                $result.Data.PdfPath | Should Not BeNullOrEmpty
                [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($result.Data.PdfPath),0,5) | Should Be '%PDF-'
                $result.Data.BrowserMode | Should Be headless
                $result.Data.NativeLayoutVerified | Should Be $false
                $result.Data.SourcePreserved | Should Be $true
                $result.Data.BrowserShutdownVerified | Should Be $true
                $remaining = @(Get-ChildItem -LiteralPath (Split-Path $result.Data.HtmlPath) -Directory -Force -Filter '.hwpx-preview-*')
                $retained = $result.Data.BrowserTemporaryDirectory
                if ($retained) {
                    [IO.Directory]::Exists($retained) | Should Be $true
                    $remaining.Count | Should Be 1
                    $remaining[0].FullName | Should Be $retained
                    $result.Warnings -join ' ' | Should Match ([regex]::Escape('Temporary browser data could not be removed: ' + $retained))
                } else {
                    $remaining.Count | Should Be 0
                    $result.Warnings -join ' ' | Should Not Match 'Temporary browser data could not be removed:'
                }
                $report = [IO.File]::ReadAllText($result.Data.ReportPath) | ConvertFrom-Json
                $report.Data.BrowserTemporaryDirectory | Should Be $retained
                ($report.Warnings -join '\n') | Should Be ($result.Warnings -join '\n')
            }
            @($monitor.NewVisibleWindowHandles).Count | Should Be 0
            @($monitor.NewHwpProcessIds).Count | Should Be 0
            @($monitor.NewWinwordProcessIds).Count | Should Be 0
            $monitor.ForegroundChanged | Should Be $false
        } finally { $monitor.Dispose() }
    }
}
