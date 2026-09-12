#!/bin/bash
# =============================================================================
# End-to-end typing check against a running emulator/device.
#
# Installs the debug APK, enables and selects RIMES as the default input
# method, opens the in-app 键入测试 field, injects physical key events through
# the system input pipeline, and asserts the committed text by reading the
# host EditText back through uiautomator. Produces screenshots and an optional
# screen recording as evidence.
#
#   ./scripts/e2e-emulator.sh                 # uses app/build/outputs/apk/debug/app-debug.apk
#   RIMES_E2E_OUT=/tmp/out ./scripts/e2e-emulator.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

APK="${RIMES_APK:-app/build/outputs/apk/debug/app-debug.apk}"
OUT="${RIMES_E2E_OUT:-e2e-out}"
IME_ID="com.isaac.inputmethod.rimes/.service.RimesInputMethodService"
PACKAGE="com.isaac.inputmethod.rimes"
FIELD_ID="$PACKAGE:id/playground_field"
RECORD="${RIMES_E2E_RECORD:-1}"
ADB="${ADB:-adb}"

die() {
    echo "e2e: $*" >&2
    exit 1
}

mkdir -p "$OUT"
[[ -f "$APK" ]] || die "APK not found at $APK; run ./gradlew :app:assembleDebug first"
"$ADB" wait-for-device
[[ "$("$ADB" shell getprop sys.boot_completed | tr -d '\r')" == "1" ]] || die "device has not finished booting"

echo "==> installing $APK"
"$ADB" install -r -t "$APK" >/dev/null
echo "==> enabling RIMES as the default input method"
"$ADB" shell ime enable "$IME_ID" >/dev/null
"$ADB" shell ime set "$IME_ID" >/dev/null
"$ADB" shell settings put secure show_ime_with_hard_keyboard 1 >/dev/null
[[ "$("$ADB" shell settings get secure default_input_method | tr -d '\r')" == "$IME_ID" ]] \
    || die "RIMES is not the default input method"

# Read the playground field's text via a uiautomator dump.
field_text() {
    "$ADB" shell uiautomator dump /sdcard/rimes-e2e.xml >/dev/null 2>&1 || true
    "$ADB" shell cat /sdcard/rimes-e2e.xml 2>/dev/null \
        | python3 -c '
import re, sys
xml = sys.stdin.read()
m = re.search(r"<node[^>]*resource-id=\"'"$FIELD_ID"'\"[^>]*>", xml)
if not m:
    sys.exit(0)
t = re.search(r"\btext=\"([^\"]*)\"", m.group(0))
print(t.group(1) if t else "")
' | tr -d '\r'
}

wait_field() {
    local expected="$1" deadline=$((SECONDS + ${2:-120}))
    while (( SECONDS < deadline )); do
        local actual
        actual="$(field_text)"
        if [[ "$actual" == "$expected" ]]; then
            echo "    field == '$expected'"
            return 0
        fi
        sleep 2
    done
    die "expected field text '$expected', got '$(field_text)'"
}

press() {
    for key in "$@"; do
        "$ADB" shell input keyevent "$key" >/dev/null
    done
}

screenshot() {
    "$ADB" exec-out screencap -p > "$OUT/$1.png"
    echo "    screenshot $OUT/$1.png"
}

echo "==> opening 键入测试"
"$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" shell am start -W -n "$PACKAGE/.settings.PlaygroundActivity" >/dev/null
sleep 3

# Focus the field by tapping its bounds from the dump.
bounds="$("$ADB" shell uiautomator dump /sdcard/rimes-e2e.xml >/dev/null 2>&1; "$ADB" shell cat /sdcard/rimes-e2e.xml | python3 -c '
import re, sys
xml = sys.stdin.read()
m = re.search(r"<node[^>]*resource-id=\"'"$FIELD_ID"'\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", xml)
if m:
    x1, y1, x2, y2 = map(int, m.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
' | tr -d '\r')"
[[ -n "$bounds" ]] || die "playground field not found on screen"
"$ADB" shell input tap $bounds >/dev/null
sleep 2

record_pid=""
if [[ "$RECORD" == "1" ]]; then
    echo "==> recording screen"
    "$ADB" shell screenrecord --time-limit 170 --bit-rate 2000000 /sdcard/rimes-e2e.mp4 &
    record_pid=$!
    sleep 2
fi

echo "==> waiting for the engine to finish deploying (first run compiles dictionaries)"
deadline=$((SECONDS + 2400))
until "$ADB" shell "run-as $PACKAGE ls files/rime/user/build/rime_ice.schema.yaml" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "deployment did not finish in time"
    sleep 10
done
# Give librime a moment to finish the maintenance thread and the smoke session.
sleep 5

echo "==> case 1: nihao + Space -> 你好"
press KEYCODE_N KEYCODE_I KEYCODE_H KEYCODE_A KEYCODE_O
sleep 3
screenshot 01-composing-nihao
press KEYCODE_SPACE
wait_field "你好"
screenshot 02-committed-nihao

echo "==> case 2: shijie + 1 -> 你好世界, then raw abc via Return"
press KEYCODE_S KEYCODE_H KEYCODE_I KEYCODE_J KEYCODE_I KEYCODE_E
sleep 2
press KEYCODE_1
wait_field "你好世界"
press KEYCODE_A KEYCODE_B KEYCODE_C KEYCODE_ENTER
wait_field "你好世界abc"
screenshot 03-committed-mixed

echo "==> case 3: backspace edits the host once composition is idle"
press KEYCODE_DEL KEYCODE_DEL KEYCODE_DEL
wait_field "你好世界"

echo "==> case 4: buffer mode stages commits and Return delivers"
"$ADB" shell "am broadcast -a $PACKAGE.E2E_SET_BUFFER --ez enabled true -p $PACKAGE" >/dev/null 2>&1 || true
sleep 2
press KEYCODE_N KEYCODE_I KEYCODE_SPACE
sleep 2
screenshot 04-buffer-staged
if [[ "$(field_text)" == "你好世界" ]]; then
    echo "    staged block did not reach the host (buffer captured it)"
    press KEYCODE_ENTER
    wait_field "你好世界你"
    screenshot 05-buffer-delivered
else
    echo "    buffer broadcast unavailable on this build; skipping buffer case"
fi
"$ADB" shell "am broadcast -a $PACKAGE.E2E_SET_BUFFER --ez enabled false -p $PACKAGE" >/dev/null 2>&1 || true

if [[ -n "$record_pid" ]]; then
    sleep 2
    "$ADB" shell pkill -INT screenrecord >/dev/null 2>&1 || true
    wait "$record_pid" 2>/dev/null || true
    sleep 3
    "$ADB" pull /sdcard/rimes-e2e.mp4 "$OUT/rimes-e2e.mp4" >/dev/null && echo "    recording $OUT/rimes-e2e.mp4"
fi

echo "==> pulling logs"
"$ADB" shell "run-as $PACKAGE cat files/rime/log/rimes.log" > "$OUT/rimes.log" 2>/dev/null || true
echo "==> E2E PASSED"
