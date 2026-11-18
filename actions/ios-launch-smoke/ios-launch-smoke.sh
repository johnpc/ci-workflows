#!/usr/bin/env bash
# iOS launch smoke: does the BUILT app actually start in a simulator and render
# its web view? Runs on the Mac mini (CI's iOS Deploy job, before the archive).
# Shared copy of the generic scene-kit script, used by the ios-launch-smoke action.
# Run it from the repository root (or set SMOKE_ROOT):
#
#   bash ios-launch-smoke.sh                     # build web + app, then check
#   SMOKE_WEB_BUILD=0 bash ios-launch-smoke.sh   # reuse the synced web bundle (CI)
#   bash ios-launch-smoke.sh cleanup             # remove this run's simulator
#
# Knobs (all optional): SMOKE_IOS_DIR (ios/App), SMOKE_SCHEME (App), SMOKE_BUNDLE_ID,
# SMOKE_WEB_BUILD_CMD ("npm run build"), SMOKE_REMOVE_PODS (space-separated pod
# names left out of a scratch copy of the iOS project for the simulator build, e.g.
# pods with no arm64 simulator slice), SMOKE_SIM_NAME, SMOKE_DEVICE_TYPE,
# SMOKE_LOAD_SECS, SMOKE_ALIVE_SECS, SMOKE_OUT, SMOKE_KEEP_SIM.
#
# WHY: apps built with the iOS 27 SDK and no UIScene manifest are killed by UIKit
# on their first frame (EXC_BREAKPOINT in
# _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption). Such a build still
# archives, uploads and passes every browser test, so nothing caught it before App
# Review or a user did (jpc.eats 4.0.0 rejected, jpc.countdowns 1.0.12 shipped
# broken). This starts the real binary. PASS requires, in a fresh simulator:
#   1. the built Info.plist declares UIApplicationSceneManifest;
#   2. the process starts and Capacitor logs "WebView loaded" within SMOKE_LOAD_SECS;
#   3. it is still alive SMOKE_ALIVE_SECS after launch;
#   4. no no-scene fault in the simulator log and no crash report for the bundle id.
# Built WITHOUT the debug dylib (ENABLE_DEBUG_DYLIB=NO) so the binary is laid out
# like the shipped one. Output (screenshot, app stdout, logs) lands in SMOKE_OUT.
#
# Mini traps this encodes (learned the hard way, 2026-11-17): no Rosetta simulators
# on Xcode 27, so arm64 only; `simctl launch --stdout=FILE` loses Swift print()
# output and fails silently on relative paths, so launch on a pty in the background;
# `simctl launch` right after install can race SpringBoard, so retry ~30 s; `log`
# echoes its own predicate, so exclude it; never touch the shared booted simulators.
set -euo pipefail
cd "${SMOKE_ROOT:-$PWD}"

IOS="${SMOKE_IOS_DIR:-ios/App}"
SCHEME="${SMOKE_SCHEME:-App}"
REMOVE_PODS="${SMOKE_REMOVE_PODS:-}"
BUNDLE_ID="${SMOKE_BUNDLE_ID:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["appId"])' "$IOS/App/capacitor.config.json" 2>/dev/null || sed -nE "s/.*appId: *[\x27\"]([^\x27\"]+).*/\1/p" capacitor.config.ts | head -1)}"
[ -n "$BUNDLE_ID" ] || { echo "ios-smoke: FAIL — could not determine the bundle id" >&2; exit 1; }
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
SIM_NAME="${SMOKE_SIM_NAME:-$REPO-launch-smoke}"
DEVICE_TYPE="${SMOKE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
LOAD_SECS="${SMOKE_LOAD_SECS:-120}"
ALIVE="${SMOKE_ALIVE_SECS:-20}"
OUT="${SMOKE_OUT:-ios-smoke-output}"
WEB_BUILD="${SMOKE_WEB_BUILD:-1}"

say() { echo "ios-smoke: $*"; }
fail() { echo "ios-smoke: FAIL — $*" >&2; exit 1; }

delete_sims() {
  for udid in $(xcrun simctl list devices | sed -n "s/^ *$SIM_NAME (\([0-9A-F-]*\)).*/\1/p"); do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" && say "deleted simulator $udid"
  done
}
if [ "${1:-}" = "cleanup" ]; then delete_sims; exit 0; fi

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
STARTED=$(date "+%Y-%m-%d %H:%M:%S")
MARKER="$OUT/.started"; touch "$MARKER"
UDID=""; SIMCTL_PID=""
cleanup() {
  # Screenshot BEFORE stopping the console-attached launch: ending it ends the app,
  # and a screenshot taken after shows SpringBoard instead of the app.
  if [ -n "$UDID" ]; then
    xcrun simctl io "$UDID" screenshot "$OUT/launch.png" >/dev/null 2>&1 && say "screenshot → $OUT/launch.png" || true
  fi
  [ -n "$SIMCTL_PID" ] && kill "$SIMCTL_PID" 2>/dev/null || true
  if [ -n "$UDID" ]; then
    if [ "${SMOKE_KEEP_SIM:-0}" != "1" ]; then
      xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
      xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

# ---- 1. Web bundle synced into the native project ---------------------------------
if [ "$WEB_BUILD" = "1" ]; then
  say "building the web app"
  ${SMOKE_WEB_BUILD_CMD:-npm run build} >"$OUT/web-build.log" 2>&1 || { tail -30 "$OUT/web-build.log" >&2; fail "web build failed"; }
  npx cap sync ios >"$OUT/cap-sync.log" 2>&1 || { tail -30 "$OUT/cap-sync.log" >&2; fail "cap sync failed"; }
fi
[ -f "$IOS/App/public/index.html" ] || fail "no synced web bundle at $IOS/App/public — run the web build + cap sync first"

# ---- 2. Fresh simulator + unsigned build ------------------------------------------
if [ -n "$REMOVE_PODS" ]; then
  # Some pods ship no arm64 SIMULATOR slice (e.g. Google ML Kit through 9.0.0 sets
  # EXCLUDED_ARCHS[sdk=iphonesimulator*]=arm64) and Xcode 27 has no Rosetta
  # simulators, so the shipped pod set cannot run in any simulator. Build the SAME
  # App target (sources, Info.plist, storyboards, project file, web bundle) from a
  # scratch copy with only those pods removed. It proves the native shell launches;
  # it cannot exercise the removed pods. The real $IOS/Pods is never touched.
  [ -f "$IOS/Podfile" ] || fail "SMOKE_REMOVE_PODS is set but $IOS has no Podfile"
  SMOKE_IOS="$(dirname "$IOS")/.smoke-$(basename "$IOS")"  # same depth: the Podfile's ../../node_modules paths still resolve
  rm -rf "$SMOKE_IOS"; mkdir -p "$SMOKE_IOS"
  rsync -a --exclude Pods --exclude '*.xcworkspace' --exclude build "$IOS/" "$SMOKE_IOS/"
  for pod in $REMOVE_PODS; do
    grep -q "$pod" "$SMOKE_IOS/Podfile" || fail "SMOKE_REMOVE_PODS names $pod but $IOS/Podfile does not use it"
    sed -i '' "/$pod/d" "$SMOKE_IOS/Podfile"
  done
  (cd "$SMOKE_IOS" && pod install >"$OUT/pod-install.log" 2>&1) || { tail -20 "$OUT/pod-install.log" >&2; fail "pod install (smoke copy) failed"; }
  cmp -s "$IOS/App/Info.plist" "$SMOKE_IOS/App/Info.plist" || fail "smoke copy drifted from $IOS"
  say "simulator build uses a scratch copy without: $REMOVE_PODS"
  PROJ=(-workspace "$SMOKE_IOS/App.xcworkspace")
elif [ -f "$IOS/Podfile" ]; then
  [ -d "$IOS/Pods" ] || (cd "$IOS" && pod install >"$OUT/pod-install.log" 2>&1) || { tail -20 "$OUT/pod-install.log" >&2; fail "pod install failed"; }
  PROJ=(-workspace "$IOS/App.xcworkspace")
else
  PROJ=(-project "$IOS/App.xcodeproj")  # Capacitor 8 Swift Package Manager layout
fi
delete_sims
UDID=$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE") || fail "simctl create failed"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null || fail "simulator never finished booting"
say "building $BUNDLE_ID for simulator $UDID"
xcodebuild "${PROJ[@]}" -scheme "$SCHEME" -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO build >"$OUT/xcodebuild.log" 2>&1 \
  || { grep -E "error:|BUILD FAILED" "$OUT/xcodebuild.log" | head -30 >&2; fail "xcodebuild failed (log: $OUT/xcodebuild.log)"; }
# The scheme is usually "App", but the product can be named after the target
# (e.g. "Small Crosswords.app"), so take whichever single .app the build produced.
APP=$(find "$OUT/DerivedData/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] && [ -d "$APP" ] || fail "no app bundle under $OUT/DerivedData/Build/Products/Debug-iphonesimulator"
# Launch what was BUILT: a Debug configuration may carry its own bundle id.
BUILT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" 2>/dev/null || true)
if [ -z "${SMOKE_BUNDLE_ID:-}" ] && [ -n "$BUILT_ID" ] && [ "$BUILT_ID" != "$BUNDLE_ID" ]; then
  say "built bundle id is $BUILT_ID (Capacitor appId $BUNDLE_ID) — launching the built one"; BUNDLE_ID="$BUILT_ID"
fi
/usr/libexec/PlistBuddy -c "Print :UIApplicationSceneManifest:UISceneConfigurations" "$APP/Info.plist" >/dev/null 2>&1 \
  || fail "the built Info.plist has no UIApplicationSceneManifest — iOS 27 will kill this app on launch"

# ---- 3. Install + launch ------------------------------------------------------------
xcrun simctl install "$UDID" "$APP" || fail "simctl install failed"
APP_PID=""
for _ in $(seq 1 10); do
  : >"$OUT/app.stdout"
  xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" >>"$OUT/app.stdout" 2>&1 &
  SIMCTL_PID=$!
  for _ in 1 2 3; do
    sleep 1
    APP_PID=$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v l="UIKitApplication:$BUNDLE_ID" '$0 ~ l && $1 ~ /^[0-9]+$/ {print $1; exit}')
    [ -n "$APP_PID" ] && break
    kill -0 "$SIMCTL_PID" 2>/dev/null || break
  done
  [ -n "$APP_PID" ] && break
  kill "$SIMCTL_PID" 2>/dev/null || true; wait "$SIMCTL_PID" 2>/dev/null || true
done
[ -n "$APP_PID" ] || { tail -5 "$OUT/app.stdout" >&2; fail "simctl launch never produced a running process within 30s"; }
LAUNCHED_AT=$(date +%s)
say "launched $BUNDLE_ID (pid $APP_PID)"

alive() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v p="$APP_PID" '$1 == p {f=1} END {exit !f}'; }

# ---- 4. The web view must load inside the native shell --------------------------
for _ in $(seq 1 "$LOAD_SECS"); do
  grep -q "WebView loaded" "$OUT/app.stdout" 2>/dev/null && break
  alive || { tail -20 "$OUT/app.stdout" >&2; fail "the app (pid $APP_PID) exited before its web view loaded — it did not launch"; }
  sleep 1
done
grep -q "WebView loaded" "$OUT/app.stdout" || fail "Capacitor never logged 'WebView loaded' within ${LOAD_SECS}s (see $OUT/app.stdout)"
say "web view loaded after $(( $(date +%s) - LAUNCHED_AT ))s"

# ---- 5. Still alive, no scene fault, no crash --------------------------------------
REMAINING=$((ALIVE - ($(date +%s) - LAUNCHED_AT))); [ "$REMAINING" -gt 0 ] && sleep "$REMAINING"
alive || fail "the app died within ${ALIVE}s of launch"
FAULT=$(xcrun simctl spawn "$UDID" log show --style compact --start "$STARTED" \
  --predicate '(eventMessage CONTAINS "NoSceneLifecycleAdoption" OR eventMessage CONTAINS "UIScene life cycle") AND process != "log"' 2>/dev/null \
  | grep -E "NoSceneLifecycleAdoption|UIScene life cycle" | grep -v "args:" | head -3 || true)
[ -z "$FAULT" ] || fail "UIKit refused the scene life cycle: $FAULT"
CRASHES=$(find ~/Library/Logs/DiagnosticReports -maxdepth 1 -newer "$MARKER" -name "*.ips" -exec grep -l "\"$BUNDLE_ID\"" {} + 2>/dev/null || true)
[ -z "$CRASHES" ] || fail "crash report(s) for $BUNDLE_ID since launch: $CRASHES"
say "PASS — launched, web view loaded, alive after ${ALIVE}s, no scene fault or crash"
