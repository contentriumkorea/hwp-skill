Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpPortable.psm1') -ErrorAction Stop

function ConvertTo-HwpComparableText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    # Binary and XML readers expose paragraph separators differently.
    # Preserve word order and all non-whitespace characters.
    return [regex]::Replace([string]$Text, '\s+', ' ').Trim()
}

function Test-HwpConvertedContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $errors = [Collections.Generic.List[string]]::new()
    $source = Get-HwpInspection -LiteralPath $InputPath
    $actual = Get-HwpInspection -LiteralPath $OutputPath
    if ($source.Status -notin 'PASS','PASS_WITH_WARNINGS' -or $source.DetectedKind -ne 'HWPX-ZIP') {
        $errors.Add('Conversion source is not a readable HWPX document.')
    }
    if ($actual.Status -notin 'PASS','PASS_WITH_WARNINGS' -or $actual.DetectedKind -ne 'HWP-BINARY') {
        $errors.Add('Converted HWP is not a readable HWP 5.x document.')
    }
    if ($errors.Count -eq 0) {
        if ((ConvertTo-HwpComparableText $source.Text) -cne (ConvertTo-HwpComparableText $actual.Text)) {
            $errors.Add('Converted HWP content does not match the source text.')
        }
        foreach ($ctrlId in @('tbl','pic')) {
            $expected = @($source.Controls | Where-Object CtrlId -eq $ctrlId).Count
            $found = @($actual.Controls | Where-Object CtrlId -eq $ctrlId).Count
            if ($expected -ne $found) { $errors.Add("Converted HWP $ctrlId count mismatch: $expected / $found.") }
        }
        if (@($source.Tables).Count -ne @($actual.Tables).Count) {
            $errors.Add('Converted HWP table structure count differs.')
        } else {
            for ($i=0; $i -lt @($source.Tables).Count; $i++) {
                $before = $source.Tables[$i]; $after = $actual.Tables[$i]
                if ($before.RowCount -ne $after.RowCount -or $before.ColumnCount -ne $after.ColumnCount -or @($before.Cells).Count -ne @($after.Cells).Count) {
                    $errors.Add("Converted HWP table $i dimensions differ."); continue
                }
                foreach ($cell in $before.Cells) {
                    $matches = @($after.Cells | Where-Object { $_.RowAddress -eq $cell.RowAddress -and $_.ColumnAddress -eq $cell.ColumnAddress })
                    if ($matches.Count -ne 1) { $errors.Add("Converted HWP table $i cell address is absent or ambiguous."); continue }
                    $match = $matches[0]
                    if ($cell.RowSpan -ne $match.RowSpan -or $cell.ColumnSpan -ne $match.ColumnSpan -or (ConvertTo-HwpComparableText $cell.Text) -cne (ConvertTo-HwpComparableText $match.Text)) {
                        $errors.Add("Converted HWP table $i cell content or merged span differs.")
                    }
                }
            }
        }
        $imageCount = @($source.Controls | Where-Object CtrlId -eq 'pic').Count
        if ($imageCount -gt 0) {
            # An asset hash inventory cannot prove which picture uses which asset.
            # The binary reader does not yet expose verified picture-to-BinData
            # correspondence. Fail closed even if every original byte is present.
            $errors.Add('Converted HWP picture-to-asset correspondence is not verified; image-bearing HWP conversion cannot be promoted. Preserve the HWPX instead.')
            $portable = Get-HwpPortableInspection -LiteralPath $OutputPath -ExpectedSha256 $actual.Sha256
            if ($portable.Status -notin 'PASS','PASS_WITH_WARNINGS' -or $null -eq $portable.Data -or
                $portable.Data.PSObject.Properties.Name -notcontains 'BinaryAssetsVerified' -or
                -not $portable.Data.BinaryAssetsVerified) {
                $errors.Add('Converted HWP image bytes could not be verified.')
            } else {
                $actualHashes = @($portable.Data.BinaryAssets | ForEach-Object { ([string]$_.Sha256).ToLowerInvariant() })
                $zip = [IO.Compression.ZipFile]::OpenRead($InputPath)
                try {
                    foreach ($entry in @($zip.Entries | Where-Object FullName -match '^BinData/')) {
                        $stream=$entry.Open(); $sha=[Security.Cryptography.SHA256]::Create()
                        try { $expectedHash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
                        finally { $sha.Dispose(); $stream.Dispose() }
                        if ($actualHashes -notcontains $expectedHash) { $errors.Add('Converted HWP lost or changed an embedded image.') }
                    }
                } finally { $zip.Dispose() }
            }
        }
    }
    [pscustomobject]@{
        Status = if ($errors.Count) { 'FAILED' } else { 'PASS' }
        Errors = @($errors)
        After = $actual
        TextVerified = ($errors.Count -eq 0)
        TablesVerified = ($errors.Count -eq 0)
        ImagesVerified = ($errors.Count -eq 0)
        NativeLayoutVerified = $false
    }
}

Export-ModuleMember -Function 'Test-HwpConvertedContent'
