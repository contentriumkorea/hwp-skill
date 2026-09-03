Describe 'Stored HWPX mimetype on both Windows runtimes' {
    foreach ($shell in @('pwsh','powershell')) {
        It ("writes and edits a stored first mimetype using $shell") {
            $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'
            $plan=Join-Path $TestDrive ($shell+'.json')
            [IO.File]::WriteAllText($plan,'{"version":"2.0","content":[{"type":"paragraph","text":"stored"}]}')
            $original=Join-Path $TestDrive ($shell+'.hwpx')
            $raw=& $shell -NoProfile -File $cli generate -NewDocument -PlanPath $plan -OutputPath $original
            $LASTEXITCODE | Should Be 0
            foreach ($path in @($original,(Join-Path $TestDrive ($shell+'-edited.hwpx')))) {
                if ($path -ne $original) {
                    $edit=Join-Path $TestDrive ($shell+'-edit.json')
                    [IO.File]::WriteAllText($edit,'{"version":"2.0","operations":[{"type":"set-page","sectionIndex":0,"orientation":"LANDSCAPE"}]}')
                    $raw=& $shell -NoProfile -File $cli edit-hwpx -LiteralPath $original -PlanPath $edit -OutputPath $path -ApproveAdvanced
                    $LASTEXITCODE | Should Be 0
                }
                $bytes=[IO.File]::ReadAllBytes($path)
                [BitConverter]::ToUInt32($bytes,0) | Should Be 0x04034b50
                [BitConverter]::ToUInt16($bytes,8) | Should Be 0
                [BitConverter]::ToUInt16($bytes,26) | Should Be 8
                [BitConverter]::ToUInt16($bytes,28) | Should Be 0
                [Text.Encoding]::ASCII.GetString($bytes,30,8) | Should Be mimetype
                [Text.Encoding]::ASCII.GetString($bytes,38,19) | Should Be 'application/hwp+zip'
            }
        }
    }
}
