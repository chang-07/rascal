#!/usr/bin/env bash
# guitest.sh — Accessibility-driven structural audit of the running app.
#
# Strategy: macOS does NOT expose windows of `.accessory`-policy apps to
# accessibility queries the same way it does for foreground apps, and it
# refuses to honour `click menu item` on a background app. So:
#
#   - We DO verify that every menu, menu-item, sub-menu, and shortcut binding
#     is registered in the app's main menu (AX reads these regardless of
#     activation state).
#   - We DO NOT try to invoke actions via AX or read window contents — those
#     paths are unreliable in background mode.
#   - The deep functional verification lives in `smoketest.sh` (in-process
#     test runner with 200+ assertions covering every feature, including
#     window/pane/file-list state, file ops, themes, vim, palette, etc.).
#
# Both scripts run silently, never bring the app on-screen, never steal focus.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/FinderTwo.app"
BIN="$APP/Contents/MacOS/FinderTwo"
LOG="/tmp/finder2-gui.log"

failures=0
fail() { echo "  ✗ $1"; failures=$((failures+1)); }
pass() { echo "  ✓ $1"; }

if [[ ! -x "$BIN" ]]; then
    echo "Binary not built. Run ./build.sh first."
    exit 1
fi

# Kill only OUR build binary (never the user's installed /Applications copy),
# launch a fresh headless (.accessory → off-screen, no Dock, no focus steal)
# instance, and target it BY PID so a running installed copy can't shadow it.
pkill -f "$BIN" 2>/dev/null || true
sleep 0.6
FT_HEADLESS_TESTING=1 "$BIN" > "$LOG" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null' EXIT
PROC="first process whose unix id is $APP_PID"
sleep 1.5

osa() { osascript -e "$1" 2>&1; }

# -- Phase 1: top-level menus -----------------------------------------------

echo "=== Phase 1: top-level menus ==="
for m in FinderTwo File Edit View Go Window; do
    out=$(osa "tell application \"System Events\" to tell ($PROC) to exists menu bar item \"$m\" of menu bar 1")
    [[ "$out" == "true" ]] && pass "menu '$m' present" || fail "menu '$m' missing"
done

# -- Phase 2: every advertised menu item present ----------------------------

echo "=== Phase 2: menu items ==="
declare -a EXPECT=(
    "FinderTwo|Settings…"
    "FinderTwo|About FinderTwo"
    "FinderTwo|Quit FinderTwo"
    "File|New Window"
    "File|New Tab"
    "File|New Folder"
    "File|New Smart Folder…"
    "File|Close Tab"
    "File|Close Window"
    "File|Get Info"
    "File|Rename"
    "File|Batch Rename…"
    "File|Move to Trash"
    "File|Save Workspace…"
    "File|Open Workspace…"
    "File|Command Palette…"
    "File|Find Files…"
    "File|Search File Contents…"
    "File|Copy Path"
    "File|Open in Terminal"
    "File|Open in Editor"
    "Edit|Cut"
    "Edit|Copy"
    "Edit|Paste"
    "Edit|Move Items Here"
    "Edit|Duplicate"
    "Edit|Select All"
    "Edit|Select by Pattern…"
    "Edit|Undo"
    "Edit|Redo"
    "View|as Icons"
    "View|as List"
    "View|as Columns"
    "View|Show Hidden Files"
    "View|Open Extra Pane"
    "Go|Back"
    "Go|Forward"
    "Go|Enclosing Folder"
    "Go|Mount Network Volume…"
    "Go|Open"
    "Go|Go to Folder…"
    "Go|Home"
    "Go|Jump to Project Root"
    "View|Focus Next Pane"
    "View|Focus Previous Pane"
    "View|Use Groups"
    "View|Transfer Activity"
    "View|Drop Stack"
    "Window|Minimize"
    "Window|Zoom"
    "Window|Next Tab"
    "Window|Previous Tab"
    "Window|Move Tab Left"
    "Window|Move Tab Right"
    "Window|Tab 1"
    "Window|Last Tab"
)
for spec in "${EXPECT[@]}"; do
    IFS="|" read -r menu item <<< "$spec"
    out=$(osa "tell application \"System Events\" to tell ($PROC) to exists menu item \"$item\" of menu \"$menu\" of menu bar item \"$menu\" of menu bar 1")
    [[ "$out" == "true" ]] && pass "$menu → $item" || fail "$menu → $item MISSING"
done

# -- Phase 3: keyboard shortcuts on advertised items -----------------------

echo "=== Phase 3: shortcuts ==="
# AX reports AXMenuItemCmdChar as the uppercase character regardless of how
# we set it on the menu item. Compare case-insensitively.
check_shortcut() {
    local menu="$1" item="$2" expected_key="$3" expected_mods="$4"
    local key=$(osa "tell application \"System Events\" to tell ($PROC) to ¬
        get value of attribute \"AXMenuItemCmdChar\" of menu item \"$item\" of menu \"$menu\" of menu bar item \"$menu\" of menu bar 1")
    local mods=$(osa "tell application \"System Events\" to tell ($PROC) to ¬
        get value of attribute \"AXMenuItemCmdModifiers\" of menu item \"$item\" of menu \"$menu\" of menu bar item \"$menu\" of menu bar 1")
    # Normalize to uppercase for comparison
    local norm_got=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
    local norm_exp=$(printf '%s' "$expected_key" | tr '[:lower:]' '[:upper:]')
    if [[ "$norm_got" == "$norm_exp" && "$mods" == "$expected_mods" ]]; then
        pass "$menu → $item shortcut ⌘$key (mods=$mods)"
    else
        fail "$menu → $item shortcut got '$key' mods=$mods, expected '$expected_key' mods=$expected_mods"
    fi
}
# AXMenuItemCmdModifiers bitmask:
#   0 = Command (default)
#   1 = Command+Shift
#   2 = Command+Option
#   3 = Command+Shift+Option
#   4 = Command+Control
check_shortcut "File" "New Tab" "t" "0"
check_shortcut "File" "Close Tab" "w" "0"
check_shortcut "File" "Command Palette…" "p" "1"
check_shortcut "File" "Find Files…" "f" "0"
check_shortcut "File" "Search File Contents…" "f" "1"
check_shortcut "File" "Batch Rename…" "r" "1"
check_shortcut "File" "Copy Path" "c" "2"
check_shortcut "File" "Open in Terminal" "t" "2"
check_shortcut "View" "Open Extra Pane" "\\" "0"
check_shortcut "Go" "Go to Folder…" "g" "1"
check_shortcut "Go" "Home" "h" "1"
check_shortcut "FinderTwo" "Settings…" "," "0"
check_shortcut "File" "New Window" "n" "0"
check_shortcut "File" "New Smart Folder…" "n" "2"
check_shortcut "View" "Drop Stack" "d" "4"
check_shortcut "View" "Show Hidden Files" "." "1"
check_shortcut "File" "Get Info" "i" "0"
check_shortcut "Go" "Back" "[" "0"
check_shortcut "Go" "Forward" "]" "0"
check_shortcut "Edit" "Copy" "c" "0"
check_shortcut "Edit" "Paste" "v" "0"
check_shortcut "Edit" "Move Items Here" "v" "2"
check_shortcut "Edit" "Duplicate" "d" "0"
check_shortcut "Edit" "Select All" "a" "0"
# Tab / pane / view-mode management (mods: 1=⌘⇧, 2=⌘⌥, 4=⌘⌃)
check_shortcut "Window" "Next Tab" "]" "1"
check_shortcut "Window" "Previous Tab" "[" "1"
check_shortcut "Window" "Move Tab Left" "[" "4"
check_shortcut "Window" "Move Tab Right" "]" "4"
check_shortcut "Window" "Tab 1" "1" "0"
check_shortcut "Window" "Last Tab" "9" "0"
check_shortcut "View" "as Icons" "1" "2"
check_shortcut "View" "as List" "2" "2"
check_shortcut "View" "as Columns" "3" "2"

# -- Phase 4: AX exposes menu titles correctly ------------------------------

echo "=== Phase 4: menu titles ==="
all_titles=$(osa "
tell application \"System Events\"
  tell ($PROC)
    set titles to {}
    repeat with bar_item in menu bar items of menu bar 1
      copy (name of bar_item) to end of titles
    end repeat
    return titles as string
  end tell
end tell")
echo "$all_titles" | grep -q "FinderTwo" && pass "menu bar exposes FinderTwo" || fail "FinderTwo missing"
echo "$all_titles" | grep -q "File" && pass "menu bar exposes File" || fail "File missing"
echo "$all_titles" | grep -q "Window" && pass "menu bar exposes Window" || fail "Window missing"

echo
echo "=== Result: $failures failure(s) ==="
echo "=== stderr tail ==="
tail -6 "$LOG"
exit $failures
