#!/usr/bin/env bash
# Build "Chief Stew.app": swift build, assemble the bundle, ad-hoc sign, verify.
#
#   ./build.sh           release build → build/Chief Stew.app
#   ./build.sh debug     debug build   → build/Chief Stew.app
#   ./build.sh install   release build of this checkout, installed into /Applications
#   ./build.sh update    release build of a clean export of main, installed (the app's
#                        "Install update" runs this; it never builds a branch or uncommitted edits)
#   ./build.sh rollback  put the newest backup back into /Applications
#
# Installing stages the new copy and verifies it before quitting the running one; if anything
# fails after that, the previous copy is put back and reopened. The three newest previous copies
# are kept in ~/Library/Application Support/Chief Stew/backups/.
#
# The app records the commit it was built from (ChiefStewSourceCommit) and this folder
# (ChiefStewSourceDir), so it can offer an update when main moves on. No Xcode project.

set -Eeuo pipefail
shopt -s nullglob
cd "$(dirname "$0")"

NAME="Chief Stew"
EXEC="ChiefStew"
BUNDLE_ID="${CHIEFSTEW_BUNDLE_ID:-com.mheyw.chiefstew}"
VERSION="0.0.1"
APP="build/$NAME.app"
DEST="/Applications/$NAME.app"
BACKUPS="$HOME/Library/Application Support/$NAME/backups"
MODE="${1:-release}"

# Provenance. `update` passes these in for the exported copy of main it builds.
SOURCE_DIR="${CHIEFSTEW_SOURCE_DIR:-$PWD}"
if [ -n "${CHIEFSTEW_SOURCE_COMMIT:-}" ]; then
  SOURCE_COMMIT="$CHIEFSTEW_SOURCE_COMMIT"
  BUILD_NUMBER="${CHIEFSTEW_BUILD_NUMBER:-0}"
else
  SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  # Untracked files count too: SwiftPM compiles every file under Sources/.
  [ -z "$(git status --porcelain 2>/dev/null)" ] || SOURCE_COMMIT="$SOURCE_COMMIT-dirty"
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
fi
SCRATCH="${CHIEFSTEW_SCRATCH:-.build}"

# The installed app's process, matched on its whole command line (launchd starts it with no
# arguments), so no shell whose command merely mentions the path can match. -a includes
# ancestors: when the app's "Install update" runs this script, the app is its ancestor, and
# macOS pgrep/pkill skip ancestors by default.
APP_PROC="^$DEST/Contents/MacOS/$EXEC\$"
running() { pgrep -a -f "$APP_PROC" >/dev/null; }

quit_running() {
  if ! running; then
    echo "  no running copy to quit"
    return 0
  fi
  # SIGTERM quits cleanly (the app handles it like Quit, removing its heartbeat).
  pkill -TERM -a -f "$APP_PROC" || true  # the signal must come first
  for _ in $(seq 1 50); do running || break; sleep 0.1; done
  if running; then
    # An older copy can ignore the polite quit (e.g. with a sheet open): force it, and clear
    # its heartbeat so emitters take notifications back straight away.
    echo "  the running copy didn't quit in 5 s; forcing it"
    pkill -KILL -a -f "$APP_PROC" || true
    for _ in $(seq 1 30); do running || break; sleep 0.1; done
    rm -f "$HOME/Library/Application Support/$NAME/alive"
  fi
  if running; then
    echo "✗ the running copy didn't quit; quit it from its panel and re-run"
    return 1
  fi
  echo "  quit the running copy"
}

reopen() {
  open "$DEST"
  for _ in $(seq 1 50); do running && break; sleep 0.1; done
  running || { echo "✗ it didn't start"; return 1; }
}

backup_current() {
  [ -d "$DEST" ] || return 0
  mkdir -p "$BACKUPS"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  ditto "$DEST" "$BACKUPS/$NAME $stamp.app"
  echo "  backed up the old copy to $BACKUPS/$NAME $stamp.app"
  local all=("$BACKUPS"/*.app)
  if [ "${#all[@]}" -gt 3 ]; then
    printf '%s\n' "${all[@]}" | sort -r | tail -n +4 | while IFS= read -r old; do rm -rf "$old"; done
  fi
}

# install_bundle <path to a built .app>
install_bundle() {
  local src="$1" stage="$DEST.new" old="$DEST.old"
  # Stage and verify first, while the running copy is still running.
  rm -rf "$stage" "$old"
  ditto "$src" "$stage"
  xattr -dr com.apple.quarantine "$stage" 2>/dev/null || true
  codesign --verify --strict "$stage"
  backup_current
  quit_running || { rm -rf "$stage"; return 1; }

  # From here, a failure must not leave nothing installed: put the previous copy back.
  restore() {
    echo "✗ install failed; putting the previous copy back"
    if [ -d "$old" ]; then rm -rf "$DEST"; mv "$old" "$DEST"; fi
    open "$DEST" 2>/dev/null || true
    osascript -e 'display notification "The update failed, so the previous copy was put back. See ~/Library/Logs/Chief Stew/update.log." with title "Chief Stew"' 2>/dev/null || true
  }
  trap restore ERR
  if [ -d "$DEST" ]; then mv "$DEST" "$old"; fi
  mv "$stage" "$DEST"
  codesign --verify --strict "$DEST"
  reopen
  trap - ERR
  rm -rf "$old"
  echo "  signature verified"
}

case "$MODE" in
  rollback)
    all=("$BACKUPS"/*.app)
    [ "${#all[@]}" -gt 0 ] || { echo "✗ no backups in $BACKUPS"; exit 1; }
    latest="$(printf '%s\n' "${all[@]}" | sort -r | head -n 1)"
    codesign --verify --strict "$latest"
    install_bundle "$latest"
    rm -rf "$latest"
    echo "✓ rolled back to $(basename "$latest")"
    exit 0
    ;;
  update)
    git rev-parse --verify --quiet refs/heads/main >/dev/null || { echo "✗ no main branch"; exit 1; }
    tmp="$(mktemp -d /tmp/chiefstew-update.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    git archive refs/heads/main | tar -x -C "$tmp"
    mkdir -p "$HOME/Library/Caches/$NAME/build"
    echo "  building main $(git rev-parse --short refs/heads/main) from a clean export"
    CHIEFSTEW_SOURCE_DIR="$PWD" \
      CHIEFSTEW_SOURCE_COMMIT="$(git rev-parse refs/heads/main)" \
      CHIEFSTEW_BUILD_NUMBER="$(git rev-list --count refs/heads/main)" \
      CHIEFSTEW_SCRATCH="$HOME/Library/Caches/$NAME/build" \
      bash "$tmp/build.sh" install
    exit 0
    ;;
  release | install) CONFIG=release ;;
  debug) CONFIG=debug ;;
  *) echo "usage: ./build.sh [release|debug|install|update|rollback]"; exit 2 ;;
esac

swift build -c "$CONFIG" --product "$EXEC" --scratch-path "$SCRATCH"
swift build -c "$CONFIG" --product chiefstew-cli --scratch-path "$SCRATCH"
BINDIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BINDIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
# The `chiefstew` command: Claude Code hooks and repo scripts call it (hook / emit).
cp "$BINDIR/chiefstew-cli" "$APP/Contents/Helpers/chiefstew"
# The contract and the workflow format, embedded in the setup prompt.
cp docs/event-contract.md "$APP/Contents/Resources/event-contract.md"
cp docs/workflow.md "$APP/Contents/Resources/workflow.md"

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>ChiefStewSourceDir</key><string>$(xml "$SOURCE_DIR")</string>
  <key>ChiefStewSourceCommit</key><string>$(xml "$SOURCE_COMMIT")</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/chiefstew"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --deep "$APP"
echo "✓ built $APP ($CONFIG, $VERSION build $BUILD_NUMBER, $SOURCE_COMMIT)"

[ "$MODE" = install ] || exit 0
install_bundle "$APP"
echo "✓ installed $DEST ($VERSION build $BUILD_NUMBER) and running"
