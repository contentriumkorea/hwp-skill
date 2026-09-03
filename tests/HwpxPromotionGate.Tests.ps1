$root = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib'
Import-Module (Join-Path $root 'HwpGenerate.psm1') -Force
Import-Module (Join-Path $root 'HwpInspect.psm1') -Force

Describe 'Independent HWPX promotion gate' {
    It 'reports independent structural checks without claiming native layout' {
        $plan = '{"version":"2.0","content":[{"type":"paragraph","text":"contract"}]}' | ConvertFrom-Json
        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath (Join-Path $TestDrive 'checked.hwpx')
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $result.StructuralVerification.Status | Should Be 'PASS'
        ($result.StructuralVerification.Checks -gt 0) | Should Be $true
        $result.StructuralVerification.NativeLayoutVerified | Should Be $false
    }

    It 'does not promote a corrupt page even if the ordinary inspector passes' {
        $plan = '{"version":"2.0","content":[{"type":"paragraph","text":"contract"}]}' | ConvertFrom-Json
        $output = Join-Path $TestDrive 'corrupt.hwpx'
        $inspector = {
            param($path, $context, $capabilities)
            $inspection = Get-HwpInspection -LiteralPath $path -ExecutionContext $context -Capabilities $capabilities
            $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Update)
            try {
                $entry = $archive.GetEntry('Contents/section0.xml')
                $reader = [IO.StreamReader]::new($entry.Open())
                try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $entry.Delete()
                $writer = [IO.StreamWriter]::new($archive.CreateEntry('Contents/section0.xml').Open(), [Text.UTF8Encoding]::new($false))
                try { $writer.Write($xml.Replace('landscape="WIDELY"', 'landscape="NARROWLY"')) } finally { $writer.Dispose() }
            } finally { $archive.Dispose() }
            return $inspection
        }
        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $output -Inspector $inspector
        $result.Status | Should Be 'FAILED'
        (Test-Path -LiteralPath $output) | Should Be $false
        ($result.Errors -join ' ') | Should Match 'landscape'
    }
}
