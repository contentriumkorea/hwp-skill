$lib = Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib'
Import-Module (Join-Path $lib 'HwpGenerate.psm1') -Force
Import-Module (Join-Path $lib 'HwpInspect.psm1') -Force

function Read-PageTestXml {
    param([string]$Path, [string]$Entry = 'Contents/section0.xml')
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry($Entry).Open())
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function New-PageTestPlan {
    param([AllowNull()][object]$Page)
    $plan = [pscustomobject]@{ version='1.0'; content=@(
        [pscustomobject]@{type='paragraph';text='쪽 방향 시험'}
        [pscustomobject]@{type='table';rows=1;columns=1;cells=@([pscustomobject]@{row=1;column=1;text='본문 폭'})}
    ) }
    if ($null -ne $Page) { $plan | Add-Member NoteProperty document ([pscustomobject]@{page=$Page}) }
    $plan
}

Describe 'HWPX 쪽 방향과 유효 영역' {
    It '생략한 기본 쪽 방향을 세로로 저장한다' {
        $out = Join-Path $TestDrive 'default.hwpx'
        $result = Invoke-HwpGenerate -NewDocument -Plan (New-PageTestPlan $null) -OutputPath $out
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $xml = Read-PageTestXml $out
        $xml.SelectSingleNode("//*[local-name()='pagePr']").GetAttribute('landscape') | Should Be 'NARROWLY'
    }

    It '가로 A4의 저장 치수는 210x297이고 유효 치수는 297x210이다' {
        $out = Join-Path $TestDrive 'landscape.hwpx'
        $result = Invoke-HwpGenerate -NewDocument -Plan (New-PageTestPlan ([pscustomobject]@{orientation='LANDSCAPE'})) -OutputPath $out
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $xml = Read-PageTestXml $out
        $page = $xml.SelectSingleNode("//*[local-name()='pagePr']")
        $page.GetAttribute('landscape') | Should Be 'WIDELY'
        [int]$page.GetAttribute('width') | Should Be 59528
        [int]$page.GetAttribute('height') | Should Be 84189
        $read = $result.After.Sections[0].PageDefinitions[0]
        $read.Orientation | Should Be 'LANDSCAPE'
        [Math]::Round($read.Width.Millimeter) | Should Be 297
        [Math]::Round($read.PaperWidth.Millimeter) | Should Be 210
    }

    It '독립적인 가로 기준 XML을 너비 비교로 세로 오판하지 않는다' {
        [xml]$xml = '<sec><pagePr landscape="WIDELY" width="59528" height="84189"><margin left="4252" right="4252"/></pagePr></sec>'
        $data = & (Get-Module HwpInspect) { param($doc) Get-HwpxSectionLayoutData -Document $doc -SectionName 'section0' -ParagraphStartIndex 0 } $xml
        $data.PageDefinitions[0].Orientation | Should Be 'LANDSCAPE'
        [Math]::Round($data.PageDefinitions[0].Width.Millimeter) | Should Be 297
    }

    It 'A5 세로의 표와 본문 폭을 좌우 여백을 제외한 118mm에 맞춘다' {
        $out = Join-Path $TestDrive 'a5.hwpx'
        $plan = New-PageTestPlan ([pscustomobject]@{orientation='PORTRAIT';widthMm=148;heightMm=210})
        $result = Invoke-HwpGenerate -NewDocument -Plan $plan -OutputPath $out
        $result.Status | Should Be 'PASS_WITH_WARNINGS'
        $xml = Read-PageTestXml $out
        $size = $xml.SelectSingleNode("//*[local-name()='tbl']/*[local-name()='sz']")
        [Math]::Round(([int]$size.GetAttribute('width')) / 283.4645669) | Should Be 118
        $line = $xml.SelectSingleNode("/*/*[local-name()='p'][2]/*[local-name()='linesegarray']/*")
        [Math]::Round(([int]$line.GetAttribute('horzsize')) / 283.4645669) | Should Be 118
    }
}
