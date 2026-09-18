[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InputPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
)

# Compatibility entry point: a hidden console never isolated Hancom COM from
# the user's desktop. This worker therefore cannot create a local COM session.
[pscustomobject]@{
    Status = 'BLOCKED'
    Errors = @('No isolated HWP converter is configured. Use the preserved HWPX document.')
    Visible = $false
    ContentWrittenByHancom = $false
} | ConvertTo-Json -Compress
exit 2
