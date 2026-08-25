#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:-$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null || true)}"

if [[ -z "$REPO_URL" ]]; then
  echo "usage: install.sh [git-url]" >&2
  exit 1
fi

echo "==> Installing Omarchy shell plugin"
omarchy plugin add "$REPO_URL" --enable

echo "==> Ensuring Hyprland plugin headers are installed (may ask for your password)"
# hyprpm add refuses to run until headers exist and match the running Hyprland
# ("Headers outdated, please run hyprpm update."), so bootstrap them first.
hyprpm update

echo "==> Adding native Hyprland sensor via hyprpm"
hyprpm add "$REPO_URL"
hyprpm enable caret-tracker

echo "==> Done. Verify with:"
echo "    socat - UNIX-CONNECT:\$XDG_RUNTIME_DIR/caret-trails.sock"
