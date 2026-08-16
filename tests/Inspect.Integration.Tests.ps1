$commonModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpCommon.psm1'
$sessionModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpSession.psm1'
$inspectModule = Join-Path $PSScriptRoot '../skill/hwp-native/scripts/lib/HwpInspect.psm1'
Import-Module $commonModule -Force
Import-Module $sessionModule -Force
if (Test-Path -LiteralPath $inspectModule) {
    Import-Module $inspectModule -Force
}

function New-SyntheticHwpx {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [string]$MimeType = 'application/hwp+zip',
        [switch]$IncludeTraversalEntry
    )

    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $entries = [ordered]@{
                'mimetype' = $MimeType
                'Contents/section0.xml' = @'
<?xml version="1.0" encoding="UTF-8"?>
<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section"
        xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph">
  <hp:p id="1"><hp:run><hp:t>HWPX 첫 문단</hp:t></hp:run></hp:p>
  <hp:p id="2"><hp:run>
    <hp:ctrl><hp:fieldBegin id="10" type="CLICKHERE" name="담당자" editable="1" dirty="0" zorder="-1" fieldid="10"/></hp:ctrl>
    <hp:t>시험 담당자</hp:t>
    <hp:ctrl><hp:fieldEnd beginIDRef="10"/></hp:ctrl>
  </hp:run></hp:p>
  <hp:tbl id="20"><hp:tr><hp:tc><hp:subList>
    <hp:p id="3"><hp:run><hp:t>표 셀 문구</hp:t></hp:run></hp:p>
  </hp:subList></hp:tc></hp:tr></hp:tbl>
  <hp:pic id="30"/>
</hs:sec>
'@
            }
            if ($IncludeTraversalEntry) {
                $entries['../outside.xml'] = '<outside />'
            }

            foreach ($name in $entries.Keys) {
                $compression = if ($name -eq 'mimetype') {
                    [IO.Compression.CompressionLevel]::NoCompression
                }
                else {
                    [IO.Compression.CompressionLevel]::Optimal
                }
                $entry = $archive.CreateEntry($name, $compression)
                $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
                try {
                    $writer.Write([string]$entries[$name])
                }
                finally {
                    $writer.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }

    $LiteralPath
}

function New-FakeControl {
    param(
        [string]$CtrlId,
        [string]$UserDesc,
        [int]$InstanceId,
        [AllowNull()][object]$Next = $null
    )

    $control = [pscustomobject]@{
        CtrlID = $CtrlId
        UserDesc = $UserDesc
        InstanceId = $InstanceId
        Next = $Next
    }
    $control | Add-Member ScriptMethod GetCtrlInstID { $this.InstanceId }
    $control
}

function New-FakeInspectionSession {
    $picture = New-FakeControl -CtrlId 'gso' -UserDesc '그림' -InstanceId 2
    $table = New-FakeControl -CtrlId 'tbl' -UserDesc '표' -InstanceId 1 -Next $picture
    $hwp = [pscustomobject]@{
        PageCount = 2
        HeadCtrl = $table
        OpenCount = 0
        LastOpenPath = ''
        LastOpenFormat = ''
        LastOpenArgument = ''
        LastSetTextData = ''
        LastSetTextFormat = ''
        SetTextFileCount = 0
        ClearCount = 0
        QuitCount = 0
        RegisterCalls = [Collections.Generic.List[string]]::new()
    }
    $hwp | Add-Member ScriptMethod RegisterModule {
        param($moduleType, $moduleName)
        $this.RegisterCalls.Add("$moduleType|$moduleName")
        $true
    }
    $hwp | Add-Member ScriptMethod Open {
        param($path, $format, $argument)
        $this.OpenCount++
        $this.LastOpenPath = $path
        $this.LastOpenFormat = $format
        $this.LastOpenArgument = $argument
        $true
    }
    $hwp | Add-Member ScriptMethod SetTextFile {
        param($data, $format, $option)
        $this.SetTextFileCount++
        $this.LastSetTextData = [string]$data
        $this.LastSetTextFormat = [string]$format
        1
    }
    $hwp | Add-Member ScriptMethod GetTextFile {
        param($format, $option)
        "HWP 네이티브 통합 시험`r`n기존 문구를 안전하게 변경합니다."
    }
    $hwp | Add-Member ScriptMethod GetFieldList {
        param($number, $option)
        "담당자$([char]2)문서제목"
    }
    $hwp | Add-Member ScriptMethod GetFieldText {
        param($name)
        if ($name -eq '담당자') { '{{담당자}}' } else { '가상 문서' }
    }
    $hwp | Add-Member ScriptMethod Clear {
        param($option)
        $this.ClearCount++
        $true
    }
    $hwp | Add-Member ScriptMethod Quit { $this.QuitCount++ }

    [pscustomobject]@{
        Hwp = $hwp
        ProgId = 'fake'
        Version = '13, 0, 0, 711'
        Owned = $true
        Visible = $false
        Closed = $false
    }
}

Describe 'HWP 읽기 함수의 가짜 세션 계약' {
    It '본문을 유니코드 텍스트로 추출한다' {
        $session = New-FakeInspectionSession

        $text = Get-HwpPlainText -Session $session

        $text | Should Match 'HWP 네이티브 통합 시험'
    }

    It '모든 일반 필드 이름과 값을 추출한다' {
        $session = New-FakeInspectionSession

        $fields = Get-HwpFieldMap -Session $session

        $fields.담당자 | Should Be '{{담당자}}'
        $fields.문서제목 | Should Be '가상 문서'
    }

    It 'HeadCtrl부터 표와 그림 컨트롤을 순서대로 추출한다' {
        $session = New-FakeInspectionSession

        $controls = @(Get-HwpControlInventory -Session $session)

        $controls.Count | Should Be 2
        $controls[0].CtrlId | Should Be 'tbl'
        $controls[1].CtrlId | Should Be 'gso'
    }

    It '읽기 전용 옵션과 자동 형식 인식으로 문서를 연다' {
        $path = Join-Path $TestDrive 'fixture.hwp'
        [IO.File]::WriteAllBytes($path, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))
        $session = New-FakeInspectionSession

        $result = Open-HwpDocumentReadOnly -Session $session -LiteralPath $path -SecurityModuleReader { @('TestModule') }

        $result.Status | Should Be 'PASS'
        $session.Hwp.LastOpenFormat | Should Be ''
        $session.Hwp.LastOpenArgument | Should Match 'suspendpassword:true'
        $session.Hwp.LastOpenArgument | Should Match 'lock:false'
    }

    It 'HWP 바이너리를 Base64 메모리 문서로 불러온다' {
        $path = Join-Path $TestDrive 'fixture.hwp'
        $bytes = [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1)
        [IO.File]::WriteAllBytes($path, $bytes)
        $session = New-FakeInspectionSession

        $result = Open-HwpDocumentFromMemory -Session $session -LiteralPath $path

        $result.Status | Should Be 'PASS'
        $session.Hwp.SetTextFileCount | Should Be 1
        $session.Hwp.LastSetTextFormat | Should Be 'HWP'
        [Convert]::FromBase64String($session.Hwp.LastSetTextData).Length | Should Be $bytes.Length
        $session.Hwp.OpenCount | Should Be 0
    }
}

Describe 'Get-HwpInspection' {
    It '확장자와 실제 형식이 다르면 세션을 만들기 전에 BLOCKED로 반환한다' {
        $path = Join-Path $TestDrive 'wrong.hwpx'
        [IO.File]::WriteAllBytes($path, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))
        $factoryCount = [pscustomobject]@{ Value = 0 }
        $factory = {
            $factoryCount.Value++
            New-FakeInspectionSession
        }.GetNewClosure()

        $result = Get-HwpInspection -LiteralPath $path -SessionFactory $factory -SecurityModuleReader { @('TestModule') }

        $result.Status | Should Be 'BLOCKED'
        $factoryCount.Value | Should Be 0
        $result.DetectedKind | Should Be 'HWP-BINARY'
    }

    It '본문과 필드와 페이지 및 컨트롤 정보를 한 객체로 반환한다' {
        $path = Join-Path $TestDrive 'fixture.hwp'
        [IO.File]::WriteAllBytes($path, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))
        $session = New-FakeInspectionSession
        $factory = { $session }.GetNewClosure()

        $actual = Get-HwpInspection -LiteralPath $path -SessionFactory $factory -SecurityModuleReader { @('TestModule') }

        $actual.Status | Should Be 'PASS'
        $actual.Text | Should Match 'HWP 네이티브 통합 시험'
        $actual.Fields.담당자 | Should Be '{{담당자}}'
        $actual.PageCount | Should Be 2
        ($actual.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 1
        $session.Hwp.QuitCount | Should Be 1
    }

    It '보안 모듈이 없어도 HWP는 메모리로 읽고 승인 창을 띄우지 않는다' {
        $path = Join-Path $TestDrive 'fixture.hwp'
        [IO.File]::WriteAllBytes($path, [byte[]](0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1))
        $session = New-FakeInspectionSession
        $factory = { $session }.GetNewClosure()

        $actual = Get-HwpInspection -LiteralPath $path -SessionFactory $factory -SecurityModuleReader { @() }

        $actual.Status | Should Be 'PASS'
        $session.Hwp.OpenCount | Should Be 0
        $session.Hwp.SetTextFileCount | Should Be 1
        $session.Hwp.QuitCount | Should Be 1
    }

    It 'HWPX는 한컴 세션 없이 ZIP XML에서 본문과 필드와 컨트롤을 읽는다' {
        $path = Join-Path $TestDrive 'fixture.hwpx'
        $null = New-SyntheticHwpx -LiteralPath $path
        $factoryCount = [pscustomobject]@{ Value = 0 }
        $factory = {
            $factoryCount.Value++
            New-FakeInspectionSession
        }.GetNewClosure()

        $actual = Get-HwpInspection -LiteralPath $path -SessionFactory $factory

        ($actual.Errors -join '; ') | Should Be ''
        $actual.Status | Should Be 'PASS_WITH_WARNINGS'
        $actual.Text | Should Match 'HWPX 첫 문단'
        $actual.Text | Should Match '표 셀 문구'
        $actual.Fields.담당자 | Should Be '시험 담당자'
        @($actual.Controls | ForEach-Object CtrlId) -contains 'tbl' | Should Be $true
        @($actual.Controls | ForEach-Object CtrlId) -contains 'pic' | Should Be $true
        $actual.PageCount | Should Be 0
        $factoryCount.Value | Should Be 0
    }

    It 'HWPX MIME 형식이 다르면 BLOCKED로 반환한다' {
        $path = Join-Path $TestDrive 'wrong-mime.hwpx'
        $null = New-SyntheticHwpx -LiteralPath $path -MimeType 'application/zip'

        $actual = Get-HwpInspection -LiteralPath $path

        $actual.Status | Should Be 'BLOCKED'
        ($actual.Errors -join ' ') | Should Match 'mimetype'
    }

    It 'HWPX ZIP 경로 탈출 항목을 BLOCKED로 반환한다' {
        $path = Join-Path $TestDrive 'traversal.hwpx'
        $null = New-SyntheticHwpx -LiteralPath $path -IncludeTraversalEntry

        $actual = Get-HwpInspection -LiteralPath $path

        $actual.Status | Should Be 'BLOCKED'
        ($actual.Errors -join ' ') | Should Match '경로'
    }
}

$fixtureRoot = Join-Path $PSScriptRoot 'fixtures/source'
$fixtureHwp = Join-Path $fixtureRoot 'native-fixture.hwp'
$fixtureHwt = Join-Path $fixtureRoot 'native-template.hwt'
$runNative = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and (Test-Path -LiteralPath $fixtureHwp)
$runNativeHwt = $env:HWP_NATIVE_RUN_INTEGRATION -eq '1' -and (Test-Path -LiteralPath $fixtureHwt)

Describe 'Get-HwpInspection 실제 한컴 통합 시험' -Tags Native {
    It 'HWP 본문과 필드와 페이지 정보를 추출한다' -Skip:(-not $runNative) {
        $actual = Get-HwpInspection -LiteralPath $fixtureHwp

        $actual.Status | Should Be 'PASS'
        $actual.Text | Should Match 'HWP 네이티브 통합 시험'
        $actual.Fields.담당자 | Should Be '시험 담당자'
        $actual.PageCount | Should BeGreaterThan 0
        ($actual.Controls | Where-Object CtrlId -eq 'tbl').Count | Should Be 1
    }

    It 'HWT를 원본 변경 없이 HWP 메모리 문서로 읽는다' -Skip:(-not $runNativeHwt) {
        $beforeHash = Get-HwpSha256 -LiteralPath $fixtureHwt

        $actual = Get-HwpInspection -LiteralPath $fixtureHwt

        $actual.Status | Should Be 'PASS'
        $actual.DetectedKind | Should Be 'HWP-BINARY'
        $actual.Text | Should Match 'HWP 네이티브 통합 시험'
        $actual.Fields.담당자 | Should Be '시험 담당자'
        (Get-HwpSha256 -LiteralPath $fixtureHwt) | Should Be $beforeHash
    }
}

Describe '프로젝트 소유 가상 문서 생성' -Tags Native {
    It '보안 모듈 없이도 HWP와 HWT 가상 문서를 메모리 방식으로 만든다' {
        $output = Join-Path $TestDrive 'generated-fixtures'
        $generator = Join-Path $PSScriptRoot 'fixtures/New-TestFixtures.ps1'

        $jsonText = & pwsh -NoProfile -File $generator -OutputDirectory $output
        $exitCode = $LASTEXITCODE
        $result = $jsonText | ConvertFrom-Json

        $exitCode | Should Be 0
        $result.Status | Should Match '^PASS'
        Test-Path -LiteralPath (Join-Path $output 'native-fixture.hwp') | Should Be $true
        Test-Path -LiteralPath (Join-Path $output 'native-template.hwt') | Should Be $true
        (Get-HwpFileKind -LiteralPath (Join-Path $output 'native-fixture.hwp')).ExtensionMatches | Should Be $true
        (Get-HwpFileKind -LiteralPath (Join-Path $output 'native-template.hwt')).ExtensionMatches | Should Be $true
    }
}
