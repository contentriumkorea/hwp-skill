Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxScopedEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpInspect.psm1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Read-ReXml($Path) {
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try{$reader=[IO.StreamReader]::new($zip.GetEntry('Contents/section0.xml').Open());try{[xml]$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
}
function Invoke-ReEdit($Source,$Output,$Operation){Invoke-HwpxScopedEdit -LiteralPath $Source -OutputPath $Output -Plan @{version='2.0';operations=@($Operation)}}
Describe 'Public no-window header footer and note settings edits' {
    BeforeEach {
        $dir=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $dir
        $source=Join-Path $dir 'source.hwpx';$output=Join-Path $dir 'output.hwpx'
        Copy-Item (Join-Path $PSScriptRoot '../skills/hwp-skill/templates/default.hwpx') $source
        $hash=(Get-FileHash $source).Hash
    }
    It 'inserts a rich header and later replaces it using an exact source text guard' {
        $r=Invoke-ReEdit $source $output @{type='set-header-footer';sectionIndex=0;kind='header';applyTo='BOTH';expectedText='';paragraphs=@(@{runs=@(@{text='Header';textStyle=@{bold=$true}},@{text="`tRight"});paragraphStyle=@{alignment='RIGHT'}})}
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-ReXml $output;$node=$xml.SelectSingleNode('//*[local-name()="header"]')
        $node.GetAttribute('applyPageType')|Should Be BOTH
        $node.SelectNodes('.//*[local-name()="run"]').Count|Should Be 2
        $next=Join-Path $dir 'replaced.hwpx'
        $r=Invoke-ReEdit $output $next @{type='set-header-footer';sectionIndex=0;kind='header';applyTo='BOTH';expectedText="Header`tRight";paragraphs=@(@{text='Replacement'})}
        ($r.Errors -join '; ')|Should Be ''
        (Read-ReXml $next).SelectSingleNode('//*[local-name()="header"]').InnerText|Should Be Replacement
        (Get-FileHash $source).Hash|Should Be $hash
    }
    It 'sets independent footnote and endnote settings in separate inspect-edit passes' {
        $r=Invoke-ReEdit $source $output @{type='set-note-settings';sectionIndex=0;kind='footnote';settings=@{numbering=@{type='ON_PAGE';newNum=3};noteSpacing=@{betweenNotesMm=2.54;belowLineMm=1.27};placement=@{place='MERGED_COLUMN';beneathText=$true}}}
        ($r.Errors -join '; ')|Should Be ''
        $xml=Read-ReXml $output;$note=$xml.SelectSingleNode('//*[local-name()="footNotePr"]')
        $note.SelectSingleNode('*[local-name()="numbering"]').GetAttribute('type')|Should Be ON_PAGE
        $note.SelectSingleNode('*[local-name()="noteSpacing"]').GetAttribute('betweenNotes')|Should Be '720'
        $xml.SelectSingleNode('//*[local-name()="endNotePr"]').OuterXml|Should BeExactly (Read-ReXml $source).SelectSingleNode('//*[local-name()="endNotePr"]').OuterXml
        $next=Join-Path $dir 'endnote.hwpx'
        $r=Invoke-ReEdit $output $next @{type='set-note-settings';sectionIndex=0;kind='endnote';settings=@{numbering=@{type='ON_SECTION';newNum=1};placement=@{place='END_OF_SECTION'}}}
        ($r.Errors -join '; ')|Should Be ''
        (Read-ReXml $next).SelectSingleNode('//*[local-name()="endNotePr"]/*[local-name()="placement"]').GetAttribute('place')|Should Be END_OF_SECTION
        (Get-FileHash $source).Hash|Should Be $hash
    }
    It 'rejects a wrong header guard and an unsupported note numbering mode without writing' {
        foreach($op in @(
            @{type='set-header-footer';sectionIndex=0;kind='header';applyTo='BOTH';expectedText='not empty';paragraphs=@(@{text='not written'})},
            @{type='set-note-settings';sectionIndex=0;kind='endnote';settings=@{numbering=@{type='ON_PAGE'}}}
        )){$r=Invoke-ReEdit $source $output $op;$r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $hash}
    }
    It 'exposes stored section note definitions for readback without assuming rendered numbering' {
        $notes=(Get-HwpxPackageInspection -LiteralPath $source).Data.Sections[0].noteDefinitions
        @($notes).Count|Should Be 2
        $foot=@($notes|Where-Object kind -eq 'footnote')[0]
        @($foot.properties.children|Where-Object element -eq 'numbering')[0].attributes.type|Should Be CONTINUOUS
    }
    It 'requires advanced approval through the real CLI and succeeds when provided' {
        $cli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1';$shell=(Get-Process -Id $PID).Path
        $ops=@(
            @{type='set-header-footer';sectionIndex=0;kind='footer';applyTo='BOTH';expectedText='';paragraphs=@(@{text='Footer'})},
            @{type='set-note-settings';sectionIndex=0;kind='footnote';settings=@{numbering=@{type='ON_PAGE';newNum=1}}}
        )
        for($i=0;$i -lt $ops.Count;$i++){
            $plan=Join-Path $dir ('plan-'+$i+'.json');$target=Join-Path $dir ('cli-'+$i+'.hwpx')
            [IO.File]::WriteAllText($plan,(@{version='2.0';operations=@($ops[$i])}|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            $raw=& $shell -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $target
            $LASTEXITCODE|Should Be 2;(($raw -join "`n")|ConvertFrom-Json).status|Should Be BLOCKED;Test-Path $target|Should Be $false
            $raw=& $shell -NoProfile -File $cli edit-hwpx -LiteralPath $source -PlanPath $plan -OutputPath $target -ApproveAdvanced
            $LASTEXITCODE|Should Be 0;(($raw -join "`n")|ConvertFrom-Json).status|Should Be PASS_WITH_WARNINGS
        }
        (Get-FileHash $source).Hash|Should Be $hash
    }
    It 'refuses overlapping section note and header replacements in the same plan' {
        $r=Invoke-HwpxScopedEdit -LiteralPath $source -OutputPath $output -Plan @{version='2.0';operations=@(
            @{type='set-note-settings';sectionIndex=0;kind='footnote';settings=@{numbering=@{type='ON_PAGE'}}},
            @{type='set-header-footer';sectionIndex=0;kind='header';applyTo='BOTH';expectedText='';paragraphs=@(@{text='Header'})}
        )}
        $r.Status|Should Be BLOCKED;($r.Errors -join '; ')|Should Match 'Overlapping'
        Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $hash
    }
    It 'keeps extension note attributes separate from actual schema numbering values' {
        $module=Get-Module HwpInspect
        & $module {
            [xml]$x='<hp:numbering xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:v="urn:vendor" type="CONTINUOUS" newNum="1" v:type="ON_PAGE"/>'
            $read=Get-HwpxElementProperties $x.DocumentElement -PreserveXml
            $read.attributes.type|Should Be CONTINUOUS
            $read.attributes.'v:type'|Should Be ON_PAGE
            $read.xml|Should Match 'v:type="ON_PAGE"'
        }
    }
    It 'rejects policy values that only match through linguistic comparison' -TestCases @(
        @{Stored='';Requested=('BO'+[char]0xAD+'TH')},
        @{Stored=('BO'+[char]0xAD+'TH');Requested='EVEN'},
        @{Stored=('EV'+[char]0xAD+'EN');Requested='ODD'}
    ) {
        param($Stored,$Requested)
        if($Stored){
            $created=Join-Path $dir 'created.hwpx'
            $policy=if($Stored.StartsWith('BO')){'BOTH'}else{'EVEN'}
            $r=Invoke-ReEdit $source $created @{type='set-header-footer';sectionIndex=0;kind='header';applyTo=$policy;expectedText='';paragraphs=@(@{text='Existing'})}
            ($r.Errors -join '; ')|Should Be ''
            $doc=Read-ReXml $created;$doc.SelectSingleNode('//*[local-name()="header"]').SetAttribute('applyPageType',$Stored)
            $zip=[IO.Compression.ZipFile]::Open($created,'Update')
            try{$zip.GetEntry('Contents/section0.xml').Delete();$stream=$zip.CreateEntry('Contents/section0.xml').Open();$bytes=[Text.Encoding]::UTF8.GetBytes($doc.OuterXml);try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
            $source=$created
        }
        $sha=(Get-FileHash $source).Hash
        $r=Invoke-ReEdit $source $output @{type='set-header-footer';sectionIndex=0;kind='header';applyTo=$Requested;expectedText='';paragraphs=@(@{text='New'})}
        $r.Status|Should Be BLOCKED;Test-Path $output|Should Be $false;(Get-FileHash $source).Hash|Should Be $sha
    }
}
