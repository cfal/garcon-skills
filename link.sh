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
    mkdir -vp "$agent_dir"
    target="$agent_dir/$base_name"
    if [[ -e "$target" || -L "$target" ]]; then
      echo "Removing: $target"
      rm -vrf "$target"
    fi
    ln -sfn "$clean_dir" "$target"
    echo "Linked: $target"
  done
done
