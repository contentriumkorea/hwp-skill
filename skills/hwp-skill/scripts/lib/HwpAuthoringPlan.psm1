Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HwpHwpxReferences.psm1') -ErrorAction Stop

function Get-HwpPlanValue {
    param([AllowNull()][object]$Object, [string]$Name, [AllowNull()][object]$Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $Object.PSObject.Properties[$Name].Name -ceq $Name) { return ,$Object.$Name }
    $Default
}

# Evaluate the subset used by the bundled schema, without requiring Test-Json (PS 7).
# Schema documents are trusted package resources, never supplied by a document or plan.
function Test-HwpSchemaNode {
    param([AllowNull()][object]$Value, [object]$Node, [object]$Root, [string]$Path,
        [Collections.Generic.List[string]]$Errors, [int]$Depth = 0)
    if ($Errors.Count -ge 32) {throw '작성 계획 오류가 32개를 초과했습니다.'}
    if ($Depth -gt 80) { $Errors.Add("$Path : 계획 중첩 한도 초과"); return }
    $negative = Get-HwpPlanValue $Node 'not'
    if ($null -ne $negative) {
        $negativeErrors = [Collections.Generic.List[string]]::new()
        Test-HwpSchemaNode $Value $negative $Root $Path $negativeErrors ($Depth + 1)
        if ($negativeErrors.Count -eq 0) { $Errors.Add("$Path : 함께 사용할 수 없는 속성입니다.") }
    }
    $ref = Get-HwpPlanValue $Node '$ref'
    if ($null -ne $ref) {
        if (-not ([string]$ref).StartsWith('#/')) { throw '외부 스키마 참조는 허용하지 않습니다.' }
        $target = $Root
        foreach ($part in ([string]$ref).Substring(2).Split('/')) {
            $target = Get-HwpPlanValue $target ($part.Replace('~1','/').Replace('~0','~'))
            if ($null -eq $target) { throw "스키마 참조가 없습니다: $ref" }
        }
        Test-HwpSchemaNode $Value $target $Root $Path $Errors ($Depth + 1)
        return
    }
    foreach ($choice in @('oneOf','anyOf')) {
        $branches = Get-HwpPlanValue $Node $choice
        if ($null -eq $branches) { continue }
        $matches = 0; $best = $null
        foreach ($branch in $branches) {
            $problems = [Collections.Generic.List[string]]::new()
            Test-HwpSchemaNode $Value $branch $Root $Path $problems ($Depth + 1)
            if ($problems.Count -eq 0) { $matches++ }
            if ($null -eq $best -or $problems.Count -lt $best.Count) { $best = $problems }
        }
        if ($matches -eq 0) {
            # Report the user's selected block type instead of a nearer unrelated shape.
            $discriminator=Get-HwpPlanValue $Value 'type'
            if ($null -ne $discriminator) {foreach ($branch in $branches) {
                $candidate=$branch;$candidateRef=Get-HwpPlanValue $branch '$ref'
                if ($null -ne $candidateRef) {$candidate=$Root;foreach($part in $candidateRef.Substring(2).Split('/')){$candidate=Get-HwpPlanValue $candidate $part}}
                $constant=Get-HwpPlanValue (Get-HwpPlanValue (Get-HwpPlanValue $candidate 'properties') 'type') 'const'
                if ($constant -ceq $discriminator) {$best=[Collections.Generic.List[string]]::new();Test-HwpSchemaNode $Value $candidate $Root $Path $best ($Depth+1);break}
            }}
            foreach ($problem in $best) { $Errors.Add($problem) }; return
        }
        if ($choice -eq 'oneOf' -and $matches -ne 1) { $Errors.Add("$Path : 배타적인 형식 중 하나만 허용합니다."); return }
    }
    $type = Get-HwpPlanValue $Node 'type'
    $numeric = $Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
    $validType = switch ($type) {
        'object' { $Value -is [pscustomobject] }
        'array' { $Value -is [array] }
        'string' { $Value -is [string] }
        'boolean' { $Value -is [bool] }
        'integer' { $numeric -and [double]$Value -eq [Math]::Truncate([double]$Value) }
        'number' { $numeric -and -not [double]::IsNaN([double]$Value) -and -not [double]::IsInfinity([double]$Value) }
        default { $true }
    }
    if (-not $validType) { $Errors.Add("$Path : $type 자료형이 필요합니다."); return }
    foreach ($key in @('const','enum')) {
        if ($Node.PSObject.Properties.Name -cnotcontains $key) { continue }
        $allowed = if ($key -eq 'const') { @($Node.const) } else { @($Node.enum) }
        $found = $false
        foreach ($item in $allowed) {
            if ($null -eq $item -and $null -eq $Value) { $found = $true }
            elseif ($numeric -and $item -is [ValueType] -and $item -isnot [bool] -and [double]$item -eq [double]$Value) { $found = $true }
            elseif ($null -ne $item -and $null -ne $Value -and $item.GetType() -eq $Value.GetType() -and $item -ceq $Value) { $found = $true }
        }
        if (-not $found) { $Errors.Add("$Path : 허용되지 않는 값입니다.") }
    }
    if ($Value -is [pscustomobject]) {
        $properties = Get-HwpPlanValue $Node 'properties' ([pscustomobject]@{})
        foreach ($required in (Get-HwpPlanValue $Node 'required' @())) {
            if ($Value.PSObject.Properties.Name -cnotcontains $required) { $Errors.Add("$Path.$required : 필수 속성이 없습니다.") }
        }
        foreach ($p in $Value.PSObject.Properties) {
            if ($Errors.Count -ge 32) {throw '작성 계획 오류가 32개를 초과했습니다.'}
            if ($null -ne $properties.PSObject.Properties[$p.Name] -and $properties.PSObject.Properties[$p.Name].Name -ceq $p.Name) {
                Test-HwpSchemaNode $p.Value $properties.($p.Name) $Root "$Path.$($p.Name)" $Errors ($Depth + 1)
            } elseif ((Get-HwpPlanValue $Node 'additionalProperties' $true) -eq $false) {
                $Errors.Add("$Path.$($p.Name) : 지원하지 않는 속성입니다.")
            }
        }
    }
    if ($type -eq 'array') {
        $min = Get-HwpPlanValue $Node 'minItems' 0; $max = Get-HwpPlanValue $Node 'maxItems' ([int]::MaxValue)
        if ($Value.Count -lt $min -or $Value.Count -gt $max) { $Errors.Add("$Path : 항목 수 범위 오류") }
        $items = Get-HwpPlanValue $Node 'items'
        if ($null -ne $items) {
            for ($i=0; $i -lt $Value.Count; $i++) { Test-HwpSchemaNode $Value[$i] $items $Root "$Path[$i]" $Errors ($Depth + 1) }
        }
    }
    if ($type -eq 'string') {
        $min = Get-HwpPlanValue $Node 'minLength' 0; $max = Get-HwpPlanValue $Node 'maxLength' ([int]::MaxValue)
        if ($Value.Length -lt $min -or $Value.Length -gt $max) { $Errors.Add("$Path : 문자열 길이 범위 오류") }
        $pattern = Get-HwpPlanValue $Node 'pattern'
        if ($null -ne $pattern -and $Value -cnotmatch $pattern) { $Errors.Add("$Path : 문자열 형식 오류") }
    }
    if ($type -in @('integer','number')) {
        foreach ($key in @('minimum','maximum','exclusiveMinimum','exclusiveMaximum')) {
            $limit = Get-HwpPlanValue $Node $key
            if ($null -eq $limit) { continue }
            $bad = switch ($key) {
                'minimum' { $Value -lt $limit }; 'maximum' { $Value -gt $limit }
                'exclusiveMinimum' { $Value -le $limit }; 'exclusiveMaximum' { $Value -ge $limit }
            }
            if ($bad) { $Errors.Add("$Path : $key 값 범위 오류") }
        }
    }
}

function Test-HwpAuthoringPlan {
    param([Parameter(Mandatory)][object]$Plan)
    $errors = [Collections.Generic.List[string]]::new()
    try {
        $json=$Plan | ConvertTo-Json -Depth 100 -Compress
        if ($json.Length -gt 10MB) {throw '작성 계획이 10 MiB 문자 한도를 초과했습니다.'}
        $copy = $json | ConvertFrom-Json
        $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../schemas/generate-plan.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-HwpPlanValue $copy 'version') -eq '1.0') {
            Test-HwpSchemaNode $copy $schema.'$defs'.version1 $schema '$' $errors
        } else {
            # Keep the selected version's diagnostics; do not report a nearer V1 branch.
            $selected=$schema|ConvertTo-Json -Depth 100 -Compress|ConvertFrom-Json
            $selected.oneOf=@($schema.oneOf[1])
            Test-HwpSchemaNode $copy $selected $schema '$' $errors
        }
        if ($errors.Count -eq 0) {
            Test-HwpAuthoringTree $copy '$' $errors
            $normalized = ConvertTo-HwpAuthoringPlan -Plan $copy
            $bookmarks=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($block in $normalized.content) {if ($block.type -eq 'bookmark' -and -not $bookmarks.Add($block.name)) {$errors.Add('중복 책갈피 이름입니다.')}}
            $gridSlots=0
            foreach ($section in $normalized.sections) {
            $doc = $section.document
            Test-HwpAuthoringTree $section '$' $errors
            $null=New-HwpxSectionReferenceXml -Document $doc -Id 1 -Width 1
            $page = Get-HwpPlanValue $doc 'page'
            $pageBorder=Get-HwpPlanValue $page 'border'
            foreach ($key in @('cellPaddingMm','cellMargins')) {if ($null -ne $pageBorder -and $null -ne $pageBorder.PSObject.Properties[$key]) {$errors.Add("page.border.$key : 쪽 테두리에는 셀 여백을 적용할 수 없습니다.")}}
            $direction = Get-HwpPlanValue $page 'orientation' 'PORTRAIT'
            $w = [double](Get-HwpPlanValue $page 'widthMm' $(if ($direction -eq 'LANDSCAPE') {297} else {210}))
            $h = [double](Get-HwpPlanValue $page 'heightMm' $(if ($direction -eq 'LANDSCAPE') {210} else {297}))
            if (($direction -eq 'PORTRAIT' -and $w -gt $h) -or ($direction -eq 'LANDSCAPE' -and $h -gt $w)) {
                $errors.Add('$.document.page : 방향과 화면상 용지 치수가 모순됩니다.')
            }
            $m = Get-HwpPlanValue $page 'margins'
            $gutter = Get-HwpPlanValue $m 'gutterMm' 0
            $topGutter = (Get-HwpPlanValue $page 'gutterType' 'LEFT_ONLY') -eq 'TOP_ONLY'
            $bodyWidth = $w - (Get-HwpPlanValue $m 'leftMm' 15) - (Get-HwpPlanValue $m 'rightMm' 15) - $(if ($topGutter) {0} else {$gutter})
            $bodyHeight = $h - (Get-HwpPlanValue $m 'topMm' 10) - (Get-HwpPlanValue $m 'bottomMm' 10) - (Get-HwpPlanValue $m 'headerMm' 15) - (Get-HwpPlanValue $m 'footerMm' 15) - $(if ($topGutter) {$gutter} else {0})
            if ($bodyWidth -le 0 -or $bodyHeight -le 0) { $errors.Add('$.document.page.margins : 본문 영역이 0 이하입니다.') }
            $bodyWidthUnits=(ConvertTo-HwpPlanUnit $w)-(ConvertTo-HwpPlanUnit (Get-HwpPlanValue $m 'leftMm' 15))-(ConvertTo-HwpPlanUnit (Get-HwpPlanValue $m 'rightMm' 15))-$(if($topGutter){0}else{ConvertTo-HwpPlanUnit $gutter})
            $bodyHeightUnits=ConvertTo-HwpPlanUnit $h
            foreach($pair in @(@('topMm',10),@('bottomMm',10),@('headerMm',15),@('footerMm',15))) {$bodyHeightUnits-=ConvertTo-HwpPlanUnit (Get-HwpPlanValue $m $pair[0] $pair[1])}
            if($topGutter){$bodyHeightUnits-=ConvertTo-HwpPlanUnit $gutter}
            if($bodyWidthUnits -le 0 -or $bodyHeightUnits -le 0){throw '반올림 후 본문 HWPUNIT 영역이 0 이하입니다.'}
            $columns = Get-HwpPlanValue $doc 'columns'
            $columnCount = Get-HwpPlanValue $columns 'count' 1
            $gap = Get-HwpPlanValue $columns 'gapMm' 0
            $available = ($bodyWidth - ($columnCount - 1)*$gap) / $columnCount
            if ($available -le 0) { $errors.Add('단 간격이 본문 영역을 초과합니다.') }
            $widths = Get-HwpPlanValue $columns 'widthsMm'
            if ($null -ne $widths) {
                if ($widths.Count -ne $columnCount -or [Math]::Abs(($widths|Measure-Object -Sum).Sum + ($columnCount-1)*$gap - $bodyWidth) -gt 0.02) { $errors.Add('단 너비 개수 또는 합이 본문 폭과 다릅니다.') }
                foreach($width in $widths){if((ConvertTo-HwpPlanUnit $width) -le 0){throw '반올림 후 단 너비가 0입니다.'}}
            }
            $columnIndex=0
            foreach ($block in $section.content) {
                if($errors.Count -ge 32){throw '작성 계획 오류가 32개를 초과했습니다.'}
                Test-HwpInheritedTextStyle $block (Get-HwpPlanValue $doc 'textStyle')
                if($block.type -eq 'column-break'){$columnIndex=($columnIndex+1)%$columnCount}
                if($block.type -eq 'page-break'){$columnIndex=0}
                $available=if($null -ne $widths){$widths[$columnIndex]}else{($bodyWidth-($columnCount-1)*$gap)/$columnCount}
                $availableUnits=if($null -ne $widths){ConvertTo-HwpPlanUnit $widths[$columnIndex]}else{[long][Math]::Floor(($bodyWidthUnits-($columnCount-1)*(ConvertTo-HwpPlanUnit $gap))/$columnCount)}
                if($availableUnits -le 0){throw '반올림 후 단 영역이 0입니다.'}
                if ($block.type -in @('field','bookmark','hyperlink','footnote','endnote','toc') -and $normalized.sourceVersion -eq '2.0') {
                    if ($block.type -eq 'field' -and ($null -ne $block.PSObject.Properties['memo'] -or $null -ne $block.PSObject.Properties['display'])) {$errors.Add('V2 실제 필드는 name/value/label을 사용하며 memo/display는 지원하지 않습니다.')}
                    $null=New-HwpxReferenceBlockXml -Block $block -Id 1 -Width 1
                    $targets=if ($block.type -eq 'hyperlink') {@($block.target)} elseif ($block.type -eq 'toc') {@($block.entries|ForEach-Object {$_.target})} else {@()}
                    foreach ($target in $targets) {if ($target.StartsWith('#') -and -not $bookmarks.Contains($target.Substring(1))) {$errors.Add("내부 링크 대상이 없습니다: $target")}}
                }
                if ($block.type -in @('image','shape')) {
                    if ($block.type -eq 'shape') {
                        $shapeStyle=Get-HwpPlanValue $block 'style'
                        foreach ($key in @('borders','cellPaddingMm','cellMargins')) {if ($null -ne $shapeStyle -and $null -ne $shapeStyle.PSObject.Properties[$key]) {$errors.Add("shape.style.$key : 기본 도형은 균일한 테두리만 지원합니다.")}}
                    }
                    $crop=Get-HwpPlanValue $block 'crop'
                    if ((Get-HwpPlanValue $crop 'left' 0)+(Get-HwpPlanValue $crop 'right' 0) -ge 1 -or (Get-HwpPlanValue $crop 'top' 0)+(Get-HwpPlanValue $crop 'bottom' 0) -ge 1) {$errors.Add('이미지 자르기 영역이 비어 있습니다.')}
                    $placement=Get-HwpPlanValue $block 'placement'
                    if ((Get-HwpPlanValue $placement 'treatAsChar' $true) -and (Get-HwpPlanValue $block 'widthMm' 40) -gt $available) {$errors.Add('인라인 개체가 부모 폭을 초과합니다.')}
                    if($block.type -eq 'shape' -and (Get-HwpPlanValue $placement 'treatAsChar' $true) -and (ConvertTo-HwpPlanUnit $block.heightMm) -gt $bodyHeightUnits){$errors.Add('인라인 도형이 본문 높이를 초과합니다.')}
                }
                if ($block.type -ne 'table') { continue }
                $gridSlots+=$block.rows*$block.columns
                if ($gridSlots -gt 20000) {throw '문서 전체 표 그리드는 20,000칸 이하여야 합니다.'}
                $tableWidth = Get-HwpPlanValue $block 'widthMm' $available
                if ($tableWidth -gt $available + 0.02) { $errors.Add('표 너비가 부모 영역을 초과합니다.') }
                $colWidths = Get-HwpPlanValue $block 'columnWidthsMm'
                if ($null -ne $colWidths -and ($colWidths.Count -ne $block.columns -or [Math]::Abs(($colWidths|Measure-Object -Sum).Sum - $tableWidth) -gt 0.02)) { $errors.Add('표 열 너비 개수 또는 합이 표 너비와 다릅니다.') }
                $rowHeights = Get-HwpPlanValue $block 'rowHeightsMm'
                if ($null -ne $rowHeights -and $rowHeights.Count -ne $block.rows) { $errors.Add('표 행 높이 개수가 행 수와 다릅니다.') }
                $tableUnits=if($null -ne $block.PSObject.Properties['widthMm']){ConvertTo-HwpPlanUnit $tableWidth}else{$availableUnits}
                if($tableUnits -le 0 -or $tableUnits -gt $availableUnits){throw '반올림 후 표 너비가 본문 영역을 벗어났습니다.'}
                if($null -ne $colWidths -and $colWidths.Count -ne $block.columns){throw '표 열 너비 개수가 잘못되었습니다.'}
                if($null -ne $rowHeights -and $rowHeights.Count -ne $block.rows){throw '표 행 높이 개수가 잘못되었습니다.'}
                $columnUnits=@(if($null -ne $colWidths){foreach($value in $colWidths){ConvertTo-HwpPlanUnit $value}}else{1..$block.columns|ForEach-Object {[long][Math]::Floor($tableUnits/$block.columns)}})
                $columnUnits[$block.columns-1]+=$tableUnits-($columnUnits|Measure-Object -Sum).Sum
                $rowUnits=@(if($null -ne $rowHeights){foreach($value in $rowHeights){ConvertTo-HwpPlanUnit $value}}else{1..$block.rows|ForEach-Object {1800}})
                if(@($columnUnits+$rowUnits|Where-Object {$_ -le 0}).Count){throw '반올림 후 표의 열 너비 또는 행 높이가 0 이하입니다.'}
                $seen = [Collections.Generic.HashSet[string]]::new()
                $anchors=@{}
                foreach ($cell in $block.cells) {
                    $rs=Get-HwpPlanValue $cell 'rowSpan' 1; $cs=Get-HwpPlanValue $cell 'colSpan' 1
                    if ($cell.row+$rs-1 -gt $block.rows -or $cell.column+$cs-1 -gt $block.columns) { throw '병합 셀이 표 범위를 벗어났습니다.' }
                    $anchors["$($cell.row):$($cell.column)"]=$cell
                    for ($r=$cell.row; $r -lt $cell.row+$rs; $r++) { for ($c=$cell.column; $c -lt $cell.column+$cs; $c++) {
                        if (-not $seen.Add("${r}:${c}")) { throw '$.content.cells : 중복 또는 겹치는 셀 주소입니다.' }
                    } }
                }
                $tableStyle=Merge-HwpPlanObject (Get-HwpPlanValue $doc 'tableStyle') (Get-HwpPlanValue $block 'style')
                for($r=1;$r -le $block.rows;$r++){for($c=1;$c -le $block.columns;$c++){
                    $key="${r}:${c}";if($seen.Contains($key) -and -not $anchors.ContainsKey($key)){continue}
                    $cell=$anchors[$key];$rs=Get-HwpPlanValue $cell 'rowSpan' 1;$cs=Get-HwpPlanValue $cell 'colSpan' 1
                    $style=Merge-HwpPlanObject $tableStyle (Get-HwpPlanValue $cell 'style');$padding=Get-HwpPlanValue $style 'cellPaddingMm' 1.8;$margins=Get-HwpPlanValue $style 'cellMargins'
                    $cellWidth=($columnUnits[($c-1)..($c+$cs-2)]|Measure-Object -Sum).Sum
                    $cellHeight=($rowUnits[($r-1)..($r+$rs-2)]|Measure-Object -Sum).Sum
                    $horizontal=(ConvertTo-HwpPlanUnit (Get-HwpPlanValue $margins 'leftMm' $padding))+(ConvertTo-HwpPlanUnit (Get-HwpPlanValue $margins 'rightMm' $padding))
                    $vertical=(ConvertTo-HwpPlanUnit (Get-HwpPlanValue $margins 'topMm' $padding))+(ConvertTo-HwpPlanUnit (Get-HwpPlanValue $margins 'bottomMm' $padding))
                    if($cellWidth -le $horizontal -or ($null -ne $rowHeights -and $cellHeight -le $vertical)){throw "표 셀 ${r}:${c}의 안쪽 여백이 유효 크기를 모두 차지합니다."}
                }}
            }
            }
        }
    } catch { $errors.Add("작성 계획 검사 실패: $($_.Exception.Message)") }
    [pscustomobject]@{ Status = $(if ($errors.Count) {'BLOCKED'} else {'PASS'}); Errors = @($errors) }
}

function ConvertTo-HwpPlanUnit {
    param([double]$Mm)
    return [long][Math]::Round($Mm*283.4645669)
}

function Test-HwpInheritedTextStyle {
    param([object]$Node,[AllowNull()][object]$ParentStyle)
    $style=Merge-HwpPlanObject $ParentStyle (Get-HwpPlanValue $Node 'textStyle')
    if((Get-HwpPlanValue $style 'superscript' $false) -and (Get-HwpPlanValue $style 'subscript' $false)){throw '상속한 글자 서식에 윗첨자와 아랫첨자가 동시에 적용됩니다.'}
    foreach($collection in @('cells','paragraphs','runs')){foreach($child in (Get-HwpPlanValue $Node $collection @())){Test-HwpInheritedTextStyle $child $style}}
}

function Test-HwpAuthoringTree {
    param([AllowNull()][object]$Value,[string]$Path,[Collections.Generic.List[string]]$Errors)
    if ($Value -is [string]) {try {$null=[Xml.XmlConvert]::VerifyXmlChars($Value)} catch {$Errors.Add("$Path : XML에 쓸 수 없는 문자가 있습니다.")};return}
    if ($Value -is [array]) {foreach ($item in $Value) {Test-HwpAuthoringTree $item $Path $Errors};return}
    if ($Value -isnot [pscustomobject]) {return}
    if ($null -ne $Value.PSObject.Properties['styles']) {
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($style in $Value.styles) {if (-not $names.Add($style.name)) {$Errors.Add('스타일 이름이 중복입니다.')}}
    }
    if ((Get-HwpPlanValue $Value 'superscript' $false) -and (Get-HwpPlanValue $Value 'subscript' $false)) {$Errors.Add('윗첨자와 아랫첨자는 동시에 적용할 수 없습니다.')}
    if ($null -ne $Value.PSObject.Properties['list']) {
        $list=$Value.list
        if ($list.type -eq 'BULLET' -and $null -ne $list.PSObject.Properties['start']) {$Errors.Add("$Path.list.start : 글머리표에 시작 번호를 지정할 수 없습니다.")}
        if ($list.type -ne 'BULLET' -and $null -ne $list.PSObject.Properties['character']) {$Errors.Add("$Path.list.character : 번호 목록의 사용자 문자는 지원하지 않습니다.")}
    }
    if ($null -ne $Value.PSObject.Properties['lineSpacing'] -and $null -ne $Value.PSObject.Properties['lineSpacingPercent']) {$Errors.Add('줄 간격은 비율 또는 고정/최소 중 하나로 지정합니다.')}
    foreach ($property in $Value.PSObject.Properties) {Test-HwpAuthoringTree $property.Value ($Path+'.'+$property.Name) $Errors}
}

function Merge-HwpPlanObject {
    param([AllowNull()][object]$Base, [AllowNull()][object]$Override)
    $result = [pscustomobject]@{}
    foreach ($obj in @($Base,$Override)) {
        if ($null -eq $obj) { continue }
        if ($null -ne $obj.PSObject.Properties['paperSize']) {$result.PSObject.Properties.Remove('paperWidthMm');$result.PSObject.Properties.Remove('paperHeightMm')}
        if ($null -ne $obj.PSObject.Properties['paperWidthMm'] -or $null -ne $obj.PSObject.Properties['paperHeightMm']) {$result.PSObject.Properties.Remove('paperSize')}
        if ($null -ne $obj.PSObject.Properties['lineSpacing'] -and $null -eq $obj.PSObject.Properties['lineSpacingPercent']) {$result.PSObject.Properties.Remove('lineSpacingPercent')}
        if ($null -ne $obj.PSObject.Properties['lineSpacingPercent'] -and $null -eq $obj.PSObject.Properties['lineSpacing']) {$result.PSObject.Properties.Remove('lineSpacing')}
        foreach ($prop in $obj.PSObject.Properties) {
            $value = $prop.Value
            if ($value -is [pscustomobject]) { $value = Merge-HwpPlanObject (Get-HwpPlanValue $result $prop.Name) $value }
            $result | Add-Member NoteProperty $prop.Name $value -Force
        }
    }
    $result
}

function ConvertTo-HwpAuthoringPlan {
    param([Parameter(Mandatory)][object]$Plan)
    $copy = $Plan | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json
    $version = [string]$copy.version
    $defaults = Get-HwpPlanValue $copy 'document' ([pscustomobject]@{})
    $sourceSections = if ($copy.PSObject.Properties.Name -contains 'sections') { @($copy.sections) } else { @([pscustomobject]@{content=@($copy.content)}) }
    $sections = @($sourceSections | ForEach-Object {
        $doc = Merge-HwpPlanObject $defaults (Get-HwpPlanValue $_ 'document')
        if ($version -eq '2.0') {
            $page = Get-HwpPlanValue $doc 'page' ([pscustomobject]@{})
            if ($null -ne $page.PSObject.Properties['widthMm'] -or $null -ne $page.PSObject.Properties['heightMm']) { throw 'V2 용지는 paperWidthMm/paperHeightMm을 사용합니다.' }
            $hasSize = $null -ne $page.PSObject.Properties['paperSize']
            $hasW = $null -ne $page.PSObject.Properties['paperWidthMm']
            $hasH = $null -ne $page.PSObject.Properties['paperHeightMm']
            if (($hasSize -and ($hasW -or $hasH)) -or ($hasW -ne $hasH)) { throw '용지 프리셋과 사용자 치수는 배타적이며 사용자 치수는 쌍으로 필요합니다.' }
            $presets = @{A3=@(297,420);A4=@(210,297);A5=@(148,210);ISO_B4=@(250,353);ISO_B5=@(176,250);JIS_B4=@(257,364);JIS_B5=@(182,257);LETTER=@(215.9,279.4);LEGAL=@(215.9,355.6)}
            $size = if ($hasW) { @($page.paperWidthMm,$page.paperHeightMm) } else { $presets[[string](Get-HwpPlanValue $page 'paperSize' 'A4')] }
            if ($size[0] -gt $size[1]) { throw '기준 용지의 너비는 높이 이하여야 합니다. 가로 방향은 orientation으로 지정합니다.' }
            $direction = Get-HwpPlanValue $page 'orientation' 'PORTRAIT'
            $page | Add-Member NoteProperty widthMm $(if ($direction -eq 'LANDSCAPE') {$size[1]} else {$size[0]}) -Force
            $page | Add-Member NoteProperty heightMm $(if ($direction -eq 'LANDSCAPE') {$size[0]} else {$size[1]}) -Force
            $doc | Add-Member NoteProperty page $page -Force
        } elseif (@((Get-HwpPlanValue $doc 'page' ([pscustomobject]@{})).PSObject.Properties | Where-Object {$_.Name -match '^paper'}).Count -gt 0) {
            throw 'V1은 paperSize 또는 기준 용지 치수를 지원하지 않습니다. version 2.0을 사용합니다.'
        }
        foreach ($block in $_.content) {
            $styleName=Get-HwpPlanValue $block 'styleName'
            if ($null -ne $styleName) {
                $styles=Get-HwpPlanValue $doc 'styles' @()
                $matches=@($styles|Where-Object {$_.name -ceq $styleName})
                if ($matches.Count -ne 1) {throw "이름 있는 스타일이 없거나 중복입니다: $styleName"}
                foreach ($property in @('textStyle','paragraphStyle')) {
                    $base=Merge-HwpPlanObject (Get-HwpPlanValue $doc $property) (Get-HwpPlanValue $matches[0] $property)
                    $block|Add-Member NoteProperty $property (Merge-HwpPlanObject $base (Get-HwpPlanValue $block $property)) -Force
                }
            }
            if ($null -ne $block.PSObject.Properties['runs']) { $block | Add-Member NoteProperty text (@($block.runs | ForEach-Object {$_.text}) -join '') -Force }
            if ($block.type -eq 'table') {foreach ($cell in $block.cells) {
                if ($null -ne $cell.PSObject.Properties['paragraphs']) {
                    foreach ($p in $cell.paragraphs) {
                        $cellStyleName=Get-HwpPlanValue $p 'styleName'
                        if ($null -ne $cellStyleName) {
                            $matches=@((Get-HwpPlanValue $doc 'styles' @())|Where-Object {$_.name -ceq $cellStyleName})
                            if ($matches.Count -ne 1) {throw "이름 있는 셀 스타일이 없거나 중복입니다: $cellStyleName"}
                            foreach ($property in @('textStyle','paragraphStyle')) {
                                $base=Merge-HwpPlanObject (Get-HwpPlanValue $doc $property) (Get-HwpPlanValue $block $property)
                                $base=Merge-HwpPlanObject $base (Get-HwpPlanValue $cell $property)
                                $base=Merge-HwpPlanObject $base (Get-HwpPlanValue $matches[0] $property)
                                $p|Add-Member NoteProperty $property (Merge-HwpPlanObject $base (Get-HwpPlanValue $p $property)) -Force
                            }
                        }
                        if ($null -ne $p.PSObject.Properties['runs']) {$p|Add-Member NoteProperty text (@($p.runs|ForEach-Object {$_.text})-join '') -Force}
                    }
                    $cell|Add-Member NoteProperty text (@($cell.paragraphs|ForEach-Object {$_.text})-join "`r`n") -Force
                }
            }}
        }
        [pscustomobject]@{document=$doc;content=@($_.content)}
    })
    [pscustomobject]@{version='1.0';sourceVersion=$version;title=(Get-HwpPlanValue $copy 'title' '');document=$sections[0].document;sections=$sections;content=@($sections | ForEach-Object {$_.content})}
}

Export-ModuleMember -Function @('Test-HwpAuthoringPlan','Get-HwpPlanValue','ConvertTo-HwpAuthoringPlan')
