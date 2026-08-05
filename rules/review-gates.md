# Review Gates

Applies to: Codex Desktop only.

Use independent fresh-context review for material risk, not ceremony.

Review is required when the user explicitly requests it; when work affects authorization, credentials, payments, migrations, deletion, publishing, deployment, external writes, concurrency, data correctness, or safety hooks; or when the implementing agent identifies and explains a specific material risk.

File count alone is not a trigger. Low-risk mechanical, documentation, comment, formatting, and routine configuration changes use self-review plus relevant validation.

Reviewers are read-only by default, must not have implemented the candidate, and report findings first in severity order with location, impact, and a concrete fix. A required review cannot be replaced by implementer self-review. Resolve actionable findings and rerun affected checks before checkpointing.
