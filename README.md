<p align="center">
  <img src="docs/assets/logo.png" alt="gegenlesen" width="420" />
</p>

# gegenlesen

Single-tenant PR review on your machine. The **CLI** starts a review (`gegenlesen review`). **Ledger** is management only: jobs, findings + 👍/👎, rules, context, learnings. Two models read the change. A judge keeps only what the lines support.

No login. Bind `127.0.0.1`. One agent job at a time.

**Site + docs:** [gegenlesen.dev](https://gegenlesen.dev)

## Run

Linux, host network, Docker socket. Full copy: [Start](https://gegenlesen.dev/docs/start).

```bash
DATA="$HOME/gegenlesen-data"
mkdir -p "$DATA" "$HOME/gegenlesen-config"
docker pull ghcr.io/pmdroid/gegenlesen:main
docker pull ghcr.io/pmdroid/gegenlesen:runner-main
docker run --rm --init --name gegenlesen \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$DATA:$DATA" \
  -v "$HOME/gegenlesen-config:/app/config" \
  -e GEGENLESEN_DATA_DIR="$DATA" \
  -e GEGENLESEN_OPENCODE_IMAGE=ghcr.io/pmdroid/gegenlesen:runner-main \
  ghcr.io/pmdroid/gegenlesen:main
```

Open `http://127.0.0.1:8080`. Ledger **setup** writes the OpenRouter key. From a repo: `gegenlesen review`.

Agents: symlink [`skills/gegenlesen`](skills/gegenlesen/SKILL.md) into `~/.agents/skills`, `~/.grok/skills`, or `~/.claude/skills` so they self-review committed `HEAD` before push.

On a Mac, Docker Desktop does not share loopback this way. From source: `scripts/build-runner.sh` then `make run` (Xcode’s Swift, not `/usr/bin/swift`).

CI builds `ghcr.io/pmdroid/gegenlesen` (`:main`, semver) and the runner as `:runner-main` / `:runner-0.1.0` on the same package.

macOS binaries are not built in CI. On a Mac with a Developer ID (and a notary profile):

```bash
xcrun notarytool store-credentials gegenlesen-notarize \
  --apple-id <apple-id> --team-id W363QN58YY   # once
./scripts/release-darwin.sh v0.1.1 --upload
```

That writes signed, notarized `dist/gegenlesen-v0.1.1-darwin-arm64.tar.gz` (and `darwin-x64`). Unpack and run `GegenlesenAPI serve` from that directory so Ledger, rules, and schemas sit next to the binaries.

## Pipeline

```
gegenlesen review  (CLI packs cwd, POST /api/jobs)
  → unpack (libarchive, not tar -xf)
  → identify git range
  → load matching enabled rules
  → deterministic checks on the host
  → OpenCode reviewers A and B in parallel
  → judge keep / drop / downgrade
  → persist findings
```

Cheap checks run first. Both reviewers always run when there is new work. The judge defaults to keep. The host still drops a finding when the cited lines do not support it. Nothing auto-enables.

## Review scopes

| Scope | What you upload | What gets reviewed |
| --- | --- | --- |
| **Full change** | Tarball from `scripts/pack-repo.sh` | The whole identified diff |
| **Incremental** | New tarball + `parent_job_id` of a succeeded job | New hunks only |

## Rules

Handwritten in Ledger, or mined and left disabled until you promote them. Deterministic (regex, deny-list, sibling tests, sandbox `command`, OpenAPI break) or semantic (natural language for both reviewers).

## Security

- Bind `127.0.0.1`. A non-loopback bind refuses to start unless `GEGENLESEN_ALLOW_REMOTE=1`.
- Agent `edit` is an allowlist of `.gegenlesen` contract files. `task` is denied.
- Uploaded `opencode.json` / `.opencode/` are renamed off the load path.
- Command checkers do not inherit API keys. They run `--network none`.
- The API Docker image mounts the host Docker socket. Treat that host as single-tenant.

## License

MIT. See [LICENSE](LICENSE).
