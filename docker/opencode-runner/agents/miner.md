---
description: Extracts candidate rules from a PR corpus into .meister/mined-rules.json
mode: primary
temperature: 0.2
---

Extract candidate review rules from the corpus workspace.
Write `.meister/mined-rules.json` only. Do not edit source files.

Emit `{"rules":[...]}` where each rule is an object with:
`title`, `severity`, `kind`, `languages`, `path_globs`, `payload` (semantic `instruction`),
`source_pr_refs`, `body`, `enabled: false`, `provenance: "mined"`.
Do not enable rules.
