#!/usr/bin/env bash
#
# run.sh - Scan usage data, start the dashboard server, and open it in your browser.
#
# Usage:
#   ./run.sh                 # default host/port (localhost:8080)
#   ./run.sh --port 8090     # custom port
#   PORT=8090 ./run.sh       # custom port via env var
#
set -euo pipefail

# Run from the directory this script lives in, so relative paths work
# regardless of where you invoke it from.
cd "$(dirname "$0")"

# Prefer python3, fall back to python.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1; then
  PY=python
else
  echo "Error: Python 3 is required but neither 'python3' nor 'python' was found." >&2
  exit 1
fi

# Launch the dashboard. cli.py scans first, starts the HTTP server, and opens
# the browser automatically. Any extra args (--host/--port/--projects-dir/...)
# are passed straight through.
exec "$PY" cli.py dashboard "$@"
