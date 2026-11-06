#!/usr/bin/env bash
# install.sh — symlink the agent-ops pieces into place.
#
# Idempotent: safe to re-run. Symlinks rather than copies, so edits to this repo
# (or a `git pull`) are picked up immediately. Run `configure` afterwards for
# the interactive machine-specific setup.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
PLUGIN_DIR="${HOME}/.config/opencode/plugins"
LAYOUT_DIR="${HOME}/.config/zellij/layouts"

link() { # link <src> <dst>
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" || -L "$dst" ]]; then
    if [[ "$(readlink -f "$dst" 2>/dev/null)" == "$src" ]]; then
      printf 'ok   %s\n' "$dst"
      return
    fi
    printf 'skip %s (exists and is not a symlink to this repo)\n' "$dst"
    return
  fi
  ln -s "$src" "$dst"
  printf 'link %s\n' "$dst"
}

printf 'repo: %s\n\n' "$REPO"
link "$REPO/bin/agent-inbox"         "$BIN_DIR/agent-inbox"
link "$REPO/bin/sys"                 "$BIN_DIR/sys"
link "$REPO/plugin/agent-log"        "$PLUGIN_DIR/agent-log"
link "$REPO/zellij/agent-ops.kdl"    "$LAYOUT_DIR/agent-ops.kdl"

cat <<EOF

Done. Next steps:

  1. Interactive setup:
       $REPO/configure

  2. Source the shell helpers from your ~/.zshrc:
       [[ -f "$REPO/shell/agent-ops.zsh" ]] && source "$REPO/shell/agent-ops.zsh"

  3. Restart OpenCode so the agent-log plugin loads:
       opencode service restart

See README.md for the full manual steps.
EOF
