Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpConversionVerify.psm1') -Force

InModuleScope HwpConversionVerify {
    Describe 'Final HWP image claims fail closed without reference correspondence' {
        It 'does not trust equal picture counts and an embedded asset inventory' {
            # Unit boundary: both original assets exist, but picture references are
            # reversed. Current binary inspection does not supply a verified map.
            Mock Get-HwpInspection {
                param($LiteralPath)
                $source = [IO.Path]::GetExtension($LiteralPath) -eq '.hwpx'
                [pscustomobject]@{
                    Status='PASS_WITH_WARNINGS';DetectedKind=$(if($source){'HWPX-ZIP'}else{'HWP-BINARY'})
                    Text='SAME';Tables=@();Sha256=('1'*64)
                    Controls=@(@{CtrlId='pic';BinaryId=$(if($source){1}else{2})},@{CtrlId='pic';BinaryId=$(if($source){2}else{1})})
                }
            }
            Mock Get-HwpPortableInspection {
                [pscustomobject]@{Status='PASS_WITH_WARNINGS';Data=[pscustomobject]@{BinaryAssetsVerified=$true;BinaryAssets=@(@{Sha256=('a'*64)},@{Sha256=('b'*64)})}}
            }
            $fixture = Join-Path $TestDrive 'source.hwpx'
            $zip=[IO.Compression.ZipFile]::Open($fixture,[IO.Compression.ZipArchiveMode]::Create)
            $zip.Dispose()
            $result=Test-HwpConvertedContent -InputPath $fixture -OutputPath (Join-Path $TestDrive 'converted.hwp')
            $result.Status | Should Be 'FAILED'
            $result.ImagesVerified | Should Be $false
            ($result.Errors -join ' ') | Should Match 'picture-to-asset correspondence'
        }
    }
}
