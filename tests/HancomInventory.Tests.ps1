Describe 'Static Hancom command inventory' {
    It 'retains definitions from every resource and unresolved command references without claiming support' {
        Import-Module (Join-Path $PSScriptRoot '../tools/HancomInventory.psm1') -Force -ErrorAction Stop
        $definitions=@{
            'commands.xml'='<Commands><Command name="Save"/><Command name="Sort"><Button><CommandItem command="SortRows"/></Button></Command></Commands>'
            'property.xml'='<CommandsProperty><CommandGroup name="Table"><Command name="Sort"/></CommandGroup></CommandsProperty>'
            'frame.xml'='<Frame><CommandItem command="Save"/><CommandItem command="SortRows"/></Frame>'
        }
        $result=ConvertFrom-HancomCommandDefinitions -Definitions $definitions
        $result.commands.Count | Should Be 3
        ($result.commands | Where-Object id -eq 'Sort').definitions.Count | Should Be 2
        ($result.commands | Where-Object id -eq 'SortRows').defined | Should Be $false
        ($result.commands | Where-Object id -eq 'SortRows').references.Count | Should Be 2
        @($result.commands | Where-Object reviewState -ne 'inventory-only').Count | Should Be 0
        $result.semanticAuditComplete | Should Be $false
    }
    It 'rejects DTD and malformed definitions instead of silently omitting their commands' {
        Import-Module (Join-Path $PSScriptRoot '../tools/HancomInventory.psm1') -Force -ErrorAction Stop
        {ConvertFrom-HancomCommandDefinitions -Definitions @{'bad.xml'='<!DOCTYPE x [<!ENTITY a "x">]><Commands><Command name="&a;"/></Commands>'}} | Should Throw
        {ConvertFrom-HancomCommandDefinitions -Definitions @{'bad.xml'='<Commands>'}} | Should Throw
    }
}
