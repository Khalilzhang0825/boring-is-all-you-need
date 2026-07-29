# Safety Boundaries

Never run destructive Git or broad deletion commands by default. Never overwrite unrelated user work or write secrets, credentials, private keys, connection strings, or sensitive vulnerability details.

Explicit authorization is required before push, publish, deploy, dependency installation, migration, bulk rename/delete, or external writes. Resolve exact targets with read-only checks first.

Codex managed guards block common dangerous command and secret-file edits before execution. Guard logs contain only timestamp, fixed reason, normalized tool name, and input SHA-256—never raw commands, patches, file content, or complete target paths.

The command guard is a deterministic mistake-prevention layer, not an adversarial sandbox. The pre-commit and explicit-file checkpoint gates remain required. Unknown matched payloads and unknown nested parallel wrappers fail closed.
