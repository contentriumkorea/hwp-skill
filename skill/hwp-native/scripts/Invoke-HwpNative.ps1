[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('preflight','inspect','validate-plan','apply','generate','batch','compare','verify','export')]
    [string]$Command
)

$result = [ordered]@{
    status = 'BLOCKED'
    command = $Command
    errors = @('필수 실행 모듈을 불러올 수 없습니다.')
}

$result | ConvertTo-Json -Depth 10
exit 2
