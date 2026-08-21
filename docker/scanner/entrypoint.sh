#!/bin/sh
set -eu
export PATH="/usr/local/bin:/usr/bin:/bin"
export HOME="/tmp"
exec python3 /usr/local/lib/gegenlesen/scan.py
