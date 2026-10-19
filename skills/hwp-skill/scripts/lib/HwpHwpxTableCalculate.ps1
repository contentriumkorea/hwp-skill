# Decimal arithmetic only. No Invoke-Expression, script compilation or shell evaluation.
function ConvertTo-ScopedFormulaCoordinate {
    param([string]$Name,$Grid)
    if ($Name -cnotmatch '^([A-Z]{1,3})([1-9][0-9]{0,3})$') {throw "Invalid cell reference: $Name"}
    [int]$column=0;foreach($ch in $Matches[1].ToCharArray()){$column=$column*26+([int]$ch-64)}
    $row=[int]$Matches[2]-1;$column--
    if($row -ge $Grid.RowCount -or $column -ge $Grid.ColumnCount){throw "Cell reference outside table: $Name"}
    return @{Row=$row;Column=$column;Key="$row,$column"}
}

function Get-ScopedFormulaTokens {
    param([object]$Expression)
    if($Expression -isnot [string] -or [string]::IsNullOrWhiteSpace($Expression) -or $Expression.Length -gt 4096){throw 'Formula must be a string of 1 to 4096 characters.'}
    $text=$Expression.Trim();if($text.StartsWith('=')){$text=$text.Substring(1)}
    $tokens=[Collections.Generic.List[string]]::new();$position=0
    while($position -lt $text.Length){
        $m=[regex]::Match($text.Substring($position),'^\s*([0-9]+(?:\.[0-9]*)?|\.[0-9]+|[A-Za-z][A-Za-z0-9]*|[+*/(),:\-])')
        if(-not $m.Success){if([string]::IsNullOrWhiteSpace($text.Substring($position))){break};throw 'Unsupported formula token.'}
        $tokens.Add($m.Groups[1].Value.ToUpperInvariant());$position+=$m.Length
        if($tokens.Count -gt 2048){throw 'Formula token limit exceeded.'}
    }
    if($tokens.Count -eq 0){throw 'Formula has no expression.'}
    return ,$tokens.ToArray()
}

function Get-ScopedNumericCell {
    param($Context,[int]$Row,[int]$Column)
    $Context.Allocation.FormulaReferences++
    if($Context.Allocation.FormulaReferences -gt 65536){throw 'Formula reference limit exceeded.'}
    $key="$Row,$Column";$cell=$Context.Grid.Occupancy[$key]
    if($cell.Row -ne $Row -or $cell.Column -ne $Column){return $null}
    if($Context.Plans.ContainsKey($key)){return Invoke-ScopedFormulaCell $Context $key}
    $text=(Get-ScopedCellVisibleText $cell.Node).Trim()
    if($text.Length -eq 0){return $null}
    if($text -cnotmatch '^[+-]?(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?$'){throw "A referenced cell is not a plain number: $key"}
    return [decimal]::Parse($text.Replace(',',''),[Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture)
}

function Get-ScopedFormulaPrimary {
    param($State)
    if($State.Position -ge $State.Tokens.Count){throw 'Incomplete formula expression.'}
    $token=$State.Tokens[$State.Position];$State.Position++
    if($token -cmatch '^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$'){return [decimal]::Parse($token,[Globalization.CultureInfo]::InvariantCulture)}
    if($token -ceq '('){$value=Get-ScopedFormulaExpression $State;if($State.Position -ge $State.Tokens.Count -or $State.Tokens[$State.Position] -cne ')'){throw 'Unclosed formula parenthesis.'};$State.Position++;return $value}
    if($token -cmatch '^[A-Z]{1,3}[1-9][0-9]{0,3}$'){$c=ConvertTo-ScopedFormulaCoordinate $token $State.Context.Grid;$value=Get-ScopedNumericCell $State.Context $c.Row $c.Column;if($null -eq $value){throw 'An arithmetic cell reference is empty or a covered merged position.'};return $value}
    if($token -cnotin @('SUM','AVERAGE','MIN','MAX','COUNT','ROUND')){throw "Unsupported formula function: $token"}
    if($State.Position -ge $State.Tokens.Count -or $State.Tokens[$State.Position] -cne '('){throw 'Function requires parentheses.'};$State.Position++
    $values=[Collections.Generic.List[decimal]]::new()
    while($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -cne ')'){
        if($token -cne 'ROUND' -and $State.Position+2 -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -cmatch '^[A-Z]{1,3}[1-9][0-9]{0,3}$' -and $State.Tokens[$State.Position+1] -ceq ':'){
            $a=ConvertTo-ScopedFormulaCoordinate $State.Tokens[$State.Position] $State.Context.Grid;$b=ConvertTo-ScopedFormulaCoordinate $State.Tokens[$State.Position+2] $State.Context.Grid;$State.Position+=3
            if($a.Row -gt $b.Row -or $a.Column -gt $b.Column){throw 'Formula range must be forward ordered.'}
            for($r=$a.Row;$r -le $b.Row;$r++){for($c=$a.Column;$c -le $b.Column;$c++){
                $v=Get-ScopedNumericCell $State.Context $r $c;if($null -ne $v){$values.Add($v)}
            }}
        }else{$values.Add((Get-ScopedFormulaExpression $State))}
        if($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -ceq ','){$State.Position++;if($State.Position -ge $State.Tokens.Count -or $State.Tokens[$State.Position] -ceq ')'){throw 'Missing formula argument.'}}else{break}
    }
    if($State.Position -ge $State.Tokens.Count -or $State.Tokens[$State.Position] -cne ')'){throw 'Unclosed function arguments.'};$State.Position++
    if($token -ceq 'ROUND'){if($values.Count -ne 2 -or $values[1] -ne [decimal]::Truncate($values[1]) -or $values[1] -lt 0 -or $values[1] -gt 8){throw 'ROUND needs a number and 0 to 8 decimal places.'};return [decimal]::Round($values[0],[int]$values[1],[MidpointRounding]::AwayFromZero)}
    if($token -ceq 'COUNT'){return [decimal]$values.Count}
    if($values.Count -eq 0){if($token -ceq 'SUM'){return [decimal]0};throw 'Aggregate has no numeric values.'}
    [decimal]$result=0
    if($token -cin @('MIN','MAX')){$result=$values[0]}
    foreach($v in $values){switch -CaseSensitive($token){'MIN'{$result=[Math]::Min($result,$v)};'MAX'{$result=[Math]::Max($result,$v)};default{$result+=$v}}}
    if($token -ceq 'AVERAGE'){$result/=$values.Count}
    return $result
}

function Get-ScopedFormulaUnary {
    param($State)
    $State.Depth++;if($State.Depth -gt 64){throw 'Formula expression nesting exceeds 64.'}
    try{
        if($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -cin @('+','-')){$sign=$State.Tokens[$State.Position];$State.Position++;$v=Get-ScopedFormulaUnary $State;if($sign -ceq '-') {return -$v};return $v}
        return Get-ScopedFormulaPrimary $State
    }finally{$State.Depth--}
}
function Get-ScopedFormulaProduct {
    param($State)
    [decimal]$value=Get-ScopedFormulaUnary $State
    while($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -cin @('*','/')){$op=$State.Tokens[$State.Position];$State.Position++;[decimal]$right=Get-ScopedFormulaUnary $State;if($op -ceq '*'){$value*=$right}else{if($right -eq 0){throw 'Formula division by zero.'};$value/=$right}}
    return $value
}
function Get-ScopedFormulaExpression {
    param($State)
    [decimal]$value=Get-ScopedFormulaProduct $State
    while($State.Position -lt $State.Tokens.Count -and $State.Tokens[$State.Position] -cin @('+','-')){$op=$State.Tokens[$State.Position];$State.Position++;[decimal]$right=Get-ScopedFormulaProduct $State;if($op -ceq '+'){$value+=$right}else{$value-=$right}}
    return $value
}
function Invoke-ScopedFormulaCell {
    param($Context,[string]$Key)
    if($Context.Results.ContainsKey($Key)){return $Context.Results[$Key]}
    if($Context.Active.Count -ge 64 -or -not $Context.Active.Add($Key)){throw 'Circular or excessively deep table formula dependency.'}
    try{
        $state=@{Tokens=(Get-ScopedFormulaTokens $Context.Plans[$Key]['expression']);Position=0;Depth=0;Context=$Context}
        $value=Get-ScopedFormulaExpression $state
        if($state.Position -ne $state.Tokens.Count){throw 'Formula has trailing tokens.'}
        $Context.Results[$Key]=[decimal]$value;return [decimal]$value
    }finally{$null=$Context.Active.Remove($Key)}
}

function New-ScopedCalculatedTable {
    param([Xml.XmlElement]$Table,$Operation,$Package,$Allocation)
    $copy=$Table.CloneNode($true);$grid=Get-ScopedTableGrid $copy
    $calculations=$Operation['calculations']
    if($calculations -isnot [Collections.IList] -or $calculations.Count -lt 1 -or $calculations.Count -gt 256){throw 'calculations must contain 1 to 256 target cells.'}
    if(-not $Allocation.ContainsKey('FormulaReferences')){$Allocation.FormulaReferences=0;$Allocation.FormulaTargets=0}
    $Allocation.FormulaTargets+=$calculations.Count
    if($Allocation.FormulaTargets -gt 1024){throw 'Formula plan exceeds 1024 target cells.'}
    $context=@{Grid=$grid;Plans=@{};Results=@{};Active=[Collections.Generic.HashSet[string]]::new();Allocation=$Allocation}
    foreach($value in $calculations){
        $plan=ConvertTo-ScopedMap $value 'calculation';Assert-ScopedKeys $plan @('row','column','expression','expectedText') 'calculation' @('format','textStyle','paragraphStyle')
        $r=Get-ScopedIndex $plan['row'] 'calculation.row';$c=Get-ScopedIndex $plan['column'] 'calculation.column';$key="$r,$c"
        if(-not $grid.Occupancy.ContainsKey($key) -or $grid.Occupancy[$key].Row -ne $r -or $grid.Occupancy[$key].Column -ne $c){throw 'Calculation target must be a real cell anchor.'}
        if($context.Plans.ContainsKey($key)){throw 'Duplicate calculation target.'}
        $cell=$grid.Occupancy[$key].Node;Assert-ScopedEditContext $cell
        $content=Get-ScopedCellContent $cell (Get-ScopedAvailableStyleIds $Package.Xml['Contents/header.xml'] 'charPr' $Allocation) (Get-ScopedAvailableStyleIds $Package.Xml['Contents/header.xml'] 'paraPr' $Allocation) -PreserveCellMetadata
        if(-not(Test-ScopedExpectedCellText $plan['expectedText'] $content.Text)){throw 'Calculation expectedText does not match target.'}
        $context.Plans[$key]=$plan
    }
    foreach($key in @($context.Plans.Keys)){$null=Invoke-ScopedFormulaCell $context $key}
    if(-not $Allocation.ContainsKey('Calculations')){$Allocation.Calculations=[Collections.Generic.List[object]]::new()}
    foreach($key in $context.Plans.Keys){
        $plan=$context.Plans[$key];$value=$context.Results[$key];$text=$value.ToString('0.############################',[Globalization.CultureInfo]::InvariantCulture)
        if($plan.ContainsKey('format')){
            $format=ConvertTo-ScopedMap $plan['format'] 'calculation.format';Assert-ScopedKeys $format @() 'format' @('decimalPlaces','groupSeparator','prefix','suffix')
            $places=if($format.ContainsKey('decimalPlaces')){Get-ScopedIndex $format['decimalPlaces'] 'decimalPlaces'}else{2}
            if($places -gt 8){throw 'decimalPlaces must be 0 to 8.'}
            if($format.ContainsKey('groupSeparator') -and $format['groupSeparator'] -isnot [bool]){throw 'groupSeparator must be Boolean.'}
            $group=$format.ContainsKey('groupSeparator') -and $format['groupSeparator'];$code=$(if($group){'N'}else{'F'})+[string]$places
            $text=([decimal]::Round($value,$places,[MidpointRounding]::AwayFromZero)).ToString($code,[Globalization.CultureInfo]::InvariantCulture)
            foreach($name in @('prefix','suffix')){if($format.ContainsKey($name)){if($format[$name] -isnot [string] -or $format[$name].Length -gt 64){throw 'Numeric affixes must be strings up to 64 characters.'};$null=[Xml.XmlConvert]::VerifyXmlChars($format[$name]);if($name -ceq 'prefix'){$text=$format[$name]+$text}else{$text+=$format[$name]}}}
        }
        $paragraph=@{text=$text};foreach($name in @('textStyle','paragraphStyle')){if($plan.ContainsKey($name)){$paragraph[$name]=$plan[$name]}}
        $cell=$grid.Occupancy[$key].Node
        $replacement=New-ScopedCellContentReplacement $cell @{expectedText=$plan['expectedText'];paragraphs=@($paragraph)} $Package $Allocation
        $null=$cell.ParentNode.ReplaceChild($replacement,$cell)
        $Allocation.Calculations.Add([pscustomobject]@{Row=$plan['row'];Column=$plan['column'];Expression=$plan['expression'];Value=$value;Text=$text})
    }
    foreach($cache in @($copy.SelectNodes('.//hp:p/hp:linesegarray',(New-ScopedNamespaces $copy.OwnerDocument)))){$null=$cache.ParentNode.RemoveChild($cache)}
    return ,$copy
}
