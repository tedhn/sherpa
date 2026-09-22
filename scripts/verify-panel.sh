#!/bin/bash
# Drives the built app through the Accessibility API and asserts what the panel
# is supposed to do: open under the status item, leave the app in front active,
# accept clicks on its own content, and close on a second click.
#
# The terminal running this needs Accessibility permission.
set -uo pipefail

DERIVED="${DERIVED:-/tmp/sherpa-verify}"
APP="$DERIVED/Build/Products/Debug/sherpa.app"
failures=0

sys() { osascript -e "tell application \"System Events\" $1" 2>&1; }
proc() { sys "to tell process \"sherpa\" $1"; }
frontmost() { sys 'to name of first process whose frontmost is true'; }

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ok   $label"
    else
        echo "  FAIL $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

cd "$(dirname "$0")/.."
pkill -f "Debug/sherpa.app" 2>/dev/null
xcodebuild -project sherpa.xcodeproj -scheme sherpa -configuration Debug \
    -derivedDataPath "$DERIVED" build >/dev/null || { echo "build failed"; exit 1; }

open -a "$APP"
sleep 2

echo "status item"
item_pos="$(proc 'to return position of menu bar item 1 of menu bar 2')"
check "icon is in the menu bar" "yes" "$([[ "$item_pos" == *,* ]] && echo yes || echo no)"
check "no panel before the first click" "0" "$(proc 'to return count of windows')"

echo "open"
front_before="$(frontmost)"
proc 'to click menu bar item 1 of menu bar 2' >/dev/null
sleep 1
check "panel is on screen" "1" "$(proc 'to return count of windows')"
front_after="$(frontmost)"
check "the app in front keeps focus" "$front_before" "$front_after"
check "sherpa did not activate" "no" "$([[ "$front_after" == "sherpa" ]] && echo yes || echo no)"

read -r item_x item_y <<<"${item_pos//,/ }"
read -r item_w item_h <<<"$(proc 'to return size of menu bar item 1 of menu bar 2' | tr ',' ' ')"
read -r panel_x panel_y <<<"$(proc 'to return position of window 1' | tr ',' ' ')"
read -r panel_w panel_h <<<"$(proc 'to return size of window 1' | tr ',' ' ')"
if [[ "$panel_x$panel_y$panel_w" =~ ^[0-9-]+$ ]]; then
    echo "  info icon at $item_x,$item_y sized ${item_w}x${item_h}; panel at $panel_x,$panel_y sized ${panel_w}x${panel_h}"
    # Accessibility reports a top-left origin with y growing downward, so a
    # panel below the icon has the larger y.
    check "panel hangs below the icon" "yes" "$([[ $panel_y -gt $item_y ]] && echo yes || echo no)"
    check "panel is centred on the icon" "yes" \
        "$([[ $(( panel_x + panel_w / 2 - item_x - item_w / 2 )) -le 2 ]] && echo yes || echo no)"
else
    echo "  skip geometry checks: no panel to measure"
    panel_x=0 panel_y=0 panel_w=0
fi

echo "content"
# NSHostingView wraps the SwiftUI body in one AXGroup, so the labels and the
# button sit a level below the window.
counter='value of static text 2 of group 1 of window 1'
count_before="$(proc "to return $counter")"
proc 'to click button 1 of group 1 of window 1' >/dev/null
sleep 1
count_after="$(proc "to return $counter")"
check "panel content takes clicks" "yes" "$([[ "$count_before" != "$count_after" ]] && echo yes || echo no)"
echo "  info '$count_before' -> '$count_after'"
check "focus still behind after using the panel" "$front_before" "$(frontmost)"

echo "close"
proc 'to click menu bar item 1 of menu bar 2' >/dev/null
sleep 1
check "a second click closes the panel" "0" "$(proc 'to return count of windows')"

# Not checked here: right-click on the icon opens the Quit Sherpa menu. The
# Accessibility API exposes no right-click on a status item, and synthetic
# CGEvents need event-posting permission this script cannot assume. Confirm it
# by hand once after changing the click routing.

mkdir -p "$DERIVED/shots"
proc 'to click menu bar item 1 of menu bar 2' >/dev/null
sleep 1
screencapture -x -R"$((panel_x - 40)),$((panel_y - 40)),$((panel_w + 80)),$((panel_h + 80))" "$DERIVED/shots/panel.png"
echo "  info corners and shadow: $DERIVED/shots/panel.png"

pkill -f "Debug/sherpa.app" 2>/dev/null
if [[ $failures -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; fi
exit $failures
