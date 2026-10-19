[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BinDirectory,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HancomInventory.psm1') -Force
if(Test-Path -LiteralPath $OutputPath){throw 'Inventory output already exists; choose a new path.'}
$ui=Get-HancomEmbeddedDefinitions -Path (Join-Path $BinDirectory 'Hwp.UxXml.dll')
$libraries=@(foreach($name in @('HwpObject.tlb','HwpAutomation.tlb')){Get-HancomTypeLibraryInventory -Path (Join-Path $BinDirectory $name)})
$dialogFiles=@(Get-ChildItem -LiteralPath (Join-Path $BinDirectory 'UxXml/Hancom2016/Hwp') -Recurse -File -Filter '*.xml'|Sort-Object FullName|ForEach-Object {
    @{relativePath=$_.FullName.Substring($BinDirectory.TrimEnd('\','/').Length+1);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
})
$result=[ordered]@{
    schemaVersion='1.0';collectedAtUtc=[DateTime]::UtcNow.ToString('o');targetApplication='한글2024'
    scope='All command/name and command-reference entries in the 14 embedded XML resources; all types and function descriptors in the two selected TLBs; installed Hwp loose dialog XML file identities.'
    targetExecuted=$false;comServerActivated=$false;semanticAuditComplete=$false;nativeRenderingVerified=$false
    limitations=@('UI definitions can include inactive, compatibility or unavailable commands.','TLB entries overlap and include inherited IUnknown/IDispatch methods; counts are not distinct user features.','Native binary-only dialogs, compiled BAML, CHM contents and runtime-generated commands are not semantically inventoried.','Inventory does not establish command behavior or document-engine support.')
    ui=$ui;typeLibraries=$libraries;looseDialogFiles=$dialogFiles
}
$json=ConvertTo-Json -InputObject $result -Depth 18
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,[Text.UTF8Encoding]::new($false))
[pscustomobject]@{path=[IO.Path]::GetFullPath($OutputPath);commands=$ui.inventory.commands.Count;typeCounts=@($libraries|ForEach-Object {$_.types.Count});memberCounts=@($libraries|ForEach-Object {($_.types|ForEach-Object {$_.members.Count}|Measure-Object -Sum).Sum});looseDialogs=$dialogFiles.Count;semanticAuditComplete=$false}
