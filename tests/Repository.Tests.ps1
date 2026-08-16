Describe 'hwp-native 저장소 구조' {
    It '스킬 메타데이터와 공용 진입점을 제공한다' {
        Test-Path "$PSScriptRoot/../skill/hwp-native/SKILL.md" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-native/agents/openai.yaml" | Should Be $true
        Test-Path "$PSScriptRoot/../skill/hwp-native/scripts/Invoke-HwpNative.ps1" | Should Be $true
    }
}
