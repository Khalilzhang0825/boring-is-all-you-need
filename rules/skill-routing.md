# Skill Routing

Use a skill when the user names it or when a clearly matching specialist workflow materially improves correctness, safety, or quality. Tell the user why an unnamed specialist skill is being used.

Ordinary tasks do not search the entire installed skill inventory. Top-level orchestration, long-running automation, new specs, ticket systems, and workflow expansion require explicit user invocation; recommend them when useful, but do not start them automatically.

Runtime skill inventories are host- and session-specific. Never claim that scanning disk proves a skill is visible to the current Codex task.

When the user asks to find a skill, or a specialist skill is clearly needed, follow this installed chain:

1. From the current Codex task, run the following copyable prompt and search. The search rebuilds a missing snapshot only from that task's `CODEX_THREAD_ID` and rollout file; never replace it with a disk scan.

   ```powershell
   $SteadyAgentRoot = Join-Path $HOME ".steadyagent"
   $SkillSearch = Join-Path $SteadyAgentRoot "tools\skill-search.ps1"
   if (-not (Test-Path -LiteralPath $SkillSearch -PathType Leaf)) {
     throw "The installed Boring Is All You Need skill search is missing."
   }
   $SkillQuery = Read-Host "Describe the task or intent"
   if ([string]::IsNullOrWhiteSpace($SkillQuery)) { throw "A skill query is required." }
   & $SkillSearch -Query $SkillQuery
   if ($LASTEXITCODE -ne 0) { throw "Skill search failed closed." }
   ```
2. Use only a result from the verified `rollout-file-confirmed` catalog. Read the returned absolute `SKILL.md` path completely before acting, then follow its referenced instructions as needed.
3. If the task identity is missing, the catalog identity fails, or no result matches, say that no current-task-visible skill was proven. Do not silently use an unadvertised disk entry or install anything without explicit authorization.
