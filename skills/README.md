# Agent skills

[`gegenlesen`](gegenlesen/SKILL.md) teaches coding agents to run `gegenlesen review` on committed `HEAD` before push.

Symlink into the agent skill dirs you use:

```bash
root="$(cd "$(dirname "$0")" && pwd)"
for dest in "$HOME/.agents/skills" "$HOME/.grok/skills" "$HOME/.claude/skills"; do
  mkdir -p "$dest"
  ln -sfn "$root/gegenlesen" "$dest/gegenlesen"
done
```
