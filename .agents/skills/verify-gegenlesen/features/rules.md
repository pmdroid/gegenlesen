# Rules

Rules are handwritten or mined checks Ledger applies to a review. The list shows title, kind, payload, scope, globs, enabled, and provenance. The editor creates semantic guidance or auto-approve weights. Nothing auto-enables mined rules.

## Sub-features

- `rules-list` shows seeded rules after boot.
- `rules-create-semantic` creates a handwritten semantic rule from `/rules/new`.
- `rules-create-weight` creates an auto-approve weight from `/rules/new?type=weight`.
- `rules-toggle` enables or disables one row.
- `rules-delete` removes a handwritten probe rule.

## How to get to it (user POV)

- Nav `rules`, or open `/rules`.
- Link `new semantic rule` → `/rules/new`.
- Link `new auto-approve weight` → `/rules/new?type=weight`.
- Click a rule title to open `/rules/<id>`.

## Driving it with drive.sh

Preconditions:

- Default launch. Doctor is `ok`.
- Seeded rules `openapi-breaking-changes` and `use-project-logger` are present. Do not delete them.
- No rule titled `verify skill probe`.

- **List.** Open rules. Run `.agents/skills/verify-gegenlesen/drive.sh shot /rules --label rules-list`. The list includes `OpenAPI / Swagger breaking changes` and `Use the project logger, not print / NSLog`. Each row has `disable` or `enable`.
- **Create semantic.** Run `.agents/skills/verify-gegenlesen/drive.sh rules-create --title "verify skill probe" --instruction "Flag print() in production Swift."` Landed URL is `/rules/verify-skill-probe`. Heading is the id `verify-skill-probe`. Artifacts `rules-before`, `rules-create-form`, `rules-after` exist.
- **Confirm persistence.** Run `.agents/skills/verify-gegenlesen/drive.sh api GET /api/rules --label rules-persisted`. The JSON includes `"title": "verify skill probe"`, `"provenance": "handwritten"`, `"kind": "semantic"`, and payload.instruction matching the typed text. Navigate to `/rules` and confirm the title link is there.
- **Disable.** On the list, click `disable` on `verify skill probe`. The button becomes `enable`. GET `/api/rules/verify-skill-probe` has `"enabled": false`.
- **Weight rule.** Open `/rules/new?type=weight`. Heading is `new auto-approve weight`. Title `verify weight probe`, leave veto unchecked, weight `-1`, match `all files`. Click `create`. GET the new rule and assert `payload.checker` is `risk_weight`.
- **Delete probe.** On `/rules/verify-skill-probe` click `delete`. List no longer has `verify skill probe`. GET `/api/rules/verify-skill-probe` is 404. Leave seeded rules in place.
- **Proof.** Screenshots of list, the filled create form, and the editor after create, plus `rules-persisted.json`. A create-form shot alone is not persistence. Do not reuse the `rules-after` label for the GET. That would overwrite the editor metadata.

## Gotchas

- Rule id is kebab-case of the title. `verify skill probe` → `verify-skill-probe`. A deleted row still occupies that id, so a second create becomes `verify-skill-probe-2`. Assert the landed path, not a guessed id.
- Semantic create requires title and instruction. Weight create requires title only.
- `disable` / `enable` is on the list row, not the editor. Editor has `save`, `delete`, and `promote` (mined/suggested only).
- `select <title>` checkboxes are for bulk delete. Do not bulk-delete the seed rules.
- Embeddings on create talk to OpenAI when a real key exists. Dummy-key launch still inserts the row even if embedding fails. Persistence proof is GET `/api/rules`, not an embedding call.
