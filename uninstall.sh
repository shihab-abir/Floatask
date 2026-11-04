#!/bin/bash
# Removes Taskflow.
#
#   curl -fsSL https://raw.githubusercontent.com/shihab-abir/Work-Management-App/main/uninstall.sh | bash
#
# Your tasks and focus history in the vault's "Task Manager" folder are NEVER touched.
# Pass --purge (`... | bash -s -- --purge`) to also remove local settings, logs and the saved API key.
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

if pgrep -xq Taskflow; then
  "$HOME/.local/bin/taskflow" quit >/dev/null 2>&1 || true
  sleep 1
  pkill -x Taskflow 2>/dev/null || true
fi

rm -rf "$HOME/Applications/Taskflow.app"
[[ -L "$HOME/.local/bin/taskflow" ]] && rm "$HOME/.local/bin/taskflow"
echo "✓ Removed Taskflow.app and the taskflow command"

if (( PURGE )); then
  rm -rf "$HOME/Library/Application Support/Taskflow" "$HOME/Library/Logs/Taskflow.log"
  security delete-generic-password -s "io.github.shihab-abir.taskflow" >/dev/null 2>&1 || true
  echo "✓ Removed local settings, logs and the saved API key"
fi

echo "Your vault's “Task Manager” folder was left as-is."
