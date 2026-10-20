# Independent regressions for input-conversion ownership and promotion races.
# Only disposable review artifacts are changed by the injected concurrent actors.
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInputConvert.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpDocumentModel.psm1') -Force
. (Join-Path $PSScriptRoot 'fixtures/New-ConversionFixture.ps1')

function New-SafetyConversionInput([string]$Path) {
    # Rebuild from the bundled, independent HWP source on every test run. Remove
    # only the known field-bearing paragraph subtree to obtain a supported input.
    $original=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
    $session=[Contentrium.HwpSkill.CompoundFileReader]::Open($original)
    try {
        $header=$session.ReadStream('','FileHeader',1MB)
        $doc=$session.ReadStream('','DocInfo',1MB)
        $body=$session.ReadStream('BodyText','Section0',1MB)
        if(([BitConverter]::ToUInt32($header,36) -band 1) -ne 0){
            $doc=[Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($doc,1MB)
            $body=[Contentrium.HwpSkill.CompoundFileReader]::ExpandDeflate($body,1MB)
        }
        $paragraphs=@(Get-HwpPortableRecords $body|Where-Object {$_.tagId -eq 0x42 -and $_.level -eq 0})
        if($paragraphs.Count -lt 6){throw 'Independent source fixture has changed; review the field-subtree selection.'}
        $first=$paragraphs[4].offset;$last=$paragraphs[5].offset
        $memory=[IO.MemoryStream]::new()
        try{$memory.Write($body,0,$first);$memory.Write($body,$last,$body.Length-$last);$clean=$memory.ToArray()}finally{$memory.Dispose()}
        [Array]::Copy([BitConverter]::GetBytes([uint32]0),0,$header,36,4)
        Write-ConversionCompoundFile -Path $Path -RootStreams @{FileHeader=$header;DocInfo=$doc} -BodyStreams @{Section0=$clean}
    }finally{$session.Dispose()}
}

Describe 'HWP input conversion workspace ownership safety' {
    BeforeEach {
        $review=Join-Path $PSScriptRoot 'output/hwp-input-conversion-2026-10-20/review'
        $case=Join-Path $review ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $case -Force
        $source=Join-Path $case 'clean-native.hwp';$output=Join-Path $case 'converted.hwpx'
        New-SafetyConversionInput $source
        $sourceHash=(Get-FileHash -LiteralPath $source).Hash
        $original=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $originalHash=(Get-FileHash -LiteralPath $original).Hash
    }

    It 'does not clean a workspace owned by another actor when directory creation loses a race' {
        Mock New-Item -ModuleName HwpInputConvert -ParameterFilter {
            $ItemType -eq 'Directory' -and [IO.Path]::GetFileName($Path) -like '.hwp-convert-*'
        } -MockWith {
            param($ItemType,$Path)
            # Model the other actor winning mkdir immediately before our call:
            # New-Item must fail and must never grant this converter ownership.
            $null=[IO.Directory]::CreateDirectory($Path)
            [IO.File]::WriteAllText((Join-Path $Path 'other-owner.txt'),'preserve the other owner')
            throw [IO.IOException]::new('Injected workspace creation collision.')
        }
        $result=Invoke-HwpToHwpx -LiteralPath $source -OutputPath $output
        [IO.File]::WriteAllText((Join-Path $case 'workspace-race-result.json'),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Assert-MockCalled New-Item -ModuleName HwpInputConvert -Times 1 -Exactly -ParameterFilter {
            $ItemType -eq 'Directory' -and [IO.Path]::GetFileName($Path) -like '.hwp-convert-*'
        }
        $result.Status|Should Be BLOCKED
        Test-Path -LiteralPath $output|Should Be $false
        (Get-FileHash -LiteralPath $source).Hash|Should Be $sourceHash
        (Get-FileHash -LiteralPath $original).Hash|Should Be $originalHash
        $workspaces=@(Get-ChildItem -LiteralPath $case -Directory -Force|Where-Object Name -Like '.hwp-convert-*')
        $workspaces.Count|Should Be 1
        [IO.File]::ReadAllText((Join-Path $workspaces[0].FullName 'other-owner.txt'))|Should BeExactly 'preserve the other owner'
    }

}

Describe 'HWP input conversion candidate promotion safety' {
    BeforeEach {
        $review=Join-Path $PSScriptRoot 'output/hwp-input-conversion-2026-10-20/review'
        $case=Join-Path $review ([guid]::NewGuid().ToString('N'))
        $null=New-Item -ItemType Directory -Path $case -Force
        $source=Join-Path $case 'clean-native.hwp';$output=Join-Path $case 'converted.hwpx'
        New-SafetyConversionInput $source
        $sourceHash=(Get-FileHash -LiteralPath $source).Hash
        $original=Join-Path $PSScriptRoot 'fixtures/source/native-fixture.hwp'
        $originalHash=(Get-FileHash -LiteralPath $original).Hash
    }
    It 'blocks bytes changed after the final candidate hash rather than promoting an unverified path' {
        Mock Get-HwpSha256 -ModuleName HwpInputConvert -ParameterFilter {
            [IO.Path]::GetFileName($LiteralPath) -ceq 'candidate.hwpx'
        } -MockWith {
            param($LiteralPath)
            $verifiedHash=(Get-FileHash -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
            # Keep the truthful hash of the old bytes while the concurrent actor
            # replaces the candidate after hashing, before publication.
            [IO.File]::WriteAllBytes($LiteralPath,[Text.Encoding]::ASCII.GetBytes('unverified concurrent candidate replacement'))
            return $verifiedHash
        }
        $result=Invoke-HwpToHwpx -LiteralPath $source -OutputPath $output
        [IO.File]::WriteAllText((Join-Path $case 'candidate-race-result.json'),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Assert-MockCalled Get-HwpSha256 -ModuleName HwpInputConvert -Times 1 -Exactly -ParameterFilter {
            [IO.Path]::GetFileName($LiteralPath) -ceq 'candidate.hwpx'
        }
        $result.Status|Should Be BLOCKED
        Test-Path -LiteralPath $output|Should Be $false
        (Get-FileHash -LiteralPath $source).Hash|Should Be $sourceHash
        (Get-FileHash -LiteralPath $original).Hash|Should Be $originalHash
        @(Get-ChildItem -LiteralPath $case -Force|Where-Object Name -Like '.hwp-convert-*').Count|Should Be 0
    }
}
