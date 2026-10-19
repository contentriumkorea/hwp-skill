Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpHwpxModel.psm1') -Force
$script:ModelCli=Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/Invoke-HwpSkill.ps1'

Describe 'Pinned official model lookup without Hancom' {
    It 'reports the bounded scope without pretending all features are implemented' {
        $m=Get-HwpxFormatModel
        $m.counts.files|Should Be 288
        $m.counts.classes|Should Be 316
        $m.counts.writeAttributes|Should Be 723
        $m.semanticAuditComplete|Should Be $false
        $m.inheritanceResolved|Should Be $false
        $m.source.commit|Should Be '1453388472c703a4b299a0834f425cdac16644b9'
    }
    It 'finds direct attributes and enum facts by class' {
        $m=Get-HwpxFormatModel -ModelClass CVisibility
        @($m.classes).Count|Should Be 1
        ($m.classes[0].definition.writeAttributes.name -contains 'hideFirstHeader')|Should Be $true
        ($m.enums.g_VisibilityValueList -join ',')|Should Be 'HIDE_FIRST,SHOW_FIRST,SHOW_ALL'
        ((Get-HwpxFormatModel -ModelClass CMarginAttrubute).classes[0].definition.writeAttributes.name -join ',')|Should Be 'left,right,top,bottom'
    }
    It 'resolves observed element aliases without claiming a unique XPath' {
        $m=Get-HwpxFormatModel -ElementName secPr
        $m.classes[0].name|Should Be CSectionDefinitionType
        ($m.classes[0].definition.children.element -contains 'pagePr')|Should Be $true
    }
    It 'returns exact enum values and rejects unknown or conflicting selectors' {
        ((Get-HwpxFormatModel -ModelEnum g_ParaLineWrapList).values -join ',')|Should Be 'BREAK,SQUEEZE,KEEP'
        {Get-HwpxFormatModel -ModelClass UnknownClass}|Should Throw
        {Get-HwpxFormatModel -ModelClass CVisibility -ElementName secPr}|Should Throw
    }
    It 'works through the real public CLI' {
        $raw=& (Get-Process -Id $PID).Path -NoProfile -File $script:ModelCli format-model -ModelClass CVisibility
        $LASTEXITCODE|Should Be 0
        $m=($raw -join "`n")|ConvertFrom-Json
        $m.status|Should Be PASS
        $m.data.classes[0].name|Should Be CVisibility
    }
}
