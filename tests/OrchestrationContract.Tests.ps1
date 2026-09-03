Describe 'HWP 스킬 단일 silent 오케스트레이션 계약' {
    BeforeAll {
        $skillPath = Join-Path $PSScriptRoot '../skills/hwp-skill/SKILL.md'
        $interfacePath = Join-Path $PSScriptRoot '../skills/hwp-skill/agents/openai.yaml'
        $script:skill = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
        $script:interface = Get-Content -LiteralPath $interfacePath -Raw -Encoding UTF8
    }

    It '일반 한글 작업의 단일 오케스트레이터다' {
        $skill | Should Match '이 스킬이.*단일.*(?:진입점|오케스트레이터)|단일.*(?:진입점|오케스트레이터)'
        $skill | Should Match 'writing-plans'
        $skill | Should Match '호출하지 않|사용하지 않'
        $skill | Should Match '원시.*명령|raw.*command|명령.*JSON'
    }

    It '승인만으로 interactive를 선택하지 않는다' {
        $skill | Should Match '(?s)승인.*interactive.*충분하지 않|interactive.*명시적.*(?:창|화면)'
        $skill | Should Match '(?s)한컴.*창.*(?:열|보이)|화면.*보이'
    }

    It '일반 작업의 사용자 보고는 내부 처리 후 한 번으로 제한한다' {
        $skill | Should Match '진행.*1회|한 번.*진행|최종.*결과'
        $skill | Should Match '내부.*(?:계획|상태)'
    }

    It '메타데이터도 단일 silent 흐름을 지시한다' {
        $interface | Should Match '단일.*silent|무창.*자동'
        $interface | Should Match '내부.*계획|명령.*표시하지'
    }
}
