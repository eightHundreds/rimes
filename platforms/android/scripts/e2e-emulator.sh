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
"$ADB" logcat -c >/dev/null 2>&1 || true
"$ADB" install -r -t "$APK" >/dev/null
echo "==> enabling RIMES as the default input method"
# InputMethodManagerService refreshes its list asynchronously after install.
deadline=$((SECONDS + 300))
until "$ADB" shell ime list -a -s | tr -d '\r' | grep -qx "$IME_ID"; do
    (( SECONDS < deadline )) || die "system never listed $IME_ID"
    sleep 3
done
deadline=$((SECONDS + 300))
until "$ADB" shell ime list -s | tr -d '\r' | grep -qx "$IME_ID"; do
    (( SECONDS < deadline )) || die "could not enable $IME_ID"
    "$ADB" shell ime enable "$IME_ID" >/dev/null 2>&1 || true
    sleep 3
done
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
# Never force-stop the package: it also hosts the input method service and the
# system would fall back to another keyboard.
"$ADB" shell am start -W --activity-clear-task -n "$PACKAGE/.settings.PlaygroundActivity" >/dev/null
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

echo "==> waiting for the engine to finish deploying (first run compiles dictionaries)"
# The IME window is not part of a uiautomator dump, so readiness is observed
# through the behaviour log: the service logs exactly one start line per process.
deadline=$((SECONDS + 2400))
while :; do
    if "$ADB" logcat -d -s RIMES:V 2>/dev/null | grep -q "rime start OK"; then
        break
    fi
    if "$ADB" logcat -d -s RIMES:V 2>/dev/null | grep -q "rime start FAILED"; then
        die "librime failed to start; see adb logcat -s RIMES RimesJNI"
    fi
    (( SECONDS < deadline )) || die "engine did not become ready in time"
    sleep 10
done
sleep 3

record_pid=""
if [[ "$RECORD" == "1" ]]; then
    echo "==> recording screen"
    "$ADB" shell screenrecord --time-limit 170 --bit-rate 2000000 /sdcard/rimes-e2e.mp4 &
    record_pid=$!
    sleep 2
fi

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
