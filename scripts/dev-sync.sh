#!/usr/bin/env bash
# Dev-loop sync: mirrors this working copy into Omarchy's plugin dir (which
# can't be a symlink — omarchy-plugin-validate refuses symlinks inside a
# plugin folder), validates it, and restarts the running shell to load it.
#
# `omarchy-shell shell rescanPlugins` is NOT enough for a bar-widget whose
# QML content changed on disk: syncPluginWidgets() only recompiles when a
# plugin's entry-point URL changes, so editing BarWidget.qml in place and
# rescanning silently keeps serving the previously-compiled component. A
# full `omarchy restart shell` guarantees a fresh QML engine, so it's used
# here instead.
#
# Usage:
#   scripts/dev-sync.sh            one-shot sync
#   scripts/dev-sync.sh --watch    sync, then re-sync on every file change
set -euo pipefail

SRC="${PLUGIN_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEST="${PLUGIN_DEST:-$HOME/.config/omarchy/plugins/shavanced.notification-center}"

sync_once() {
  rsync -a --delete --exclude='.git' "$SRC"/ "$DEST"/
  if ! omarchy plugin validate "$DEST"; then
    echo "$(date '+%H:%M:%S') validation failed — not restarting" >&2
    return 1
  fi
  omarchy restart shell
  echo "$(date '+%H:%M:%S') synced $SRC -> $DEST, shell restarted"
}

if [[ "${1:-}" == "--watch" ]]; then
  command -v inotifywait >/dev/null || { echo "inotifywait not found (package: inotify-tools)" >&2; exit 1; }
  sync_once || true
  echo "Watching $SRC for changes (Ctrl-C to stop)..."
  while inotifywait -r -e modify,create,delete,move --exclude '(^|/)\.git(/|$)' "$SRC" >/dev/null 2>&1; do
    sync_once || true
  done
else
  sync_once
fi
