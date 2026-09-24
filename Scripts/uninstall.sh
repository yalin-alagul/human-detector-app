#!/usr/bin/env bash
#
# Remove Human Detector and everything it stored on this Mac.
#
#   Scripts/uninstall.sh            list what would go, ask, then remove it
#   Scripts/uninstall.sh --dry-run  only list
#   Scripts/uninstall.sh --yes      remove without asking
#
# Never touches your photos, the output folders you sorted into, or their
# .humandetector/ undo history. The project folder itself is left for you to
# delete.
#
set -uo pipefail

BUNDLE_ID="com.humandetector.app"
APP_NAME="Human Detector.app"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

dry_run=0
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --yes|-y) assume_yes=1 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

candidates=(
  "/Applications/$APP_NAME"
  "$HOME/Applications/$APP_NAME"
  "$HOME/Library/Containers/$BUNDLE_ID"
  "$HOME/Library/Application Scripts/$BUNDLE_ID"
  "$HOME/Library/Application Support/HumanDetector"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  "$REPO/build"
  "$REPO/.build"
)

# Output folders named in saved configs, so we can say they were left alone.
configs=(
  "$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/HumanDetector/HumanDetectorConfig.json"
  "$HOME/Library/Application Support/HumanDetector/HumanDetectorConfig.json"
)
outputs=()
for config in "${configs[@]}"; do
  [[ -f "$config" ]] || continue
  output="$(plutil -extract io.outputPath raw -o - "$config" 2>/dev/null || true)"
  [[ -n "$output" ]] && outputs+=("$output")
done

targets=()
for path in "${candidates[@]}"; do
  [[ -e "$path" ]] && targets+=("$path")
done

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "Nothing to remove — Human Detector has no app or data on this Mac."
else
  echo "Human Detector files on this Mac:"
  for path in "${targets[@]}"; do
    size="$(du -sh "$path" 2>/dev/null | cut -f1)"
    printf '  %6s  %s\n' "${size:-?}" "$path"
  done
fi

if [[ ${#outputs[@]} -gt 0 ]]; then
  echo
  for output in "${outputs[@]}"; do
    echo "Sorted photos and undo history in $output will be left alone."
  done
fi

if [[ $dry_run -eq 1 || ${#targets[@]} -eq 0 ]]; then
  [[ $dry_run -eq 1 ]] && echo && echo "Dry run — nothing was removed."
  exit 0
fi

if [[ $assume_yes -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Not a terminal; re-run with --yes to remove without asking." >&2
    exit 1
  fi
  echo
  read -r -p "Remove these? [y/N] " answer
  [[ "$answer" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

if pgrep -xq "Human Detector"; then
  echo "Quitting Human Detector…"
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || pkill -x "Human Detector"
  sleep 1
fi

# Clear cached preferences before their file goes, or cfprefsd writes it back.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

failed=()
for path in "${targets[@]}"; do
  rm -rf "$path" 2>/dev/null
  if [[ -e "$path" ]]; then
    failed+=("$path")
  else
    echo "  removed $path"
  fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo
  echo "Could not remove (macOS may block Terminal from deleting another app's data):"
  for path in "${failed[@]}"; do echo "  $path"; done
  echo "Drag these to the Trash in Finder, or give Terminal Full Disk Access and re-run."
fi

cat <<EOF

To remove the source code and models too, delete this folder:
  $REPO
Left in place because other projects may use them: Homebrew's python@3.10 and
xcodegen, and ~/Library/Application Support/Ultralytics (a 4 KB settings file).
EOF

[[ ${#failed[@]} -eq 0 ]]
