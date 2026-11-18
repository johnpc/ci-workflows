#!/usr/bin/env bash
# Unlock the CI signing keychain unless it already is. `security show-keychain-info`
# succeeds only for an unlocked keychain in the current security session (a locked
# one answers "User interaction is not allowed"), so it is the no-op test. Left
# locked, codesign finds the Apple Distribution identity and waits forever for a
# password prompt nobody can answer.
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
require_tools security
KC="${KC_INPUT:-}"
[ -n "$KC" ] || KC="$HOME/Library/Keychains/ci-signing.keychain-db"
[ -f "$KC" ] || { echo "::error::CI keychain $KC does not exist on this runner"; exit 1; }

unlock_here() {
  if security show-keychain-info "$KC" >/dev/null 2>&1; then
    echo "keychain already unlocked: $KC"
    return 0
  fi
  [ -n "${CI_KEYCHAIN_PASSWORD:-}" ] || { echo "::error::$KC is locked and no password was given (pass secrets.CI_KEYCHAIN_PASSWORD)"; exit 1; }
  security unlock-keychain -p "$CI_KEYCHAIN_PASSWORD" "$KC"
  echo "unlocked $KC"
}
unlock_here

# Runner jobs live in the *system* launchd context, where macOS uses the system-domain
# keychain search list. The CI keychain was added there once during setup.
security list-keychains | grep -q "$(basename "$KC")" || {
  echo "::error::CI keychain missing from the search list. Fix once: sudo security list-keychains -d system -s /Library/Keychains/System.keychain $KC"
  exit 1
}

if [ "${USER_SESSION:-false}" = "true" ]; then
  [ -n "${CI_KEYCHAIN_PASSWORD:-}" ] || { echo "::error::user-session unlock needs the keychain password"; exit 1; }
  sudo -n launchctl asuser "$(id -u)" sudo -n -u "$(id -un)" env HOME="$HOME" \
    security unlock-keychain -p "$CI_KEYCHAIN_PASSWORD" "$KC"
  echo "unlocked $KC in the user session too"
fi
