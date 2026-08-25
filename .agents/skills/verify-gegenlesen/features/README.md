# gegenlesen verification map

This directory is the maintained source for verifying user-facing gegenlesen behavior. Read the index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch with `VERIFY_RUN` set and `.agents/skills/verify-gegenlesen/drive.sh launch`.
- `drive.sh doctor` reports `ok: true`, loopback bind, Ledger at `GET /`, and a data dir under this run's cache.
- Default launch is skip-agent with a dummy OpenRouter key. `/setup` is reachable but not a redirect gate.
- Never drive `make run`, Vite on 5173, or whatever is bound to 8080.
- Seeded rules `openapi-breaking-changes` and `use-project-logger` exist after boot. Leave them enabled.

## Driving conventions

- Start every recipe from the baseline unless its preconditions say otherwise.
- Prefer ARIA roles, accessible names, and wrapping labels over CSS or DOM position.
- Treat every command as literal.
- Browser actions go through `drive.sh shot`, `drive.sh rules-create`, `drive.sh context-create`, or the job/learning helpers.
- CLI actions go through `drive.sh cli-review`, `drive.sh harvest`, or `.build/debug/gegenlesen` with `GEGENLESEN_URL` set to the instance `baseUrl`.
- Restore seeded data after a mutation. Do not remove proof artifacts during cleanup.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes an ARIA snapshot and a screenshot with the `gegenlesen` brand and `api 127.0.0.1:` status visible.
- CLI proof includes the command, stdout, stderr, and exit code.
- Mutation proof includes a second read (API GET or navigate away and back).
- Record the feature id and entry point with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.
- A skip-agent job is not a full A/B review. Say so in the proof.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with drive.sh` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Jobs](./jobs.md) covers the jobs list, filters, empty state, and job detail after a review.
- [Rules](./rules.md) covers list, create semantic / weight rules, enable/disable, and delete.
- [Context](./context.md) covers house notes create, edit, cancel, and delete.
- [Setup](./setup.md) covers the first-run key gate and saving models.
- [CLI review](./cli-review.md) covers `gegenlesen review` and the job it creates in Ledger.
- [Learnings loop](./learnings.md) covers harvest, thumbs, merge-intent, Learn, suppress on job 2, and `→ rule` promote.
