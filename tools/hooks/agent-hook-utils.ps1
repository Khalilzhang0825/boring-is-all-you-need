[CmdletBinding()]
param()

Set-StrictMode -Version Latest

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
        [System.Collections.Generic.List[string]]$Names
    )
    if ($null -eq $Value) { return }

    $toolName = Get-HookToolName -Object $Value
    if ($toolName) { Add-HookString -List $Names -Value $toolName }

    foreach ($containerName in @("input", "tool_input", "parameters")) {
        Add-HookToolNamesFromValue -Value (Get-HookPropertyValue -Object $Value -Name $containerName) -Names $Names
    }

    $toolUses = Get-HookPropertyValue -Object $Value -Name "tool_uses"
    if ($toolUses) {
        foreach ($toolUse in @($toolUses)) {
            Add-HookToolNamesFromValue -Value $toolUse -Names $Names
        }
    }
}

function Get-HookToolNames {
    param([object]$Event)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Event) { Add-HookToolNamesFromValue -Value $Event -Names $names }
    return @($names | Select-Object -Unique)
}

function Get-HookParallelToolUses {
    param([object]$Event)
    $uses = @()
    if ($null -eq $Event) { return @() }

    $topLevelUses = Get-HookPropertyValue -Object $Event -Name "tool_uses"
    if ($topLevelUses) {
        foreach ($toolUse in @($topLevelUses)) { $uses += ,$toolUse }
    }

    foreach ($containerName in @("tool_input", "input", "parameters")) {
        $container = Get-HookPropertyValue -Object $Event -Name $containerName
        if ($null -eq $container) { continue }
        $containerUses = Get-HookPropertyValue -Object $container -Name "tool_uses"
        if ($containerUses) {
            foreach ($toolUse in @($containerUses)) { $uses += ,$toolUse }
        }
    }

    return $uses
}

function Get-HookParallelValidationError {
    param(
        [object]$Event,
        [ValidateSet("Command", "File")]
        [string]$GuardKind
    )
    if ($null -eq $Event) { return "parallel event is null" }
    if (-not (Test-ParallelToolName -Name (Get-HookToolName -Object $Event))) {
        return "parallel event name is missing or invalid"
    }

    $parallelUses = @(Get-HookParallelToolUses -Event $Event)
    if ($parallelUses.Count -eq 0) { return "parallel wrapper schema is unknown" }

    foreach ($toolUse in $parallelUses) {
        $toolName = Get-HookToolName -Object $toolUse
        if (-not $toolName) { return "parallel tool call is unnamed" }

        if (Test-ParallelToolName -Name $toolName) {
            $nestedError = Get-HookParallelValidationError -Event $toolUse -GuardKind $GuardKind
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
        [System.Collections.Generic.List[string]]$Commands
    )
    if ($null -eq $Object) { return }

    $toolUses = Get-HookPropertyValue -Object $Object -Name "tool_uses"
    if ($toolUses) {
        foreach ($toolUse in @($toolUses)) {
            $toolName = Get-HookToolName -Object $toolUse
            if (Test-ShellToolName -Name $toolName) {
                foreach ($containerName in @("parameters", "tool_input", "input")) {
                    $container = Get-HookPropertyValue -Object $toolUse -Name $containerName
                    $command = Get-HookPropertyValue -Object $container -Name "command"
                    Add-HookString -List $Commands -Value $command
                }
            }
            foreach ($containerName in @("parameters", "tool_input", "input")) {
                Add-HookCommandsFromWrapper -Object (Get-HookPropertyValue -Object $toolUse -Name $containerName) -Commands $Commands
            }
        }
    }
}

function Get-HookCommands {
    param([object]$Event)
    $commands = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Event) { return @() }

    $topTool = Get-HookToolName -Object $Event
    foreach ($containerName in @("tool_input", "input", "parameters")) {
        $container = Get-HookPropertyValue -Object $Event -Name $containerName
        if ($null -eq $container) { continue }
        $command = Get-HookPropertyValue -Object $container -Name "command"
        if ($command -and (($topTool -eq "") -or (Test-ShellToolName -Name $topTool))) {
            Add-HookString -List $commands -Value $command
        }
        Add-HookCommandsFromWrapper -Object $container -Commands $commands
    }
    Add-HookCommandsFromWrapper -Object $Event -Commands $commands

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
        [System.Collections.Generic.List[string]]$Paths
    )
    if ($null -eq $Value) { return }

    if ($Value -is [string]) {
        Add-PatchPathsFromText -Text ([string]$Value) -Paths $Paths
        return
    }

    foreach ($name in @("file_path", "path")) {
        $path = Get-HookPropertyValue -Object $Value -Name $name
        if ($path) { Add-HookString -List $Paths -Value $path }
    }

    foreach ($name in @("command", "patch", "content", "changes")) {
        $text = Get-HookPropertyValue -Object $Value -Name $name
        if ($text -is [string]) {
            Add-PatchPathsFromText -Text ([string]$text) -Paths $Paths
        }
    }

    foreach ($name in @("input", "tool_input", "parameters")) {
        Add-HookPathsFromValue -Value (Get-HookPropertyValue -Object $Value -Name $name) -Paths $Paths
    }

    $toolUses = Get-HookPropertyValue -Object $Value -Name "tool_uses"
    if ($toolUses) {
        foreach ($toolUse in @($toolUses)) {
            $toolName = Get-HookToolName -Object $toolUse
            if ((Test-FileToolName -Name $toolName) -or (Test-ParallelToolName -Name $toolName) -or -not $toolName) {
                Add-HookPathsFromValue -Value $toolUse -Paths $Paths
            }
        }
    }
}

function Get-HookPaths {
    param([object]$Event)
    $paths = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Event) { Add-HookPathsFromValue -Value $Event -Paths $paths }
    return @($paths | Select-Object -Unique)
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
            $character -eq "`r" -or $character -eq "`n") {
            if ($token.Length -gt 0) {
                $tokens.Add($token.ToString()) | Out-Null
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
                $tokens.Add($token.ToString()) | Out-Null
                [void]$token.Clear()
            }
            continue
        }
        [void]$token.Append($character)
    }
    if ($token.Length -gt 0) { $tokens.Add($token.ToString()) | Out-Null }
    if ($tokens.Count -gt 0) {
        $statements.Add([pscustomobject]@{ Tokens = $tokens.ToArray() }) | Out-Null
    }
    return $statements.ToArray()
}

function Get-GitCommandInfo {
    param([string[]]$Tokens)

    if ($Tokens.Count -eq 0 -or $Tokens[0] -notmatch "(?i)^git(?:[.]exe)?$") {
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
            Error = ("unrecognized Git global option: " + $value)
        }
    }
    return [pscustomobject]@{ Subcommand = $null; Arguments = [string[]]@(); Error = "missing Git subcommand" }
}

function Test-DangerousCommand {
    param([string]$Command)
    if (-not $Command) { return $null }
    $statements = @(Get-CommandTokenStatements -Command $Command)
    $statementTexts = @($statements | ForEach-Object { @($_.Tokens) -join " " })
    $cmd = $statementTexts -join " ; "
    foreach ($statement in $statements) {
        $tokens = @($statement.Tokens)
        $wrapperFlagIndex = -1
        if ($tokens.Count -ge 3) {
            for ($candidateIndex = 1; $candidateIndex -lt $tokens.Count - 1; $candidateIndex++) {
                if (($tokens[0] -match "(?i)^cmd(?:[.]exe)?$" -and $tokens[$candidateIndex] -eq "/c") -or
                    ($tokens[0] -match "(?i)^(?:powershell|pwsh)(?:[.]exe)?$" -and $tokens[$candidateIndex] -match "(?i)^-(?:Command|c)$") -or
                    ($tokens[0] -match "(?i)^(?:ba|z|k)?sh(?:[.]exe)?$" -and $tokens[$candidateIndex] -eq "-c")) {
                    $wrapperFlagIndex = $candidateIndex
                    break
                }
            }
        }
        if ($wrapperFlagIndex -ge 0) {
            $nestedReason = Test-DangerousCommand -Command (($tokens[($wrapperFlagIndex + 1)..($tokens.Count - 1)]) -join " ")
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
                        $_ -match "(?i)^(?:--force|--force-with-lease|-f)$" -or $_.StartsWith("+")
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
            $tailTokens = @($tokens[$tokenIndex..($tokens.Count - 1)])
            if ($commandToken -match "(?i)^rm(?:[.]exe)?$") {
                $hasRecursive = @($tailTokens | Where-Object { $_ -match "(?i)^(?:--recursive|-[A-Za-z]*r[A-Za-z]*)$" }).Count -gt 0
                $hasForce = @($tailTokens | Where-Object { $_ -match "(?i)^(?:--force|-[A-Za-z]*f[A-Za-z]*)$" }).Count -gt 0
                if ($hasRecursive -and $hasForce) {
                    return "Blocked: recursive force delete requires explicit approval and verified target paths."
                }
            }
            if ($commandToken -match "(?i)^(?:Remove-Item|ri|del|erase)$" -and
                @($tailTokens | Where-Object { $_ -match "(?i)^-(?:Recurse|Rec|Re|R)$" }).Count -gt 0) {
                return "Blocked: recursive Remove-Item requires explicit approval and verified target paths."
            }
            if ($commandToken -match "(?i)^(?:rmdir|rd)$" -and
                @($tailTokens | Where-Object { $_ -match "(?i)^(?:/s|-Recurse|-r)$" }).Count -gt 0) {
                return "Blocked: recursive directory delete requires explicit approval and verified target paths."
            }
            if ($commandToken -match "(?i)^(?:del|erase)$" -and
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
