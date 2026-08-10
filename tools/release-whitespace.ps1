#requires -Version 7.5
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

if ($null -eq ("SteadyAgent.ReleaseWhitespaceProcess" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace SteadyAgent
{
    public sealed class ReleaseWhitespaceProcessResult
    {
        public string StdOut;
        public string StdErr;
        public int ExitCode;
        public bool StdOutTruncated;
        public bool StdErrTruncated;
        public bool TimedOut;
    }

    public static class ReleaseWhitespaceProcess
    {
        private sealed class Capture
        {
            public string Text;
            public bool Truncated;
        }

        private static Capture Drain(StreamReader reader, int limit)
        {
            StringBuilder kept = new StringBuilder(Math.Min(limit, 4096));
            char[] buffer = new char[4096];
            bool truncated = false;
            int read;
            while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
            {
                int remaining = limit - kept.Length;
                if (remaining > 0)
                {
                    int take = Math.Min(remaining, read);
                    kept.Append(buffer, 0, take);
                }
                if (read > remaining)
                {
                    truncated = true;
                }
            }
            return new Capture { Text = kept.ToString(), Truncated = truncated };
        }

        private static bool IsGitControlVariable(string name)
        {
            return name.StartsWith("GIT_", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("SSH_ASKPASS", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsAllowedGitControlVariable(string name)
        {
            return name.Equals("GIT_OPTIONAL_LOCKS", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("GIT_PAGER", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("GIT_TERMINAL_PROMPT", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("GIT_CONFIG_GLOBAL", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("GIT_CONFIG_NOSYSTEM", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("GIT_ATTR_NOSYSTEM", StringComparison.OrdinalIgnoreCase);
        }

        private static StringDictionary GetNormalizedEnvironment(ProcessStartInfo start)
        {
            StringDictionary childEnvironment = null;
            try
            {
                childEnvironment = start.EnvironmentVariables;
            }
            catch (ArgumentException)
            {
                childEnvironment = start.EnvironmentVariables;
            }
            if (childEnvironment == null)
            {
                childEnvironment = start.EnvironmentVariables;
            }
            if (childEnvironment == null)
            {
                throw new InvalidOperationException(
                    "Cannot initialize the Git child environment.");
            }

            childEnvironment.Clear();
            foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
            {
                string name = entry.Key as string;
                if (String.IsNullOrEmpty(name))
                {
                    continue;
                }
                childEnvironment[name] = entry.Value == null ? "" : entry.Value.ToString();
            }
            return childEnvironment;
        }

        public static ReleaseWhitespaceProcessResult Run(
            string fileName,
            string arguments,
            string workingDirectory,
            IDictionary<string, string> environmentOverrides,
            int stdoutLimit,
            int stderrLimit,
            int timeoutMilliseconds)
        {
            ProcessStartInfo start = new ProcessStartInfo();
            start.FileName = fileName;
            start.Arguments = arguments;
            start.WorkingDirectory = workingDirectory;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            start.StandardOutputEncoding = Encoding.UTF8;
            start.StandardErrorEncoding = Encoding.UTF8;

            StringDictionary childEnvironment = GetNormalizedEnvironment(start);
            List<string> inheritedGitControls = new List<string>();
            foreach (string name in childEnvironment.Keys)
            {
                if (IsGitControlVariable(name))
                {
                    inheritedGitControls.Add(name);
                }
            }
            foreach (string name in inheritedGitControls)
            {
                childEnvironment.Remove(name);
            }

            if (environmentOverrides != null)
            {
                foreach (KeyValuePair<string, string> pair in environmentOverrides)
                {
                    if (pair.Value == null ||
                        pair.Value == "__STEADYAGENT_REMOVE_ENV_7B9E__")
                    {
                        childEnvironment.Remove(pair.Key);
                    }
                    else
                    {
                        if (IsGitControlVariable(pair.Key) &&
                            !IsAllowedGitControlVariable(pair.Key))
                        {
                            throw new InvalidOperationException(
                                "Unsafe Git child environment override was rejected.");
                        }
                        childEnvironment[pair.Key] = pair.Value;
                    }
                }
            }
            childEnvironment["GIT_CONFIG_GLOBAL"] = "NUL";
            childEnvironment["GIT_CONFIG_NOSYSTEM"] = "1";
            childEnvironment["GIT_ATTR_NOSYSTEM"] = "1";

            using (Process process = new Process())
            {
                process.StartInfo = start;
                if (!process.Start())
                {
                    throw new InvalidOperationException("Git process did not start.");
                }

                Capture stdout = null;
                Capture stderr = null;
                Thread stdoutThread = new Thread(delegate()
                {
                    stdout = Drain(process.StandardOutput, stdoutLimit);
                });
                Thread stderrThread = new Thread(delegate()
                {
                    stderr = Drain(process.StandardError, stderrLimit);
                });
                stdoutThread.IsBackground = true;
                stderrThread.IsBackground = true;
                stdoutThread.Start();
                stderrThread.Start();

                bool timedOut = !process.WaitForExit(timeoutMilliseconds);
                if (timedOut)
                {
                    try { process.Kill(); }
                    catch { }
                    process.WaitForExit();
                }
                stdoutThread.Join();
                stderrThread.Join();

                return new ReleaseWhitespaceProcessResult
                {
                    StdOut = stdout == null ? "" : stdout.Text,
                    StdErr = stderr == null ? "" : stderr.Text,
                    ExitCode = timedOut ? 2 : process.ExitCode,
                    StdOutTruncated = stdout != null && stdout.Truncated,
                    StdErrTruncated = stderr != null && stderr.Truncated,
                    TimedOut = timedOut
                };
            }
        }
    }
}
'@ | Out-Null
}

function ConvertTo-ReleaseWhitespaceProcessArgument {
    param([AllowEmptyString()][string]$Argument)

    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object Text.StringBuilder
    $backslash = [char]92
    $quote = [char]34
    [void]$builder.Append($quote)
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq $backslash) {
            $backslashCount++
            continue
        }
        if ($character -eq $quote) {
            [void]$builder.Append($backslash, ($backslashCount * 2) + 1)
            [void]$builder.Append($quote)
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append($backslash, $backslashCount)
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append($backslash, $backslashCount * 2)
    }
    [void]$builder.Append($quote)
    return $builder.ToString()
}

function Get-ReleaseWhitespaceDiagnostic {
    param(
        [string]$Text,
        [string]$Repository
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    $safe = $Text
    $knownPaths = @(
        [pscustomobject]@{ Value = $Repository; Replacement = "<repo>" },
        [pscustomobject]@{ Value = [Environment]::GetFolderPath("UserProfile"); Replacement = "<user>" },
        [pscustomobject]@{ Value = [IO.Path]::GetTempPath(); Replacement = "<temp>" }
    )
    foreach ($knownPath in $knownPaths) {
        if ([string]::IsNullOrWhiteSpace([string]$knownPath.Value)) { continue }
        $safe = [regex]::Replace(
            $safe,
            [regex]::Escape(([string]$knownPath.Value).TrimEnd("\", "/")),
            [string]$knownPath.Replacement,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b([a-z][a-z0-9+.-]*://)(?:[^/@\s]+@)',
        '${1}<credentials>@'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b(token|password|secret|api[_-]?key)\s*[:=]\s*[^\s]+',
        '$1=<redacted>'
    )
    $safe = [regex]::Replace($safe, '(?i)\\\\[^\\\s]+\\[^\r\n"''<>|]*', "<unc>")
    $safe = [regex]::Replace($safe, '(?i)[A-Z]:[\\/][^\r\n"''<>|]*', "<path>")
    $safe = [regex]::Replace(
        $safe,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        "<email>"
    )
    $safe = [regex]::Replace($safe, '\s+', " ").Trim()
    if ($safe.Length -gt 240) {
        $safe = $safe.Substring(0, 237) + "..."
    }
    return $safe
}

function New-ReleaseWhitespaceGitEnvironment {
    param(
        [Collections.Generic.IDictionary[string, string]]$Overrides
    )
    $result = New-Object "Collections.Generic.Dictionary[string,string]" (
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @(
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR"
    )) {
        $result[$name] = "__STEADYAGENT_REMOVE_ENV_7B9E__"
    }
    $result["GIT_OPTIONAL_LOCKS"] = "0"
    $result["GIT_PAGER"] = "cat"
    $result["GIT_TERMINAL_PROMPT"] = "0"
    $result["LC_ALL"] = "C"
    $result["LANG"] = "C"
    if ($null -ne $Overrides) {
        foreach ($name in $Overrides.Keys) {
            $result[[string]$name] = $Overrides[$name]
        }
    }
    $result["GIT_CONFIG_GLOBAL"] = "NUL"
    $result["GIT_CONFIG_NOSYSTEM"] = "1"
    $result["GIT_ATTR_NOSYSTEM"] = "1"
    return $result
}

function Invoke-ReleaseWhitespaceGit {
    param(
        [string[]]$GitArgs,
        [string]$WorkingDirectory = (Get-Location).Path,
        [Collections.Generic.IDictionary[string, string]]$EnvironmentOverrides,

        [ValidateRange(1, 120000)]
        [int]$TimeoutMilliseconds = 120000
    )

    $output = [string[]]@()
    $rawOutput = ""
    $code = 2
    $errorText = ""
    $stdoutTruncated = $false
    $stderrTruncated = $false
    $timedOut = $false
    try {
        $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        if ($null -eq $gitCommand) { throw "Git executable was not found." }
        $effectiveGitArgs = @(
            "--no-pager",
            "-c",
            "core.fsmonitor="
        ) + @($GitArgs)
        $argumentText = @($effectiveGitArgs | ForEach-Object {
            ConvertTo-ReleaseWhitespaceProcessArgument -Argument ([string]$_)
        }) -join " "
        $childEnvironment = New-ReleaseWhitespaceGitEnvironment -Overrides $EnvironmentOverrides
        $processResult = [SteadyAgent.ReleaseWhitespaceProcess]::Run(
            [string]$gitCommand.Source,
            $argumentText,
            [IO.Path]::GetFullPath($WorkingDirectory),
            $childEnvironment,
            262144,
            4096,
            $TimeoutMilliseconds
        )
        $rawOutput = [string]$processResult.StdOut
        $code = [int]$processResult.ExitCode
        $stdoutTruncated = [bool]$processResult.StdOutTruncated
        $stderrTruncated = [bool]$processResult.StdErrTruncated
        $timedOut = [bool]$processResult.TimedOut

        $rawError = [string]$processResult.StdErr
        $rawError = [regex]::Replace(
            $rawError,
            '(?im)((?:unknown|unrecognized)\s+(?:option|switch)[^:\r\n]*:\s*).+$',
            '${1}<arg>'
        )
        foreach ($argument in @(
            $effectiveGitArgs | Sort-Object { ([string]$_).Length } -Descending
        )) {
            $argumentTextValue = [string]$argument
            if ([string]::IsNullOrEmpty($argumentTextValue)) { continue }
            $rawError = [regex]::Replace(
                $rawError,
                [regex]::Escape($argumentTextValue),
                "<arg>",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
        $errorText = Get-ReleaseWhitespaceDiagnostic `
            -Text $rawError -Repository ([IO.Path]::GetFullPath($WorkingDirectory))

        if ($stdoutTruncated -or $stderrTruncated -or $timedOut) {
            $code = 2
            $captureReason = if ($timedOut) {
                "Git process timed out."
            }
            elseif ($stdoutTruncated) {
                "Git stdout exceeded the bounded capture limit."
            }
            else {
                "Git stderr exceeded the bounded capture limit."
            }
            $errorText = ($captureReason + $(if ($errorText) { " " + $errorText } else { "" }))
            if ($errorText.Length -gt 240) {
                $errorText = $errorText.Substring(0, 237) + "..."
            }
        }

        $trimmedOutput = $rawOutput.TrimEnd([char]13, [char]10)
        $output = if ($trimmedOutput.Length -gt 0) {
            [string[]]@($trimmedOutput -split "`r?`n")
        }
        else {
            [string[]]@()
        }
    }
    catch {
        $code = 2
        $errorText = Get-ReleaseWhitespaceDiagnostic `
            -Text $_.Exception.Message -Repository ([IO.Path]::GetFullPath($WorkingDirectory))
    }
    return [pscustomobject]@{
        Output = [string[]]$output
        RawOutput = $rawOutput
        Code = $code
        Error = $errorText
        StdOutTruncated = $stdoutTruncated
        StdErrTruncated = $stderrTruncated
        TimedOut = $timedOut
    }
}

function Get-ReleaseWhitespaceFailureOutput {
    param(
        [string]$Message,
        [object]$GitResult
    )
    if ($GitResult.Error) { return $Message + " git: " + [string]$GitResult.Error }
    return $Message + " git: no diagnostic output."
}

function Get-ReleaseWhitespaceCheckSummaries {
    param(
        [string]$RawOutput,
        [string]$Repository
    )
    $summaries = New-Object Collections.Generic.List[string]
    foreach ($line in @($RawOutput -split "`r?`n")) {
        if ($line -notmatch '^(.+):(\d+):\s+(trailing whitespace[.]|space before tab in indent[.]|new blank line at EOF[.])$') {
            continue
        }
        $pathText = Get-ReleaseWhitespaceDiagnostic -Text $Matches[1] -Repository $Repository
        $reasonText = Get-ReleaseWhitespaceDiagnostic -Text $Matches[3] -Repository $Repository
        $summary = "{0}:{1}: {2}" -f $pathText, $Matches[2], $reasonText
        if ($summary.Length -gt 400) {
            $summary = $summary.Substring(0, 397) + "..."
        }
        $summaries.Add($summary) | Out-Null
        if ($summaries.Count -ge 50) { break }
    }
    return $summaries.ToArray()
}

function Get-ReleaseWhitespaceCheckOutput {
    param(
        [object]$GitResult,
        [string]$Repository
    )
    $parts = New-Object Collections.Generic.List[string]
    foreach ($summary in @(Get-ReleaseWhitespaceCheckSummaries `
        -RawOutput ([string]$GitResult.RawOutput) -Repository $Repository)) {
        $parts.Add([string]$summary) | Out-Null
    }
    if ($GitResult.Error -and $GitResult.Code -ne 0) {
        $parts.Add("git: " + [string]$GitResult.Error) | Out-Null
    }
    return $parts.ToArray() -join "`n"
}

function New-ReleaseWhitespaceResult {
    param(
        [string]$BaseRef,
        [string]$BaseCommit,
        [string]$MergeBase,
        [string]$Mode,
        [int]$Code,
        [string]$Output
    )
    return [pscustomobject]@{
        BaseRef = $BaseRef
        BaseCommit = $BaseCommit
        MergeBase = $MergeBase
        Mode = $Mode
        Code = $Code
        Output = $Output
    }
}

function Get-ReleaseWhitespaceRemainingMilliseconds {
    param(
        [Diagnostics.Stopwatch]$Stopwatch,
        [int]$DeadlineMilliseconds
    )
    $remaining = [long]$DeadlineMilliseconds - [long]$Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) { return 0 }
    return [int]$remaining
}

function Test-ReleaseWhitespace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$BaseRef,

        [switch]$AllowDirty,

        [ValidateRange(1, 256)]
        [int]$UntrackedFileLimit = 256,

        [ValidateRange(1, 60000)]
        [int]$UntrackedDeadlineMilliseconds = 60000
    )

    $mode = if ($AllowDirty) { "wip" } else { "clean" }
    $baseCommit = ""
    $mergeBase = ""
    try {
        $repositoryFull = [IO.Path]::GetFullPath($Repository)
    }
    catch {
        return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit "" -MergeBase "" `
            -Mode $mode -Code 2 -Output "Repository path is invalid."
    }
    if (-not (Test-Path -LiteralPath $repositoryFull -PathType Container)) {
        return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit "" -MergeBase "" `
            -Mode $mode -Code 2 -Output "Repository path does not exist."
    }

    try {
        $baseResult = Invoke-ReleaseWhitespaceGit `
            -GitArgs @("rev-parse", "--verify", ($BaseRef + "^{commit}")) `
            -WorkingDirectory $repositoryFull
        if ($baseResult.Code -ne 0 -or @($baseResult.Output).Count -eq 0) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit "" -MergeBase "" `
                -Mode $mode -Code 2 -Output (
                    Get-ReleaseWhitespaceFailureOutput `
                        -Message "Release base does not resolve." -GitResult $baseResult
                )
        }
        $baseCommit = ([string]$baseResult.Output[0]).Trim()

        $mergeResult = Invoke-ReleaseWhitespaceGit `
            -GitArgs @("merge-base", $baseCommit, "HEAD") `
            -WorkingDirectory $repositoryFull
        if ($mergeResult.Code -ne 0 -or @($mergeResult.Output).Count -eq 0) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit -MergeBase "" `
                -Mode $mode -Code 2 -Output (
                    Get-ReleaseWhitespaceFailureOutput `
                        -Message "Release base has no merge-base with HEAD." -GitResult $mergeResult
                )
        }
        $mergeBase = ([string]$mergeResult.Output[0]).Trim()

        if (-not $AllowDirty) {
            $diffResult = Invoke-ReleaseWhitespaceGit `
                -GitArgs @(
                    "-c", "core.whitespace=blank-at-eol,blank-at-eof,space-before-tab",
                    "-c", "core.attributesFile=NUL",
                    "diff", "--no-ext-diff", "--no-textconv", "--check",
                    ($mergeBase + "...HEAD"), "--"
                ) `
                -WorkingDirectory $repositoryFull
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "clean" -Code $diffResult.Code `
                -Output (Get-ReleaseWhitespaceCheckOutput `
                    -GitResult $diffResult -Repository $repositoryFull)
        }

        # A commit-versus-worktree diff represents the final tracked state,
        # including committed, staged, unstaged, and deleted paths, without
        # creating an alternate index or writing candidate blobs.
        $trackedResult = Invoke-ReleaseWhitespaceGit `
            -GitArgs @(
                "-c", "core.whitespace=blank-at-eol,blank-at-eof,space-before-tab",
                "-c", "core.attributesFile=NUL",
                "diff", "--no-ext-diff", "--no-textconv", "--check", $mergeBase, "--"
            ) `
            -WorkingDirectory $repositoryFull
        if ($trackedResult.Code -ne 0) {
            $trackedSummaries = @(Get-ReleaseWhitespaceCheckSummaries `
                -RawOutput ([string]$trackedResult.RawOutput) -Repository $repositoryFull)
            $trackedOutput = Get-ReleaseWhitespaceCheckOutput `
                -GitResult $trackedResult -Repository $repositoryFull
            if ($trackedSummaries.Count -gt 0) {
                return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                    -MergeBase $mergeBase -Mode "wip" -Code 1 -Output $trackedOutput
            }
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "wip" -Code 2 -Output (
                    Get-ReleaseWhitespaceFailureOutput `
                        -Message "Cannot inspect the final tracked worktree." `
                        -GitResult $trackedResult
                )
        }

        $untrackedStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $untrackedDeadlineOutput = (
            "Untracked release file inspection exceeded the total time limit of {0} ms." -f
            $UntrackedDeadlineMilliseconds
        )
        $remainingMilliseconds = Get-ReleaseWhitespaceRemainingMilliseconds `
            -Stopwatch $untrackedStopwatch `
            -DeadlineMilliseconds $UntrackedDeadlineMilliseconds
        if ($remainingMilliseconds -le 0) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "wip" -Code 2 -Output $untrackedDeadlineOutput
        }
        $untrackedListResult = Invoke-ReleaseWhitespaceGit `
            -GitArgs @(
                "-c", "core.excludesFile=NUL",
                "ls-files", "--others", "--exclude-standard", "-z", "--"
            ) `
            -WorkingDirectory $repositoryFull `
            -TimeoutMilliseconds $remainingMilliseconds
        if ($untrackedListResult.TimedOut -or
            $untrackedStopwatch.ElapsedMilliseconds -ge $UntrackedDeadlineMilliseconds) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "wip" -Code 2 -Output $untrackedDeadlineOutput
        }
        if ($untrackedListResult.Code -ne 0) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "wip" -Code 2 -Output (
                    Get-ReleaseWhitespaceFailureOutput `
                        -Message "Cannot enumerate untracked release files." `
                        -GitResult $untrackedListResult
                )
        }

        $untrackedPaths = New-Object Collections.Generic.List[string]
        foreach ($relativePath in @(([string]$untrackedListResult.RawOutput) -split ([char]0))) {
            if ([string]::IsNullOrEmpty($relativePath)) { continue }
            if ([IO.Path]::IsPathRooted($relativePath) -or
                $relativePath -match '(^|[\\/])[.][.]([\\/]|$)') {
                return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                    -MergeBase $mergeBase -Mode "wip" -Code 2 `
                    -Output "Untracked path escaped the repository boundary."
            }
            $untrackedPaths.Add([string]$relativePath) | Out-Null
            if ($untrackedPaths.Count -gt $UntrackedFileLimit) {
                return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                    -MergeBase $mergeBase -Mode "wip" -Code 2 `
                    -Output (
                        "Untracked release file count exceeds the safe limit of {0}." -f
                        $UntrackedFileLimit
                    )
            }
        }

        $untrackedWhitespace = New-Object Collections.Generic.List[string]
        foreach ($relativePath in $untrackedPaths) {
            $remainingMilliseconds = Get-ReleaseWhitespaceRemainingMilliseconds `
                -Stopwatch $untrackedStopwatch `
                -DeadlineMilliseconds $UntrackedDeadlineMilliseconds
            if ($remainingMilliseconds -le 0) {
                return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                    -MergeBase $mergeBase -Mode "wip" -Code 2 -Output $untrackedDeadlineOutput
            }
            # On Windows, NUL is an empty source. --no-index reads the
            # untracked file without adding it to an object database.
            $untrackedResult = Invoke-ReleaseWhitespaceGit `
                -GitArgs @(
                    "-c", "core.autocrlf=false",
                    "-c", "core.whitespace=blank-at-eol,blank-at-eof,space-before-tab",
                    "-c", "core.attributesFile=NUL",
                    "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--check", "--",
                    "NUL", $relativePath
                ) `
                -WorkingDirectory $repositoryFull `
                -TimeoutMilliseconds $remainingMilliseconds
            if ($untrackedResult.TimedOut -or
                $untrackedStopwatch.ElapsedMilliseconds -ge $UntrackedDeadlineMilliseconds) {
                return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                    -MergeBase $mergeBase -Mode "wip" -Code 2 -Output $untrackedDeadlineOutput
            }
            $summaries = @(Get-ReleaseWhitespaceCheckSummaries `
                -RawOutput ([string]$untrackedResult.RawOutput) -Repository $repositoryFull)
            if ($summaries.Count -gt 0) {
                foreach ($summary in $summaries) {
                    if ($untrackedWhitespace.Count -lt 50) {
                        $untrackedWhitespace.Add([string]$summary) | Out-Null
                    }
                }
                continue
            }
            # no-index returns 1 for an ordinary clean difference. Every other
            # nonzero result without a whitespace summary is an operational error.
            if ($untrackedResult.Code -ne 0 -and $untrackedResult.Code -ne 1) {
                return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                    -MergeBase $mergeBase -Mode "wip" -Code 2 -Output (
                        Get-ReleaseWhitespaceFailureOutput `
                            -Message "Cannot inspect an untracked release file." `
                            -GitResult $untrackedResult
                    )
            }
        }

        if ($untrackedStopwatch.ElapsedMilliseconds -ge $UntrackedDeadlineMilliseconds) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "wip" -Code 2 -Output $untrackedDeadlineOutput
        }
        if ($untrackedWhitespace.Count -gt 0) {
            return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
                -MergeBase $mergeBase -Mode "wip" -Code 1 `
                -Output ($untrackedWhitespace.ToArray() -join "`n")
        }
        return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
            -MergeBase $mergeBase -Mode "wip" -Code 0 -Output ""
    }
    catch {
        $diagnostic = Get-ReleaseWhitespaceDiagnostic `
            -Text $_.Exception.Message -Repository $repositoryFull
        return New-ReleaseWhitespaceResult -BaseRef $BaseRef -BaseCommit $baseCommit `
            -MergeBase $mergeBase -Mode $mode -Code 2 `
            -Output ("Whitespace check failed closed." + $(if ($diagnostic) {
                " git: " + $diagnostic
            } else { "" }))
    }
}
