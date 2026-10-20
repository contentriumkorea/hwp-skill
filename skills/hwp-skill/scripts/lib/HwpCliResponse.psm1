Set-StrictMode -Version Latest

function Get-HwpResponseMap {
    param([AllowNull()][object]$Value)
    $map = [ordered]@{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) { $map[$key] = $Value[$key] }
    }
    elseif ($null -ne $Value) {
        foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = $property.Value }
    }
    return ,$map
}

function Get-HwpInspectionResponseSummary {
    param([AllowNull()][object]$Inspection)
    if ($null -eq $Inspection) { return $null }
    $map = Get-HwpResponseMap $Inspection
    $summary = [ordered]@{}
    foreach ($key in 'status','path','sha256','detectedKind','pageCount','layout','warnings','errors') {
        if ($map.Contains($key)) { $summary[$key] = $map[$key] }
    }
    foreach ($key in 'paragraphs','tables','controls','sections') {
        if ($map.Contains($key)) { $summary[$key + 'Count'] = @($map[$key]).Count }
    }
    [pscustomobject]$summary
}

function ConvertTo-HwpCliResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result, [Parameter(Mandatory)][string]$Command)

    # Projection is deliberately after execution/verification. Never mutate the
    # full result or feed the shortened view back into safety checks.
    $view = Get-HwpResponseMap $Result
    $omitted = @()
    if ($Command -eq 'inspect' -and $view.Contains('resources')) {
        $resources = Get-HwpResponseMap $view['resources']
        $counts = [ordered]@{}
        foreach ($key in $resources.Keys) { $counts[$key] = @($resources[$key]).Count }
        $view.Remove('resources')
        $view['resourceSummary'] = [pscustomobject]$counts
        $omitted = @('resources')
    }
    elseif ($Command -eq 'generate' -and $view.Contains('data') -and $null -ne $view['data']) {
        $data = Get-HwpResponseMap $view['data']
        # The historical full API mirrors data at the top level. Compact keeps
        # one copy, including all operation failures and recovery paths.
        foreach ($key in @($data.Keys)) {
            if ($key -notin @('status','command','warnings','errors','data')) { $view.Remove($key) }
        }
        foreach ($key in 'Before','After') {
            if ($data.Contains($key)) {
                $data[$key + 'Summary'] = Get-HwpInspectionResponseSummary $data[$key]
                $data.Remove($key)
                $omitted += 'data.' + $key
            }
        }
        $view['data'] = [pscustomobject]$data
    }
    else {
        # Unknown result contracts and failures are returned intact, not guessed.
        return $Result
    }
    $view['resultDetail'] = 'compact'
    $view['omitted'] = $omitted
    $view['fullResultHint'] = 'Use -ResultDetail full for resource definitions and complete inspections; inspect the output for editing addresses.'
    [pscustomobject]$view
}

Export-ModuleMember -Function ConvertTo-HwpCliResponse
