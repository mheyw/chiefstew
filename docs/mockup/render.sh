#!/usr/bin/env bash
# Re-render the overview: the app's own offscreen renders (the UI snapshot tests, all invented
# data) are copied into img/, then overview.html is screenshotted to overview.png.
#
#   docs/mockup/render.sh

set -euo pipefail
cd "$(dirname "$0")"
SNAPS="$(mktemp -d)"
trap 'rm -rf "$SNAPS"' EXIT

(cd ../.. && CHIEFSTEW_SNAPSHOTS="$SNAPS" swift test --filter ChiefStewUITests >/dev/null 2>&1)

rm -rf img && mkdir img
for name in \
  menubar-1-idle menubar-2-in-progress menubar-3-needs-you menubar-4-left-behind \
  panel-1-idle panel-2-in-progress panel-3-needs-you panel-3-needs-you-dark panel-4-left-behind panel-5-stale \
  panel-6-no-repos panel-11-teammates panel-12-folder-builds panel-update-available panel-budget \
  window-roadmap window-all-repos window-left-behind; do
  cp "$SNAPS/$name.png" img/
done

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# The page measures its own height; ask Chrome for it, then screenshot exactly that tall.
HEIGHT="$("$CHROME" --headless=new --window-size=1064,1000 --virtual-time-budget=3000 --dump-dom "file://$PWD/overview.html" 2>/dev/null \
  | sed -n 's/.*data-height="\([0-9]*\)".*/\1/p' | head -1)"
"$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1064,"$HEIGHT" --screenshot="$PWD/overview.png" "file://$PWD/overview.html" 2>/dev/null
echo "✓ docs/mockup/overview.png"
