#!/bin/bash
# Removes Floatask.
#
#   curl -fsSL https://raw.githubusercontent.com/shihab-abir/Floatask/main/uninstall.sh | bash
#
# Your tasks and focus history in the vault's "Task Manager" folder are NEVER touched.
# Pass --purge (`... | bash -s -- --purge`) to also remove local settings, logs and the saved API key.
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

if pgrep -xq Floatask; then
  "$HOME/.local/bin/floatask" quit >/dev/null 2>&1 || true
  sleep 1
  pkill -x Floatask 2>/dev/null || true
fi

rm -rf "$HOME/Applications/Floatask.app"
[[ -L "$HOME/.local/bin/floatask" ]] && rm "$HOME/.local/bin/floatask"
echo "✓ Removed Floatask.app and the floatask command"

if (( PURGE )); then
  rm -rf "$HOME/Library/Application Support/Floatask" "$HOME/Library/Logs/Floatask.log"
  security delete-generic-password -s "io.github.shihab-abir.floatask" >/dev/null 2>&1 || true
  echo "✓ Removed local settings, logs and the saved API key"
fi

echo "Your vault's “Task Manager” folder was left as-is."
