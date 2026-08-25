# Setup

Setup is Ledger first-run. Without an OpenRouter key the app redirects every route to `/setup`. Saving a key and four model slots writes isolated config and continues to jobs. Later visits show `models and key` instead of `set up gegenlesen`.

## Sub-features

- `setup-gate` redirects `/`, `/rules`, and `/jobs/:id` to `/setup` when no key is configured.
- `setup-first-run` shows heading `set up gegenlesen` and requires a key.
- `setup-save` persists models and a key, then lands on `/`.
- `setup-revisit` shows heading `models and key` and lets the key field stay blank.

## How to get to it (user POV)

- Launch with `--no-key`, then open any Ledger URL.
- Nav `setup`, or open `/setup`, on a configured instance.

## Driving it with drive.sh

Preconditions:

- For the gate and first-run, launch with `--no-key`. `OPENROUTER_API_KEY` must not leak in from the shell.
- Doctor still requires health and Ledger HTML. `openrouterConfigured` is false.
- Do not save a real key into the isolated config unless the operator asked. A dummy key is enough to leave the gate. Skip-agent does not call OpenRouter to verify it.

- **Gate.** Launch `--no-key`. Run `.agents/skills/verify-gegenlesen/drive.sh shot / --label setup-gate`. Landed path is `/setup`. Heading is `set up gegenlesen`. Reviewer pickers are disabled (`add a key first`).
- **Gate from another route.** Run `.agents/skills/verify-gegenlesen/drive.sh shot /rules --label setup-gate-rules`. Still `/setup`, not the rules list.
- **Required key.** On first run, click `save and continue` with the key blank. Error copy is `OpenRouter API key is required`. Settings PUT is not sent.
- **Save dummy key.** Fill `OpenRouter API key` with `sk-or-verify-not-a-real-key`. Pick remains on the default model ids already in the fields. Click `save and continue`. Land on `/`. GET `/api/settings` has `"openrouter_configured": true`. `GET /api/settings` body must not contain `openrouter_api_key` or `sk-or-`.
- **Revisit.** Open `/setup` on the default (keyed) launch. Heading is `models and key`. Submit button is `save`. Key placeholder is `leave blank to keep the current key`.
- **Proof.** `setup-gate` screenshot plus settings JSON after save. A save that never leaves `/setup` is not configured.

## Gotchas

- Default `drive.sh launch` plants a dummy key. That launch cannot prove the gate. Use `--no-key`.
- A real `OPENROUTER_API_KEY` in the process environment counts as configured even with `--no-key`. Doctor `openrouterConfigured` tells you.
- Catalog fetch (`loading OpenRouter models…`) needs a live key. Dummy key shows a catalog error. That error is not a failed save if you still land on `/`.
- PUT `/api/settings` writes `GEGENLESEN_CONFIG`. Isolated launch keeps that file under the run cache. Never point this recipe at `config/gegenlesen.json`.
- Appetite chips `4` and `5` show `most jobs will auto-approve at this level`. Do not change appetite unless that is the claim.
