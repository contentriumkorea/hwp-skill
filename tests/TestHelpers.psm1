function New-Operation {
    [CmdletBinding()]
    param(
        [string]$Type = 'replace-text',
        [string]$Anchor = '기존 문구',
        [string]$Before = '기존 문구',
        [string]$After = '새 문구',
        [ValidateSet('safe','advanced')]
        [string]$Risk = 'safe',
        [int]$ExpectedMatches = 1,
        [ValidateSet('stop','skip')]
        [string]$OnFailure = 'stop'
    )

    [pscustomobject]@{
        id = [guid]::NewGuid().ToString('n')
        type = $Type
        risk = $Risk
        expectedMatches = $ExpectedMatches
        target = [pscustomobject]@{
            anchor = $Anchor
            beforeContext = ''
            afterContext = ''
        }
        before = $Before
        after = $After
        onFailure = $OnFailure
        verify = [pscustomobject]@{
            kind = 'text-contains'
            expected = $After
        }
    }
}

function New-ValidPlan {
    [CmdletBinding()]
    param(
        [string]$Type = 'replace-text',
        [ValidateSet('safe','advanced')]
        [string]$Risk = 'safe',
        [bool]$ApprovedAdvanced = $false,
        [string]$VerifyExpected = '새 문구',
        [string]$SourcePath = 'C:\fixture.hwp',
        [string]$SourceSha256 = ('a' * 64)
    )

    [pscustomobject]@{
        version = '1.0'
        source = [pscustomobject]@{
            path = $SourcePath
            sha256 = $SourceSha256
        }
        approvedAdvanced = $ApprovedAdvanced
        operations = @(
            New-Operation -Type $Type -Anchor '기존 문구' -Before '기존 문구' -After $VerifyExpected -Risk $Risk
        )
    }
}

Export-ModuleMember -Function New-Operation, New-ValidPlan
