<#
.SYNOPSIS
Writes the public interface of the module, as PublicInterface.txt records it.

.DESCRIPTION
For each exported command and each of its parameter sets, one line per parameter: its type, position
(none when it takes a name only), whether it is mandatory or comes from the pipeline, its validation
attributes with all their arguments, and its default value. The common parameters are left out;
-WhatIf and -Confirm stay, as the sign of SupportsShouldProcess, and -Confirm carries the
ConfirmImpact of the command: when it reaches $ConfirmPreference (High by default), the command asks
before it acts, and a script that nobody watches waits for an answer.

PublicInterface.Tests.ps1 fails when the module differs from PublicInterface.txt. After a change to
the interface made on purpose, regenerate the file and commit it with the change, so that the review
shows what callers will see.

.EXAMPLE
./Tests/Get-PublicInterface.ps1 | Set-Content ./Tests/PublicInterface.txt
#>
param (
    [string]$ModulePath = (Join-Path (Split-Path $PSScriptRoot) 'ElektoImapPosh.psd1')
)

$module = Import-Module $ModulePath -Force -PassThru
$commonParameters = [System.Management.Automation.Cmdlet]::CommonParameters

# An argument of an attribute: a constant written in one way, so that only a change of value shows;
# anything else (a script block, an enum member) as its text
function Format-AttributeArgument($Ast) {
    try { $value = $Ast.SafeGetValue() } catch { return $Ast.Extent.Text -replace '\s+', ' ' }
    if ($null -eq $value) { return '$null' }
    if ($value -is [string]) { return "'" + ($value -replace "'", "''") + "'" }
    if ($value -is [bool]) { return ('$' + $value).ToLowerInvariant() }
    if ($value -is [scriptblock]) { return "$value".Trim() -replace '\s+', ' ' }
    return "$value"
}

# An attribute with all the arguments it was declared with, since any of them may change what a call
# accepts: IgnoreCase of ValidateSet, Options of ValidatePattern, the kind of range of ValidateRange
function Format-Attribute([System.Management.Automation.Language.AttributeAst]$Attribute) {
    $type = $Attribute.TypeName.GetReflectionAttributeType()
    $arguments = @($Attribute.PositionalArguments | ForEach-Object { Format-AttributeArgument $_ })
    $arguments += @($Attribute.NamedArguments | ForEach-Object {
        # A named argument as the attribute spells it, and true when its value is left out
        $name = $type.GetProperty($_.ArgumentName, [Reflection.BindingFlags]'IgnoreCase, Public, Instance').Name
        "$name = $(Format-AttributeArgument $_.Argument)"
    } | Sort-Object)
    return ($type.Name -replace 'Attribute$') + $(if ($arguments) { "($($arguments -join ', '))" })
}

'# The public interface of ElektoImapPosh, written by Tests/Get-PublicInterface.ps1. Tests/PublicInterface.Tests.ps1'
'# fails when the module differs from it: regenerate it only for a change made on purpose.'
foreach ($command in Get-Command -Module $module.Name | Sort-Object Name) {
    # The defaults and the attributes as declared; Parameter and Alias are read from the command below
    $defaults = @{}
    $attributes = @{}
    foreach ($parameterAst in $command.ScriptBlock.Ast.Body.ParamBlock.Parameters) {
        $name = $parameterAst.Name.VariablePath.UserPath
        if ($parameterAst.DefaultValue) { $defaults[$name] = $parameterAst.DefaultValue.Extent.Text }
        $attributes[$name] = @($parameterAst.Attributes |
            Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.GetReflectionAttributeType() -notin [System.Management.Automation.ParameterAttribute], [System.Management.Automation.AliasAttribute] } |
            ForEach-Object { Format-Attribute $_ } | Sort-Object)
    }
    $confirmImpact = ($command.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }).ConfirmImpact

    ''
    $command.Name
    foreach ($parameterSet in $command.ParameterSets | Sort-Object { -not $_.IsDefault }, Name) {
        '  ' + $parameterSet.Name + $(if ($parameterSet.IsDefault) { ' (default)' })
        $parameters = $parameterSet.Parameters | Where-Object Name -notin $commonParameters
        $positional = $parameters | Where-Object Position -ge 0 | Sort-Object Position
        $named = $parameters | Where-Object Position -lt 0 | Sort-Object Name
        foreach ($parameter in @($positional) + @($named)) {
            $traits = @($parameter.ParameterType.Name)
            if ($parameter.Position -ge 0) { $traits += "position $($parameter.Position)" }
            if ($parameter.IsMandatory) { $traits += 'mandatory' }
            if ($parameter.ValueFromPipeline) { $traits += 'from the pipeline' }
            if ($parameter.ValueFromPipelineByPropertyName) { $traits += 'from the pipeline by property name' }
            if ($parameter.ValueFromRemainingArguments) { $traits += 'remaining arguments' }
            if ($parameter.Aliases.Count -gt 0) { $traits += "alias $($parameter.Aliases -join ', ')" }
            if ($attributes.ContainsKey($parameter.Name)) { $traits += $attributes[$parameter.Name] }
            if ($parameter.Name -eq 'Confirm') { $traits += "ConfirmImpact $confirmImpact" }
            if ($defaults.ContainsKey($parameter.Name)) { $traits += "default $($defaults[$parameter.Name])" }
            '    -' + $parameter.Name + ' ' + ($traits -join ', ')
        }
    }
}
