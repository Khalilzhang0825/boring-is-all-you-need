# SteadyAgent Lessons

These are title-level reminders for repeated, general failure modes. The
SessionStart Hook injects only the headings; open this file for details.

### PowerShell 5.1 encoding is part of correctness

PowerShell scripts containing non-ASCII text must use UTF-8 with BOM. Prefer
ASCII-only scripts where practical and verify parsing with Windows PowerShell.

### Shell Hook entrypoints require LF and no BOM

Git Hook shell entrypoints on Windows must retain LF line endings and must not
start with a UTF-8 BOM.

### Native command stderr is not a PowerShell object stream

Do not use `2>&1` with native commands in Windows PowerShell 5.1 when output
shape or exit behavior matters. Capture stdout, stderr, and exit status
deliberately.

### Fixture evidence is not Live host evidence

Repository and isolated fixture checks prove package behavior. They do not
prove that an already-running Codex Desktop process reloaded managed Hooks.

### Generated runtime identity must be bound to its source

Catalogs and other generated evidence must bind host, thread, source prompt,
and content digest. Caller-supplied identity cannot override source metadata.
