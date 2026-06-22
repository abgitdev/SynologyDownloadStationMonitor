#!/bin/bash
# Forensic trace check for "Synology Download Station Monitor" (Phase 3 test tool).
#
# Run it on the test Mac to prove the app's self-uninstall left NOTHING behind:
#   1) ./forensic-check.sh         → before installing: should be all CLEAN
#   2) (install + use the app)
#   3) ./forensic-check.sh         → now several items are PRESENT (the app's footprint)
#   4) (in the app: "Delete…" → "Delete permanently")
#   5) ./forensic-check.sh         → must be all CLEAN again  ✅
#
# Exit code 0 = no traces found, 1 = leftovers found. Read-only: it never deletes anything.

BUNDLE_ID="com.abgitdev.SynologyDownloadStationMonitor"
BUNDLE_NAME="Synology Download Station Monitor"   # CFBundleName
EXEC_NAME="SynologyDownloadStationMonitor"        # CFBundleExecutable
PW_SERVICE="SynologyDownloadStationMonitor.password"
PIN_SERVICE="SynologyDownloadStationMonitor.pin"
DT_SERVICE="SynologyDownloadStationMonitor.devicetoken"   # 2FA "remember this device" token
LIB="$HOME/Library"

leftovers=0
present()  { printf "  \033[31m❌ LEFTOVER\033[0m  %s\n" "$1"; leftovers=$((leftovers+1)); }
clean()    { printf "  \033[32m✅ clean\033[0m   %s\n" "$1"; }
note()     { printf "  \033[33mℹ️  %s\033[0m\n" "$1"; }

# A path is a "trace": report PRESENT if it exists, CLEAN otherwise.
check_path() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then present "$label — $path"; else clean "$label"; fi
}

echo "═══════════════════════════════════════════════════════════════"
echo " Forensic trace check · $BUNDLE_ID"
echo " $(date)"
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "▸ Files in ~/Library"
check_path "Caches"                       "$LIB/Caches/$BUNDLE_ID"
check_path "HTTPStorages"                 "$LIB/HTTPStorages/$BUNDLE_ID"
check_path "HTTPStorages cookies"         "$LIB/HTTPStorages/$BUNDLE_ID.binarycookies"
check_path "WebKit"                       "$LIB/WebKit/$BUNDLE_ID"
check_path "Saved Application State"       "$LIB/Saved Application State/$BUNDLE_ID.savedState"
check_path "Application Support (by id)"   "$LIB/Application Support/$BUNDLE_ID"
check_path "Application Support (by name)" "$LIB/Application Support/$BUNDLE_NAME"
check_path "Logs"                         "$LIB/Logs/$BUNDLE_ID"
check_path "Preferences plist"            "$LIB/Preferences/$BUNDLE_ID.plist"
check_path "Group Containers"             "$LIB/Group Containers/$BUNDLE_ID"
check_path "Containers (sandbox)"         "$LIB/Containers/$BUNDLE_ID"

echo ""
echo "▸ Crash reports (may contain process data)"
crash_hits=$(ls "$LIB/Logs/DiagnosticReports/" 2>/dev/null | grep -c "^$EXEC_NAME")
if [ "${crash_hits:-0}" -gt 0 ]; then
  present "DiagnosticReports — found $crash_hits file(s) $EXEC_NAME*"
  ls "$LIB/Logs/DiagnosticReports/" 2>/dev/null | grep "^$EXEC_NAME" | sed 's/^/        • /'
else
  clean "DiagnosticReports"
fi

echo ""
echo "▸ Keychain (presence only, password is NOT shown)"
if security find-generic-password -s "$PW_SERVICE" >/dev/null 2>&1; then
  present "Keychain: $PW_SERVICE (saved password present)"
else
  clean "Keychain: $PW_SERVICE"
fi
if security find-generic-password -s "$PIN_SERVICE" >/dev/null 2>&1; then
  present "Keychain: $PIN_SERVICE (pinned certificate present)"
else
  clean "Keychain: $PIN_SERVICE"
fi
if security find-generic-password -s "$DT_SERVICE" >/dev/null 2>&1; then
  present "Keychain: $DT_SERVICE (2FA device token present)"
else
  clean "Keychain: $DT_SERVICE"
fi

echo ""
echo "▸ UserDefaults (cfprefsd may keep a cache until re-login)"
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
  present "defaults domain $BUNDLE_ID is still readable"
else
  clean "defaults domain $BUNDLE_ID"
fi

echo ""
echo "▸ Processes"
pids=$(pgrep -f "$EXEC_NAME" 2>/dev/null)
if [ -n "$pids" ]; then present "Running processes: $pids"; else clean "No processes running"; fi

echo ""
echo "▸ The .app itself (search in the usual locations)"
app_found=0
for d in "/Applications" "$HOME/Applications" "$HOME/Desktop" "$HOME/Downloads"; do
  while IFS= read -r hit; do
    [ -n "$hit" ] && { present ".app found — $hit"; app_found=1; }
  done < <(find "$d" -maxdepth 2 -name "$EXEC_NAME*.app" 2>/dev/null)
done
[ "$app_found" -eq 0 ] && clean ".app not found in /Applications, ~/Applications, ~/Desktop, ~/Downloads"

echo ""
echo "▸ Trash (self-uninstall puts items here — this is EXPECTED, removed when the Trash is emptied)"
trash_hits=$(ls "$HOME/.Trash" 2>/dev/null | grep -c "$EXEC_NAME")
if [ "${trash_hits:-0}" -gt 0 ]; then
  note "Trash has $trash_hits item(s) named $EXEC_NAME — this is normal, empty the Trash."
else
  clean "Nothing of ours in the Trash"
fi

echo ""
echo "▸ What the app CANNOT remove (system-level — do it manually)"
note "System Settings → Privacy → Local Network: the app's entry remains (SIP)."
note "Browser history (if you clicked «Open in DSM web») — outside the app's scope."

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$leftovers" -eq 0 ]; then
  printf " \033[32mRESULT: no traces found — CLEAN ✅\033[0m\n"
  echo "═══════════════════════════════════════════════════════════════"
  exit 0
else
  printf " \033[31mRESULT: leftovers found: %s ❌\033[0m\n" "$leftovers"
  echo " (if this is BEFORE self-uninstall — normal; if AFTER — it's a bug, send the output)"
  echo "═══════════════════════════════════════════════════════════════"
  exit 1
fi
