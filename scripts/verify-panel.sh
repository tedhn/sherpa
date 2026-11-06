#!/bin/bash
# Drives the built app through the Accessibility API and asserts what the panel
# is supposed to do: open under the status item, leave the app in front active,
# record the microphone while the talk control is held, close on a second click,
# and close when a real mouse click lands anywhere else.
#
# The terminal running this needs Accessibility permission.
set -uo pipefail

DERIVED="${DERIVED:-/tmp/sherpa-verify}"
APP="$DERIVED/Build/Products/Debug/sherpa.app"
failures=0

sys() { osascript -e "tell application \"System Events\" $1" 2>&1; }
# Addressed by process id, not by name. A copy launched from Xcode is also
# called sherpa, and by name the Accessibility API picks one of them at random.
proc() { sys "to tell (first process whose unix id is $app_pid) $1"; }
frontmost() { sys 'to name of first process whose frontmost is true'; }

# Accessibility clicks on the real menu bar settle at their own pace, more so
# while the bar is mid-animation, so poll for the state instead of sleeping a
# fixed amount and hoping.
wait_for_windows() {
    local expected="$1" deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        [[ "$(proc 'to return count of windows')" == "$expected" ]] && return 0
        sleep 0.25
    done
    return 1
}

# The front app must not become sherpa. It changing to something else means a
# person switched apps while the script ran, which says nothing about the panel.
check_focus_kept() {
    local label="$1" before="$2" after="$3"
    if [[ "$after" == "sherpa" ]]; then
        echo "  FAIL $label: sherpa took focus"
        failures=$((failures + 1))
    elif [[ "$before" != "$after" ]]; then
        echo "  skip $label: the front app went from $before to $after, someone is using the machine"
    else
        echo "  ok   $label"
    fi
}

close_panel_if_open() {
    [[ "$(proc 'to return count of windows')" == "0" ]] && return
    proc 'to click menu bar item 1 of menu bar 2' >/dev/null
    wait_for_windows 0
}

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
# Only ever touch the build this script owns. Anything running from Xcode's own
# DerivedData belongs to whoever launched it.
pkill -f "$DERIVED" 2>/dev/null
xcodebuild -project sherpa.xcodeproj -scheme sherpa -configuration Debug \
    -derivedDataPath "$DERIVED" build >/dev/null || { echo "build failed"; exit 1; }

echo "build"
check "signature carries the audio-input entitlement" "yes" \
    "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q com.apple.security.device.audio-input && echo yes || echo no)"
check "Info.plist explains the microphone" "Sherpa hears you only while you hold to talk." \
    "$(plutil -extract NSMicrophoneUsageDescription raw "$APP/Contents/Info.plist" 2>&1)"

echo "level meter"
swiftc -parse-as-library -o "$DERIVED/level-meter-check" \
    sherpa/LevelMeter.swift scripts/level-meter-check.swift >/dev/null \
    && "$DERIVED/level-meter-check" || failures=$((failures + 1))

echo "speech audio"
swiftc -parse-as-library -o "$DERIVED/speech-audio-check" \
    sherpa/SpeechAudio.swift scripts/speech-audio-check.swift >/dev/null \
    && "$DERIVED/speech-audio-check" || failures=$((failures + 1))

echo "assemblyai"
swiftc -parse-as-library -o "$DERIVED/assemblyai-check" \
    sherpa/AssemblyAI.swift scripts/assemblyai-check.swift >/dev/null \
    && "$DERIVED/assemblyai-check" || failures=$((failures + 1))

echo "dictation"
swiftc -parse-as-library -o "$DERIVED/dictation-check" \
    sherpa/AssemblyAI.swift sherpa/Dictation.swift scripts/dictation-check.swift >/dev/null \
    && "$DERIVED/dictation-check" || failures=$((failures + 1))

echo "transcription"
app_swift_flags=(
    -swift-version 5 -default-isolation=MainActor -target arm64-apple-macos14.2 -D DEBUG
    -enable-upcoming-feature DisableOutwardActorInference
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature InferSendableFromCaptures
    -enable-upcoming-feature MemberImportVisibility
    -enable-upcoming-feature NonisolatedNonsendingByDefault
)
swiftc -o "$DERIVED/fake-assemblyai" scripts/fake-assemblyai.swift >/dev/null \
    && swiftc -parse-as-library "${app_swift_flags[@]}" -o "$DERIVED/transcription-check" \
        sherpa/SpeechAudio.swift sherpa/AssemblyAI.swift sherpa/Transcription.swift \
        scripts/transcription-check.swift >/dev/null \
    && "$DERIVED/transcription-check" "$DERIVED/fake-assemblyai" || failures=$((failures + 1))

fake_answer_delay=1.0
fake_ports="$DERIVED/fake-assemblyai.ports"
fake_capture="$DERIVED/fake-assemblyai.pcm"
fake_scenario="$DERIVED/fake-assemblyai.scenario"
rm -f "$fake_ports"
echo ok > "$fake_scenario"
"$DERIVED/fake-assemblyai" "$fake_ports" "$fake_capture" --answer-delay "$fake_answer_delay" \
    --scenario-file "$fake_scenario" >/dev/null &
fake_pid=$!
trap 'kill "$fake_pid" 2>/dev/null' EXIT
deadline=$((SECONDS + 10))
while [[ ! -s "$fake_ports" ]] && (( SECONDS < deadline )); do sleep 0.1; done
if [[ -s "$fake_ports" ]]; then
    read -r token_field socket_field < "$fake_ports"
    open -a "$APP" --args -AssemblyAITokenURL "${token_field#token=}" \
        -AssemblyAISocketURL "${socket_field#socket=}" -AssemblyAIAPIKey fake
else
    echo "  FAIL the fake AssemblyAI never wrote its ports"
    failures=$((failures + 1))
    fake_capture=""
    open -a "$APP"
fi
app_pid=""
# A cold first launch from a fresh build location takes longer than any fixed
# sleep worth writing, so wait for the icon to actually appear.
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    app_pid="$(pgrep -f "$APP/Contents/MacOS/sherpa" | head -1)"
    [[ -n "$app_pid" ]] \
        && [[ "$(proc 'to return position of menu bar item 1 of menu bar 2')" == *,* ]] \
        && break
    sleep 0.5
done
if [[ -z "$app_pid" ]]; then echo "the app never started"; exit 1; fi
echo "  info driving pid $app_pid from $DERIVED"

echo "status item"
item_pos="$(proc 'to return position of menu bar item 1 of menu bar 2')"
check "icon is in the menu bar" "yes" "$([[ "$item_pos" == *,* ]] && echo yes || echo no)"
check "no panel before the first click" "0" "$(proc 'to return count of windows')"

echo "open"
front_before="$(frontmost)"
proc 'to click menu bar item 1 of menu bar 2' >/dev/null
wait_for_windows 1
check "panel is on screen" "1" "$(proc 'to return count of windows')"
front_after="$(frontmost)"
check_focus_kept "the app in front keeps focus" "$front_before" "$front_after"
check "sherpa did not activate" "no" "$([[ "$front_after" == "sherpa" ]] && echo yes || echo no)"

# The menu bar moves on its own: it hides over a fullscreen app and follows the
# pointer between displays. Bracket the panel reading with two icon readings and
# only compare when the icon held still, so a bar that moved mid-measurement
# reports as unmeasured instead of as a failure.
item_before="$(proc 'to return position of menu bar item 1 of menu bar 2')"
read -r item_w item_h <<<"$(proc 'to return size of menu bar item 1 of menu bar 2' | tr ',' ' ')"
read -r panel_x panel_y <<<"$(proc 'to return position of window 1' | tr ',' ' ')"
read -r panel_w panel_h <<<"$(proc 'to return size of window 1' | tr ',' ' ')"
item_after="$(proc 'to return position of menu bar item 1 of menu bar 2')"
read -r item_x item_y <<<"${item_after//,/ }"
if [[ "$item_before" != "$item_after" ]]; then
    echo "  skip geometry checks: the menu bar moved from $item_before to $item_after mid-measurement"
    panel_x=0 panel_y=0 panel_w=0
elif [[ "$panel_x$panel_y$panel_w" =~ ^[0-9-]+$ ]]; then
    echo "  info icon at $item_x,$item_y sized ${item_w}x${item_h}; panel at $panel_x,$panel_y sized ${panel_w}x${panel_h}"
    # Accessibility reports a top-left origin with y growing downward, so a
    # panel below the icon has the larger y.
    check "panel hangs below the icon" "yes" "$([[ $panel_y -gt $item_y ]] && echo yes || echo no)"
    check "panel is centred on the icon" "yes" \
        "$([[ $(( panel_x + panel_w / 2 - item_x - item_w / 2 )) -le 2 ]] && echo yes || echo no)"
else
    echo "  skip geometry checks: no panel to measure"
    panel_x=0 panel_y=0 panel_w=0 panel_h=0 panel_h=0
fi

echo "hold to talk"
swift "$(dirname "$0")/hold-to-talk-check.swift" "$app_pid" ${fake_capture:+"$fake_capture" "$fake_scenario"} \
    || failures=$((failures + 1))
check_focus_kept "focus still behind after using the panel" "$front_before" "$(frontmost)"

echo "close"
proc 'to click menu bar item 1 of menu bar 2' >/dev/null
wait_for_windows 0
check "a second click closes the panel" "0" "$(proc 'to return count of windows')"

echo "outside click"
if [[ $panel_w -eq 0 ]]; then
    echo "  skip outside click: the geometry to aim at was not measured"
else
    proc 'to click menu bar item 1 of menu bar 2' >/dev/null
    wait_for_windows 1
    check "panel is open before the outside click" "1" "$(proc 'to return count of windows')"
    swift "$(dirname "$0")/menu-bar-tracking-check.swift" outside-click "$app_pid" \
        || failures=$((failures + 1))
    check "sherpa did not activate over the outside click" "no" \
        "$([[ "$(frontmost)" == "sherpa" ]] && echo yes || echo no)"
    close_panel_if_open
fi

echo "icon click"
if [[ $panel_w -eq 0 ]]; then
    echo "  skip icon click: the geometry to aim at was not measured"
else
    proc 'to click menu bar item 1 of menu bar 2' >/dev/null
    wait_for_windows 1
    check "panel is open before the icon click" "1" "$(proc 'to return count of windows')"
    swift "$(dirname "$0")/menu-bar-tracking-check.swift" icon-click "$app_pid" \
        || failures=$((failures + 1))
    check "sherpa did not activate over the icon click" "no" \
        "$([[ "$(frontmost)" == "sherpa" ]] && echo yes || echo no)"
    close_panel_if_open
fi

echo "menu bar over a fullscreen app"
# Cannot be checked here: that the menu bar actually stays down. The reveal is
# edge-triggered on real pointer movement, and warping the cursor does not
# generate it. What is checked is that the app claims and releases the pin.
swift "$(dirname "$0")/menu-bar-tracking-check.swift" toggle "$app_pid" || failures=$((failures + 1))

# Not checked here: right-click on the icon opens the Quit Sherpa menu. The
# Accessibility API exposes no right-click on a status item, though the posted
# CGEvents the clicking modes use could drive one. Confirm it by hand once after
# changing the click routing.

mkdir -p "$DERIVED/shots"
proc 'to click menu bar item 1 of menu bar 2' >/dev/null
wait_for_windows 1
screencapture -x -R"$((panel_x - 40)),$((panel_y - 40)),$((panel_w + 80)),$((panel_h + 80))" "$DERIVED/shots/panel.png"
echo "  info corners and shadow: $DERIVED/shots/panel.png"

# Tear down by quitting with the panel still open, which is the path that
# strands the pin if applicationWillTerminate does not release it.
swift "$(dirname "$0")/menu-bar-tracking-check.swift" quit "$app_pid" || failures=$((failures + 1))
pkill -f "$DERIVED" 2>/dev/null
if [[ $failures -eq 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; fi
exit $failures
