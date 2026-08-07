#!/bin/bash

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

AGENT_DIRS=(
  "$HOME/.claude/skills"
  "$HOME/.codex/skills"
  "$HOME/.agents/skills"
  "$HOME/.pi/agent/skills"
)

for dir in "$SCRIPT_DIR"/*/; do
  clean_dir="${dir%/}"
  base_name="$(basename "$clean_dir")"

  for agent_dir in "${AGENT_DIRS[@]}"; do
    target="$agent_dir/$base_name"
    # Only remove if it's a symlink pointing at exactly this repo's skill dir
    if [[ -L "$target" && "$(readlink -f "$target")" == "$clean_dir" ]]; then
      rm -v "$target"
      echo "Unlinked: $target"
    fi
  done
done
