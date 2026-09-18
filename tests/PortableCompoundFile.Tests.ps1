# These fixtures are built directly from the CFB layout; no native storage APIs.
$readerSource = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCompoundFile.cs'
if (-not ('Contentrium.HwpSkill.CompoundFileReader' -as [type])) { Add-Type -Path $readerSource }
$script:cfbHasNativeDependency = @([Contentrium.HwpSkill.CompoundFileReader].Assembly.GetTypes() |
    Where-Object { $_.Namespace -eq 'Contentrium.HwpSkill' } | ForEach-Object {
        $_.GetMethods([Reflection.BindingFlags]'Public,NonPublic,Static,Instance') |
            Where-Object { ($_.Attributes -band [Reflection.MethodAttributes]::PinvokeImpl) -ne 0 }
    }).Count -gt 0

function Set-CfbU16($Bytes, [int]$Offset, [uint16]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 2)
}
function Set-CfbU32($Bytes, [int]$Offset, [uint32]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4)
}
function Set-CfbU64($Bytes, [int]$Offset, [uint64]$Value) {
    [Array]::Copy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 8)
}
function Set-CfbEntry($Bytes, [int]$Offset, [string]$Name, [int]$Type,
    [uint32]$Start = 4294967294, [uint64]$Size = 0,
    [uint32]$Child = 4294967295, [uint32]$Right = 4294967295) {
    [Array]::Clear($Bytes, $Offset, 128)
    $nameBytes = [Text.Encoding]::Unicode.GetBytes($Name + [char]0)
    [Array]::Copy($nameBytes, 0, $Bytes, $Offset, $nameBytes.Length)
    Set-CfbU16 $Bytes ($Offset + 64) $nameBytes.Length
    $Bytes[$Offset + 66] = $Type
    $Bytes[$Offset + 67] = 1
    Set-CfbU32 $Bytes ($Offset + 68) 4294967295
    Set-CfbU32 $Bytes ($Offset + 72) $Right
    Set-CfbU32 $Bytes ($Offset + 76) $Child
    Set-CfbU32 $Bytes ($Offset + 116) $Start
    Set-CfbU64 $Bytes ($Offset + 120) $Size
}
function New-CfbFixture([int]$Version = 3, [switch]$ExtendedDifat) {
    $sector = if ($Version -eq 3) { 512 } else { 4096 }
    $fatCount = if ($ExtendedDifat) { 110 } else { 1 }
    $difatCount = if ($ExtendedDifat) { 1 } else { 0 }
    $dirCount = if ($Version -eq 3) { 2 } else { 1 }
    $dir = $fatCount + $difatCount
    $miniFat = $dir + $dirCount
    $miniRoot = $miniFat + 1
    $big = $miniRoot + 1
    $bigCount = [int][Math]::Ceiling(4113.0 / $sector)
    $count = $big + $bigCount
    $bytes = [byte[]]::new(($count + 1) * $sector)
    [Array]::Copy([byte[]](0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1), $bytes, 8)
    Set-CfbU16 $bytes 24 62
    Set-CfbU16 $bytes 26 $Version
    Set-CfbU16 $bytes 28 65534
    Set-CfbU16 $bytes 30 $(if ($Version -eq 3) { 9 } else { 12 })
    Set-CfbU16 $bytes 32 6
    Set-CfbU32 $bytes 40 $(if ($Version -eq 4) { $dirCount } else { 0 })
    Set-CfbU32 $bytes 44 $fatCount
    Set-CfbU32 $bytes 48 $dir
    Set-CfbU32 $bytes 56 4096
    Set-CfbU32 $bytes 60 $miniFat
    Set-CfbU32 $bytes 64 1
    Set-CfbU32 $bytes 68 $(if ($ExtendedDifat) { $fatCount } else { 4294967294 })
    Set-CfbU32 $bytes 72 $difatCount
    for ($i = 0; $i -lt 109; $i++) {
        Set-CfbU32 $bytes (76 + $i * 4) $(if ($i -lt $fatCount) { $i } else { 4294967295 })
    }
    # All FAT/DIFAT slots initially FREESECT.
    for ($i = $sector; $i -lt ($dir + 1) * $sector; $i++) { $bytes[$i] = 255 }
    for ($i = 0; $i -lt $fatCount; $i++) { Set-CfbU32 $bytes ($sector + $i * 4) 4294967293 }
    if ($ExtendedDifat) {
        Set-CfbU32 $bytes ($sector + $fatCount * 4) 4294967292
        Set-CfbU32 $bytes (($fatCount + 1) * $sector) 109
        Set-CfbU32 $bytes (($fatCount + 2) * $sector - 4) 4294967294
    }
    for ($i = 0; $i -lt $dirCount; $i++) {
        Set-CfbU32 $bytes ($sector + ($dir + $i) * 4) $(if ($i + 1 -eq $dirCount) { 4294967294 } else { $dir + $i + 1 })
    }
    Set-CfbU32 $bytes ($sector + $miniFat * 4) 4294967294
    Set-CfbU32 $bytes ($sector + $miniRoot * 4) 4294967294
    # A fragmented regular stream (reverse physical order).
    for ($i = 0; $i -lt $bigCount; $i++) {
        $sid = $big + $bigCount - 1 - $i
        Set-CfbU32 $bytes ($sector + $sid * 4) $(if ($i + 1 -eq $bigCount) { 4294967294 } else { $sid - 1 })
        for ($j = 0; $j -lt $sector -and $i * $sector + $j -lt 4113; $j++) {
            $bytes[($sid + 1) * $sector + $j] = [byte](($i * $sector + $j) % 251)
        }
    }
    $d = ($dir + 1) * $sector
    Set-CfbEntry $bytes $d 'Root Entry' 5 $miniRoot 192 1
    Set-CfbEntry $bytes ($d + 128) 'Folder' 1 0 0 2 4
    Set-CfbEntry $bytes ($d + 256) 'Deep' 1 0 0 3
    Set-CfbEntry $bytes ($d + 384) 'Tiny' 2 0 100
    Set-CfbEntry $bytes ($d + 512) 'Big' 2 ($big + $bigCount - 1) 4113 4294967295 5
    Set-CfbEntry $bytes ($d + 640) 'Empty' 2
    for ($i = 0; $i -lt $sector; $i++) { $bytes[($miniFat + 1) * $sector + $i] = 255 }
    Set-CfbU32 $bytes (($miniFat + 1) * $sector) 2
    Set-CfbU32 $bytes (($miniFat + 1) * $sector + 8) 4294967294
    for ($i = 0; $i -lt 100; $i++) {
        $offset = if ($i -lt 64) { $i } else { $i + 64 }
        $bytes[($miniRoot + 1) * $sector + $offset] = [byte]($i + 1)
    }
    [pscustomobject]@{ Bytes=$bytes; Sector=$sector; Dir=$d; MiniFat=($miniFat+1)*$sector;
        MiniRoot=($miniRoot+1)*$sector; Big=$big; BigStart=$big+$bigCount-1; Difat=($fatCount+1)*$sector }
}
function Get-CfbFailure([scriptblock]$Action) {
    try { & $Action; throw 'Expected an exception.' }
    catch {
        $errorObject = $_.Exception
        while ($null -ne $errorObject.InnerException) { $errorObject = $errorObject.InnerException }
        return $errorObject
    }
}

function Compress-CfbTestBytes([byte[]]$Bytes) {
    $output=[IO.MemoryStream]::new()
    $zip=[IO.Compression.DeflateStream]::new($output,[IO.Compression.CompressionMode]::Compress,$true)
    try { $zip.Write($Bytes,0,$Bytes.Length) } finally { $zip.Dispose() }
    try { return ,$output.ToArray() } finally { $output.Dispose() }
}

# A real CFB containing minimal HWP records and the bundled PNG, all in mini streams.
function New-CfbAssetHwp([string]$Path, [int]$Mode=0, [bool]$DocumentCompressed=$false,
    [byte[]]$AssetBytes, [switch]$Corrupt, [switch]$NoMetadata, [switch]$MissingStream,
    [switch]$Linked, [switch]$Truncated) {
    if ($null -eq $AssetBytes) {
        $AssetBytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'))
    }
    $f=New-CfbFixture
    [Array]::Clear($f.Bytes,$f.Dir,1024)
    [Array]::Clear($f.Bytes,$f.MiniRoot,$f.Bytes.Length-$f.MiniRoot)
    for ($i=0;$i -lt 512;$i++) { $f.Bytes[$f.MiniFat+$i]=255 }
    for ($i=4;$i -lt $f.Bytes.Length/512-1;$i++) { Set-CfbU32 $f.Bytes (512+$i*4) 4294967295 }
    $header=[byte[]]::new(256)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('HWP Document File'),$header,17)
    $header[35]=5
    Set-CfbU32 $header 36 ([int]$DocumentCompressed)
    $doc=[byte[]]::new(16)
    Set-CfbU32 $doc 0 ((12 -shl 20) -bor 0x12)
    Set-CfbU16 $doc 4 (1 -bor ($Mode -shl 4))
    Set-CfbU16 $doc 6 1
    Set-CfbU16 $doc 8 3
    [Array]::Copy([Text.Encoding]::Unicode.GetBytes('png'),0,$doc,10,6)
    if ($NoMetadata) { $doc=[byte[]](0x10,0,0,0) }
    if ($Linked) { $doc=[byte[]](0x12,0,0x60,0,0,0,0,0,0,0) }
    $body=[byte[]]::new(8)
    Set-CfbU32 $body 0 ((4 -shl 20) -bor 0x43)
    [Array]::Copy([Text.Encoding]::Unicode.GetBytes('OK'),0,$body,4,4)
    if ($DocumentCompressed) { $doc=Compress-CfbTestBytes $doc; $body=Compress-CfbTestBytes $body }
    $assetCompressed=($Mode -eq 1 -or ($Mode -eq 0 -and $DocumentCompressed))
    $stored=if ($assetCompressed) { Compress-CfbTestBytes $AssetBytes } else { $AssetBytes }
    if ($Corrupt) { $stored=[byte[]](255,255,255,255) }
    if ($Truncated) { $stored=[byte[]]$stored[0..($stored.Length-5)] }
    $streams=@(
        @{Id=1;Name='FileHeader';Bytes=$header;Right=2},
        @{Id=2;Name='DocInfo';Bytes=$doc;Right=3},
        @{Id=4;Name='Section0';Bytes=$body;Right=4294967295}
    )
    if (-not $MissingStream -and -not $Linked) {
        $streams+=@{Id=6;Name='BIN0001.png';Bytes=$stored;Right=4294967295}
    }
    $mini=0
    foreach ($stream in $streams) {
        $payload=[byte[]]$stream.Bytes
        if ($payload.Length -ge 4096) { throw 'Test fixture only supports mini stream payloads.' }
        $count=[int][Math]::Ceiling($payload.Length/64.0)
        Set-CfbEntry $f.Bytes ($f.Dir+$stream.Id*128) $stream.Name 2 $mini $payload.Length 4294967295 $stream.Right
        [Array]::Copy($payload,0,$f.Bytes,$f.MiniRoot+$mini*64,$payload.Length)
        for ($i=0;$i -lt $count;$i++) {
            Set-CfbU32 $f.Bytes ($f.MiniFat+($mini+$i)*4) $(if ($i+1 -eq $count) { 4294967294 } else { $mini+$i+1 })
        }
        $mini+=$count
    }
    Set-CfbEntry $f.Bytes $f.Dir 'Root Entry' 5 4 ($mini*64) 1
    Set-CfbEntry $f.Bytes ($f.Dir+384) 'BodyText' 1 0 0 4 5
    Set-CfbEntry $f.Bytes ($f.Dir+640) 'BinData' 1 0 0 $(if ($MissingStream -or $Linked) { 4294967295 } else { 6 })
    $rootCount=[int][Math]::Ceiling($mini*64.0/512)
    for ($i=0;$i -lt $rootCount;$i++) {
        Set-CfbU32 $f.Bytes (512+(4+$i)*4) $(if ($i+1 -eq $rootCount) { 4294967294 } else { 5+$i })
    }
    [IO.File]::WriteAllBytes($Path,$f.Bytes)
}

Describe 'Portable CFB managed dependency contract' {
    It 'loads a reader without any native entry points' {
        $script:cfbHasNativeDependency | Should Be $false
    }
}
# The pre-change RED run must never invoke the old COM implementation.
if ($script:cfbHasNativeDependency) { return }
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPortable.psm1') -Force

Describe 'Portable CFB streams and lifetime' {
    foreach ($version in @(3,4)) {
        It "reads fragmented regular and mini streams and nested paths in v$version" {
            $f = New-CfbFixture -Version $version
            $path = Join-Path $TestDrive "v$version.cfb"
            [IO.File]::WriteAllBytes($path, $f.Bytes)
            $s = [Contentrium.HwpSkill.CompoundFileReader]::Open($path)
            try {
                $tiny = $s.ReadStream('/folder\deep/', 'tInY', 100)
                [Convert]::ToBase64String($tiny) | Should Be ([Convert]::ToBase64String([byte[]](1..100)))
                $big = $s.ReadStream('', 'Big', 4113)
                $big.Length | Should Be 4113
                for ($i = 0; $i -lt $big.Length; $i++) {
                    if ($big[$i] -ne ($i % 251)) { throw "Wrong regular byte $i" }
                }
                $s.ReadStream('', 'Empty', 1).Length | Should Be 0
                @($s.ListElements('Folder/Deep')).Count | Should Be 1
                ($s.ListElements('Folder/Deep'))[0].Size | Should Be 100
                @($s.ListElements('')).Count | Should Be 3
                (Get-CfbFailure { $s.ReadStream('', 'Big', 4112) }).GetType().FullName | Should Be 'System.IO.InvalidDataException'
                (Get-CfbFailure { $s.ReadStream('', 'missing', 10) }).GetType().FullName | Should Be 'System.IO.InvalidDataException'
                (Get-CfbFailure { $s.ListElements('Big') }).GetType().FullName | Should Be 'System.IO.InvalidDataException'
                $s.ComputeSha256() | Should Be ((Get-FileHash $path).Hash.ToLowerInvariant())
                # Hashing shares the same handle without changing subsequent reads.
                $s.ReadStream('Folder/Deep', 'Tiny', 100)[99] | Should Be 100
            } finally { $s.Dispose() }
            $s.Dispose()
            (Get-CfbFailure { $s.ListElements('') }).GetType().FullName | Should Be 'System.ObjectDisposedException'
            [Contentrium.HwpSkill.CompoundFileReader]::ReadStream($path, '', 'Big', 4113).Length | Should Be 4113
            @([Contentrium.HwpSkill.CompoundFileReader]::ListElements($path, '')).Count | Should Be 3
        }
    }
    It 'reads FAT addresses stored in an extended DIFAT sector' {
        $f = New-CfbFixture -ExtendedDifat
        $path = Join-Path $TestDrive 'difat.cfb'
        [IO.File]::WriteAllBytes($path, $f.Bytes)
        [Contentrium.HwpSkill.CompoundFileReader]::ReadStream($path, '', 'Big', 4113).Length | Should Be 4113
    }
    It 'accepts legacy uninitialized upper stream size words in v3' {
        $f = New-CfbFixture
        Set-CfbU32 $f.Bytes ($f.Dir + 384 + 124) 3735928559
        $path = Join-Path $TestDrive 'legacy.cfb'
        [IO.File]::WriteAllBytes($path, $f.Bytes)
        [Contentrium.HwpSkill.CompoundFileReader]::ReadStream($path, 'Folder/Deep', 'Tiny', 100).Length | Should Be 100
    }
    It 'holds a read-only handle for the entire session and releases it on disposal' {
        $f = New-CfbFixture
        $path = Join-Path $TestDrive 'lock.cfb'
        [IO.File]::WriteAllBytes($path, $f.Bytes)
        $s = [Contentrium.HwpSkill.CompoundFileReader]::Open($path)
        try {
            # .NET FileShare deny-write is mandatory on Windows; Unix sharing is
            # advisory, so the same-handle hashes remain necessary on Unix.
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                (Get-CfbFailure {
                    $w = [IO.File]::Open($path, 'Open', 'Write', 'ReadWrite'); $w.Dispose()
                }).GetType().FullName | Should Be 'System.IO.IOException'
            }
        } finally { $s.Dispose() }
        $w = [IO.File]::Open($path, 'Open', 'Write', 'None'); $w.Dispose()
    }
}

Describe 'Portable CFB hostile input rejection' {
    $mutations = @(
        @{Name='bad signature'; Edit={param($f) $f.Bytes[0]=0}},
        @{Name='wrong byte order'; Edit={param($f) Set-CfbU16 $f.Bytes 28 65535}},
        @{Name='unsupported version'; Edit={param($f) Set-CfbU16 $f.Bytes 26 5}},
        @{Name='invalid sector shift'; Edit={param($f) Set-CfbU16 $f.Bytes 30 31}},
        @{Name='invalid mini shift'; Edit={param($f) Set-CfbU16 $f.Bytes 32 7}},
        @{Name='invalid cutoff'; Edit={param($f) Set-CfbU32 $f.Bytes 56 512}},
        @{Name='FAT count overflow'; Edit={param($f) Set-CfbU32 $f.Bytes 44 4294967295}},
        @{Name='FAT sector outside file'; Edit={param($f) Set-CfbU32 $f.Bytes 76 999999}},
        @{Name='FAT marker mismatch'; Edit={param($f) Set-CfbU32 $f.Bytes $f.Sector 4294967294}},
        @{Name='directory cycle'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Sector+8) 1}},
        @{Name='directory points into FAT'; Edit={param($f) Set-CfbU32 $f.Bytes 48 0}},
        @{Name='missing root'; Edit={param($f) $f.Bytes[$f.Dir+66]=1}},
        @{Name='directory sibling cycle'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Dir+128+72) 1}},
        @{Name='directory child cycle'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Dir+256+76) 1}},
        @{Name='directory index outside table'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Dir+76) 999999}},
        @{Name='duplicate name'; Edit={param($f) Set-CfbEntry $f.Bytes ($f.Dir+640) 'bIG' 2}},
        @{Name='invalid name length'; Edit={param($f) Set-CfbU16 $f.Bytes ($f.Dir+128+64) 65}},
        @{Name='unterminated name'; Edit={param($f) $f.Bytes[$f.Dir+128+12]=65}},
        @{Name='stream has children'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Dir+384+76) 5}},
        @{Name='unreachable active entry'; Edit={param($f) Set-CfbEntry $f.Bytes ($f.Dir+768) 'Orphan' 2}},
        @{Name='regular chain cycle'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Sector+$f.BigStart*4) $f.BigStart}},
        @{Name='regular chain too short'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Sector+$f.BigStart*4) 4294967294}},
        @{Name='regular chain outside file'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Sector+$f.BigStart*4) 10000}},
        @{Name='regular chain reserved marker'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Sector+$f.BigStart*4) 4294967293}},
        @{Name='regular alias'; Edit={param($f) Set-CfbEntry $f.Bytes ($f.Dir+640) 'Alias' 2 $f.BigStart 4113}},
        @{Name='mini chain cycle'; Edit={param($f) Set-CfbU32 $f.Bytes $f.MiniFat 0}},
        @{Name='mini chain too short'; Edit={param($f) Set-CfbU32 $f.Bytes $f.MiniFat 4294967294}},
        @{Name='mini chain exceeds root'; Edit={param($f) Set-CfbU32 $f.Bytes $f.MiniFat 3}},
        @{Name='mini chain too long'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.MiniFat+8) 1}},
        @{Name='mini alias'; Edit={param($f) Set-CfbEntry $f.Bytes ($f.Dir+640) 'Alias' 2 0 100}},
        @{Name='mini FAT count overflow'; Edit={param($f) Set-CfbU32 $f.Bytes 64 4294967295}},
        @{Name='mini FAT chain cycle'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Sector+12) 3}},
        @{Name='huge root stream'; Edit={param($f) Set-CfbU64 $f.Bytes ($f.Dir+120) 2147483647}},
        @{Name='huge regular stream'; Edit={param($f) Set-CfbU64 $f.Bytes ($f.Dir+512+120) 2147483647}},
        @{Name='empty stream with allocated chain'; Edit={param($f) Set-CfbU32 $f.Bytes ($f.Dir+640+116) 0}}
    )
    foreach ($case in $mutations) {
        It ("rejects " + $case.Name + ' deterministically and releases the file') {
            $f = New-CfbFixture
            & $case.Edit $f
            $path = Join-Path $TestDrive 'malformed.cfb'
            [IO.File]::WriteAllBytes($path, $f.Bytes)
            $messages = @()
            for ($attempt = 0; $attempt -lt 2; $attempt++) {
                $e = Get-CfbFailure { $s=[Contentrium.HwpSkill.CompoundFileReader]::Open($path); $s.Dispose() }
                $e.GetType().FullName | Should Be 'System.IO.InvalidDataException'
                $messages += $e.Message
            }
            $messages[0] | Should Be $messages[1]
            $w=[IO.File]::Open($path, 'Open', 'Write', 'None'); $w.Dispose()
        }
    }
    It 'rejects truncated sectors and headers' {
        $f=New-CfbFixture
        foreach ($length in @(0,8,511,512,($f.Bytes.Length-1))) {
            $path=Join-Path $TestDrive 'short.cfb'
            $w=[IO.File]::Create($path)
            try { $w.Write($f.Bytes,0,$length) } finally { $w.Dispose() }
            (Get-CfbFailure { $s=[Contentrium.HwpSkill.CompoundFileReader]::Open($path); $s.Dispose() }).GetType().FullName |
                Should Be 'System.IO.InvalidDataException'
        }
    }
    It 'rejects 64-bit v4 sizes before allocating their payloads' {
        $f=New-CfbFixture -Version 4
        Set-CfbU64 $f.Bytes ($f.Dir+512+120) ([uint64]::MaxValue)
        $path=Join-Path $TestDrive 'huge.cfb'
        [IO.File]::WriteAllBytes($path,$f.Bytes)
        (Get-CfbFailure { $s=[Contentrium.HwpSkill.CompoundFileReader]::Open($path); $s.Dispose() }).GetType().FullName |
            Should Be 'System.IO.InvalidDataException'
    }
    foreach ($kind in @('cycle','duplicate','outside','count','marker')) {
        It "rejects an extended DIFAT $kind" {
            $f=New-CfbFixture -ExtendedDifat
            switch ($kind) {
                cycle { Set-CfbU32 $f.Bytes ($f.Difat+$f.Sector-4) 110 }
                duplicate { Set-CfbU32 $f.Bytes $f.Difat 0 }
                outside { Set-CfbU32 $f.Bytes 68 999999 }
                count { Set-CfbU32 $f.Bytes 72 2 }
                marker { Set-CfbU32 $f.Bytes ($f.Sector+110*4) 4294967294 }
            }
            $path=Join-Path $TestDrive 'bad-difat.cfb'
            [IO.File]::WriteAllBytes($path,$f.Bytes)
            (Get-CfbFailure { $s=[Contentrium.HwpSkill.CompoundFileReader]::Open($path); $s.Dispose() }).GetType().FullName |
                Should Be 'System.IO.InvalidDataException'
        }
    }
    It 'enforces the file budget on the opened handle' {
        $f=New-CfbFixture
        $path=Join-Path $TestDrive 'budget.cfb'
        [IO.File]::WriteAllBytes($path,$f.Bytes)
        (Get-CfbFailure { $s=[Contentrium.HwpSkill.CompoundFileReader]::Open($path,1024); $s.Dispose() }).GetType().FullName |
            Should Be 'System.IO.InvalidDataException'
    }
}

Describe 'Portable bundled HWP and HWT readback' {
    Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPortable.psm1') -Force
    foreach ($fixture in @(
        @{Name='native-fixture.hwp'; Hash='6dc4eb32c641a5d723936f1a5e4a4bfdb8ca2d2f0826f02a610296cf48fc50fe'},
        @{Name='native-template.hwt'; Hash='373235a1369c29445ec4aec47ab3949345178792214c00366a7f02a4583839c5'}
    )) {
        It ("preserves hashes, text and the 2x2 table in " + $fixture.Name) {
            $path=Join-Path $PSScriptRoot ('fixtures/source/'+$fixture.Name)
            (Get-FileHash $path).Hash.ToLowerInvariant() | Should Be $fixture.Hash
            $result=Get-HwpPortableInspection -LiteralPath $path -ExpectedSha256 $fixture.Hash
            $result.Status | Should Be 'PASS_WITH_WARNINGS'
            $result.Data.Text | Should Match 'HWP 네이티브 통합 시험'
            $result.Data.Tables.Count | Should Be 1
            $table=$result.Data.Tables[0]
            $table.RowCount | Should Be 2
            $table.ColumnCount | Should Be 2
            $table.Cells.Count | Should Be 4
            $table.Grid.Count | Should Be 2
            foreach ($row in @(0,1)) { foreach ($col in @(0,1)) {
                $slot = $table.Grid[$row][$col]
                $slot.IsAnchor | Should Be $true
                $slot.CellIndex | Should Be ($row * 2 + $col)
                $table.Cells[$slot.CellIndex].RowAddress | Should Be $row
                $table.Cells[$slot.CellIndex].ColumnAddress | Should Be $col
            } }
            (Get-FileHash $path).Hash.ToLowerInvariant() | Should Be $fixture.Hash
            (Get-HwpPortableInspection -LiteralPath $path -ExpectedSha256 ('0'*64)).Status | Should Be 'BLOCKED'
        }
    }
}

Describe 'Portable HWP binary asset hashes' {
    foreach ($case in @(
        @{Mode=0;Compressed=$false}, @{Mode=0;Compressed=$true},
        @{Mode=1;Compressed=$false}, @{Mode=2;Compressed=$true}
    )) {
        It "hashes original PNG bytes for mode $($case.Mode) document compression $($case.Compressed)" {
            $path=Join-Path $TestDrive 'asset.hwp'
            New-CfbAssetHwp $path -Mode $case.Mode -DocumentCompressed $case.Compressed
            $r=Get-HwpPortableInspection -LiteralPath $path
            $r.Status | Should Be 'PASS_WITH_WARNINGS'
            $r.Data.Text | Should Be 'OK'
            $r.Data.BinaryAssets.Count | Should Be 1
            $asset=$r.Data.BinaryAssets[0]
            $asset.StreamName | Should Be 'BIN0001.png'
            $asset.Id | Should Be 1
            $asset.Extension | Should Be 'png'
            $asset.VerificationStatus | Should Be 'HASHED'
            $asset.DecodedBytes | Should Be 158
            $asset.Sha256 | Should Be ((Get-FileHash (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png')).Hash.ToLowerInvariant())
            $asset.StoredSha256.Length | Should Be 64
            $r.Data.BinaryAssetsVerified | Should Be $true
        }
    }
    foreach ($kind in @('corrupt','truncated','metadata','missing','linked','reserved')) {
        It "reports an explicit asset limitation for $kind without claiming a decoded hash" {
            $path=Join-Path $TestDrive 'unverified-asset.hwp'
            switch ($kind) {
                corrupt { New-CfbAssetHwp $path -Mode 1 -Corrupt }
                truncated { New-CfbAssetHwp $path -Mode 1 -Truncated }
                metadata { New-CfbAssetHwp $path -NoMetadata }
                missing { New-CfbAssetHwp $path -MissingStream }
                linked { New-CfbAssetHwp $path -Linked }
                reserved { New-CfbAssetHwp $path -Mode 3 }
            }
            $r=Get-HwpPortableInspection -LiteralPath $path
            $r.Status | Should Be 'PASS_WITH_WARNINGS'
            $r.Data.BinaryAssetsVerified | Should Be $false
            $r.Data.BinaryAssets.Count | Should Be 1
            $r.Data.BinaryAssets[0].Sha256 | Should BeNullOrEmpty
            $r.Data.BinaryAssets[0].VerificationLimitation.Length | Should BeGreaterThan 0
            ($r.Warnings -join ' ') | Should Match 'BinData'
        }
    }
    It 'bounds asset expansion by the remaining document budget' {
        $path=Join-Path $TestDrive 'asset-bomb.hwp'
        New-CfbAssetHwp $path -Mode 1 -AssetBytes ([byte[]]::new(100000))
        $r=Get-HwpPortableInspection -LiteralPath $path -MaximumExpandedBytes 128
        $r.Status | Should Be 'PASS_WITH_WARNINGS'
        $r.Data.BinaryAssetsVerified | Should Be $false
        $r.Data.BinaryAssets[0].Sha256 | Should BeNullOrEmpty
        $r.Data.BinaryAssets[0].VerificationLimitation | Should Match '한도|limit'
    }
}
