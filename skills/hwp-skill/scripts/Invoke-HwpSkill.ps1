[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('capabilities','format-model','preflight','inspect','convert-hwpx','convert-pdf','validate-plan','validate-generate-plan','edit-hwpx','preview','apply','generate','batch','compare','verify','export')]
    [string]$Command,

    [string]$LiteralPath,
    [string]$PlanPath,
    [string]$OutputPath,
    [string]$OutputDirectory,
    [string]$TemplatePath,
    [string]$ModelClass,
    [string]$ElementName,
    [string]$ModelEnum,
    [string]$BrowserPath,
    [ValidateSet('auto','stored-layout','reflow')][string]$PdfMode='auto',
    [string[]]$FontDirectories=@(),
    [string]$WorkDirectory,
    [ValidateSet('full','compact')][string]$ResultDetail = 'full',
    [switch]$NewDocument,
    [switch]$ApproveAdvanced,
    [string[]]$InputPaths,
    [string]$InputDirectory,
    [switch]$Apply,
    [switch]$Recurse,
    [string]$BeforePath,
    [string]$AfterPath,
    [ValidateSet('pdf','images')][string]$ExportKind = 'pdf',
    [switch]$RequireUnattendedOpen,
    [ValidateSet('silent','isolated-native','interactive')]
    [string]$ExecutionMode = 'silent',
    [switch]$AllowInteractiveWindow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

function Read-HwpCliJson {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ([IO.Path]::GetExtension($resolved).ToLowerInvariant() -ne '.json') {
        throw "JSON 파일이 아닙니다: $resolved"
    }
    $length = (Get-Item -LiteralPath $resolved).Length
    if ($length -gt 10485760) { throw 'JSON 파일이 10MB 안전 한도를 초과했습니다.' }
    $text = [IO.File]::ReadAllText($resolved, [Text.UTF8Encoding]::new($false, $true))
    $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
    if ($convertFromJson.Parameters.ContainsKey('Depth')) {
        return $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    $text | ConvertFrom-Json -ErrorAction Stop
}

function Assert-HwpCliValue {
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name 인수가 필요합니다." }
}

$libraryRoot = Join-Path $PSScriptRoot 'lib'
$result = $null
try {
    Import-Module (Join-Path $libraryRoot 'HwpExecution.psm1') -ErrorAction Stop
    Import-Module (Join-Path $libraryRoot 'HwpCapabilities.psm1') -ErrorAction Stop
    Import-Module (Join-Path $libraryRoot 'HwpBackendRouter.psm1') -ErrorAction Stop
    Import-Module (Join-Path $libraryRoot 'HwpCommon.psm1') -ErrorAction Stop

    # Dependencies import their own requirements. Read-only commands must not pay
    # the generation/editing engine startup cost or acquire unrelated state.
    $commandModules = switch ($Command) {
        'preflight' { if ($ExecutionMode -eq 'interactive') { 'HwpSession' } }
        'inspect' { 'HwpInspect' }
        'validate-plan' { 'HwpPlan' }
        'validate-generate-plan' { 'HwpGenerate' }
        'apply' { 'HwpPlan'; 'HwpEdit' }
        'generate' { 'HwpPlan'; 'HwpGenerate' }
        'batch' { 'HwpPlan'; 'HwpBatch' }
        'compare' { 'HwpVerify' }
        'verify' { 'HwpVerify' }
        'export' { 'HwpVerify' }
    }
    foreach ($module in $commandModules) {
        Import-Module (Join-Path $libraryRoot ($module + '.psm1')) -ErrorAction Stop
    }

    $hwpExecutionContext = New-HwpExecutionContext -Mode $ExecutionMode `
        -AllowInteractiveWindow:([bool]$AllowInteractiveWindow)
    $capabilities = Get-HwpCapabilitySnapshot -ExecutionContext $hwpExecutionContext

    $result = switch ($Command) {
        'format-model' {
            Import-Module (Join-Path $libraryRoot 'HwpHwpxModel.psm1') -ErrorAction Stop
            New-HwpResult -Status PASS -Command format-model -Data (Get-HwpxFormatModel -ModelClass $ModelClass -ElementName $ElementName -ModelEnum $ModelEnum)
            break
        }
        'capabilities' {
            $route = Resolve-HwpBackend -Command capabilities -Capabilities $capabilities `
                -ExecutionContext $hwpExecutionContext
            if ($route.Status -ne 'PASS') {
                New-HwpResult -Status FAILED -Command capabilities -Data $capabilities `
                    -Warnings @($route.Warnings) -Errors @($route.Errors)
            }
            else {
                New-HwpResult -Status PASS -Command capabilities -Data $capabilities
            }
            break
        }
        'preflight' {
            $route = Resolve-HwpBackend -Command preflight -Capabilities $capabilities `
                -ExecutionContext $hwpExecutionContext
            if ($route.Status -ne 'PASS') {
                New-HwpResult -Status FAILED -Command preflight -Data $capabilities `
                    -Warnings @($route.Warnings) -Errors @($route.Errors)
            }
            elseif ($ExecutionMode -eq 'interactive') {
                Invoke-HwpPreflight -ExecutionContext $hwpExecutionContext `
                    -RequireUnattendedOpen:([bool]$RequireUnattendedOpen)
            }
            else {
                New-HwpResult -Status PASS -Command preflight -Data $capabilities
            }
            break
        }
        'inspect' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Get-HwpInspection -LiteralPath $LiteralPath `
                -ExecutionContext $hwpExecutionContext -Capabilities $capabilities
            break
        }
        'convert-hwpx' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Assert-HwpCliValue -Value $OutputPath -Name 'OutputPath'
            Import-Module (Join-Path $libraryRoot 'HwpInputConvert.psm1') -ErrorAction Stop
            Invoke-HwpToHwpx -LiteralPath $LiteralPath -OutputPath $OutputPath
            break
        }
        'validate-plan' {
            Assert-HwpCliValue -Value $PlanPath -Name 'PlanPath'
            $imported = Import-HwpEditPlan -LiteralPath $PlanPath
            New-HwpResult -Status $imported.Status -Command validate-plan -Data $imported.Data `
                -Warnings @($imported.Warnings) -Errors @($imported.Errors)
            break
        }
        'validate-generate-plan' {
            Assert-HwpCliValue -Value $PlanPath -Name 'PlanPath'
            Test-HwpNewDocumentPlan -Plan (Read-HwpCliJson -Path $PlanPath)
            break
        }
        'edit-hwpx' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Assert-HwpCliValue -Value $PlanPath -Name 'PlanPath'
            Assert-HwpCliValue -Value $OutputPath -Name 'OutputPath'
            $plan=Read-HwpCliJson -Path $PlanPath
            if (@($plan.operations|Where-Object {$_.type -in @('set-page','set-columns','set-page-border','set-section-settings','set-note-settings','set-header-footer','set-object-format','set-paragraph-breaks','insert-paragraphs','delete-paragraph','move-paragraph','apply-named-style','set-cell-diagonal','sort-table-rows','merge-cells','split-cell','insert-table-row','insert-table-column','delete-table-row','delete-table-column','set-table-format','insert-cell-table')}).Count -gt 0 -and -not $ApproveAdvanced) {
                New-HwpResult -Status BLOCKED -Command edit-hwpx -Errors @('기존 문서의 쪽 설정과 표 구조 변경은 대상과 변경값을 확인한 후 -ApproveAdvanced로 실행합니다.')
                break
            }
            Import-Module (Join-Path $libraryRoot 'HwpHwpxScopedEdit.psm1') -ErrorAction Stop
            Invoke-HwpxScopedEdit -LiteralPath $LiteralPath -OutputPath $OutputPath -Plan $plan
            break
        }
        'convert-pdf' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Assert-HwpCliValue -Value $OutputPath -Name 'OutputPath'
            Import-Module (Join-Path $libraryRoot 'HwpPdfConvert.psm1') -ErrorAction Stop
            Export-HwpxPdf -LiteralPath $LiteralPath -OutputPath $OutputPath -PdfMode $PdfMode -BrowserPath $BrowserPath -FontDirectories $FontDirectories -WorkDirectory $WorkDirectory
            break
        }
        'preview' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Assert-HwpCliValue -Value $OutputDirectory -Name 'OutputDirectory'
            Import-Module (Join-Path $libraryRoot 'HwpPreview.psm1') -ErrorAction Stop
            $previewParameters = @{LiteralPath=$LiteralPath; OutputDirectory=$OutputDirectory}
            if ($PSBoundParameters.ContainsKey('BrowserPath')) { $previewParameters.BrowserPath=$BrowserPath }
            Export-HwpxPreview @previewParameters
            break
        }
        'apply' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Assert-HwpCliValue -Value $PlanPath -Name 'PlanPath'
            $imported = Import-HwpEditPlan -LiteralPath $PlanPath
            if ($imported.Status -ne 'PASS') { $imported; break }
            if ([string]::IsNullOrWhiteSpace($OutputPath)) {
                Invoke-HwpApply -LiteralPath $LiteralPath -Plan $imported.Data.Plan `
                    -ApproveAdvanced:([bool]$ApproveAdvanced) -ExecutionContext $hwpExecutionContext `
                    -Capabilities $capabilities
            }
            else {
                Invoke-HwpApply -LiteralPath $LiteralPath -Plan $imported.Data.Plan -OutputPath $OutputPath `
                    -ApproveAdvanced:([bool]$ApproveAdvanced) -ExecutionContext $hwpExecutionContext `
                    -Capabilities $capabilities
            }
            break
        }
        'generate' {
            Assert-HwpCliValue -Value $PlanPath -Name 'PlanPath'
            Assert-HwpCliValue -Value $OutputPath -Name 'OutputPath'
            if ($NewDocument) {
                $plan = Read-HwpCliJson -Path $PlanPath
                Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $OutputPath `
                    -ExecutionContext $hwpExecutionContext -Capabilities $capabilities
            }
            else {
                Assert-HwpCliValue -Value $TemplatePath -Name 'TemplatePath'
                $imported = Import-HwpEditPlan -LiteralPath $PlanPath
                if ($imported.Status -ne 'PASS') { $imported; break }
                Invoke-HwpGenerate -TemplatePath $TemplatePath -Plan $imported.Data.Plan -OutputPath $OutputPath `
                    -ApproveAdvanced:([bool]$ApproveAdvanced) -ExecutionContext $hwpExecutionContext `
                    -Capabilities $capabilities
            }
            break
        }
        'batch' {
            Assert-HwpCliValue -Value $PlanPath -Name 'PlanPath'
            $imported = Import-HwpEditPlan -LiteralPath $PlanPath
            if ($imported.Status -ne 'PASS') { $imported; break }
            $hasDirectory = -not [string]::IsNullOrWhiteSpace($InputDirectory)
            $hasPaths = $null -ne $InputPaths -and @($InputPaths).Count -gt 0
            if ($hasDirectory -eq $hasPaths) { throw 'InputDirectory 또는 InputPaths 중 하나만 지정해야 합니다.' }
            if ($hasDirectory) {
                Invoke-HwpBatch -InputDirectory $InputDirectory -Plan $imported.Data.Plan `
                    -OutputDirectory $OutputDirectory -Apply:([bool]$Apply) `
                    -ApproveAdvanced:([bool]$ApproveAdvanced) -Recurse:([bool]$Recurse) `
                    -ExecutionContext $hwpExecutionContext -Capabilities $capabilities
            }
            else {
                Invoke-HwpBatch -InputPaths $InputPaths -Plan $imported.Data.Plan `
                    -OutputDirectory $OutputDirectory -Apply:([bool]$Apply) `
                    -ApproveAdvanced:([bool]$ApproveAdvanced) -ExecutionContext $hwpExecutionContext `
                    -Capabilities $capabilities
            }
            break
        }
        'compare' {
            Assert-HwpCliValue -Value $BeforePath -Name 'BeforePath'
            Assert-HwpCliValue -Value $AfterPath -Name 'AfterPath'
            $before = Read-HwpCliJson -Path $BeforePath
            $after = Read-HwpCliJson -Path $AfterPath
            Compare-HwpInspection -Before $before -After $after
            break
        }
        'verify' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            Assert-HwpCliValue -Value $OutputDirectory -Name 'OutputDirectory'
            $before = if ([string]::IsNullOrWhiteSpace($BeforePath)) { $null } else { Read-HwpCliJson -Path $BeforePath }
            Invoke-HwpVerify -LiteralPath $LiteralPath -OutputDirectory $OutputDirectory -Before $before `
                -ExecutionContext $hwpExecutionContext -Capabilities $capabilities
            break
        }
        'export' {
            Assert-HwpCliValue -Value $LiteralPath -Name 'LiteralPath'
            if ($ExportKind -eq 'pdf') {
                Assert-HwpCliValue -Value $OutputPath -Name 'OutputPath'
                Export-HwpPdf -LiteralPath $LiteralPath -OutputPath $OutputPath `
                    -ExecutionContext $hwpExecutionContext -Capabilities $capabilities
            }
            else {
                Assert-HwpCliValue -Value $OutputDirectory -Name 'OutputDirectory'
                Export-HwpPageImages -LiteralPath $LiteralPath -ImageDirectory $OutputDirectory `
                    -ExecutionContext $hwpExecutionContext -Capabilities $capabilities
            }
            break
        }
    }
}
catch {
    if (Get-Command New-HwpResult -ErrorAction SilentlyContinue) {
        $result = New-HwpResult -Status FAILED -Command $Command -Errors @($_.Exception.Message)
    }
    else {
        $result = [pscustomobject]@{
            status = 'FAILED'
            command = $Command
            data = $null
            warnings = @()
            errors = @($_.Exception.Message)
        }
    }
}

if ($null -eq $result) {
    $result = [pscustomobject]@{
        status = 'FAILED'
        command = $Command
        data = $null
        warnings = @()
        errors = @('명령이 결과를 반환하지 않았습니다.')
    }
}
if ($ResultDetail -eq 'compact') {
    Import-Module (Join-Path $libraryRoot 'HwpCliResponse.psm1') -ErrorAction Stop
    ConvertTo-HwpCliResponse -Result $result -Command $Command | ConvertTo-Json -Depth 100 -Compress
}
else {
    $result | ConvertTo-Json -Depth 100
}
$status = [string]$result.status
if ($status -in 'PASS','PASS_WITH_WARNINGS') { exit 0 }
if ($status -eq 'BLOCKED') { exit 2 }
exit 1
