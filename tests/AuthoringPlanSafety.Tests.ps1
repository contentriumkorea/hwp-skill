Import-Module (Join-Path $PSScriptRoot '../skills/hwp-skill/scripts/lib/HwpAuthoringPlan.psm1') -Force

function Test-AuthoringSafetyJson([string]$Json) {
    Test-HwpAuthoringPlan -Plan ($Json | ConvertFrom-Json)
}

function Test-AuthoringStandardSchema([string]$Json) {
    $schemaPath = Join-Path $PSScriptRoot '../skills/hwp-skill/schemas/generate-plan.schema.json'
    if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
        try { return Test-Json -Json $Json -SchemaFile $schemaPath -ErrorAction Stop } catch { return $false }
    }
    # PS 5.1 has no Test-Json. Use the installed PS 7 validator, with no downloads.
    $code = "try { [Console]::Write([int](Test-Json -Json '" + $Json.Replace("'", "''") +
        "' -SchemaFile '" + $schemaPath.Replace("'", "''") + "' -ErrorAction Stop)) } catch { [Console]::Write(0) }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $answer = & pwsh -NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw 'The installed standard schema validator failed to start.' }
    ([string]$answer).Trim() -eq '1'
}

Describe 'Bounded authoring plan validation' {
    It 'stops duplicate merged spans without expanding thousands of errors' {
        $cell = [pscustomobject]@{row=1;column=1;rowSpan=100;colSpan=100;text='x'}
        $plan = [pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='table';rows=100;columns=100;cells=@($cell,$cell,$cell)})}
        $result = Test-HwpAuthoringPlan $plan
        $result.Status | Should Be BLOCKED
        $result.Errors.Count | Should BeLessThan 64
    }
    It 'bounds diagnostics for hundreds of unknown properties' {
        $plan = [pscustomobject]@{version='2.0';content=@([pscustomobject]@{type='paragraph';text='x'})}
        foreach ($i in 1..500) { $plan | Add-Member NoteProperty ('unknown'+$i) 1 }
        $result = Test-HwpAuthoringPlan $plan
        $result.Status | Should Be BLOCKED
        $result.Errors.Count | Should BeLessThan 64
    }
    It 'rejects out-of-grid spans before occupancy expansion' {
        (Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"rowSpan":100,"colSpan":100,"text":"x"}]}]}').Status | Should Be BLOCKED
    }
    It 'reports the unsupported property of the matching block type' {
        $result=Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"toc","includePageNumbers":true,"entries":[{"text":"A","target":"#a"}]}]}'
        $result.Status | Should Be BLOCKED
        ($result.Errors -join ' ') | Should Match 'includePageNumbers'
        ($result.Errors -join ' ') | Should Not Match '\.text\b'
    }
}

Describe 'Standard JSON Schema and runtime version parity' {
    $cases = @(
        @{Name='minimal V1';Valid=$true;Json='{"version":"1.0","content":[{"type":"paragraph","text":"x"}]}'},
        @{Name='frozen V1 arbitrary border width';Valid=$true;Json='{"version":"1.0","document":{"tableStyle":{"borderWidthMm":0.35}},"content":[{"type":"table","rows":1,"columns":1,"style":{"borderWidthMm":0.35},"cells":[{"row":1,"column":1,"text":"x","style":{"borderWidthMm":0.35}}]}]}'},
        @{Name='minimal V2';Valid=$true;Json='{"version":"2.0","content":[{"type":"paragraph","text":"x"}]}'},
        @{Name='V2 integer enum width';Valid=$true;Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"style":{"borderWidthMm":1.0},"cells":[]}]}'},
        @{Name='V2 sections';Valid=$true;Json='{"version":"2.0","sections":[{"content":[{"type":"paragraph","text":"x"}]}]}'},
        @{Name='V2 unsupported border width';Valid=$false;Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"style":{"borderWidthMm":0.35},"cells":[]}]}'},
        @{Name='V1 rich runs';Valid=$false;Json='{"version":"1.0","content":[{"type":"paragraph","runs":[{"text":"x"}]}]}'},
        @{Name='V2 legacy page dimensions';Valid=$false;Json='{"version":"2.0","document":{"page":{"widthMm":210,"heightMm":297}},"content":[{"type":"paragraph","text":"x"}]}'},
        @{Name='V2 unknown property';Valid=$false;Json='{"version":"2.0","content":[{"type":"paragraph","text":"x","unknown":true}]}'},
        @{Name='V2 content and sections';Valid=$false;Json='{"version":"2.0","content":[{"type":"paragraph","text":"x"}],"sections":[{"content":[{"type":"paragraph","text":"y"}]}]}'}
    )
    foreach ($case in $cases) {
        It ('agrees for '+$case.Name) {
            (Test-AuthoringStandardSchema $case.Json) | Should Be $case.Valid
            ((Test-AuthoringSafetyJson $case.Json).Status -eq 'PASS') | Should Be $case.Valid
        }
    }
}

Describe 'Positive HWPUNIT page table and cell geometry' {
    $bad = @(
        @{Name='rounded page width';Json='{"version":"2.0","document":{"page":{"paperWidthMm":12,"paperHeightMm":20,"margins":{"leftMm":6,"rightMm":5.999,"topMm":0,"bottomMm":0,"headerMm":0,"footerMm":0}}},"content":[{"type":"paragraph","text":"x"}]}'},
        @{Name='rounded page height';Json='{"version":"2.0","document":{"page":{"paperWidthMm":10,"paperHeightMm":12,"margins":{"leftMm":0,"rightMm":0,"topMm":6,"bottomMm":5.999,"headerMm":0,"footerMm":0}}},"content":[{"type":"paragraph","text":"x"}]}'},
        @{Name='rounded column width';Json='{"version":"2.0","document":{"columns":{"count":2,"gapMm":10,"widthsMm":[0.001,169.999]}},"content":[{"type":"paragraph","text":"x"}]}'},
        @{Name='rounded table width';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"widthMm":0.001,"style":{"cellPaddingMm":0},"cells":[]}]}'},
        @{Name='last column correction';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":4,"widthMm":0.01,"columnWidthsMm":[0.0025,0.0025,0.0025,0.0025],"style":{"cellPaddingMm":0},"cells":[]}]}'},
        @{Name='rounded row height';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"rowHeightsMm":[0.001],"style":{"cellPaddingMm":0},"cells":[]}]}'},
        @{Name='inherited horizontal padding';Json='{"version":"2.0","document":{"tableStyle":{"cellMargins":{"leftMm":6,"rightMm":6}}},"content":[{"type":"table","rows":1,"columns":1,"widthMm":10,"cells":[{"row":1,"column":1,"text":"x"}]}]}'},
        @{Name='implicit cell padding';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"widthMm":3,"cells":[]}]}'},
        @{Name='vertical cell padding';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"rowHeightsMm":[1],"cells":[{"row":1,"column":1,"text":"x","style":{"cellMargins":{"topMm":0.5,"bottomMm":0.5}}}]}]}'}
    )
    foreach ($case in $bad) {
        It ('rejects '+$case.Name+' before writing') {
            (Test-AuthoringSafetyJson $case.Json).Status | Should Be BLOCKED
        }
    }
    It 'accepts positive rounded dimensions with explicit zero padding' {
        (Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"widthMm":0.01,"rowHeightsMm":[0.01],"style":{"cellPaddingMm":0},"cells":[]}]}').Status | Should Be PASS
    }
    It 'validates merged cell padding against the entire span' {
        (Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"table","rows":1,"columns":2,"widthMm":10,"cells":[{"row":1,"column":1,"colSpan":2,"text":"x","style":{"cellMargins":{"leftMm":3,"rightMm":3}}}]}]}').Status | Should Be PASS
    }
    It 'honors an inherited side override and preserves the input' {
        $plan='{"version":"2.0","document":{"tableStyle":{"cellMargins":{"leftMm":6,"rightMm":6}}},"sections":[{"document":{"tableStyle":{"cellMargins":{"rightMm":2}}},"content":[{"type":"table","rows":1,"columns":1,"widthMm":10,"cells":[{"row":1,"column":1,"text":"x"}]}]}]}'|ConvertFrom-Json
        $before=$plan|ConvertTo-Json -Depth 30 -Compress
        (Test-HwpAuthoringPlan $plan).Status | Should Be PASS
        ($plan|ConvertTo-Json -Depth 30 -Compress) | Should Be $before
    }
}

Describe 'Inline shape height and active column validation' {
    It 'subtracts default header and footer space even when empty' {
        (Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":250}]}').Status | Should Be BLOCKED
    }
    It 'honors explicit zero header and footer margins' {
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"page":{"margins":{"headerMm":0,"footerMm":0}}},"content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":250}]}').Status | Should Be PASS
    }
    It 'rejects a page consumed by header and footer space' {
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"page":{"margins":{"headerMm":150,"footerMm":127}}},"content":[{"type":"paragraph","text":"x"}]}').Status | Should Be BLOCKED
    }
    It 'rejects a shape taller than the inline body' {
        (Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":500}]}').Status | Should Be BLOCKED
    }
    It 'leaves explicit floating shape placement available' {
        (Test-AuthoringSafetyJson '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":500,"placement":{"treatAsChar":false}}]}').Status | Should Be PASS
    }
    It 'accounts for a top gutter in inline height' {
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"page":{"orientation":"LANDSCAPE","gutterType":"TOP_ONLY","margins":{"gutterMm":10}}},"content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":185}]}').Status | Should Be BLOCKED
    }
    $cases=@(
        @{Name='first wide column';Breaks='';Want='PASS'},
        @{Name='second narrow column';Breaks='{"type":"column-break"},';Want='BLOCKED'},
        @{Name='column wrap';Breaks='{"type":"column-break"},{"type":"column-break"},';Want='PASS'},
        @{Name='page reset';Breaks='{"type":"column-break"},{"type":"page-break"},';Want='PASS'}
    )
    foreach($case in $cases) {
        It ('uses '+$case.Name) {
            $json='{"version":"2.0","document":{"columns":{"count":2,"gapMm":10,"widthsMm":[110,60]}},"content":['+$case.Breaks+'{"type":"table","rows":1,"columns":1,"widthMm":100,"cells":[]}]}'
            (Test-AuthoringSafetyJson $json).Status | Should Be $case.Want
        }
    }
    It 'resets active column at each section' {
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"columns":{"count":2,"gapMm":10,"widthsMm":[110,60]}},"sections":[{"content":[{"type":"column-break"}]},{"content":[{"type":"table","rows":1,"columns":1,"widthMm":100,"cells":[]}]}]}').Status | Should Be PASS
    }
    It 'preserves uniform column bounds after a column break' {
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"columns":{"count":2,"gapMm":10}},"content":[{"type":"column-break"},{"type":"table","rows":1,"columns":1,"widthMm":84,"cells":[]}]}').Status | Should Be PASS
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"columns":{"count":2,"gapMm":10}},"content":[{"type":"column-break"},{"type":"table","rows":1,"columns":1,"widthMm":86,"cells":[]}]}').Status | Should Be BLOCKED
    }
}

Describe 'Effective inherited superscript and subscript safety' {
    $cases=@(
        @{Name='paragraph';Json='{"version":"2.0","document":{"textStyle":{"superscript":true}},"content":[{"type":"paragraph","text":"x","textStyle":{"subscript":true}}]}'},
        @{Name='run';Json='{"version":"2.0","document":{"textStyle":{"superscript":true}},"content":[{"type":"paragraph","runs":[{"text":"x","textStyle":{"subscript":true}}]}]}'},
        @{Name='cell';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"textStyle":{"superscript":true},"cells":[{"row":1,"column":1,"text":"x","textStyle":{"subscript":true}}]}]}'},
        @{Name='cell paragraph';Json='{"version":"2.0","content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"textStyle":{"superscript":true},"paragraphs":[{"type":"paragraph","text":"x","textStyle":{"subscript":true}}]}]}]}'},
        @{Name='cell run';Json='{"version":"2.0","document":{"textStyle":{"superscript":true}},"content":[{"type":"table","rows":1,"columns":1,"cells":[{"row":1,"column":1,"paragraphs":[{"type":"paragraph","runs":[{"text":"x","textStyle":{"subscript":true}}]}]}]}]}'},
        @{Name='named style run';Json='{"version":"2.0","document":{"styles":[{"name":"Super","textStyle":{"superscript":true}}]},"content":[{"type":"paragraph","styleName":"Super","runs":[{"text":"x","textStyle":{"subscript":true}}]}]}'},
        @{Name='section default';Json='{"version":"2.0","sections":[{"document":{"textStyle":{"superscript":true}},"content":[{"type":"paragraph","text":"x","textStyle":{"subscript":true}}]}]}'}
    )
    foreach($case in $cases) {
        It ('rejects a conflict inherited by a '+$case.Name) {
            (Test-AuthoringSafetyJson $case.Json).Status | Should Be BLOCKED
        }
    }
    It 'preserves an explicit false when switching to subscript' {
        (Test-AuthoringSafetyJson '{"version":"2.0","document":{"textStyle":{"superscript":true}},"content":[{"type":"paragraph","runs":[{"text":"x","textStyle":{"superscript":false,"subscript":true}}]}]}').Status | Should Be PASS
    }
}

Describe 'Existing unsupported option guards remain fail closed' {
    It 'keeps shape page and list semantic guards' {
        foreach($json in @(
            '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":10,"style":{"borders":{"left":{"color":"#FF0000"}}}}]}',
            '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":10,"style":{"cellMargins":{"leftMm":1}}}]}',
            '{"version":"2.0","content":[{"type":"shape","shape":"rectangle","widthMm":10,"heightMm":10,"style":{"cellPaddingMm":1}}]}',
            '{"version":"2.0","document":{"page":{"border":{"cellPaddingMm":1}}},"content":[{"type":"paragraph","text":"x"}]}',
            '{"version":"2.0","document":{"page":{"border":{"cellMargins":{"leftMm":1}}}},"content":[{"type":"paragraph","text":"x"}]}',
            '{"version":"2.0","content":[{"type":"paragraph","text":"x","paragraphStyle":{"list":{"type":"BULLET","start":2}}}]}',
            '{"version":"2.0","content":[{"type":"paragraph","text":"x","paragraphStyle":{"list":{"type":"NUMBER","character":"X"}}}]}')) {
            (Test-AuthoringSafetyJson $json).Status | Should Be BLOCKED
        }
    }
}
