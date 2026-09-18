Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxObjects.psm1') -Force
Describe 'Portable image decoding without GDI or application windows' {
    It 'fully decodes a PNG using the portable validator' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        Test-HwpxPortableRasterIntegrity (Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png') | Should Be $true
    }
    It 'rejects a truncated PNG rather than trusting its dimensions' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
        $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures/source/fixture-blue.png'))
        $path=Join-Path $TestDrive 'truncated.png'
        [IO.File]::WriteAllBytes($path,$bytes[0..30])
        { Test-HwpxPortableRasterIntegrity $path } | Should Throw 'Invalid or incomplete'
    }
}
