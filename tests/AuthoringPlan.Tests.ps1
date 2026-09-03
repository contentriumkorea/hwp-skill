Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpGenerate.psm1') -Force

Describe '작성 계획의 거짓 통과 방지' {
    It '사용자 용지와 프리셋 모순을 정규화로 숨기지 않는다' {
        $p='{"version":"2.0","document":{"page":{"paperSize":"A4","paperWidthMm":120,"paperHeightMm":200}},"content":[{"type":"paragraph","text":"bad"}]}'|ConvertFrom-Json
        (Test-HwpNewDocumentPlan $p).Status | Should Be BLOCKED
    }
    $cases = @(
        @{Name='미지원 머리말'; Json='{"version":"1.0","document":{"header":{"text":"기관명"}},"content":[{"type":"paragraph","text":"본문"}]}'},
        @{Name='잘못된 Boolean'; Json='{"version":"1.0","content":[{"type":"paragraph","text":"본문","textStyle":{"bold":"false"}}]}'},
        @{Name='소수 행'; Json='{"version":"1.0","content":[{"type":"table","rows":1.4,"columns":1,"cells":[]}]}'},
        @{Name='용지를 초과한 여백'; Json='{"version":"1.0","document":{"page":{"margins":{"leftMm":150,"rightMm":150}}},"content":[{"type":"paragraph","text":"본문"}]}'},
        @{Name='방향과 모순된 치수'; Json='{"version":"1.0","document":{"page":{"orientation":"PORTRAIT","widthMm":297,"heightMm":210}},"content":[{"type":"paragraph","text":"본문"}]}'},
        @{Name='중복 셀'; Json='{"version":"1.0","content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"text":"A"},{"row":1,"column":1,"text":"B"}]}]}'},
        @{Name='미지원 병합'; Json='{"version":"1.0","content":[{"type":"table","rows":1,"columns":2,"cells":[{"row":1,"column":1,"text":"A","colSpan":2}]}]}'},
        @{Name='숫자가 아닌 치수'; Json='{"version":"1.0","document":{"page":{"widthMm":"abc"}},"content":[{"type":"paragraph","text":"본문"}]}' }
    )
    foreach ($case in $cases) {
        It "$($case.Name)를 예외나 성공 대신 차단한다" {
            $r = Test-HwpNewDocumentPlan -Plan ($case.Json | ConvertFrom-Json)
            $r.Status | Should Be 'BLOCKED'
            @($r.Errors).Count | Should BeGreaterThan 0
        }
    }
    It '유효한 기본 문서와 명시적 false를 보존한다' {
        $p = '{"version":"1.0","content":[{"type":"paragraph","text":"본문","textStyle":{"bold":false}}]}' | ConvertFrom-Json
        (Test-HwpNewDocumentPlan -Plan $p).Status | Should Be 'PASS'
        $p.content[0].textStyle.bold | Should Be $false
    }
}
