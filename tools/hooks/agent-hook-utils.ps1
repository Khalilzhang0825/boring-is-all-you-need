[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$script:HookMaxInputBytes = 262144
$script:HookMaxTraversalDepth = 32
$script:HookMaxTraversalNodes = 512
$script:HookMaxCollectionItems = 256

function Read-BoundedHookInput {
    [CmdletBinding()]
    param([int]$MaxBytes = $script:HookMaxInputBytes)

    if ($MaxBytes -le 0) { throw "Hook input byte limit must be positive." }
    $stream = [Console]::OpenStandardInput()
    $buffer = New-Object byte[] 4096
    $memory = New-Object IO.MemoryStream
    $total = 0
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) {
                return [pscustomobject]@{ Text = ""; Exceeded = $true; BytesRead = $total }
            }
            $memory.Write($buffer, 0, $read)
        }
        $bytes = $memory.ToArray()
        $offset = if ($bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            3
        } else {
            0
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        return [pscustomobject]@{
            Text = $strictUtf8.GetString($bytes, $offset, $bytes.Length - $offset)
            Exceeded = $false
            BytesRead = $total
        }
    }
    finally {
        $memory.Dispose()
    }
}

function New-HookTraversalState {
    return @{ Nodes = 0 }
}

function Assert-HookTraversalBudget {
    param(
        [int]$Depth,
        [hashtable]$State
    )
    if ($Depth -gt $script:HookMaxTraversalDepth) {
        throw "Hook event tree exceeds the safe traversal depth limit."
    }
    if ($null -eq $State) { throw "Hook traversal state is missing." }
    $State.Nodes = [int]$State.Nodes + 1
    if ([int]$State.Nodes -gt $script:HookMaxTraversalNodes) {
        throw "Hook event tree exceeds the safe traversal node limit."
    }
}

function Assert-HookCollectionWidth {
    param([object[]]$Items)
    if (@($Items).Count -gt $script:HookMaxCollectionItems) {
        throw "Hook event collection exceeds the safe item limit."
    }
}

function Test-HookProperty {
    param(
        [object]$Object,
        [string]$Name
    )
    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Get-HookPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )
    if (Test-HookProperty -Object $Object -Name $Name) {
        return $Object.$Name
    }
    return $null
}

function Add-HookString {
    param(
        [System.Collections.Generic.List[string]]$List,
        [object]$Value
    )
    if ($null -eq $Value) { return }
    $text = [string]$Value
    if ($text.Trim().Length -gt 0) { $List.Add($text) }
}

function Get-HookToolName {
    param([object]$Object)
    foreach ($name in @("tool_name", "recipient_name", "name")) {
        $value = Get-HookPropertyValue -Object $Object -Name $name
        if ($value) { return [string]$value }
    }
    return ""
}

function Test-ShellToolName {
    param([string]$Name)
    return ($Name -match "(?i)^(Bash|PowerShell|shell_command|functions[.]shell_command)$")
}

function Test-FileToolName {
    param([string]$Name)
    return ($Name -match "(?i)^(apply_patch|Edit|Write|MultiEdit|functions[.]apply_patch)$")
}

function Test-ParallelToolName {
    param([string]$Name)
    return ($Name -match "(?i)^multi_tool_use[.]parallel$")
}

function Add-HookToolNamesFromValue {
    param(
        [object]$Value,
        [System.Collections.Generic.List[string]]$Names,
        [int]$Depth = 0,
        [hashtable]$TraversalState
    )
    if ($null -eq $Value) { return }
    if ($null -eq $TraversalState) { $TraversalState = New-HookTraversalState }
    Assert-HookTraversalBudget -Depth $Depth -State $TraversalState

    $toolName = Get-HookToolName -Object $Value
    if ($toolName) { Add-HookString -List $Names -Value $toolName }

    foreach ($containerName in @("input", "tool_input", "parameters")) {
        Add-HookToolNamesFromValue `
            -Value (Get-HookPropertyValue -Object $Value -Name $containerName) `
            -Names $Names -Depth ($Depth + 1) -TraversalState $TraversalState
    }

    $toolUses = Get-HookPropertyValue -Object $Value -Name "tool_uses"
    if ($toolUses) {
        $toolUseItems = @($toolUses)
        Assert-HookCollectionWidth -Items $toolUseItems
        foreach ($toolUse in $toolUseItems) {
            Add-HookToolNamesFromValue `
                -Value $toolUse -Names $Names -Depth ($Depth + 1) `
                -TraversalState $TraversalState
        }
    }
}

function Get-HookToolNames {
    param([object]$Event)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Event) {
        Add-HookToolNamesFromValue `
            -Value $Event -Names $names -Depth 0 `
            -TraversalState (New-HookTraversalState)
    }
    return @($names | Select-Object -Unique)
}

function Get-HookParallelToolUses {
    param(
        [object]$Event,
        [int]$Depth = 0,
        [hashtable]$TraversalState
    )
    $uses = @()
    if ($null -eq $Event) { return @() }
    if ($null -eq $TraversalState) { $TraversalState = New-HookTraversalState }
    Assert-HookTraversalBudget -Depth $Depth -State $TraversalState

    $topLevelUses = Get-HookPropertyValue -Object $Event -Name "tool_uses"
    if ($topLevelUses) {
        $topLevelItems = @($topLevelUses)
        Assert-HookCollectionWidth -Items $topLevelItems
        foreach ($toolUse in $topLevelItems) { $uses += ,$toolUse }
    }

    foreach ($containerName in @("tool_input", "input", "parameters")) {
        $container = Get-HookPropertyValue -Object $Event -Name $containerName
        if ($null -eq $container) { continue }
        $containerUses = Get-HookPropertyValue -Object $container -Name "tool_uses"
        if ($containerUses) {
            $containerItems = @($containerUses)
            Assert-HookCollectionWidth -Items $containerItems
            foreach ($toolUse in $containerItems) { $uses += ,$toolUse }
        }
    }

    Assert-HookCollectionWidth -Items @($uses)
    return $uses
}

function Get-HookParallelValidationError {
    param(
        [object]$Event,
        [ValidateSet("Command", "File")]
        [string]$GuardKind,
        [int]$Depth = 0,
        [hashtable]$TraversalState
    )
    if ($null -eq $Event) { return "parallel event is null" }
    if ($null -eq $TraversalState) { $TraversalState = New-HookTraversalState }
    Assert-HookTraversalBudget -Depth $Depth -State $TraversalState
    if (-not (Test-ParallelToolName -Name (Get-HookToolName -Object $Event))) {
        return "parallel event name is missing or invalid"
    }

    $parallelUses = @(Get-HookParallelToolUses `
        -Event $Event -Depth ($Depth + 1) -TraversalState $TraversalState)
    if ($parallelUses.Count -eq 0) { return "parallel wrapper schema is unknown" }

    foreach ($toolUse in $parallelUses) {
        $toolName = Get-HookToolName -Object $toolUse
        if (-not $toolName) { return "parallel tool call is unnamed" }

        if (Test-ParallelToolName -Name $toolName) {
            $nestedError = Get-HookParallelValidationError `
                -Event $toolUse -GuardKind $GuardKind -Depth ($Depth + 1) `
                -TraversalState $TraversalState
            if ($nestedError) { return $nestedError }
            continue
        }

        if ($GuardKind -eq "Command" -and (Test-ShellToolName -Name $toolName)) {
            if (@(Get-HookCommands -Event $toolUse).Count -eq 0) {
                return "parallel shell call is incomplete"
            }
        }
        elseif ($GuardKind -eq "File" -and (Test-FileToolName -Name $toolName)) {
            if (@(Get-HookPaths -Event $toolUse).Count -eq 0) {
                return "parallel file call is incomplete"
            }
        }
    }

    return $null
}

function Write-HookDeny {
    param(
        [string]$HookEventName,
        [string]$Reason
    )
    @{
        hookSpecificOutput = @{
            hookEventName = $HookEventName
            permissionDecision = "deny"
            permissionDecisionReason = $Reason
        }
    } | ConvertTo-Json -Depth 5 -Compress
}

function Add-HookCommandsFromWrapper {
    param(
        [object]$Object,
        [System.Collections.Generic.List[string]]$Commands,
        [int]$Depth = 0,
        [hashtable]$TraversalState
    )
    if ($null -eq $Object) { return }
    if ($null -eq $TraversalState) { $TraversalState = New-HookTraversalState }
    Assert-HookTraversalBudget -Depth $Depth -State $TraversalState

    $toolUses = Get-HookPropertyValue -Object $Object -Name "tool_uses"
    if ($toolUses) {
        $toolUseItems = @($toolUses)
        Assert-HookCollectionWidth -Items $toolUseItems
        foreach ($toolUse in $toolUseItems) {
            $toolName = Get-HookToolName -Object $toolUse
            if (Test-ShellToolName -Name $toolName) {
                foreach ($containerName in @("parameters", "tool_input", "input")) {
                    $container = Get-HookPropertyValue -Object $toolUse -Name $containerName
                    $command = Get-HookPropertyValue -Object $container -Name "command"
                    Add-HookString -List $Commands -Value $command
                }
            }
            foreach ($containerName in @("parameters", "tool_input", "input")) {
                Add-HookCommandsFromWrapper `
                    -Object (Get-HookPropertyValue -Object $toolUse -Name $containerName) `
                    -Commands $Commands -Depth ($Depth + 1) `
                    -TraversalState $TraversalState
            }
        }
    }
}

function Get-HookCommands {
    param([object]$Event)
    $commands = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Event) { return @() }
    $traversalState = New-HookTraversalState
    Assert-HookTraversalBudget -Depth 0 -State $traversalState

    $topTool = Get-HookToolName -Object $Event
    foreach ($containerName in @("tool_input", "input", "parameters")) {
        $container = Get-HookPropertyValue -Object $Event -Name $containerName
        if ($null -eq $container) { continue }
        $command = Get-HookPropertyValue -Object $container -Name "command"
        if ($command -and (($topTool -eq "") -or (Test-ShellToolName -Name $topTool))) {
            Add-HookString -List $commands -Value $command
        }
        Add-HookCommandsFromWrapper `
            -Object $container -Commands $commands -Depth 1 `
            -TraversalState $traversalState
    }
    Add-HookCommandsFromWrapper `
        -Object $Event -Commands $commands -Depth 1 `
        -TraversalState $traversalState

    return @($commands | Select-Object -Unique)
}

function Add-PatchPathsFromText {
    param(
        [string]$Text,
        [System.Collections.Generic.List[string]]$Paths
    )
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\*\*\* (Add|Update|Delete) File: (.+)$') {
            $candidate = $Matches[2].Trim()
            if ($candidate.Length -gt 0) { $Paths.Add($candidate) }
        }
        elseif ($line -match '^\*\*\* Move to: (.+)$') {
            $candidate = $Matches[1].Trim()
            if ($candidate.Length -gt 0) { $Paths.Add($candidate) }
        }
    }
}

function Add-HookPathsFromValue {
    param(
        [object]$Value,
        [System.Collections.Generic.List[string]]$Paths,
        [int]$Depth = 0,
        [hashtable]$TraversalState
    )
    if ($null -eq $Value) { return }
    if ($null -eq $TraversalState) { $TraversalState = New-HookTraversalState }
    Assert-HookTraversalBudget -Depth $Depth -State $TraversalState

    if ($Value -is [string]) {
        Add-PatchPathsFromText -Text ([string]$Value) -Paths $Paths
        return
    }

    $valueToolName = Get-HookToolName -Object $Value
    if ($valueToolName -match '(?i)^(?:apply_patch|functions[.]apply_patch)$') {
        foreach ($containerName in @("input", "tool_input", "parameters")) {
            $container = Get-HookPropertyValue -Object $Value -Name $containerName
            $command = Get-HookPropertyValue -Object $container -Name "command"
            if ($command -is [string]) {
                Add-PatchPathsFromText -Text ([string]$command) -Paths $Paths
            }
        }
    }

    foreach ($name in @("file_path", "path")) {
        $path = Get-HookPropertyValue -Object $Value -Name $name
        if ($path) { Add-HookString -List $Paths -Value $path }
    }

    foreach ($name in @("patch")) {
        $text = Get-HookPropertyValue -Object $Value -Name $name
        if ($text -is [string]) {
            Add-PatchPathsFromText -Text ([string]$text) -Paths $Paths
        }
    }

    foreach ($name in @("input", "tool_input", "parameters")) {
        Add-HookPathsFromValue `
            -Value (Get-HookPropertyValue -Object $Value -Name $name) `
            -Paths $Paths -Depth ($Depth + 1) -TraversalState $TraversalState
    }

    $toolUses = Get-HookPropertyValue -Object $Value -Name "tool_uses"
    if ($toolUses) {
        $toolUseItems = @($toolUses)
        Assert-HookCollectionWidth -Items $toolUseItems
        foreach ($toolUse in $toolUseItems) {
            $toolName = Get-HookToolName -Object $toolUse
            if ((Test-FileToolName -Name $toolName) -or (Test-ParallelToolName -Name $toolName) -or -not $toolName) {
                Add-HookPathsFromValue `
                    -Value $toolUse -Paths $Paths -Depth ($Depth + 1) `
                    -TraversalState $TraversalState
            }
        }
    }
}

function Get-HookPaths {
    param([object]$Event)
    $paths = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Event) {
        $topTool = Get-HookToolName -Object $Event
        if ($topTool -and
            -not (Test-FileToolName -Name $topTool) -and
            -not (Test-ParallelToolName -Name $topTool)) {
            return @()
        }
        Add-HookPathsFromValue `
            -Value $Event -Paths $paths -Depth 0 `
            -TraversalState (New-HookTraversalState)
    }
    return @($paths | Select-Object -Unique)
}

function ConvertTo-CommandGuardToken {
    param([string]$Token)

    if (-not $Token) { return $Token }
    if ($Token[0] -eq [char]0x2013 -or
        $Token[0] -eq [char]0x2014 -or
        $Token[0] -eq [char]0x2015) {
        return "-" + $Token.Substring(1)
    }
    return $Token
}

function Test-CommandHasUninspectableBacktick {
    param([string]$Command)

    if (-not $Command) { return $false }
    $quote = [char]0
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $backtick = [char]96
    for ($index = 0; $index -lt $Command.Length; $index++) {
        $character = $Command[$index]
        if ($quote -eq $singleQuote) {
            if ($character -eq $singleQuote) {
                if ($index + 1 -lt $Command.Length -and
                    $Command[$index + 1] -eq $singleQuote) {
                    $index++
                }
                else {
                    $quote = [char]0
                }
            }
            continue
        }
        if ($quote -eq $doubleQuote) {
            if ($character -eq $backtick) { return $true }
            if ($character -eq $doubleQuote) { $quote = [char]0 }
            continue
        }
        if ($character -eq $singleQuote -or $character -eq $doubleQuote) {
            $quote = $character
            continue
        }
        if ($character -eq $backtick) { return $true }
    }
    return $false
}

function Get-CommandTokenStatements {
    param([string]$Command)

    $statements = New-Object System.Collections.Generic.List[object]
    $tokens = New-Object System.Collections.Generic.List[string]
    $token = New-Object Text.StringBuilder
    $quote = [char]0
    $singleQuote = [char]39
    $doubleQuote = [char]34
    for ($index = 0; $index -lt $Command.Length; $index++) {
        $character = $Command[$index]
        if ($quote -ne [char]0) {
            if ($character -eq $quote) {
                if ($quote -eq $singleQuote -and
                    $index + 1 -lt $Command.Length -and
                    $Command[$index + 1] -eq $singleQuote) {
                    [void]$token.Append($singleQuote)
                    $index++
                }
                else {
                    $quote = [char]0
                }
            }
            else {
                [void]$token.Append($character)
            }
            continue
        }
        if ($character -eq $singleQuote -or $character -eq $doubleQuote) {
            $quote = $character
            continue
        }
        if ($character -eq ";" -or $character -eq "|" -or $character -eq "&" -or
            $character -eq "{" -or $character -eq "}" -or
            $character -eq "`r" -or $character -eq "`n") {
            if ($token.Length -gt 0) {
                $tokens.Add((ConvertTo-CommandGuardToken -Token $token.ToString())) | Out-Null
                [void]$token.Clear()
            }
            if ($tokens.Count -gt 0) {
                $statements.Add([pscustomobject]@{ Tokens = $tokens.ToArray() }) | Out-Null
                $tokens = New-Object System.Collections.Generic.List[string]
            }
            continue
        }
        if ([char]::IsWhiteSpace($character)) {
            if ($token.Length -gt 0) {
                $tokens.Add((ConvertTo-CommandGuardToken -Token $token.ToString())) | Out-Null
                [void]$token.Clear()
            }
            continue
        }
        [void]$token.Append($character)
    }
    if ($token.Length -gt 0) {
        $tokens.Add((ConvertTo-CommandGuardToken -Token $token.ToString())) | Out-Null
    }
    if ($tokens.Count -gt 0) {
        $statements.Add([pscustomobject]@{ Tokens = $tokens.ToArray() }) | Out-Null
    }
    return $statements.ToArray()
}

function Get-CommandExecutableLeaf {
    param([string]$Token)

    if (-not $Token) { return "" }
    $separatorIndex = [Math]::Max(
        $Token.LastIndexOf([char]92),
        $Token.LastIndexOf([char]47)
    )
    if ($separatorIndex -ge 0 -and $separatorIndex + 1 -lt $Token.Length) {
        return $Token.Substring($separatorIndex + 1)
    }
    return $Token
}

function Test-PowerShellCommandInvocationSwitch {
    param([string]$Token)

    if (-not $Token -or -not $Token.StartsWith("-", [StringComparison]::Ordinal)) {
        return $false
    }
    $name = $Token.Substring(1)
    if ($name -ieq "c") { return $true }
    if ($name.Length -lt 3) { return $false }
    return (
        "command".StartsWith($name, [StringComparison]::OrdinalIgnoreCase) -or
        "commandwithargs".StartsWith($name, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-PowerShellEncodedCommandSwitch {
    param([string]$Token)

    if (-not $Token -or -not $Token.StartsWith("-", [StringComparison]::Ordinal)) {
        return $false
    }
    $name = $Token.Substring(1)
    return $name -match '(?i)^(?:e|ec|enc|EncodedCommand)$'
}

function Get-GitCommandInfo {
    param([string[]]$Tokens)

    if ($Tokens.Count -eq 0 -or
        (Get-CommandExecutableLeaf -Token $Tokens[0]) -notmatch "(?i)^git(?:[.]exe)?$") {
        return $null
    }
    $noValueOptions = @(
        "-p", "-P", "--paginate", "--no-pager", "--no-replace-objects",
        "--bare", "--no-optional-locks", "--literal-pathspecs",
        "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs",
        "--no-advice", "--no-lazy-fetch"
    )
    $terminalOptions = @("--version", "-v", "--help", "-h", "--exec-path", "--html-path", "--man-path", "--info-path")
    $valueOptions = @("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env")
    $index = 1
    while ($index -lt $Tokens.Count) {
        $value = $Tokens[$index]
        if ($terminalOptions -contains $value) {
            return [pscustomobject]@{
                Subcommand = "__safe_terminal__"
                Arguments = [string[]]@()
                Error = $null
            }
        }
        if (-not $value.StartsWith("-")) {
            $arguments = if ($index + 1 -lt $Tokens.Count) {
                [string[]]$Tokens[($index + 1)..($Tokens.Count - 1)]
            }
            else {
                [string[]]@()
            }
            return [pscustomobject]@{
                Subcommand = $value.ToLowerInvariant()
                Arguments = $arguments
                Error = $null
            }
        }
        if ($noValueOptions -contains $value) {
            $index++
            continue
        }
        if ($valueOptions -contains $value) {
            if ($index + 1 -ge $Tokens.Count) {
                return [pscustomobject]@{ Subcommand = $null; Arguments = [string[]]@(); Error = "missing Git global option value" }
            }
            $index += 2
            continue
        }
        if ($value -match "^-C.+" -or $value -match "^-c.+" -or
            $value -match "^--(?:git-dir|work-tree|namespace|super-prefix|config-env|exec-path)=") {
            $index++
            continue
        }
        return [pscustomobject]@{
            Subcommand = $null
            Arguments = [string[]]@()
            Error = "unrecognized Git global option"
        }
    }
    return [pscustomobject]@{ Subcommand = $null; Arguments = [string[]]@(); Error = "missing Git subcommand" }
}

function Get-NormalizedCmdInvocationTokens {
    param([string[]]$Tokens)

    $current = @($Tokens)
    $removedAtPrefix = $false
    $removedCallPrefix = $false
    $removedParentheses = $false
    $normalizationDepth = 0

    while ($current.Count -gt 0) {
        if ($current[0].StartsWith("@", [StringComparison]::Ordinal)) {
            if ($removedAtPrefix -or $current[0].Length -eq 1) {
                return [pscustomobject]@{
                    Tokens = [string[]]@()
                    Depth = $normalizationDepth
                    Error = "ambiguous cmd statement-leading @ prefix"
                }
            }
            $current[0] = $current[0].Substring(1)
            $removedAtPrefix = $true
            $normalizationDepth++
            continue
        }

        if ($current[0].StartsWith("(", [StringComparison]::Ordinal)) {
            $statementText = $current -join " "
            if ($removedParentheses -or
                -not $current[$current.Count - 1].EndsWith(")", [StringComparison]::Ordinal) -or
                [regex]::Matches($statementText, "[(]").Count -ne 1 -or
                [regex]::Matches($statementText, "[)]").Count -ne 1) {
                return [pscustomobject]@{
                    Tokens = [string[]]@()
                    Depth = $normalizationDepth
                    Error = "ambiguous cmd statement parentheses"
                }
            }

            $current[0] = $current[0].Substring(1)
            $lastIndex = $current.Count - 1
            $current[$lastIndex] = $current[$lastIndex].Substring(
                0,
                $current[$lastIndex].Length - 1
            )
            $current = @($current | Where-Object { $_.Length -gt 0 })
            if ($current.Count -eq 0) {
                return [pscustomobject]@{
                    Tokens = [string[]]@()
                    Depth = $normalizationDepth
                    Error = "empty cmd statement parentheses"
                }
            }
            $removedParentheses = $true
            $normalizationDepth++
            continue
        }

        if ($current[0] -ieq "call") {
            if ($removedCallPrefix -or $current.Count -eq 1) {
                return [pscustomobject]@{
                    Tokens = [string[]]@()
                    Depth = $normalizationDepth
                    Error = "ambiguous cmd call prefix"
                }
            }
            $current = @($current[1..($current.Count - 1)])
            $removedCallPrefix = $true
            $normalizationDepth++
            continue
        }

        break
    }

    return [pscustomobject]@{
        Tokens = [string[]]$current
        Depth = $normalizationDepth
        Error = $null
    }
}

function Get-PowerShellCommandTexts {
    param([string]$Command)

    $parseTokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Command,
        [ref]$parseTokens,
        [ref]$parseErrors
    )
    if (@($parseErrors).Count -gt 0) {
        return [pscustomobject]@{
            Parsed = $false
            Commands = [string[]]@()
        }
    }

    $commands = New-Object System.Collections.Generic.List[string]
    $commandAsts = @($ast.FindAll({
        param($node)
        return $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($commandAst in $commandAsts) {
        $commandText = [string]$commandAst.Extent.Text
        if (-not [string]::IsNullOrWhiteSpace($commandText)) {
            $commands.Add($commandText) | Out-Null
        }
    }
    return [pscustomobject]@{
        Parsed = $true
        Commands = [string[]]$commands.ToArray()
    }
}

function Test-DangerousCommand {
    param(
        [string]$Command,
        [int]$InspectionDepth = 0,
        [ValidateSet("Generic", "Cmd", "PowerShell")]
        [string]$CommandLanguage = "Generic",
        [switch]$SkipPowerShellAst
    )
    if (-not $Command) { return $null }
    if ($Command.Length -gt 65536) {
        return "Blocked: command text exceeds the safe inspection length limit."
    }
    if ($InspectionDepth -gt 16) {
        return "Blocked: command wrapper nesting exceeds the safe inspection depth limit."
    }
    if (Test-CommandHasUninspectableBacktick -Command $Command) {
        return "Blocked: command guard cannot safely inspect executable shell backtick escapes. Use a literal command without backtick escapes."
    }
    if ($CommandLanguage -ne "Cmd" -and -not $SkipPowerShellAst) {
        $powerShellCommands = Get-PowerShellCommandTexts -Command $Command
        if ($powerShellCommands.Parsed) {
            foreach ($powerShellCommand in @($powerShellCommands.Commands)) {
                $powerShellReason = Test-DangerousCommand `
                    -Command ([string]$powerShellCommand) `
                    -InspectionDepth ($InspectionDepth + 1) `
                    -CommandLanguage $CommandLanguage `
                    -SkipPowerShellAst
                if ($powerShellReason) { return $powerShellReason }
            }
            return $null
        }
    }
    $statements = @(Get-CommandTokenStatements -Command $Command)
    if ($statements.Count -gt 256) {
        return "Blocked: command contains too many statements for safe inspection."
    }
    $statementTexts = @($statements | ForEach-Object { @($_.Tokens) -join " " })
    $cmd = $statementTexts -join " ; "
    foreach ($statement in $statements) {
        $tokens = @($statement.Tokens)
        $currentDepth = $InspectionDepth
        while ($tokens.Count -gt 0) {
            if ($currentDepth -gt 16) {
                return "Blocked: command wrapper nesting exceeds the safe inspection depth limit."
            }

            if ($CommandLanguage -eq "Cmd") {
                $cmdInvocation = Get-NormalizedCmdInvocationTokens -Tokens ([string[]]$tokens)
                if ($cmdInvocation.Error) {
                    return "Blocked: command guard could not safely normalize cmd invocation prefixes."
                }
                $tokens = @($cmdInvocation.Tokens)
                $currentDepth += [int]$cmdInvocation.Depth
                if ($currentDepth -gt 16) {
                    return "Blocked: command wrapper nesting exceeds the safe inspection depth limit."
                }
            }

            if ($CommandLanguage -eq "PowerShell" -and $tokens[0] -eq ".") {
                if ($tokens.Count -eq 1) {
                    return "Blocked: command guard could not safely locate the literal PowerShell dot-invocation target."
                }
                $tokens = @($tokens[1..($tokens.Count - 1)])
                if ($tokens[0] -match '[$`*?(){}]' -or
                    $tokens[0] -match "^[.](?:[.]?)$") {
                    return "Blocked: command guard could not safely locate a literal PowerShell dot-invocation target."
                }
                $currentDepth++
                if ($currentDepth -gt 16) {
                    return "Blocked: command wrapper nesting exceeds the safe inspection depth limit."
                }
            }

            $removedPowerShellStructure = $false
            while ($tokens.Count -gt 0 -and $tokens[0] -eq "{") {
                if ($tokens.Count -eq 1) {
                    $tokens = @()
                }
                else {
                    $tokens = @($tokens[1..($tokens.Count - 1)])
                }
                $removedPowerShellStructure = $true
            }
            while ($tokens.Count -gt 0 -and $tokens[$tokens.Count - 1] -eq "}") {
                if ($tokens.Count -eq 1) {
                    $tokens = @()
                }
                else {
                    $tokens = @($tokens[0..($tokens.Count - 2)])
                }
                $removedPowerShellStructure = $true
            }
            if ($removedPowerShellStructure) {
                $currentDepth++
                continue
            }
            if ($tokens.Count -eq 0) { break }

            $transparentLeaf = Get-CommandExecutableLeaf -Token $tokens[0]
            $nestedStart = -1
            if ($transparentLeaf -match "(?i)^env(?:[.]exe)?$") {
                $nestedStart = 1
                while ($nestedStart -lt $tokens.Count) {
                    $envToken = $tokens[$nestedStart]
                    if ($envToken -eq "--") {
                        $nestedStart++
                        break
                    }
                    if ($envToken -match "^[A-Za-z_][A-Za-z0-9_]*=.*$" -or
                        $envToken -match "^(?:-|-[i0v]|--ignore-environment|--null|--debug)$" -or
                        $envToken -match "^--(?:unset|chdir)=.+$") {
                        $nestedStart++
                        continue
                    }
                    if ($envToken -match "^(?:-u|--unset|-C|--chdir)$") {
                        if ($nestedStart + 1 -ge $tokens.Count) {
                            return "Blocked: command guard could not safely locate the command after env."
                        }
                        $nestedStart += 2
                        continue
                    }
                    if ($envToken -match "^(?:-S|--split-string)(?:=|$)") {
                        return "Blocked: command guard cannot safely inspect env split-string execution."
                    }
                    if ($envToken -match "^(?:--help|--version)$") {
                        $nestedStart = $tokens.Count
                        break
                    }
                    if ($envToken.StartsWith("-")) {
                        return "Blocked: command guard could not safely locate the command after env."
                    }
                    break
                }
            }
            elseif ($transparentLeaf -match "(?i)^exec(?:[.]exe)?$") {
                $nestedStart = 1
                while ($nestedStart -lt $tokens.Count) {
                    $execToken = $tokens[$nestedStart]
                    if ($execToken -eq "--") {
                        $nestedStart++
                        break
                    }
                    if ($execToken -match "^-[cl]+$") {
                        $nestedStart++
                        continue
                    }
                    if ($execToken -eq "-a") {
                        if ($nestedStart + 1 -ge $tokens.Count) {
                            return "Blocked: command guard could not safely locate the command after exec."
                        }
                        $nestedStart += 2
                        continue
                    }
                    if ($execToken.StartsWith("-")) {
                        return "Blocked: command guard could not safely locate the command after exec."
                    }
                    break
                }
            }
            elseif ($transparentLeaf -match "(?i)^command(?:[.]exe)?$") {
                $nestedStart = 1
                $isCommandQuery = $false
                while ($nestedStart -lt $tokens.Count) {
                    $commandToken = $tokens[$nestedStart]
                    if ($commandToken -eq "--") {
                        $nestedStart++
                        break
                    }
                    if ($commandToken -match "^-[pvV]+$") {
                        if ($commandToken -match "[vV]") { $isCommandQuery = $true }
                        $nestedStart++
                        continue
                    }
                    if ($commandToken.StartsWith("-")) {
                        return "Blocked: command guard could not safely locate the command after command."
                    }
                    break
                }
                if ($isCommandQuery) {
                    $nestedStart = $tokens.Count
                }
            }

            if ($nestedStart -lt 0) { break }
            if ($nestedStart -ge $tokens.Count) {
                $tokens = @()
                break
            }
            $tokens = @($tokens[$nestedStart..($tokens.Count - 1)])
            if ($tokens.Count -eq 0 -or
                $tokens[0] -match '[$`*?(){}]' -or
                $tokens[0] -match "^[.](?:[.]?)$") {
                return "Blocked: command guard could not safely locate a literal nested executable."
            }
            $currentDepth++
        }
        if ($tokens.Count -eq 0) { continue }

        $executableLeaf = if ($tokens.Count -gt 0) {
            Get-CommandExecutableLeaf -Token $tokens[0]
        }
        else {
            ""
        }
        $wrapperFlagIndex = -1
        $inlineCmdCommand = $null
        if ($tokens.Count -ge 2) {
            for ($candidateIndex = 1; $candidateIndex -lt $tokens.Count; $candidateIndex++) {
                if ($executableLeaf -match "(?i)^cmd(?:[.]exe)?$" -and
                    $tokens[$candidateIndex] -match "(?i)^/[ck]$") {
                    $wrapperFlagIndex = $candidateIndex
                    break
                }
                if ($executableLeaf -match "(?i)^cmd(?:[.]exe)?$" -and
                    $tokens[$candidateIndex] -match "(?i)^/[ck](.+)$") {
                    $wrapperFlagIndex = $candidateIndex
                    $inlineCmdCommand = [string]$Matches[1]
                    break
                }
                if (($executableLeaf -match "(?i)^(?:powershell|pwsh)(?:[.]exe)?$" -and
                        (Test-PowerShellCommandInvocationSwitch -Token $tokens[$candidateIndex])) -or
                    ($executableLeaf -match "(?i)^(?:ba|z|k)?sh(?:[.]exe)?$" -and
                        $tokens[$candidateIndex] -match "(?i)^-[A-Za-z]*c[A-Za-z]*$")) {
                    $wrapperFlagIndex = $candidateIndex
                    break
                }
            }
        }
        if ($wrapperFlagIndex -ge 0) {
            if ($null -eq $inlineCmdCommand -and
                $wrapperFlagIndex + 1 -ge $tokens.Count) {
                return "Blocked: command guard could not safely locate the nested wrapper command."
            }
            $nestedCommand = if ($executableLeaf -match "(?i)^(?:ba|z|k)?sh(?:[.]exe)?$") {
                $tokens[$wrapperFlagIndex + 1]
            }
            elseif ($null -ne $inlineCmdCommand) {
                @(
                    $inlineCmdCommand
                    if ($wrapperFlagIndex + 1 -lt $tokens.Count) {
                        $tokens[($wrapperFlagIndex + 1)..($tokens.Count - 1)]
                    }
                ) -join " "
            }
            else {
                ($tokens[($wrapperFlagIndex + 1)..($tokens.Count - 1)]) -join " "
            }
            if (-not $nestedCommand) {
                return "Blocked: command guard could not safely locate the nested wrapper command."
            }
            $nestedCommandLanguage = if ($executableLeaf -match "(?i)^cmd(?:[.]exe)?$") {
                "Cmd"
            }
            elseif ($executableLeaf -match "(?i)^(?:powershell|pwsh)(?:[.]exe)?$") {
                "PowerShell"
            }
            else {
                "Generic"
            }
            $nestedReason = Test-DangerousCommand `
                -Command $nestedCommand `
                -InspectionDepth ($currentDepth + 1) `
                -CommandLanguage $nestedCommandLanguage
            if ($nestedReason) { return $nestedReason }
        }
        $gitCommand = Get-GitCommandInfo -Tokens ([string[]]$tokens)
        if ($null -ne $gitCommand) {
            if ($gitCommand.Error) {
                return ("Blocked: command guard could not safely locate the Git subcommand (" + $gitCommand.Error + ").")
            }
            $gitArguments = @($gitCommand.Arguments)
            switch ($gitCommand.Subcommand) {
                "reset" {
                    if (@($gitArguments | Where-Object { $_ -eq "--hard" }).Count -gt 0) {
                        return "Blocked: 'git reset --hard' can destroy uncommitted work. Ask the user explicitly and explain the rollback scope."
                    }
                }
                "clean" {
                    if (@($gitArguments | Where-Object { $_ -match "(?i)^(?:--force|-[A-Za-z]*f[A-Za-z]*)$" }).Count -gt 0) {
                        return "Blocked: 'git clean -f' can delete untracked files. Ask the user explicitly and list the target paths."
                    }
                }
                "push" {
                    if (@($gitArguments | Where-Object {
                        $_ -match "(?i)^-[A-Za-z]*f[A-Za-z]*(?:=.*)?$" -or
                        $_ -match "(?i)^--force(?:$|[-=].*)" -or
                        $_ -match "(?i)^--mirror(?:=.*)?$" -or
                        $_.StartsWith("+")
                    }).Count -gt 0) {
                        return "Blocked: force push is not allowed without explicit user approval."
                    }
                }
                "add" {
                    if (@($gitArguments | Where-Object {
                        $_ -match "(?i)^(?:[.]|-A|--all|-u|--update|:/|:)$"
                    }).Count -gt 0) {
                        return "Blocked: avoid blanket staging. Use git-checkpoint.ps1 with an explicit -Files list."
                    }
                }
                "restore" {
                    $hasStaged = @($gitArguments | Where-Object { $_ -match "(?i)^--staged(?:=|$)" }).Count -gt 0
                    $hasWorktree = @($gitArguments | Where-Object { $_ -match "(?i)^--worktree(?:=|$)" }).Count -gt 0
                    if (-not $hasStaged -or $hasWorktree) {
                        return "Blocked: git restore can discard uncommitted worktree changes. Use staged-only restore or ask the user explicitly."
                    }
                }
                "checkout" {
                    return "Blocked: git checkout is ambiguous and can discard uncommitted work. Use git switch for branches or ask the user explicitly."
                }
            }
        }
        for ($tokenIndex = 0; $tokenIndex -lt $tokens.Count; $tokenIndex++) {
            $commandToken = $tokens[$tokenIndex]
            $commandLeaf = Get-CommandExecutableLeaf -Token $commandToken
            $tailTokens = @($tokens[$tokenIndex..($tokens.Count - 1)])
            if ($commandLeaf -match '(?i)^(?:powershell|pwsh)(?:[.]exe)?$' -and
                @($tailTokens | Where-Object {
                    Test-PowerShellEncodedCommandSwitch -Token $_
                }).Count -gt 0) {
                return "Blocked: encoded PowerShell commands hide intent. Ask the user explicitly and use readable commands."
            }
            if ($commandLeaf -match '(?i)^git-checkpoint[.]ps1$' -and
                @($tailTokens | Where-Object {
                    $_ -match '(?i)^-(?:A|Al|All)(?:(?::|=).*)?$' -and
                    $_ -notmatch '(?i)^-(?:A|Al|All):(?:[$]?false|0)$'
                }).Count -gt 0) {
                return "Blocked: git-checkpoint.ps1 requires an explicit -Files list; blanket staging is not supported."
            }
            if ($commandLeaf -match "(?i)^rm(?:[.]exe)?$") {
                $hasRecursive = @($tailTokens | Where-Object { $_ -match "(?i)^(?:--recursive|-[A-Za-z]*r[A-Za-z]*)$" }).Count -gt 0
                $hasForce = @($tailTokens | Where-Object { $_ -match "(?i)^(?:--force|-[A-Za-z]*f[A-Za-z]*)$" }).Count -gt 0
                if ($hasRecursive -and $hasForce) {
                    return "Blocked: recursive force delete requires explicit approval and verified target paths."
                }
            }
            if ($commandLeaf -match "(?i)^(?:Remove-Item|ri|rm|del|erase)$" -and
                @($tailTokens | Where-Object {
                    $_ -match '(?i)^-(?:R|Re|Rec|Recu|Recur|Recurs|Recurse)(?:(?::|=)(?!(?:[$]?false|0)$).*)?$'
                }).Count -gt 0) {
                return "Blocked: recursive Remove-Item requires explicit approval and verified target paths."
            }
            if ($commandLeaf -match "(?i)^(?:rmdir|rd)$" -and
                @($tailTokens | Where-Object { $_ -match "(?i)^(?:/s|-Recurse|-r)$" }).Count -gt 0) {
                return "Blocked: recursive directory delete requires explicit approval and verified target paths."
            }
            if ($commandLeaf -match "(?i)^(?:del|erase)$" -and
                @($tailTokens | Where-Object { $_ -match "(?i)^/s$" }).Count -gt 0) {
                return "Blocked: recursive delete requires explicit approval and verified target paths."
            }
        }
    }
    if ($cmd -match "(?i)\b(powershell(?:[.]exe)?|pwsh(?:[.]exe)?)\b[^\r\n]*\s-(EncodedCommand|enc|e|ec)\b") {
        return "Blocked: encoded PowerShell commands hide intent. Ask the user explicitly and use readable commands."
    }
    if (($cmd -match "(?i)(>>?|Out-File|Set-Content|Add-Content|Tee-Object)") -and ($cmd -match "(?i)(\.env\b|id_rsa|id_dsa|id_ecdsa|id_ed25519|\.pem\b|\.p12\b|\.pfx\b|\.key\b|\.keystore\b|\.pgpass\b)")) {
        return "Blocked: writing to a secret/.env file via shell redirection is not allowed. Use .env.example, or ask the user."
    }

    return $null
}

function Get-Sha256Hex {
    param([string]$Text)
    if ($null -eq $Text) { $Text = "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Write-GuardAuditRecord {
    param(
        [ValidateSet("command-guard", "file-guard")]
        [string]$GuardName,
        [string]$Reason,
        [string]$ToolName,
        [string]$RawInput
    )
    $logFile = if ($env:STEADYAGENT_GUARD_AUDIT_LOG) {
        [IO.Path]::GetFullPath([string]$env:STEADYAGENT_GUARD_AUDIT_LOG)
    } else {
        $logBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
        Join-Path $logBase "SteadyAgent\logs\guard-audit.log"
    }
    $logDir = Split-Path -Parent $logFile
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    if ((Test-Path -LiteralPath $logFile -PathType Leaf) -and
        ((Get-Item -LiteralPath $logFile).Length -gt 5MB)) {
        $archiveName = "guard-audit-" + (Get-Date -Format "yyyyMMddHHmmss") + ".log"
        Move-Item -LiteralPath $logFile -Destination (Join-Path $logDir $archiveName) -Force
    }

    $safeReason = ([string]$Reason -replace "[`r`n]+", " ").Trim()
    if ($safeReason.Length -gt 240) {
        $safeReason = $safeReason.Substring(0, 237) + "..."
    }
    $safeToolName = ([string]$ToolName -replace "[^A-Za-z0-9_.-]", "")
    if (-not $safeToolName) { $safeToolName = "unknown" }
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $inputHash = Get-Sha256Hex -Text ([string]$RawInput)
    $entry = "{0} [{1}] {2} -- tool={3} input_sha256={4}" -f @(
        $stamp,
        $GuardName,
        $safeReason,
        $safeToolName,
        $inputHash
    )
    [IO.File]::AppendAllText(
        $logFile,
        $entry + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
}
