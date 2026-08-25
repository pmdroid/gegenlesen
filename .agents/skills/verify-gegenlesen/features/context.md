# Context

Context notes are house text the reviewers may receive. Ledger lists them and offers a create/edit form on the same page. Nothing auto-applies from learnings.

## Sub-features

- `context-empty` shows the empty copy when there are no notes.
- `context-create` saves a titled note.
- `context-edit` updates an existing note and can cancel an unfinished edit.
- `context-delete` removes a note.

## How to get to it (user POV)

- Nav `context`, or open `/context`.
- Fill `new note` at the bottom of the page. Click `edit` on a row to reuse that form.

## Driving it with drive.sh

Preconditions:

- Default launch. Doctor is `ok`.
- No note titled `verify context probe`.

- **Empty.** Open context. Run `.agents/skills/verify-gegenlesen/drive.sh shot /context --label context-empty`. Copy includes `No notes yet.` Heading `new note` is present.
- **Create.** Run `.agents/skills/verify-gegenlesen/drive.sh context-create --title "verify context probe" --body "Always use the project logger."` The page shows a row titled `verify context probe`. Artifacts `context-before`, `context-form`, `context-after`.
- **Confirm persistence.** Run `.agents/skills/verify-gegenlesen/drive.sh api GET /api/context --label context-after`. JSON `notes[]` contains that title and body. Reload `/context` and the row is still there.
- **Edit.** Click `edit` on that row. Heading becomes `edit note`. Change the body. Click `save`. GET `/api/context` shows the new body.
- **Cancel edit.** Click `edit`, change the title to `discard me`, click `cancel`. Heading returns to `new note`. No note titled `discard me`.
- **Delete.** Click `delete` on `verify context probe`. Empty copy returns (if it was the only note). GET `/api/context` has no such title.
- **Proof.** Create form + after screenshot, plus `context-after.json`. Reload or GET is required.

## Gotchas

- Title and body are both required. Submit with one blank shows `title and body are required` and does not POST.
- `cancel` only resets the form. It does not delete an already-saved note.
- `always include in review context` is a checkbox in the form. Default off.
- Blank repository means global. Do not invent a repo name for the probe.
