# Test-only CFB writer. Never opens Hancom or a native structured-storage API.
$fixtureWriter=Join-Path $PSScriptRoot 'fixtures/New-ConversionFixture.ps1'
if(Test-Path -LiteralPath $fixtureWriter){. $fixtureWriter}
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpPortable.psm1') -Force

function Get-ConversionFixtureStreams([string]$Path) {
    $root=@{};$body=@{};$bin=@{};$hasBin=$false
    $session=[Contentrium.HwpSkill.CompoundFileReader]::Open($Path)
    try {
        $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue('')
        while($queue.Count){
            $storage=$queue.Dequeue()
            foreach($entry in $session.ListElements($storage)){
                $key=if($storage){$storage+'/'+$entry.Name}else{$entry.Name}
                if($entry.Type -eq 1){if($key -eq 'BinData'){$hasBin=$true};$queue.Enqueue($key);continue}
                $bytes=$session.ReadStream($storage,$entry.Name,[Math]::Max(1,[int]$entry.Size))
                if($storage -eq 'BodyText'){$body[$entry.Name]=$bytes}
                elseif($storage -eq 'BinData'){$bin[$entry.Name]=$bytes}
                else{$root[$key]=$bytes}
            }
        }
        return @{RootStreams=$root;BodyStreams=$body;BinStreams=$(if($hasBin){$bin}else{$null})}
    }finally{$session.Dispose()}
}
function Get-ConversionFixtureHash([byte[]]$Bytes){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Assert-ConversionDirectoryTree([string]$Path){
    $bytes=[IO.File]::ReadAllBytes($Path)
    [BitConverter]::ToUInt16($bytes,26)|Should Be 3
    $fat=[Collections.Generic.List[uint32]]::new()
    # These cases have one header DIFAT page; the separate large case exercises extension pages.
    for($i=0;$i -lt [BitConverter]::ToUInt32($bytes,44);$i++){
        $sid=[BitConverter]::ToUInt32($bytes,76+4*$i)
        for($j=0;$j -lt 128;$j++){$fat.Add([BitConverter]::ToUInt32($bytes,512*($sid+1)+4*$j))}
    }
    $directory=[IO.MemoryStream]::new();$sid=[BitConverter]::ToUInt32($bytes,48)
    while($sid -ne 4294967294){$directory.Write($bytes,512*($sid+1),512);$sid=$fat[[int]$sid]}
    try{$raw=$directory.ToArray()}finally{$directory.Dispose()}
    $nodes=@(for($i=0;$i -lt $raw.Length;$i+=128){
        $len=[BitConverter]::ToUInt16($raw,$i+64)
        [pscustomobject]@{Name=if($len -ge 2){[Text.Encoding]::Unicode.GetString($raw,$i,$len-2)}else{''};Type=$raw[$i+66];Color=$raw[$i+67];Left=[BitConverter]::ToUInt32($raw,$i+68);Right=[BitConverter]::ToUInt32($raw,$i+72);Child=[BitConverter]::ToUInt32($raw,$i+76)}
    })
    function Test-ConversionTree($Id,$Lower,$Upper,[bool]$RedParent){
        if($Id -eq 4294967295){return 1}
        if($Id -ge $nodes.Count -or -not $seen.Add([int]$Id)){throw 'Invalid/cyclic directory tree'}
        $n=$nodes[[int]$Id]
        if($n.Type -notin @(1,2)){throw 'Tree links an unused entry'}
        foreach($bound in @(@{Value=$Lower;Sign=1},@{Value=$Upper;Sign=-1})){
            if($null -eq $bound.Value){continue}
            $cmp=$n.Name.Length.CompareTo($bound.Value.Length)
            if($cmp -eq 0){$cmp=[StringComparer]::OrdinalIgnoreCase.Compare($n.Name,$bound.Value)}
            if($cmp*$bound.Sign -le 0){throw 'Directory name order is invalid'}
        }
        if($n.Color -notin @(0,1) -or ($RedParent -and $n.Color -eq 0)){throw 'Invalid red/black colors'}
        $a=Test-ConversionTree $n.Left $Lower $n.Name ($n.Color -eq 0)
        $b=Test-ConversionTree $n.Right $n.Name $Upper ($n.Color -eq 0)
        if($a -ne $b){throw 'Unequal directory black heights'}
        return $a+[int]($n.Color -eq 1)
    }
    $seen=[Collections.Generic.HashSet[int]]::new()
    foreach($n in $nodes|Where-Object {$_.Type -in @(1,5)}){
        if($n.Child -ne 4294967295){$nodes[[int]$n.Child].Color|Should Be 1}
        $null=Test-ConversionTree $n.Child $null $null $false
    }
    $seen.Count|Should Be @($nodes|Where-Object {$_.Type -in @(1,2)}).Count
}

Describe 'Managed HWP conversion fixture compound writer' {
    BeforeEach {
        $outputRoot=Join-Path $PSScriptRoot 'output/hwp-input-conversion-2026-10-20/fixture-helper'
        $dir=Join-Path $outputRoot ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $dir -Force
    }
    It 'round trips empty, mini, regular and optional BinData streams with a proper directory tree' {
        $root=@{};$body=@{};$bin=@{}
        foreach($length in @(0,1,63,64,65,4095,4096,4113)){
            $payload=[byte[]]::new($length);for($i=0;$i -lt $length;$i++){$payload[$i]=[byte]($i%251)}
            $root['Payload'+$length]=$payload
        }
        foreach($i in 1..30){$body['Section'+$i]=[byte[]]@(1,2,3)}
        $root['Extra/Deep/Metadata']=[byte[]]@(6,7)
        $bin['BIN0001.bin']=[byte[]]::new(4096);$bin['BIN0002.bin']=[byte[]]@(8,9)
        $path=Join-Path $dir 'mixed.cfb'
        Write-ConversionCompoundFile -Path $path -RootStreams $root -BodyStreams $body -BinStreams $bin
        $copy=Get-ConversionFixtureStreams $path
        foreach($group in @('RootStreams','BodyStreams','BinStreams')){
            $expected=@{RootStreams=$root;BodyStreams=$body;BinStreams=$bin}[$group]
            $copy[$group].Count|Should Be $expected.Count
            foreach($name in $expected.Keys){(Get-ConversionFixtureHash $copy[$group][$name])|Should Be (Get-ConversionFixtureHash $expected[$name])}
        }
        Assert-ConversionDirectoryTree $path
    }
    It 'writes FAT addresses beyond the header DIFAT capacity' {
        $payload=[byte[]]::new(8MB);$payload[0]=37;$payload[$payload.Length-1]=91
        $path=Join-Path $dir 'extended-difat.cfb'
        Write-ConversionCompoundFile -Path $path -RootStreams @{Large=$payload} -BodyStreams @{}
        $bytes=[IO.File]::ReadAllBytes($path)
        ([BitConverter]::ToUInt32($bytes,44) -gt 109)|Should Be $true
        ([BitConverter]::ToUInt32($bytes,72) -gt 0)|Should Be $true
        (Get-ConversionFixtureHash ([Contentrium.HwpSkill.CompoundFileReader]::ReadStream($path,'','Large',8MB)))|Should Be (Get-ConversionFixtureHash $payload)
    }
    It 'rejects duplicate paths and invalid payloads without overwriting existing files' {
        $path=Join-Path $dir 'invalid.cfb'
        {Write-ConversionCompoundFile -Path $path -RootStreams @{BodyText=[byte[]]@(1)} -BodyStreams @{Section0=[byte[]]@(2)}}|Should Throw
        Test-Path -LiteralPath $path|Should Be $false
        {Write-ConversionCompoundFile -Path $path -RootStreams @{Invalid='text'} -BodyStreams @{}}|Should Throw
        Test-Path -LiteralPath $path|Should Be $false
        Write-ConversionCompoundFile -Path $path -RootStreams @{Keep=[byte[]]@(4,5)} -BodyStreams @{}
        $hash=(Get-FileHash -LiteralPath $path).Hash
        {Write-ConversionCompoundFile -Path $path -RootStreams @{} -BodyStreams @{}}|Should Throw
        (Get-FileHash -LiteralPath $path).Hash|Should Be $hash
    }
    It 'copies every real source stream and preserves managed inspection text' {
        $source=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $originalHash=(Get-FileHash -LiteralPath $source).Hash
        $maps=Get-ConversionFixtureStreams $source
        $path=Join-Path $dir 'copied.hwp'
        Write-ConversionCompoundFile -Path $path @maps
        $copy=Get-ConversionFixtureStreams $path
        $streamEvidence=@(foreach($group in @('RootStreams','BodyStreams','BinStreams')){
            $copy[$group].Count|Should Be $maps[$group].Count
            foreach($key in $maps[$group].Keys){
                $original=Get-ConversionFixtureHash $maps[$group][$key];$copied=Get-ConversionFixtureHash $copy[$group][$key]
                $copied|Should Be $original
                [pscustomobject]@{Group=$group;Name=$key;Bytes=$maps[$group][$key].Length;SourceSha256=$original;CopiedSha256=$copied;Equal=($original -eq $copied)}
            }
        })
        $before=Get-HwpPortableInspection -LiteralPath $source;$after=Get-HwpPortableInspection -LiteralPath $path
        ($before.Errors -join ';')|Should Be ''
        ($after.Errors -join ';')|Should Be ''
        $after.Data.Text|Should Be $before.Data.Text
        $after.Data.RecordCount|Should Be $before.Data.RecordCount
        $originalSession=[Contentrium.HwpSkill.CompoundFileReader]::Open($source)
        $copiedSession=[Contentrium.HwpSkill.CompoundFileReader]::Open($path)
        try{
            (($copiedSession.ListElements('')|ForEach-Object {$_.Name+':'+$_.Type}) -join '|')|Should Be (($originalSession.ListElements('')|ForEach-Object {$_.Name+':'+$_.Type}) -join '|')
        }finally{$originalSession.Dispose();$copiedSession.Dispose()}
        (Get-FileHash -LiteralPath $source).Hash|Should Be $originalHash
        Assert-ConversionDirectoryTree $path
        $evidence=[ordered]@{Source=$source;Copied=$path;SourceSha256=$originalHash;CopiedSha256=(Get-FileHash -LiteralPath $path).Hash;SourceUnchanged=$true;Streams=$streamEvidence;ManagedTextEqual=$true;TextCharacters=$after.Data.Text.Length;TextSha256=(Get-ConversionFixtureHash ([Text.Encoding]::UTF8.GetBytes($after.Data.Text)))}
        [IO.File]::WriteAllText((Join-Path $dir 'roundtrip-evidence.json'),($evidence|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    }
    It 'rewrites one real BodyText record without changing any other stream' {
        $source=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $sourceHash=(Get-FileHash -LiteralPath $source).Hash;$maps=Get-ConversionFixtureStreams $source
        $before=Get-HwpPortableInspection -LiteralPath $source
        $name=@($maps.BodyStreams.Keys|Sort-Object)[0]
        $compressed=([BitConverter]::ToUInt32($maps.RootStreams.FileHeader,36) -band 1) -ne 0
        $body=if($compressed){[Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($maps.BodyStreams[$name],16MB)}else{[byte[]]$maps.BodyStreams[$name].Clone()}
        $changed=$false;$position=0
        while($position+4 -le $body.Length -and -not $changed){
            $header=[BitConverter]::ToUInt32($body,$position);$position+=4;$size=[int]($header -shr 20)
            if($size -eq 4095){$size=[BitConverter]::ToInt32($body,$position);$position+=4}
            if($size -lt 0 -or $position+$size -gt $body.Length){throw 'Invalid source record extent'}
            if(($header -band 1023) -eq 0x43){
                for($i=$position;$i+1 -lt $position+$size;$i+=2){
                    $code=[BitConverter]::ToUInt16($body,$i)
                    if($code -ge 0xac00 -and $code -le 0xd7a3){
                        $old=[char]$code;$new=if($code -eq 0xac00){[char]0xb098}else{[char]0xac00}
                        [Array]::Copy([BitConverter]::GetBytes([uint16]$new),0,$body,$i,2);$changed=$true;break
                    }
                }
            }
            $position+=$size
        }
        $changed|Should Be $true
        if($compressed){
            $memory=[IO.MemoryStream]::new();$deflate=[IO.Compression.DeflateStream]::new($memory,[IO.Compression.CompressionMode]::Compress,$true)
            try{$deflate.Write($body,0,$body.Length)}finally{$deflate.Dispose()}
            try{$maps.BodyStreams[$name]=$memory.ToArray()}finally{$memory.Dispose()}
        }else{$maps.BodyStreams[$name]=$body}
        $path=Join-Path $dir 'body-record-edit.hwp';Write-ConversionCompoundFile -Path $path @maps
        $after=Get-HwpPortableInspection -LiteralPath $path
        ($after.Errors -join ';')|Should Be ''
        $after.Data.Text.Length|Should Be $before.Data.Text.Length
        $after.Data.Text|Should Not Be $before.Data.Text
        @(for($i=0;$i -lt $after.Data.Text.Length;$i++){if($after.Data.Text[$i] -cne $before.Data.Text[$i]){$i}}).Count|Should Be 1
        $after.Data.RecordCount|Should Be $before.Data.RecordCount
        $copy=Get-ConversionFixtureStreams $path
        foreach($group in @('RootStreams','BodyStreams','BinStreams')){foreach($key in $maps[$group].Keys){(Get-ConversionFixtureHash $copy[$group][$key])|Should Be (Get-ConversionFixtureHash $maps[$group][$key])}}
        (Get-FileHash -LiteralPath $source).Hash|Should Be $sourceHash
        [IO.File]::WriteAllText((Join-Path $dir 'body-edit-evidence.json'),([ordered]@{SourceUnchanged=$true;ChangedStream=('BodyText/'+$name);TextCharacters=$after.Data.Text.Length;TextChanged=$true;RecordCountEqual=($after.Data.RecordCount -eq $before.Data.RecordCount);Output=$path}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
    It 'reuses the unpacked HwpForge package to read the copied real document identically' {
        $source=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $package=Join-Path $PSScriptRoot '../tmp/hwpforge-probe/unpacked'
        if(-not(Test-Path -LiteralPath $package)){Set-TestInconclusive 'The optional local HwpForge probe package is unavailable';return}
        $path=Join-Path $dir 'hwpforge-copy.hwp';$maps=Get-ConversionFixtureStreams $source
        Write-ConversionCompoundFile -Path $path @maps
        $code=@'
import hashlib, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import hwpforge
documents = [hwpforge.convert_hwp5(Path(p).read_bytes(), carry_layout_cache=False).document for p in sys.argv[2:4]]
texts = [d.to_md().text for d in documents]
assert texts[0] == texts[1] and len(texts[0]) > 0
for i, doc in enumerate(documents):
    Path(sys.argv[4], 'converted-' + str(i) + '.hwpx').write_bytes(doc.to_bytes())
print(json.dumps({'version': hwpforge.__version__, 'equal': True, 'characters': len(texts[0]), 'textSha256': hashlib.sha256(texts[0].encode('utf-8')).hexdigest()}))
'@
        $raw=& python -B -c $code $package $source $path $dir
        $LASTEXITCODE|Should Be 0
        $result=$raw|ConvertFrom-Json
        $result.equal|Should Be $true
        $result.characters|Should BeGreaterThan 0
        [IO.File]::WriteAllText((Join-Path $dir 'hwpforge-evidence.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    }
}
