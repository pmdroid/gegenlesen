#!/bin/sh
set -eu
mkdir -p /home/gegenlesen/.claude/debug 2>/dev/null || true
# Host supplies argv; do not invent a default command.
exec "$@"
