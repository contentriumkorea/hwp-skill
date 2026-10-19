Set-StrictMode -Version Latest

function Get-HwpxFormatModel {
    [CmdletBinding()]
    param([string]$ModelClass,[string]$ElementName,[string]$ModelEnum)
    $selectors=@($ModelClass,$ElementName,$ModelEnum|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
    if($selectors.Count -gt 1){throw 'Use only one model selector.'}
    foreach($selector in $selectors){if($selector -cnotmatch '^[A-Za-z_][A-Za-z_0-9]{0,127}$'){throw 'Invalid model selector.'}}
    $path=Join-Path $PSScriptRoot '../../references/hwpx-model-catalog.json'
    if((Get-Item -LiteralPath $path).Length -gt 4MB){throw 'Model catalog exceeds its size limit.'}
    $model=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json
    $result=[ordered]@{source=$model.source;counts=$model.counts;scope=$model.scope;semanticAuditComplete=$false;inheritanceResolved=$false;limitations=@($model.limitations)}
    if(-not [string]::IsNullOrWhiteSpace($ModelEnum)) {
        $entry=@($model.enums.PSObject.Properties|Where-Object Name -CEQ $ModelEnum)
        if($entry.Count -ne 1){throw 'Unknown model enum.'}
        $result.enum=$ModelEnum;$result.values=@($entry[0].Value)
    } elseif($selectors.Count -eq 1) {
        $classes=@($model.classes.PSObject.Properties|Where-Object {
            if(-not [string]::IsNullOrWhiteSpace($ModelClass)){$_.Name -ceq $ModelClass}else{$ElementName -cin $_.Value.elements}
        })
        if($classes.Count -eq 0){throw 'Unknown model class or observed element alias.'}
        $result.classes=@($classes|ForEach-Object {[pscustomobject]@{name=$_.Name;definition=$_.Value}})
        $result.enums=[ordered]@{}
        foreach($class in $classes) {
            foreach($attribute in @($class.Value.writeAttributes)+@($class.Value.readAttributes)) {
                $prop=$attribute.PSObject.Properties['enum']
                if($null -ne $prop -and -not $result.enums.Contains($prop.Value)) {
                    $entry=$model.enums.PSObject.Properties[$prop.Value]
                    if($null -ne $entry){$result.enums[$prop.Value]=@($entry.Value)}
                }
            }
        }
    } else {
        $result.classNames=@($model.classes.PSObject.Properties.Name)
        $result.enumNames=@($model.enums.PSObject.Properties.Name)
    }
    # The file manifest is available in the bundled catalog; keep routine tool output compact.
    $result.source=[pscustomobject]@{repository=$model.source.repository;commit=$model.source.commit;license=$model.source.license}
    [pscustomobject]$result
}

Export-ModuleMember -Function Get-HwpxFormatModel
