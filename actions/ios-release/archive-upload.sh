#!/usr/bin/env bash
# Archive, export and upload to App Store Connect; on a version conflict bump the
# marketing version, upload THAT build, and leave the bump in the working tree for
# the version-bump PR (outputs: bumped, old-version, new-version).
#
# Every path is per job ($RUNNER_TEMP): fixed /tmp and ~/Desktop paths were
# overwritten by other apps' deploys running at the same time on the Mac mini
# (cadence lost an upload to another app's ExportOptions).
set -euo pipefail
# Self-hosted runners' .path may be just /usr/bin:/bin:/usr/sbin:/sbin (peek's is), so
# Homebrew tools (gh, pod, python3) are not found: put the usual prefixes first.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { echo "::error title=Missing tool::'$t' is not on PATH ($PATH) on runner ${RUNNER_NAME:-?}. Install it (brew install $t) or fix the runner's .path."; exit 127; }
  done
}
require_tools xcodebuild python3 sed grep
: "${PROJECT:?}" "${SCHEME:?}" "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
SIGNING="$ACTION_ROOT/ios-signing/ios_manual_signing.py"
WORK="$RUNNER_TEMP/ios-release"
mkdir -p "$WORK"
EXPORT_OPTIONS="$WORK/ExportOptions.plist"
ARCHIVE="$WORK/${ARCHIVE_NAME:-$SCHEME}.xcarchive"
EXPORT_DIR="$WORK/export"
PBXPROJ="$PROJECT/project.pbxproj"

if [ -n "${WORKSPACE:-}" ]; then CONTAINER=(-workspace "$WORKSPACE"); else CONTAINER=(-project "$PROJECT"); fi
# shellcheck disable=SC2206  # extra xcodebuild args are word-split on purpose
EXTRA=(${XCODEBUILD_ARGS:-})
PINS=()
while IFS= read -r pin; do
  pin="$(echo "$pin" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$pin" ] || PINS+=(--profile "$pin")
done <<< "${PROFILES:-}"

MARKER="$WORK/.started"; touch "$MARKER"
DIAG="$RUNNER_TEMP/ios-release-diagnostics"

# On an export/upload failure, surface what Xcode wrote elsewhere: the
# .xcdistributionlogs bundle (IDEDistribution logs) and any xcodebuild crash report
# since this step started (the AppSSO SIGTRAP shows up only there).
diagnose() {
  mkdir -p "$DIAG"
  echo "::group::Export diagnostics"
  local logs
  logs=$( { echo "${OUTPUT:-}" | grep -oE '/[^ "]*\.xcdistributionlogs' || true
            find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name '*.xcdistributionlogs' -newer "$MARKER" 2>/dev/null || true; } | sort -u)
  for d in $logs; do
    [ -d "$d" ] || continue
    echo "== $d"; ls -la "$d"
    # Only the standard/critical logs are kept: the verbose log carries full
    # request traces, and artifacts of public repos are readable by anyone.
    for f in "$d"/IDEDistribution.standard.log "$d"/IDEDistribution.critical.log; do
      [ -f "$f" ] || continue
      echo "-- tail $f"; tail -60 "$f"
      cp "$f" "$DIAG/$(basename "$d")-$(basename "$f")" 2>/dev/null || true
    done
  done
  [ -n "$logs" ] || echo "no .xcdistributionlogs found"
  local crashes
  crashes=$(find ~/Library/Logs/DiagnosticReports -maxdepth 1 -newer "$MARKER" \( -name 'xcodebuild*' -o -name 'IDEDistribution*' -o -name 'AppSSO*' \) 2>/dev/null || true)
  for c in $crashes; do
    echo "== crash report $c"; head -80 "$c"; cp "$c" "$DIAG/" 2>/dev/null || true
  done
  [ -n "$crashes" ] || echo "no xcodebuild crash report since this step started"
  echo "::endgroup::"
}

sign_apply() {
  python3 -B "$SIGNING" apply "$PROJECT" --export-options "$EXPORT_OPTIONS" \
    --platform "${PLATFORM:-ios}" ${PINS[@]+"${PINS[@]}"}
}
sign_revert() { python3 -B "$SIGNING" revert "$PROJECT"; }

archive_and_upload() {
  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  xcodebuild archive "${CONTAINER[@]}" \
    -scheme "$SCHEME" \
    -destination "${DESTINATION:-generic/platform=iOS}" \
    -archivePath "$ARCHIVE" \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    -quiet
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

sign_apply
set +e
OUTPUT=$(archive_and_upload 2>&1)
STATUS=$?
set -e
# Always show the full output: a swallowed error here once cost a whole run.
echo "$OUTPUT"
echo "archive/export exit status: $STATUS"
if [ "$STATUS" -eq 0 ]; then echo "bumped=false" >> "$GITHUB_OUTPUT"; exit 0; fi

if ! echo "$OUTPUT" | grep -qi "version.*already exists\|already been uploaded\|redundant binary\|train.*closed\|higher version"; then
  diagnose
  exit "$STATUS"
fi

# The version already exists (or its train is closed): bump and upload again.
sign_revert
CURRENT=$(grep -m 1 'MARKETING_VERSION' "$PBXPROJ" | sed 's/.*= *\(.*\);/\1/; s/"//g')
NEW_VERSION=$(python3 - "$CURRENT" "${BUMP:-patch}" <<'PY'
import sys
cur, part = sys.argv[1], sys.argv[2]
nums = [int(x) for x in cur.split(".")]
while len(nums) < 3:
    nums.append(0)
if part == "minor":
    nums = [nums[0], nums[1] + 1, 0]
elif part == "patch":
    nums = [nums[0], nums[1], nums[2] + 1]
else:
    sys.exit(f"bump must be patch or minor, not {part}")
# Keep two-component versions two-component on a minor bump (2.7 -> 2.8).
if part == "minor" and len(cur.split(".")) == 2:
    nums = nums[:2]
print(".".join(map(str, nums)))
PY
)
echo "::notice title=Version bumped::$CURRENT already exists in App Store Connect; uploading build ${BUILD_NUM:-?} as $NEW_VERSION"
sed -i '' "s/MARKETING_VERSION = \"\{0,1\}${CURRENT}\"\{0,1\};/MARKETING_VERSION = ${NEW_VERSION};/g" "$PBXPROJ"
grep -q "MARKETING_VERSION = ${NEW_VERSION};" "$PBXPROJ" || { echo "::error::failed to write MARKETING_VERSION $NEW_VERSION"; exit 1; }

# Upload the bumped build FIRST, so a rejected push can never leave App Store
# Connect without a build for this commit.
sign_apply
OUTPUT=""
archive_and_upload || { STATUS=$?; diagnose; exit "$STATUS"; }
sign_revert
{
  echo "bumped=true"
  echo "old-version=$CURRENT"
  echo "new-version=$NEW_VERSION"
  echo "files=$PBXPROJ"
} >> "$GITHUB_OUTPUT"
