#!/usr/bin/env bash
# M2 spike (passed 2026-09-30): an ad-hoc-signed SwiftPM .app can post via UNUserNotificationCenter.
# Builds a throwaway bundle with Chief Stew's bundle ID and sends one test notification.
# Run it from a normal terminal: Claude Code's command sandbox makes the request come back denied.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/notify-check/Chief Stew.app"
rm -rf build/notify-check && mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/NotifyCheck" dev/notify-check.swift
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string NotifyCheck" \
  -c "Add :CFBundleIdentifier string com.mheyw.chiefstew" -c "Add :CFBundleName string Chief Stew" \
  -c "Add :CFBundlePackageType string APPL" -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"
open -W --stdout /dev/stdout --stderr /dev/stderr "$APP"
