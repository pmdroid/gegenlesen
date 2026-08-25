# Agents

Agents is Ledger for the five OpenCode prompts (reviewer, judge, miner, harvester, suggestion-judge). The page loads the shipped defaults. Save writes an override. Reset restores the packaged file. Improve sends the current prompt plus an instruction to the miner model over OpenRouter and puts the rewrite in the editor without saving.

## Sub-features

- `agents-list` shows nav `agents`, heading `agents`, and the five agent tabs with the reviewer prompt prefilled.
- `agents-switch` opens judge and shows its packaged prompt, not the reviewer text.
- `agents-save` persists a prompt override. Reload still shows it and `custom`.
- `agents-reset` restores the packaged default and drops `custom`.
- `agents-improve-skip` on skip-agent shows `prompt improve is disabled in skip-agent` and does not save.

## How to get to it (user POV)

- Nav `agents`, or open `/agents`.
- Agent tabs on the left. Prompt and improve form on the right.

## Driving it with drive.sh

Preconditions:

- Default `drive.sh launch` (dummy key, skip-agent). Doctor `ok: true`. `/agents` is not a setup redirect.
- Do not point this recipe at `config/gegenlesen.json`. Overrides live under the run data dir.
- Improve against a live miner needs `--with-agent` and a real OpenRouter key. That is not this recipe.

- **List.** Run `.agents/skills/verify-gegenlesen/drive.sh shot /agents --label agents-list`. Heading is `agents`. Tabs include `reviewer`, `judge`, `miner`, `harvester`, `suggestion-judge`. Prompt label is filled. Status is `default`.
- **Switch.** Click tab `judge`. Prompt contains `judge.json`. Status stays `default`.
- **Save.** Run `.agents/skills/verify-gegenlesen/drive.sh agents-save --id reviewer --text "verify agent override"`. Artifacts `agents-before`, `agents-edit`, `agents-after`. Copy `saved` is visible. Status is `custom`. `GET /api/agents/reviewer` has `"customized": true` and the extra text.
- **Reload.** Run `.agents/skills/verify-gegenlesen/drive.sh shot /agents --label agents-reloaded`. Reviewer prompt still contains `verify agent override`. Badge `custom`.
- **Reset.** Run `.agents/skills/verify-gegenlesen/drive.sh agents-reset --id reviewer`. Copy `restored default`. `GET /api/agents/reviewer` has `"customized": false` and no `verify agent override`.
- **Improve on skip-agent.** Run `.agents/skills/verify-gegenlesen/drive.sh agents-improve --id miner --instruction "be shorter"`. Error copy is `prompt improve is disabled in skip-agent`. Prompt is unchanged. No `saved`.
- **Proof.** `agents-list` plus `agents-after` plus GET after save and after reset. A screenshot of the empty default page is not a save proof.

## Gotchas

- Improve does not persist. After a live improve the editor is unsaved until `save`.
- Skip-agent never calls OpenRouter. Dummy keys cannot prove a real rewrite.
- `GEGENLESEN_SKIP_AGENT=1` is the default launch. Do not call that path a miner rewrite.
- Saving an agent does not rebuild the runner image. The host overlays `dataDir/agents/<id>.md` onto the materialized runner tree for the next job.
- Tab accessible names grow a `· edited` suffix when the draft differs from the saved prompt. Match on the id prefix.
- The prompt field is the textbox named `prompt` (exact). `getByLabel("prompt")` also hits `how should this prompt change`.
