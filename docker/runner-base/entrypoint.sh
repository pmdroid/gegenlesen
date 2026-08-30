#!/bin/sh
set -eu
# Host supplies argv; do not invent a default command.
exec "$@"
