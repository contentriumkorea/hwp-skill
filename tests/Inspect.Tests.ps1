$commonModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpSession.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1'
Import-Module $commonModule -Force
Import-Module $sessionModule -Force
Import-Module $inspectModule -Force

Describe 'HWP/HWT 메모리 입력 크기 제한' {
    It '한도를 넘는 파일은 전체 바이트를 읽거나 한컴에 전달하기 전에 차단한다' {
        $path = Join-Path $TestDrive 'oversized.hwp'
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $signature = [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1)
            $stream.Write($signature, 0, $signature.Length)
            $stream.SetLength(2048)
        }
        finally {
            $stream.Dispose()
        }
        $counter = [pscustomobject]@{ Calls = 0 }
        $hwp = [pscustomobject]@{ Counter = $counter }
        $hwp | Add-Member ScriptMethod SetTextFile {
            param($base64,$format,$option)
            $this.Counter.Calls++
            1
        }
        $session = [pscustomobject]@{ Hwp = $hwp }

        $result = Open-HwpDocumentFromMemory -Session $session -LiteralPath $path -MaximumFileBytes 1024

        $result.Status | Should Be 'BLOCKED'
        ($result.Errors -join ' ') | Should Match '크기|한도'
        $counter.Calls | Should Be 0
    }
}
