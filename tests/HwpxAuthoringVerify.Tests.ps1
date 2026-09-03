$verifyLib = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib'
$verifyModule = Join-Path $verifyLib 'HwpAuthoringVerify.psm1'
if (Test-Path -LiteralPath $verifyModule) { Import-Module $verifyModule -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Literal, independently calculated HWPUNIT fixtures. No writer computes expectations.
function New-ContractFixture {
    param([string]$Path)
    $hp = 'http://www.hancom.co.kr/hwpml/2011/paragraph'
    $hh = 'http://www.hancom.co.kr/hwpml/2011/head'
    $hs = 'http://www.hancom.co.kr/hwpml/2011/section'
    $hc = 'http://www.hancom.co.kr/hwpml/2011/core'
    $imagePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
    $plan = @'
{"version":"1.0","sourceVersion":"2.0","sections":[
 {"document":{},"content":[
  {"type":"field","name":"first","value":"A"},
  {"type":"table","rows":2,"columns":3,"widthMm":100,"columnWidthsMm":[33.333,33.333,33.334],"rowHeightsMm":[10,12],"repeatHeader":true,"cells":[{"row":1,"column":1,"colSpan":2,"text":"header"},{"row":2,"column":1,"text":"body"},{"row":2,"column":2,"colSpan":2,"text":"merged"}]},
  {"type":"image","path":"","widthMm":20,"heightMm":10}]},
 {"document":{"page":{"orientation":"LANDSCAPE","widthMm":210,"heightMm":148,"gutterType":"LEFT_ONLY","margins":{"leftMm":10,"rightMm":10,"topMm":5,"bottomMm":6,"headerMm":7,"footerMm":8,"gutterMm":2}},"columns":{"count":2,"gapMm":8,"widthsMm":[80,100]}},"content":[
  {"type":"field","name":"second","value":"B"},
  {"type":"table","rows":1,"columns":2,"cells":[]}]}
]}
'@ | ConvertFrom-Json
    $plan.sections[0].content[2].path = $imagePath
    $plan | Add-Member NoteProperty content @($plan.sections | ForEach-Object { $_.content })
    $fonts = (@('HANGUL','LATIN','HANJA','JAPANESE','OTHER','SYMBOL','USER') | ForEach-Object {
        '<hh:fontface lang="{0}"><hh:font id="0" face="fixture"/></hh:fontface>' -f $_
    }) -join ''
    $header = '<hh:head xmlns:hh="'+$hh+'" secCnt="2"><hh:refList><hh:fontfaces>'+ $fonts +'</hh:fontfaces><hh:charProperties><hh:charPr id="0"><hh:fontRef hangul="0" latin="0" hanja="0" japanese="0" other="0" symbol="0" user="0"/></hh:charPr></hh:charProperties><hh:paraProperties><hh:paraPr id="0" tabPrIDRef="0"><hh:heading type="NONE" idRef="0"/></hh:paraPr></hh:paraProperties><hh:borderFills><hh:borderFill id="1"/></hh:borderFills><hh:styles><hh:style id="0" charPrIDRef="0" paraPrIDRef="0" nextStyleIDRef="0"/></hh:styles><hh:tabProperties><hh:tabPr id="0"/></hh:tabProperties><hh:numberings><hh:numbering id="1"/></hh:numberings><hh:bullets><hh:bullet id="1"/></hh:bullets></hh:refList></hh:head>'
    $start = '<hs:sec xmlns:hs="'+$hs+'" xmlns:hp="'+$hp+'" xmlns:hc="'+$hc+'"><hp:p paraPrIDRef="0" styleIDRef="0"><hp:run charPrIDRef="0">'
    $end = '</hp:run></hp:p></hs:sec>'
    $page0 = '<hp:secPr><hp:pagePr landscape="NARROWLY" width="59528" height="84189" gutterType="LEFT_ONLY"><hp:margin left="4252" right="4252" top="2835" bottom="2835" header="4252" footer="4252" gutter="0"/></hp:pagePr></hp:secPr><hp:ctrl><hp:colPr colCount="1" sameSz="1" sameGap="0"/></hp:ctrl>'
    $page1 = '<hp:secPr><hp:pagePr landscape="WIDELY" width="41953" height="59528" gutterType="LEFT_ONLY"><hp:margin left="2835" right="2835" top="1417" bottom="1701" header="1984" footer="2268" gutter="567"/></hp:pagePr></hp:secPr><hp:ctrl><hp:colPr colCount="2" sameSz="0" sameGap="2268"><hp:colSz width="22677" gap="2268"/><hp:colSz width="28346" gap="0"/></hp:colPr></hp:ctrl>'
    $cell = '<hp:tc header="{0}" borderFillIDRef="1"><hp:cellAddr rowAddr="{1}" colAddr="{2}"/><hp:cellSpan rowSpan="{3}" colSpan="{4}"/><hp:cellSz width="{5}" height="{6}"/></hp:tc>'
    $table0 = '<hp:tbl rowCnt="2" colCnt="3" repeatHeader="1"><hp:sz width="28346" height="6237"/><hp:tr>'+($cell -f 1,0,0,1,2,18898,2835)+($cell -f 1,0,2,1,1,9448,2835)+'</hp:tr><hp:tr>'+($cell -f 0,1,0,1,1,9449,3402)+($cell -f 0,1,1,1,2,18897,3402)+'</hp:tr></hp:tbl>'
    $table1 = '<hp:tbl rowCnt="1" colCnt="2" repeatHeader="0"><hp:sz width="22677" height="1800"/><hp:tr>'+($cell -f 0,0,0,1,1,11338,1800)+($cell -f 0,0,1,1,1,11339,1800)+'</hp:tr></hp:tbl>'
    $picture = '<hp:pic><hp:orgSz width="5669" height="2835"/><hp:curSz width="5669" height="2835"/><hc:img binaryItemIDRef="picture"/><hp:sz width="5669" height="2835"/></hp:pic>'
    $field = '<hp:ctrl><hp:fieldBegin id="{0}" fieldid="{0}"/></hp:ctrl><hp:t>value</hp:t><hp:ctrl><hp:fieldEnd beginIDRef="{0}" fieldid="{0}"/></hp:ctrl>'
    $parts = [ordered]@{
        'Contents/content.hpf' = '<opf:package xmlns:opf="http://www.idpf.org/2007/opf/"><opf:manifest><opf:item id="header" href="Contents/header.xml"/><opf:item id="section0" href="Contents/section0.xml"/><opf:item id="section1" href="Contents/section1.xml"/><opf:item id="picture" href="BinData/picture.PNG" isEmbeded="1"/></opf:manifest><opf:spine><opf:itemref idref="header"/><opf:itemref idref="section0"/><opf:itemref idref="section1"/></opf:spine></opf:package>'
        'Contents/header.xml' = $header
        'Contents/section0.xml' = $start+$page0+($field -f 101)+$table0+$picture+$end
        'Contents/section1.xml' = $start+$page1+($field -f 201)+$table1+$end
    }
    # Independently fixed ZIP fixture: local header + stored ASCII mimetype + directory.
    [IO.File]::WriteAllBytes($Path,[Convert]::FromBase64String('UEsDBBQAAAAAAAAAISiC8EFHEwAAABMAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9od3AremlwUEsBAhQAFAAAAAAAAAAhKILwQUcTAAAAEwAAAAgAAAAAAAAAAAAAAAAAAAAAAG1pbWV0eXBlUEsFBgAAAAABAAEANgAAADkAAAAAAA=='))
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($name in $parts.Keys) {
            $stream = $zip.CreateEntry($name).Open()
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try { $writer.Write($parts[$name]) } finally { $writer.Dispose() }
        }
        $stream = $zip.CreateEntry('BinData/picture.PNG').Open()
        try { $bytes = [IO.File]::ReadAllBytes($imagePath); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    } finally { $zip.Dispose() }
    $plan
}

function Edit-ContractFixture {
    param([string]$Path, [string]$Entry, [scriptblock]$Edit)
    $zip = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $entryObject = $zip.GetEntry($Entry)
        $reader = [IO.StreamReader]::new($entryObject.Open())
        try { [xml]$doc = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $ns = [Xml.XmlNamespaceManager]::new($doc.NameTable)
        $ns.AddNamespace('hp','http://www.hancom.co.kr/hwpml/2011/paragraph')
        $ns.AddNamespace('hh','http://www.hancom.co.kr/hwpml/2011/head')
        $ns.AddNamespace('opf','http://www.idpf.org/2007/opf/')
        $ns.AddNamespace('hc','http://www.hancom.co.kr/hwpml/2011/core')
        & $Edit $doc $ns | Out-Null
        $entryObject.Delete()
        $writer = [IO.StreamWriter]::new($zip.CreateEntry($Entry).Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write($doc.OuterXml) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}

Describe 'Bounded independent generated HWPX contract verifier' {
    It 'exports the read-only contract API' {
        @(Get-Command Test-HwpxGeneratedContract -ErrorAction SilentlyContinue).Count | Should Be 1
    }
    if (Get-Command Test-HwpxGeneratedContract -ErrorAction SilentlyContinue) {
        It 'accepts hand-checked mixed sections and preserves ZIP, assets and Plan' {
            $path = Join-Path $TestDrive 'literal [mixed].hwpx'
            $plan = New-ContractFixture $path
            $before = (Get-FileHash -LiteralPath $path).Hash
            $assetBefore = (Get-FileHash -LiteralPath $plan.content[2].path).Hash
            $jsonBefore = $plan | ConvertTo-Json -Depth 40 -Compress
            $r = Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
            $r.Status | Should Be PASS
            $r.Errors.Count | Should Be 0
            ($r.Errors -is [string[]]) | Should Be $true
            ($r.Checks -gt 50) | Should Be $true
            $r.NativeLayoutVerified | Should Be $false
            (Get-FileHash -LiteralPath $path).Hash | Should Be $before
            (Get-FileHash -LiteralPath $plan.content[2].path).Hash | Should Be $assetBefore
            ($plan | ConvertTo-Json -Depth 40 -Compress) | Should Be $jsonBefore
        }

        $corruptions = @(
            @{Name='page direction'; Entry='Contents/section1.xml'; XPath='//hp:pagePr'; Attr='landscape'; Value='NARROWLY'; Error='landscape'},
            @{Name='rotated stored dimensions'; Entry='Contents/section1.xml'; XPath='//hp:pagePr'; Attr='width'; Value='59528'; Error='width'},
            @{Name='missing page height'; Entry='Contents/section0.xml'; XPath='//hp:pagePr'; Attr='height'; Value=''; Error='height'},
            @{Name='margin'; Entry='Contents/section0.xml'; XPath='//hp:pagePr/hp:margin'; Attr='left'; Value='4251'; Error='left'},
            @{Name='gutter'; Entry='Contents/section1.xml'; XPath='//hp:pagePr/hp:margin'; Attr='gutter'; Value='0'; Error='gutter'},
            @{Name='gutter type'; Entry='Contents/section1.xml'; XPath='//hp:pagePr'; Attr='gutterType'; Value='TOP_ONLY'; Error='gutterType'},
            @{Name='column count'; Entry='Contents/section1.xml'; XPath='//hp:colPr'; Attr='colCount'; Value='1'; Error='colCount'},
            @{Name='column gap'; Entry='Contents/section1.xml'; XPath='//hp:colPr'; Attr='sameGap'; Value='2267'; Error='sameGap'},
            @{Name='custom column width'; Entry='Contents/section1.xml'; XPath='//hp:colSz[1]'; Attr='width'; Value='22678'; Error='colSz'},
            @{Name='style reference'; Entry='Contents/section0.xml'; XPath='//hp:p'; Attr='styleIDRef'; Value='999'; Error='styleIDRef'},
            @{Name='character reference'; Entry='Contents/section0.xml'; XPath='//hp:run'; Attr='charPrIDRef'; Value='999'; Error='charPrIDRef'},
            @{Name='paragraph reference'; Entry='Contents/section0.xml'; XPath='//hp:p'; Attr='paraPrIDRef'; Value='999'; Error='paraPrIDRef'},
            @{Name='font reference by language'; Entry='Contents/header.xml'; XPath='//hh:fontRef'; Attr='latin'; Value='999'; Error='font'},
            @{Name='next style reference'; Entry='Contents/header.xml'; XPath='//hh:style'; Attr='nextStyleIDRef'; Value='999'; Error='nextStyleIDRef'},
            @{Name='tab reference'; Entry='Contents/header.xml'; XPath='//hh:paraPr'; Attr='tabPrIDRef'; Value='999'; Error='tabPrIDRef'},
            @{Name='border reference'; Entry='Contents/section0.xml'; XPath='//hp:tc'; Attr='borderFillIDRef'; Value='999'; Error='borderFillIDRef'},
            @{Name='header section count'; Entry='Contents/header.xml'; XPath='/hh:head'; Attr='secCnt'; Value='1'; Error='secCnt'},
            @{Name='unknown spine target'; Entry='Contents/content.hpf'; XPath='//opf:itemref[2]'; Attr='idref'; Value='missing'; Error='spine'},
            @{Name='missing manifest entry'; Entry='Contents/content.hpf'; XPath='//opf:item[@id="section1"]'; Attr='href'; Value='Contents/missing.xml'; Error='manifest'},
            @{Name='table rows'; Entry='Contents/section0.xml'; XPath='//hp:tbl'; Attr='rowCnt'; Value='3'; Error='rowCnt'},
            @{Name='table columns'; Entry='Contents/section0.xml'; XPath='//hp:tbl'; Attr='colCnt'; Value='2'; Error='colCnt'},
            @{Name='table width'; Entry='Contents/section0.xml'; XPath='//hp:tbl/hp:sz'; Attr='width'; Value='28347'; Error='width'},
            @{Name='table column span'; Entry='Contents/section0.xml'; XPath='//hp:cellSpan'; Attr='colSpan'; Value='1'; Error='colSpan'},
            @{Name='table row span'; Entry='Contents/section0.xml'; XPath='//hp:cellSpan'; Attr='rowSpan'; Value='2'; Error='rowSpan'},
            @{Name='table cell address'; Entry='Contents/section0.xml'; XPath='//hp:cellAddr'; Attr='colAddr'; Value='1'; Error='cell'},
            @{Name='rounding residual'; Entry='Contents/section0.xml'; XPath='//hp:tr[1]/hp:tc[2]/hp:cellSz'; Attr='width'; Value='9449'; Error='width'},
            @{Name='explicit cell height'; Entry='Contents/section0.xml'; XPath='//hp:cellSz'; Attr='height'; Value='1800'; Error='height'},
            @{Name='default cell minimum'; Entry='Contents/section1.xml'; XPath='//hp:cellSz'; Attr='height'; Value='1799'; Error='height'},
            @{Name='repeat header'; Entry='Contents/section0.xml'; XPath='//hp:tbl'; Attr='repeatHeader'; Value='0'; Error='repeatHeader'},
            @{Name='header cell marker'; Entry='Contents/section0.xml'; XPath='//hp:tc'; Attr='header'; Value='0'; Error='header'},
            @{Name='image size'; Entry='Contents/section0.xml'; XPath='//hp:pic/hp:sz'; Attr='width'; Value='5668'; Error='image'},
            @{Name='image current size'; Entry='Contents/section0.xml'; XPath='//hp:pic/hp:curSz'; Attr='height'; Value='2834'; Error='image'},
            @{Name='picture resource reference'; Entry='Contents/section0.xml'; XPath='//hc:img'; Attr='binaryItemIDRef'; Value='absent'; Error='image'},
            @{Name='unmatched field end'; Entry='Contents/section0.xml'; XPath='//hp:fieldEnd'; Attr='beginIDRef'; Value='999'; Error='field'},
            @{Name='mismatched field identity'; Entry='Contents/section0.xml'; XPath='//hp:fieldEnd'; Attr='fieldid'; Value='999'; Error='field'}
        )
        foreach ($case in $corruptions) {
            It ('rejects independently corrupted '+$case.Name) {
                $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('n')+'.hwpx')
                $plan = New-ContractFixture $path
                Edit-ContractFixture $path $case.Entry { param($doc,$ns) $doc.SelectSingleNode($case.XPath,$ns).SetAttribute($case.Attr,$case.Value) }
                $r = Test-HwpxGeneratedContract -LiteralPath $path -Plan $plan
                $r.Status | Should Be FAILED
                ($r.Errors -join ' ') | Should Match $case.Error
                $r.NativeLayoutVerified | Should Be $false
            }
        }
        foreach ($resource in @('charPr','paraPr','borderFill','style','tabPr','numbering','bullet')) {
            It ('rejects duplicate '+$resource+' IDs') {
                $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('n')+'.hwpx'); $plan=New-ContractFixture $path
                Edit-ContractFixture $path 'Contents/header.xml' { param($doc,$ns) $n=$doc.SelectSingleNode('//hh:'+$resource,$ns); $null=$n.ParentNode.AppendChild($n.CloneNode($true)) }
                $r=Test-HwpxGeneratedContract $path $plan
                $r.Status | Should Be FAILED
                ($r.Errors -join ' ') | Should Match ('duplicate.*'+$resource)
            }
        }
        It 'rejects duplicate field IDs even with separately matched ends across sections' {
            $path=Join-Path $TestDrive 'duplicate-fields.hwpx'; $plan=New-ContractFixture $path
            Edit-ContractFixture $path 'Contents/section1.xml' { param($doc,$ns)
                $b=$doc.SelectSingleNode('//hp:fieldBegin',$ns); $b.SetAttribute('id','101'); $b.SetAttribute('fieldid','101')
                $e=$doc.SelectSingleNode('//hp:fieldEnd',$ns); $e.SetAttribute('beginIDRef','101'); $e.SetAttribute('fieldid','101')
            }
            $r=Test-HwpxGeneratedContract $path $plan
            $r.Status | Should Be FAILED
            ($r.Errors -join ' ') | Should Match 'duplicate.*field'
        }
        foreach ($kind in @('spine order','missing section','missing field end','extra picture','V2 line cache','wrong namespace')) {
            It ('rejects '+$kind) {
                $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('n')+'.hwpx'); $plan=New-ContractFixture $path
                $entry=if($kind -eq 'spine order'){'Contents/content.hpf'}else{'Contents/section0.xml'}
                Edit-ContractFixture $path $entry { param($doc,$ns)
                    switch($kind) {
                        'spine order' { $a=$doc.SelectSingleNode('//opf:itemref[2]',$ns); $b=$doc.SelectSingleNode('//opf:itemref[3]',$ns); $a.SetAttribute('idref','section1');$b.SetAttribute('idref','section0') }
                        'missing field end' { $n=$doc.SelectSingleNode('//hp:fieldEnd',$ns);$null=$n.ParentNode.RemoveChild($n) }
                        'extra picture' { $n=$doc.SelectSingleNode('//hp:pic',$ns);$null=$n.ParentNode.AppendChild($n.CloneNode($true)) }
                        'V2 line cache' { $null=$doc.DocumentElement.AppendChild($doc.CreateElement('hp','linesegarray',$ns.LookupNamespace('hp'))) }
                        'wrong namespace' { $n=$doc.SelectSingleNode('//hp:pagePr',$ns);$bad=$doc.CreateElement('wrong','pagePr','urn:not-hwp');$null=$n.ParentNode.ReplaceChild($bad,$n) }
                    }
                }
                if($kind -eq 'missing section') { $z=[IO.Compression.ZipFile]::Open($path,'Update');try{$z.GetEntry('Contents/section1.xml').Delete()}finally{$z.Dispose()} }
                (Test-HwpxGeneratedContract $path $plan).Status | Should Be FAILED
            }
        }
        It 'rejects modified BinData bytes and preserves the corrupt input' {
            $path=Join-Path $TestDrive 'bytes.hwpx'; $plan=New-ContractFixture $path
            $z=[IO.Compression.ZipFile]::Open($path,'Update');try{$z.GetEntry('BinData/picture.PNG').Delete();$s=$z.CreateEntry('BinData/picture.PNG').Open();try{$s.WriteByte(42)}finally{$s.Dispose()}}finally{$z.Dispose()}
            $before=(Get-FileHash -LiteralPath $path).Hash
            $r=Test-HwpxGeneratedContract $path $plan
            $r.Status | Should Be FAILED
            ($r.Errors -join ' ') | Should Match 'SHA256'
            (Get-FileHash -LiteralPath $path).Hash | Should Be $before
        }
        It 'accepts namespace inheritance, aliases, repeated declarations and unused resources' {
            $path=Join-Path $TestDrive 'namespaces.hwpx'; $plan=New-ContractFixture $path
            Edit-ContractFixture $path 'Contents/section0.xml' {param($doc,$ns)
                foreach($n in $doc.SelectNodes('//hp:*',$ns)) {$n.Prefix='p'}
                $n=$doc.SelectSingleNode('//hp:tbl',$ns);$n.SetAttribute('xmlns:p',$ns.LookupNamespace('hp'))
            }
            Edit-ContractFixture $path 'Contents/header.xml' {param($doc,$ns)
                $n=$doc.SelectSingleNode('//hh:charPr',$ns).CloneNode($true);$n.SetAttribute('id','25');$null=$doc.SelectSingleNode('//hh:charProperties',$ns).AppendChild($n)
            }
            (Test-HwpxGeneratedContract $path $plan).Status | Should Be PASS
        }
        It 'allows V1 line caches and taller default table rows' {
            $path=Join-Path $TestDrive 'v1.hwpx'; $plan=New-ContractFixture $path; $plan.sourceVersion='1.0'
            Edit-ContractFixture $path 'Contents/section1.xml' {param($doc,$ns)
                $null=$doc.DocumentElement.AppendChild($doc.CreateElement('hp','linesegarray',$ns.LookupNamespace('hp')))
                foreach($n in $doc.SelectNodes('//hp:cellSz | //hp:tbl/hp:sz',$ns)) {$n.SetAttribute('height','2400')}
            }
            (Test-HwpxGeneratedContract $path $plan).Status | Should Be PASS
        }
        foreach($kind in @('DTD','duplicate entry','oversize XML','traversal href','foreign OPF namespace')) {
            It ('safely rejects '+$kind) {
                $path=Join-Path $TestDrive ([guid]::NewGuid().ToString('n')+'.hwpx'); $plan=New-ContractFixture $path
                if($kind -eq 'traversal href') {Edit-ContractFixture $path 'Contents/content.hpf' {param($doc,$ns) $doc.SelectSingleNode('//opf:item',$ns).SetAttribute('href','../outside.xml')}}
                else {
                    $z=[IO.Compression.ZipFile]::Open($path,'Update')
                    try {
                        $name='Contents/header.xml';if($kind -eq 'foreign OPF namespace'){$name='Contents/content.hpf'}
                        if($kind -ne 'duplicate entry') {$z.GetEntry($name).Delete()}
                        $s=$z.CreateEntry($name).Open();$w=[IO.StreamWriter]::new($s)
                        try {switch($kind) {
                            'DTD' {$w.Write('<!DOCTYPE head [<!ENTITY ext SYSTEM "file:///does-not-exist">]><hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head" secCnt="2">&ext;</hh:head>')}
                            'oversize XML' {$w.Write(' ' * (16MB+1))}
                            'duplicate entry' {$w.Write('<duplicate/>')}
                            'foreign OPF namespace' {$w.Write('<package xmlns="http://www.idpf.org/2007/opf"><manifest/><spine/></package>')}
                        }}finally{$w.Dispose()}
                    } finally {$z.Dispose()}
                }
                $r=Test-HwpxGeneratedContract $path $plan
                $r.Status | Should Be FAILED
                $r.NativeLayoutVerified | Should Be $false
            }
        }
        It 'returns a typed failure for missing input without creating it' {
            $path=Join-Path $TestDrive 'does-not-exist.hwpx'
            $r=Test-HwpxGeneratedContract $path ([pscustomobject]@{version='1.0';sourceVersion='2.0';sections=@()})
            $r.Status | Should Be FAILED
            ($r.Errors -is [string[]]) | Should Be $true
            Test-Path -LiteralPath $path | Should Be $false
        }
        It 'rejects a missing mimetype before promotion' {
            $path=Join-Path $TestDrive 'missing-mimetype.hwpx'
            $plan=New-ContractFixture $path
            $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Update)
            try { $zip.GetEntry('mimetype').Delete() } finally { $zip.Dispose() }
            (Test-HwpxGeneratedContract $path $plan).Status | Should Be FAILED
        }
        It 'rejects a deflated first local header even if its central entry claims stored' {
            $path=Join-Path $TestDrive 'compressed-mimetype.hwpx'
            $plan=New-ContractFixture $path
            $bytes=[IO.File]::ReadAllBytes($path)
            $bytes[8]=8
            [IO.File]::WriteAllBytes($path,$bytes)
            (Test-HwpxGeneratedContract $path $plan).Status | Should Be FAILED
        }
        It 'rejects resolved remote paths without opening a file' {
            $module = Get-Module HwpAuthoringVerify
            foreach ($remote in @('\\server.invalid\share\x.hwpx', 'FileSystem::\\server.invalid\share\x.hwpx', 'Microsoft.PowerShell.Core\FileSystem::\\server.invalid\share\x.hwpx')) {
                $errorText = & $module {
                    param($candidate)
                    try { Get-HavLocalPath $candidate 'probe'; return 'ACCEPTED' }
                    catch { return $_.Exception.Message }
                } $remote
                $errorText | Should Match 'local file'
            }
        }
        It 'keeps local provider-qualified paths usable' {
            $module = Get-Module HwpAuthoringVerify
            $path = Join-Path $TestDrive 'literal [path].hwpx'
            (& $module { param($candidate) Get-HavLocalPath $candidate 'probe' } ('FileSystem::' + $path)) | Should Be $path
        }
        It 'checks the document path before opening the archive' {
            $path = Join-Path $TestDrive 'document-path-gate.hwpx'
            $plan = New-ContractFixture $path
            Mock Get-HavLocalPath { throw 'LOCAL_PATH_GATE' } -ModuleName HwpAuthoringVerify -ParameterFilter { $Path -like '*document-path-gate.hwpx' }
            $result = Test-HwpxGeneratedContract $path $plan
            $result.Status | Should Be FAILED
            ($result.Errors -join ' ') | Should Match 'LOCAL_PATH_GATE'
            Assert-MockCalled Get-HavLocalPath -ModuleName HwpAuthoringVerify -Times 1 -Exactly -Scope It -ParameterFilter { $Path -like '*document-path-gate.hwpx' }
        }
        It 'checks the original image path before hashing its bytes' {
            $path = Join-Path $TestDrive 'image-path-gate.hwpx'
            $plan = New-ContractFixture $path
            $plan.sections[0].content[2].path = Join-Path $TestDrive 'image-path-gate.png'
            Mock Get-HavLocalPath { throw 'IMAGE_PATH_GATE' } -ModuleName HwpAuthoringVerify -ParameterFilter { $Path -like '*image-path-gate.png' }
            $result = Test-HwpxGeneratedContract $path $plan
            $result.Status | Should Be FAILED
            ($result.Errors -join ' ') | Should Match 'IMAGE_PATH_GATE'
            Assert-MockCalled Get-HavLocalPath -ModuleName HwpAuthoringVerify -Times 1 -Exactly -Scope It -ParameterFilter { $Path -like '*image-path-gate.png' }
        }
        It 'accepts generator integration with mixed sections and all block types' {
            Import-Module (Join-Path $verifyLib 'HwpHwpx.psm1') -Force
            Import-Module (Join-Path $verifyLib 'HwpAuthoringPlan.psm1') -Force
            $p=@'
{"version":"2.0","sections":[
 {"content":[{"type":"paragraph","text":"mixed"},{"type":"field","name":"field","value":"value"},{"type":"bookmark","name":"target","text":"anchor"},{"type":"hyperlink","target":"#target","text":"link"},{"type":"footnote","text":"foot"},{"type":"endnote","text":"end"},{"type":"toc","entries":[{"target":"#target","text":"entry"}]},{"type":"shape","shape":"rectangle","widthMm":20,"heightMm":10},{"type":"image","path":"","widthMm":20},{"type":"page-break"}]},
 {"document":{"page":{"paperSize":"A5","orientation":"LANDSCAPE","gutterType":"TOP_ONLY","margins":{"gutterMm":3}},"columns":{"count":2,"gapMm":6}},"content":[{"type":"column-break"},{"type":"table","rows":2,"columns":3,"repeatHeader":true,"cells":[{"row":1,"column":1,"colSpan":2,"text":"merged"}]}]},
 {"document":{"page":{"paperSize":"A5"}},"content":[{"type":"paragraph","text":"last"}]}]}
'@ | ConvertFrom-Json
            $p.sections[0].content[8].path=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Path
            $normalized=ConvertTo-HwpAuthoringPlan $p
            $path=Join-Path $TestDrive 'generator-mixed.hwpx'
            $generated=Invoke-HwpxGenerateDocument -Plan $p -OutputPath $path
            if($generated.Status -ne 'PASS') {throw ('GENERATOR INTEGRATION: '+($generated.Errors -join '; '))}
            $r=Test-HwpxGeneratedContract $path $normalized
            if($r.Status -ne 'PASS') {throw ('GENERATED CONTRACT INTEGRATION: '+($r.Errors -join '; '))}
            $r.NativeLayoutVerified | Should Be $false
        }
    }
}
