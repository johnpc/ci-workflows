#!/usr/bin/env bash
# Record a marketing-version bump the deploy already uploaded. Order matters: the
# caller uploads the bumped build FIRST, so a rejected push can never leave App Store
# Connect without a build; this only persists the bump in git.
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
require_tools gh git
BUILD_NUM="${BUILD_NUM_INPUT:-${BUILD_NUM:-unknown}}"
BASE="${BASE_INPUT:-}"
[ -n "$BASE" ] || BASE=$(gh repo view "$GITHUB_REPOSITORY" --json defaultBranchRef --jq .defaultBranchRef.name)
BRANCH="ci/bump-version-${NEW_VERSION}"
TITLE="chore(release): bump version to ${NEW_VERSION}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -B "$BRANCH"
# shellcheck disable=SC2086  # FILES is a space-separated list on purpose
git add -- $FILES
git commit -m "$TITLE"

BODY="Automated by the iOS deploy (${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}): ${OLD_VERSION} already exists in App Store Connect, so build ${BUILD_NUM} was uploaded as ${NEW_VERSION}. This PR records that bump."

# Base the bump on the CURRENT base branch. If main moved during the deploy, a branch
# cut from the old commit is behind, and when the move touched .github/workflows,
# GitHub refuses GITHUB_TOKEN's push of it outright ("refusing to allow a GitHub App
# to create or update workflow ... without workflows permission").
if [ "${BUMP_REBASE:-true}" = "true" ]; then
  git fetch -q --deepen=100 origin 2>/dev/null || true
  git fetch -q origin "$BASE"
  if ! git merge-base --is-ancestor "origin/$BASE" HEAD; then
    if git rebase -q "origin/$BASE"; then
      echo "rebased the bump onto the current $BASE ($(git rev-parse --short "origin/$BASE"))"
    else
      git rebase --abort || true
      echo "::error::the bump to $NEW_VERSION (build $BUILD_NUM) conflicts with the current $BASE; it is uploaded but NOT recorded in git. Set MARKETING_VERSION = $NEW_VERSION by hand."
      exit 1
    fi
  fi
fi

if ! git push -f -u origin "$BRANCH"; then
  echo "::error::could not push $BRANCH; the bump to $NEW_VERSION (build $BUILD_NUM) is uploaded but NOT recorded in git"
  exit 1
fi

if ! URL=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY" 2>&1); then
  # Usually "GitHub Actions is not permitted to create or approve pull requests"
  # (repo setting). An unprotected base still takes a direct push; a protected one
  # must not be bypassed, so fail loudly there.
  echo "$URL"
  if git fetch -q --depth=50 origin "$BASE" && git rebase -q "origin/$BASE" && git push origin "HEAD:$BASE"; then
    echo "::warning title=Version bump pushed directly::could not open a PR ($URL); pushed $TITLE straight to $BASE. Enable 'Allow GitHub Actions to create and approve pull requests' to get the PR flow."
    git push origin --delete "$BRANCH" || true
    echo "pr-url=" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  echo "::error::could not open the bump PR or push to $BASE; $BRANCH holds the bump to $NEW_VERSION (build $BUILD_NUM)"
  exit 1
fi
URL=$(echo "$URL" | tail -1)
echo "opened $URL"
echo "pr-url=$URL" >> "$GITHUB_OUTPUT"

# Protected base: let GitHub merge it once the required checks pass. A PR opened
# with GITHUB_TOKEN starts no pull_request workflows, so dispatch CI on the branch
# (its check runs land on the same commit and satisfy the required checks).
# A strict protected main ("require branches to be up to date") never auto-merges a
# branch that is behind, and auto-merge does not update it: if main moved during the
# deploy, update the branch first (then the dispatched CI runs on the updated head).
merge_state() { gh pr view "$URL" --json mergeStateStatus --jq .mergeStateStatus; }
STATE=UNKNOWN
for _ in 1 2 3 4 5 6; do
  STATE=$(merge_state || echo UNKNOWN)
  [ "$STATE" != "UNKNOWN" ] && break
  sleep 5  # GitHub computes mergeability asynchronously right after creation
done
echo "merge state: $STATE"
if [ "$STATE" = "BEHIND" ]; then
  gh pr update-branch "$URL"
  echo "updated $BRANCH with $BASE (main moved during the deploy)"
fi

if gh pr merge "$URL" --auto --squash --delete-branch 2>/tmp/bump-merge.$$; then
  STATE=$(gh pr view "$URL" --json state --jq .state)
  echo "auto-merge requested (state: $STATE)"
  if [ "$STATE" != "MERGED" ] && [ -n "${CI_WORKFLOW:-}" ]; then
    gh workflow run "$CI_WORKFLOW" --ref "$BRANCH"
    echo "dispatched $CI_WORKFLOW on $BRANCH for the required checks"
  fi
  exit 0
fi
cat /tmp/bump-merge.$$ >&2 || true
# Unprotected base (auto-merge is unavailable without required checks): merge now.
gh pr merge "$URL" --squash --delete-branch
echo "merged $URL"
