Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpCommon.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpExecution.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpCapabilities.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpBackendRouter.psm1') -ErrorAction Stop -Global
Import-Module (Join-Path $PSScriptRoot 'HwpSession.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'HwpInspect.psm1') -ErrorAction Stop

function Test-HwpVerifyProperty {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $null -ne $InputObject -and $InputObject.PSObject.Properties.Name -contains $Name
}

function Get-HwpVerifyControlCounts {
    param([AllowNull()][object[]]$Controls = @())

    $counts = [ordered]@{}
    foreach ($control in @($Controls)) {
        if ($null -eq $control) { continue }
        $property = $control.PSObject.Properties['CtrlId']
        if ($null -eq $property) { $property = $control.PSObject.Properties['ctrlId'] }
        $ctrlId = if ($null -eq $property) { '' } else { [string]$property.Value }
        if ([string]::IsNullOrWhiteSpace($ctrlId)) { continue }
        if (-not $counts.Contains($ctrlId)) { $counts[$ctrlId] = 0 }
        $counts[$ctrlId] = [int]$counts[$ctrlId] + 1
    }
    [pscustomobject]$counts
}

function Compare-HwpInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Before,
        [Parameter(Mandatory)][ValidateNotNull()][object]$After,
        [object[]]$ExpectedOperations = @()
    )

    $warnings = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $beforeText = if (Test-HwpVerifyProperty -InputObject $Before -Name 'Text') { [string]$Before.Text } else { '' }
    $afterText = if (Test-HwpVerifyProperty -InputObject $After -Name 'Text') { [string]$After.Text } else { '' }
    $beforePages = if (Test-HwpVerifyProperty -InputObject $Before -Name 'PageCount') { [int]$Before.PageCount } else { 0 }
    $afterPages = if (Test-HwpVerifyProperty -InputObject $After -Name 'PageCount') { [int]$After.PageCount } else { 0 }
    $beforeControls = Get-HwpVerifyControlCounts -Controls @(if (Test-HwpVerifyProperty -InputObject $Before -Name 'Controls') { $Before.Controls } else { @() })
    $afterControls = Get-HwpVerifyControlCounts -Controls @(if (Test-HwpVerifyProperty -InputObject $After -Name 'Controls') { $After.Controls } else { @() })
    $operationTypes = @($ExpectedOperations | ForEach-Object {
        if ($null -ne $_ -and $_.PSObject.Properties.Name -contains 'type') { [string]$_.type }
    })

    if ($beforeText.Trim().Length -gt 0 -and $afterText.Trim().Length -eq 0) {
        $errors.Add('원본에 본문이 있었지만 결과 본문이 비어 있습니다.')
    }
    if ($afterPages -lt 1) {
        $errors.Add('결과 문서의 쪽 수가 1보다 작습니다.')
    }
    $pageAffecting = @('insert-page-break','build-toc','merge-documents','set-section')
    if (@($operationTypes | Where-Object { $_ -in $pageAffecting }).Count -eq 0 -and
        [Math]::Abs($afterPages - $beforePages) -gt 1) {
        $warnings.Add("계획에 쪽 구조 작업이 없지만 쪽 수가 크게 변했습니다: $beforePages -> $afterPages")
    }
    if ($operationTypes -notcontains 'delete-range' -and $beforeText.Length -gt 0 -and
        $afterText.Length -lt [Math]::Floor($beforeText.Length * 0.7)) {
        $warnings.Add("명시적 삭제 작업 없이 본문 길이가 크게 감소했습니다: $($beforeText.Length) -> $($afterText.Length)")
    }

    foreach ($property in $beforeControls.PSObject.Properties) {
        $ctrlId = $property.Name
        $beforeCount = [int]$property.Value
        $afterProperty = $afterControls.PSObject.Properties[$ctrlId]
        $afterCount = if ($null -eq $afterProperty) { 0 } else { [int]$afterProperty.Value }
        if ($afterCount -lt $beforeCount) {
            $errors.Add("컨트롤 '$ctrlId' 수가 예상하지 않게 감소했습니다: $beforeCount -> $afterCount")
        }
    }

    $beforeFields = if (Test-HwpVerifyProperty -InputObject $Before -Name 'Fields') { $Before.Fields } else { [pscustomobject]@{} }
    $afterFields = if (Test-HwpVerifyProperty -InputObject $After -Name 'Fields') { $After.Fields } else { [pscustomobject]@{} }
    foreach ($property in $beforeFields.PSObject.Properties) {
        if ($null -eq $afterFields.PSObject.Properties[$property.Name]) {
            $errors.Add("원본 필드가 결과에서 사라졌습니다: $($property.Name)")
        }
    }

    $data = [pscustomobject]@{
        BeforeTextLength = $beforeText.Length
        AfterTextLength = $afterText.Length
        BeforePageCount = $beforePages
        AfterPageCount = $afterPages
        PageCountDelta = $afterPages - $beforePages
        BeforeControlCounts = $beforeControls
        AfterControlCounts = $afterControls
        ExpectedOperationTypes = @($operationTypes)
    }
    if ($errors.Count -gt 0) {
        return New-HwpResult -Status FAILED -Command compare-inspection -Data $data -Warnings @($warnings) -Errors @($errors)
    }
    $status = if ($warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' }
    New-HwpResult -Status $status -Command compare-inspection -Data $data -Warnings @($warnings)
}

function Test-HwpPdfFile {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($LiteralPath)
    $bytes.Length -ge 5 -and [Text.Encoding]::ASCII.GetString($bytes, 0, 5) -eq '%PDF-'
}

function Test-HwpPngFile {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $false }
    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $bytes = [byte[]]::new(8)
        $length = $stream.Read($bytes, 0, 8)
    }
    finally { $stream.Dispose() }
    $length -eq 8 -and [BitConverter]::ToString($bytes) -eq '89-50-4E-47-0D-0A-1A-0A'
}

function Export-HwpPdfFromSession {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput).ToLowerInvariant() -ne '.pdf') {
        return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @('PDF 결과 경로는 .pdf 확장자여야 합니다.')
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @("기존 PDF를 덮어쓰지 않습니다: $resolvedOutput")
    }
    $directory = [IO.Path]::GetDirectoryName($resolvedOutput)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @("PDF 결과 폴더가 없습니다: $directory")
    }
    $temporaryPath = [IO.Path]::Combine(
        $directory,
        ('{0}.{1}.partial.pdf' -f [IO.Path]::GetFileNameWithoutExtension($resolvedOutput), [guid]::NewGuid().ToString('n'))
    )
    try {
        $saved = [bool]$Session.Hwp.SaveAs($temporaryPath, 'PDF', 'lock:false;backup:false')
        if (-not $saved -or -not (Test-HwpPdfFile -LiteralPath $temporaryPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
            $action = $Session.Hwp.CreateAction('PrintToPDFEx')
            $set = $action.CreateSet()
            $null = $action.GetDefault($set)
            $null = $set.SetItem('FileName', $temporaryPath)
            if (-not $action.Execute($set)) {
                throw 'SaveAs와 PrintToPDFEx가 모두 PDF를 만들지 못했습니다.'
            }
        }
        if (-not (Test-HwpPdfFile -LiteralPath $temporaryPath)) {
            throw '생성된 PDF의 시그니처가 올바르지 않습니다.'
        }
        [IO.File]::Move($temporaryPath, $resolvedOutput)
    }
    catch {
        return New-HwpResult -Status FAILED -Command export-pdf -Errors @(
            "PDF 내보내기 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    New-HwpResult -Status PASS -Command export-pdf -Data ([pscustomobject]@{
        PdfPath = $resolvedOutput
        ByteLength = (Get-Item -LiteralPath $resolvedOutput).Length
        Sha256 = Get-HwpSha256 -LiteralPath $resolvedOutput
    })
}

function Export-HwpPageImagesFromSession {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$ImageDirectory
    )

    $directory = [IO.Path]::GetFullPath($ImageDirectory)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return New-HwpResult -Status BLOCKED -Command export-page-images -Errors @("페이지 이미지 폴더가 없습니다: $directory")
    }
    $pageCount = [int]$Session.Hwp.PageCount
    if ($pageCount -lt 1) {
        return New-HwpResult -Status FAILED -Command export-page-images -Errors @('이미지로 만들 문서 쪽이 없습니다.')
    }
    $planned = @(
        for ($page = 0; $page -lt $pageCount; $page++) {
            [IO.Path]::Combine($directory, ('page-{0:D3}.png' -f ($page + 1)))
        }
    )
    $existing = @($planned | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -gt 0) {
        return New-HwpResult -Status BLOCKED -Command export-page-images -Errors @(
            "기존 페이지 이미지를 덮어쓰지 않습니다: $($existing[0])"
        )
    }

    $images = [Collections.Generic.List[string]]::new()
    $emptyPages = [Collections.Generic.List[int]]::new()
    $temporaryFiles = [Collections.Generic.List[string]]::new()
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        for ($page = 0; $page -lt $pageCount; $page++) {
            $pngPath = $planned[$page]
            $bmpPath = [IO.Path]::Combine($directory, ('page-{0:D3}.{1}.partial.bmp' -f ($page + 1), [guid]::NewGuid().ToString('n')))
            $temporaryFiles.Add($bmpPath)
            if (-not $Session.Hwp.CreatePageImage($bmpPath, $page, 96, 24, 'BMP')) {
                throw "한컴오피스가 $($page + 1)쪽 이미지를 만들지 못했습니다."
            }
            $bitmap = [Drawing.Bitmap]::FromFile($bmpPath)
            try { $bitmap.Save($pngPath, [Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
            if (-not (Test-HwpPngFile -LiteralPath $pngPath)) {
                throw "$($page + 1)쪽 PNG 시그니처가 올바르지 않습니다."
            }
            $images.Add($pngPath)
            $pageText = [string]$Session.Hwp.GetPageText($page, 0)
            if ([string]::IsNullOrWhiteSpace($pageText)) { $emptyPages.Add($page + 1) }
            Remove-Item -LiteralPath $bmpPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        foreach ($path in @($images)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        return New-HwpResult -Status FAILED -Command export-page-images -Data ([pscustomobject]@{
            PageImages = @()
            EmptyPageCandidates = @($emptyPages)
        }) -Errors @("페이지 이미지 내보내기 중 오류가 발생했습니다: $($_.Exception.Message)")
    }
    finally {
        foreach ($path in @($temporaryFiles)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
    }

    New-HwpResult -Status PASS -Command export-page-images -Data ([pscustomobject]@{
        PageImages = @($images)
        PageCount = $pageCount
        EmptyPageCandidates = @($emptyPages)
        Method = 'Hancom-CreatePageImage-BMP-to-PNG'
    })
}

function Open-HwpVerifySession {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [AllowNull()][scriptblock]$SecurityModuleReader = $null
    )

    $session = & $SessionFactory $ExecutionContext
    if ($null -eq $session) { throw '세션 팩터리가 한컴 세션을 반환하지 않았습니다.' }
    $open = Open-HwpDocumentFromMemory -Session $session -LiteralPath $LiteralPath
    if ($open.Status -ne 'PASS') {
        Close-HwpSession -Session $session
        return [pscustomobject]@{ Session = $null; Open = $open; Security = $null }
    }
    $security = if ($null -eq $SecurityModuleReader) {
        Register-HwpSecurityModules -Session $session
    }
    else {
        Register-HwpSecurityModules -Session $session -SecurityModuleReader $SecurityModuleReader
    }
    [pscustomobject]@{ Session = $session; Open = $open; Security = $security }
}

function Export-HwpPdf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [AllowNull()][scriptblock]$SecurityModuleReader = $null
    )

    $format = $null
    $sourceHash = try {
        $format = Get-HwpFileKind -LiteralPath $LiteralPath
        Get-HwpSha256 -LiteralPath $format.Path
    } catch {
        return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @($_.Exception.Message)
    }
    if (-not $format.ExtensionMatches) {
        return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @('확장자와 실제 파일 형식이 다릅니다.')
    }
    $route = Resolve-HwpBackend -Command export -DetectedKind $format.DetectedKind `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpResult -Status $route.Status -Command export-pdf -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @("백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)")
    }
    $opened = $null
    try {
        $opened = Open-HwpVerifySession -LiteralPath $format.Path -ExecutionContext $ExecutionContext `
            -SessionFactory $SessionFactory -SecurityModuleReader $SecurityModuleReader
        if ($null -eq $opened.Session) { return $opened.Open }
        if ($opened.Security.Status -notin 'PASS','PASS_WITH_WARNINGS') {
            return New-HwpResult -Status BLOCKED -Command export-pdf -Errors @($opened.Security.Errors)
        }
        $result = Export-HwpPdfFromSession -Session $opened.Session -OutputPath $OutputPath
    }
    catch {
        return New-HwpResult -Status FAILED -Command export-pdf -Errors @($_.Exception.Message)
    }
    finally {
        if ($null -ne $opened -and $null -ne $opened.Session) { Close-HwpSession -Session $opened.Session }
    }
    if ((Get-HwpSha256 -LiteralPath $format.Path) -ne $sourceHash) {
        if ($result.Status -eq 'PASS' -and (Test-Path -LiteralPath $result.Data.PdfPath)) {
            Remove-Item -LiteralPath $result.Data.PdfPath -Force -ErrorAction SilentlyContinue
        }
        return New-HwpResult -Status FAILED -Command export-pdf -Errors @('PDF 내보내기 중 원본 SHA-256이 변경되었습니다.')
    }
    if ($result.Status -eq 'PASS' -and $opened.Security.Status -eq 'PASS_WITH_WARNINGS') {
        return New-HwpResult -Status PASS_WITH_WARNINGS -Command export-pdf -Data $result.Data -Warnings @($opened.Security.Warnings)
    }
    $result
}

function Export-HwpPageImages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ImageDirectory,
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext },
        [AllowNull()][scriptblock]$SecurityModuleReader = $null
    )

    $format = $null
    $sourceHash = try {
        $format = Get-HwpFileKind -LiteralPath $LiteralPath
        Get-HwpSha256 -LiteralPath $format.Path
    } catch {
        return New-HwpResult -Status BLOCKED -Command export-page-images -Errors @($_.Exception.Message)
    }
    if (-not $format.ExtensionMatches) {
        return New-HwpResult -Status BLOCKED -Command export-page-images -Errors @('확장자와 실제 파일 형식이 다릅니다.')
    }
    $route = Resolve-HwpBackend -Command export -DetectedKind $format.DetectedKind `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpResult -Status $route.Status -Command export-page-images -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpResult -Status BLOCKED -Command export-page-images -Errors @(
            "백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)"
        )
    }
    $opened = $null
    try {
        $opened = Open-HwpVerifySession -LiteralPath $format.Path -ExecutionContext $ExecutionContext `
            -SessionFactory $SessionFactory -SecurityModuleReader $SecurityModuleReader
        if ($null -eq $opened.Session) { return $opened.Open }
        if ($opened.Security.Status -notin 'PASS','PASS_WITH_WARNINGS') {
            return New-HwpResult -Status BLOCKED -Command export-page-images -Errors @($opened.Security.Errors)
        }
        $result = Export-HwpPageImagesFromSession -Session $opened.Session -ImageDirectory $ImageDirectory
    }
    catch {
        return New-HwpResult -Status FAILED -Command export-page-images -Errors @($_.Exception.Message)
    }
    finally {
        if ($null -ne $opened -and $null -ne $opened.Session) { Close-HwpSession -Session $opened.Session }
    }
    if ((Get-HwpSha256 -LiteralPath $format.Path) -ne $sourceHash) {
        return New-HwpResult -Status FAILED -Command export-page-images -Errors @('페이지 이미지 내보내기 중 원본 SHA-256이 변경되었습니다.')
    }
    if ($result.Status -eq 'PASS' -and $opened.Security.Status -eq 'PASS_WITH_WARNINGS') {
        return New-HwpResult -Status PASS_WITH_WARNINGS -Command export-page-images -Data $result.Data -Warnings @($opened.Security.Warnings)
    }
    $result
}

function Convert-HwpPdfToPageImages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PdfPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ImageDirectory
    )

    if (-not (Test-HwpPdfFile -LiteralPath $PdfPath)) {
        return New-HwpResult -Status BLOCKED -Command convert-pdf-images -Errors @('유효한 PDF가 아닙니다.')
    }
    $directory = [IO.Path]::GetFullPath($ImageDirectory)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return New-HwpResult -Status BLOCKED -Command convert-pdf-images -Errors @("페이지 이미지 폴더가 없습니다: $directory")
    }
    $command = Get-Command pdftoppm -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return New-HwpResult -Status BLOCKED -Command convert-pdf-images -Errors @('pdftoppm을 찾지 못했습니다.')
    }
    $prefix = [IO.Path]::Combine($directory, 'pdftoppm-' + [guid]::NewGuid().ToString('n'))
    try {
        $output = & $command.Source -png -r 144 $PdfPath $prefix 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join ' ') }
        $rawImages = @(Get-ChildItem -LiteralPath $directory -File -Filter ([IO.Path]::GetFileName($prefix) + '-*.png') | Sort-Object Name)
        if ($rawImages.Count -lt 1) { throw 'pdftoppm이 페이지 이미지를 만들지 않았습니다.' }
        $images = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $rawImages.Count; $index++) {
            $final = [IO.Path]::Combine($directory, ('page-{0:D3}.png' -f ($index + 1)))
            if (Test-Path -LiteralPath $final) { throw "기존 페이지 이미지를 덮어쓰지 않습니다: $final" }
            [IO.File]::Move($rawImages[$index].FullName, $final)
            if (-not (Test-HwpPngFile -LiteralPath $final)) { throw "PNG 시그니처가 올바르지 않습니다: $final" }
            $images.Add($final)
        }
    }
    catch {
        return New-HwpResult -Status FAILED -Command convert-pdf-images -Errors @(
            "PDF 페이지 이미지 변환 중 오류가 발생했습니다: $($_.Exception.Message)"
        )
    }
    finally {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -Filter ([IO.Path]::GetFileName($prefix) + '-*.png') -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    New-HwpResult -Status PASS -Command convert-pdf-images -Data ([pscustomobject]@{
        PageImages = @($images)
        PageCount = $images.Count
        EmptyPageCandidates = @()
        Method = 'pdftoppm-144dpi'
    })
}

function New-HwpVerifyResult {
    param(
        [ValidateSet('PASS','PASS_WITH_WARNINGS','BLOCKED','FAILED')][string]$Status,
        [string]$LiteralPath = '',
        [AllowNull()][object]$After = $null,
        [AllowNull()][object]$Comparison = $null,
        [string]$PdfPath = '',
        [string[]]$PageImages = @(),
        [int[]]$EmptyPageCandidates = @(),
        [bool]$VisualVerificationCompleted = $false,
        [string[]]$Warnings = @(),
        [string[]]$Errors = @()
    )

    $data = [pscustomobject]@{
        Path = $LiteralPath
        After = $After
        Comparison = $Comparison
        PdfPath = $PdfPath
        PageImages = @($PageImages)
        EmptyPageCandidates = @($EmptyPageCandidates)
        VisualVerificationCompleted = $VisualVerificationCompleted
    }
    $result = New-HwpResult -Status $Status -Command verify -Data $data -Warnings $Warnings -Errors $Errors
    foreach ($property in $data.PSObject.Properties) {
        $result | Add-Member NoteProperty $property.Name $property.Value
    }
    $result
}

function Get-HwpUniqueVerifyStem {
    param(
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$BaseName
    )

    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $stem = "${BaseName}_검증_${stamp}"
    $candidate = $stem
    $sequence = 1
    while ((Test-Path -LiteralPath ([IO.Path]::Combine($OutputDirectory, "$candidate.pdf"))) -or
        (Test-Path -LiteralPath ([IO.Path]::Combine($OutputDirectory, "$candidate-pages")))) {
        $candidate = '{0}_{1:D2}' -f $stem, $sequence
        $sequence++
    }
    $candidate
}

function Invoke-HwpVerify {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
        [AllowNull()][object]$Before = $null,
        [object[]]$ExpectedOperations = @(),
        [object]$ExecutionContext = (New-HwpExecutionContext),
        [object]$Capabilities = (Get-HwpCapabilitySnapshot -ExecutionContext $ExecutionContext),
        [scriptblock]$SessionFactory = { param($executionContext) New-HwpSession -ExecutionContext $executionContext }
    )

    $format = $null
    try {
        $resolvedPath = (Resolve-Path -LiteralPath $LiteralPath -ErrorAction Stop).Path
        $resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolvedOutput -PathType Container)) { throw '검증 출력 경로가 폴더가 아닙니다.' }
        $format = Get-HwpFileKind -LiteralPath $resolvedPath
    }
    catch {
        return New-HwpVerifyResult -Status BLOCKED -Errors @($_.Exception.Message)
    }
    if (-not $format.ExtensionMatches) {
        return New-HwpVerifyResult -Status BLOCKED -LiteralPath $resolvedPath -Errors @('확장자와 실제 파일 형식이 다릅니다.')
    }
    $route = Resolve-HwpBackend -Command verify -DetectedKind $format.DetectedKind `
        -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($route.Status -ne 'PASS') {
        return New-HwpVerifyResult -Status $route.Status -LiteralPath $resolvedPath `
            -Warnings @($route.Warnings) -Errors @($route.Errors)
    }
    if ($route.BackendId -ne 'hancom-interactive') {
        return New-HwpVerifyResult -Status BLOCKED -LiteralPath $resolvedPath -Errors @(
            "백엔드 구현이 현재 단계에 없습니다: $($route.BackendId)"
        )
    }
    $after = Get-HwpInspection -LiteralPath $resolvedPath -ExecutionContext $ExecutionContext -Capabilities $Capabilities
    if ($after.Status -notin 'PASS','PASS_WITH_WARNINGS') {
        return New-HwpVerifyResult -Status BLOCKED -LiteralPath $resolvedPath -After $after -Errors @($after.Errors)
    }
    $comparison = if ($null -eq $Before) {
        New-HwpResult -Status PASS -Command compare-inspection -Data ([pscustomobject]@{ Skipped = $true })
    }
    else {
        Compare-HwpInspection -Before $Before -After $after -ExpectedOperations $ExpectedOperations
    }
    $warnings = [Collections.Generic.List[string]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($message in @($after.Warnings)) { $warnings.Add([string]$message) }
    foreach ($message in @($comparison.Warnings)) { $warnings.Add([string]$message) }
    foreach ($message in @($comparison.Errors)) { $errors.Add([string]$message) }

    $session = $null
    $pdfPath = ''
    $pageImages = @()
    $emptyPages = @()
    $visualCompleted = $false
    try {
        $session = & $SessionFactory $ExecutionContext
        $open = Open-HwpDocumentFromMemory -Session $session -LiteralPath $resolvedPath
        if ($open.Status -ne 'PASS') {
            foreach ($message in @($open.Errors)) { $warnings.Add("시각 검증 열기 실패: $message") }
        }
        else {
            $security = Register-HwpSecurityModules -Session $session
            if ($security.Status -notin 'PASS','PASS_WITH_WARNINGS') {
                foreach ($message in @($security.Errors)) { $warnings.Add("시각 검증 보안 모듈 미준비: $message") }
            }
            else {
                foreach ($message in @($security.Warnings)) { $warnings.Add([string]$message) }
                $stem = Get-HwpUniqueVerifyStem -OutputDirectory $resolvedOutput -BaseName ([IO.Path]::GetFileNameWithoutExtension($resolvedPath))
                $pdfCandidate = [IO.Path]::Combine($resolvedOutput, "$stem.pdf")
                $imageDirectory = [IO.Path]::Combine($resolvedOutput, "$stem-pages")
                New-Item -ItemType Directory -Path $imageDirectory -ErrorAction Stop | Out-Null

                $pdf = Export-HwpPdfFromSession -Session $session -OutputPath $pdfCandidate
                if ($pdf.Status -in 'PASS','PASS_WITH_WARNINGS') {
                    $pdfPath = [string]$pdf.Data.PdfPath
                }
                else {
                    foreach ($message in @($pdf.Errors)) { $warnings.Add("PDF 내보내기 실패: $message") }
                }
                $images = Export-HwpPageImagesFromSession -Session $session -ImageDirectory $imageDirectory
                if ($images.Status -notin 'PASS','PASS_WITH_WARNINGS' -and $pdfPath.Length -gt 0) {
                    foreach ($message in @($images.Errors)) { $warnings.Add("한컴 페이지 이미지 실패: $message") }
                    $images = Convert-HwpPdfToPageImages -PdfPath $pdfPath -ImageDirectory $imageDirectory
                }
                if ($images.Status -in 'PASS','PASS_WITH_WARNINGS') {
                    $pageImages = @($images.Data.PageImages)
                    $emptyPages = @($images.Data.EmptyPageCandidates)
                }
                else {
                    foreach ($message in @($images.Errors)) { $warnings.Add("페이지 이미지 내보내기 실패: $message") }
                }
                $visualCompleted = $pdfPath.Length -gt 0 -and $pageImages.Count -eq [int]$after.PageCount
                if (-not $visualCompleted) {
                    $warnings.Add('PDF와 전체 페이지 이미지가 모두 준비되지 않아 시각 검증을 완료로 표시하지 않습니다.')
                }
                if ($emptyPages.Count -gt 0) {
                    $warnings.Add("빈 페이지 후보가 있습니다: $($emptyPages -join ', ')")
                }
            }
        }
    }
    catch {
        $warnings.Add("시각 검증 준비 중 오류가 발생했습니다: $($_.Exception.Message)")
    }
    finally {
        if ($null -ne $session) { Close-HwpSession -Session $session }
    }

    if ($comparison.Status -eq 'FAILED' -or $errors.Count -gt 0) {
        return New-HwpVerifyResult -Status FAILED -LiteralPath $resolvedPath -After $after -Comparison $comparison `
            -PdfPath $pdfPath -PageImages @($pageImages) -EmptyPageCandidates @($emptyPages) `
            -VisualVerificationCompleted:$visualCompleted -Warnings @($warnings) -Errors @($errors)
    }
    $status = if ($warnings.Count -gt 0 -or -not $visualCompleted -or $comparison.Status -eq 'PASS_WITH_WARNINGS') {
        'PASS_WITH_WARNINGS'
    }
    else { 'PASS' }
    New-HwpVerifyResult -Status $status -LiteralPath $resolvedPath -After $after -Comparison $comparison `
        -PdfPath $pdfPath -PageImages @($pageImages) -EmptyPageCandidates @($emptyPages) `
        -VisualVerificationCompleted:$visualCompleted -Warnings @($warnings)
}

Export-ModuleMember -Function @(
    'Compare-HwpInspection',
    'Export-HwpPdf',
    'Export-HwpPageImages',
    'Convert-HwpPdfToPageImages',
    'Invoke-HwpVerify'
)
