# Boring Is All You Need Lessons

These are title-level reminders for repeated, general failure modes. The
SessionStart Hook injects only the headings; open this file for details.

### PowerShell 7 encoding is part of correctness

PowerShell scripts must use strict UTF-8 without BOM and LF line endings.
Verify parsing and execution with the supported `pwsh` runtime.

### Shell Hook entrypoints require LF and no BOM

Git Hook shell entrypoints on Windows must retain LF line endings and must not
start with a UTF-8 BOM.

### Native command stderr is not a PowerShell object stream

Do not treat native stderr as a PowerShell object stream when output shape or
exit behavior matters. Capture stdout, stderr, and exit status deliberately.

### Fixture evidence is not Live host evidence

Repository and isolated fixture checks prove package behavior. They do not
prove that an already-running Codex Desktop process reloaded managed Hooks.

### Generated runtime identity must be bound to its source

Catalogs and other generated evidence must bind host, thread, source prompt,
and content digest. Caller-supplied identity cannot override source metadata.
