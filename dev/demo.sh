#!/usr/bin/env bash
# Run Chief Stew against the demo repo, with its own inbox, leaving your real settings alone.
#
#   dev/demo.sh [idle|progress|needs|left|broken]   build, then run in that state
#   dev/demo.sh state <name>                        switch state (the next poll or Refresh shows it)
#   dev/demo.sh ask ["message"]                     drop an agent.needs_input event for build 173
#   dev/demo.sh answer                              drop agent.resumed for the same session
#
# Inbox: /tmp/chiefstew-demo/inbox; live state dump: /tmp/chiefstew-demo/debug/. Quit the demo app from its panel.

set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD/dev/demo-repo"
export CHIEFSTEW_HOME=/tmp/chiefstew-demo

emit() {  # emit <json> — atomic write, like a real emitter (contract § 2)
  mkdir -p "$CHIEFSTEW_HOME/inbox"
  local name
  name="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')-$$-$(openssl rand -hex 2).json"
  printf '%s' "$1" > "$CHIEFSTEW_HOME/inbox/.$name.tmp"
  mv "$CHIEFSTEW_HOME/inbox/.$name.tmp" "$CHIEFSTEW_HOME/inbox/$name"
}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "${1:-progress}" in
  state) echo "$2" > "$REPO/demo-state" ;;
  ask)
    emit "{\"v\":1,\"ts\":\"$(now)\",\"kind\":\"agent.needs_input\",\"repo\":\"$REPO\",\"worktree\":\"$REPO/.worktrees/build-173\",\"session\":\"demo\",\"agent\":\"claude-code\",\"message\":\"${2:-Claude needs your permission to use Bash}\"}" ;;
  answer)
    emit "{\"v\":1,\"ts\":\"$(now)\",\"kind\":\"agent.resumed\",\"repo\":\"$REPO\",\"worktree\":\"$REPO/.worktrees/build-173\",\"session\":\"demo\"}" ;;
  *)
    echo "$1" > "$REPO/demo-state"
    ./build.sh debug
    pkill -f "Chief Stew.app/Contents/MacOS/ChiefStew" 2>/dev/null || true
    CHIEFSTEW_DEBUG_DIR="$CHIEFSTEW_HOME/debug" CHIEFSTEW_REPOS="$REPO" nohup "build/Chief Stew.app/Contents/MacOS/ChiefStew" \
      >"$CHIEFSTEW_HOME.log" 2>&1 </dev/null &
    echo "running (pid $!) against $REPO in state '$1'; output in $CHIEFSTEW_HOME.log"
    ;;
esac
