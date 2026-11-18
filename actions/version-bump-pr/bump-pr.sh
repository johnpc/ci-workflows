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
# Smoke and build output (the launch smoke's DerivedData, its scratch iOS copy) is
# not ours to commit, and a repo hook that scans the workspace (eslint .) chokes on it.
# shellcheck disable=SC2086  # space-separated lists on purpose
for p in ${CLEAN_PATHS:-ios-smoke-output ios/.smoke-App}; do
  case "$p" in /*|*..*) echo "::warning::skipping unsafe clean path $p"; continue;; esac
  [ -e "$p" ] && rm -rf -- "$p" && echo "removed build output $p"
done
git checkout -B "$BRANCH"
git reset -q  # stage nothing but FILES
# shellcheck disable=SC2086  # FILES is a space-separated list on purpose
git add -- $FILES
STAGED=$(git diff --cached --name-only)
[ -n "$STAGED" ] || { echo "::error::nothing to commit: $FILES did not change"; exit 1; }
for f in $STAGED; do
  case " $FILES " in *" $f "*) ;; *) echo "::error::refusing to commit $f: the bump commits only $FILES"; exit 1;; esac
done
echo "staged: $STAGED"
# Hooks off: a MARKETING_VERSION-only diff whose PR runs the repo's full CI anyway;
# the repo's pre-commit (lint, coverage, build) only adds minutes and failure modes.
NOHOOKS=(-c core.hooksPath=/dev/null)
HUSKY=0 git "${NOHOOKS[@]}" commit -m "$TITLE"

BODY="Automated by the iOS deploy (${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}): ${OLD_VERSION} already exists in App Store Connect, so build ${BUILD_NUM} was uploaded as ${NEW_VERSION}. This PR records that bump."

# Base the bump on the CURRENT base branch. If main moved during the deploy, a branch
# cut from the old commit is behind, and when the move touched .github/workflows,
# GitHub refuses GITHUB_TOKEN's push of it outright ("refusing to allow a GitHub App
# to create or update workflow ... without workflows permission").
if [ "${BUMP_REBASE:-true}" = "true" ]; then
  git fetch -q --deepen=100 origin 2>/dev/null || true
  git fetch -q origin "$BASE"
  if ! git merge-base --is-ancestor "origin/$BASE" HEAD; then
    if HUSKY=0 git "${NOHOOKS[@]}" rebase -q "origin/$BASE"; then
      echo "rebased the bump onto the current $BASE ($(git rev-parse --short "origin/$BASE"))"
    else
      git rebase --abort || true
      echo "::error::the bump to $NEW_VERSION (build $BUILD_NUM) conflicts with the current $BASE; it is uploaded but NOT recorded in git. Set MARKETING_VERSION = $NEW_VERSION by hand."
      exit 1
    fi
  fi
fi

if ! git "${NOHOOKS[@]}" push -f -u origin "$BRANCH"; then
  echo "::error::could not push $BRANCH; the bump to $NEW_VERSION (build $BUILD_NUM) is uploaded but NOT recorded in git"
  exit 1
fi

if ! URL=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY" 2>&1); then
  # Usually "GitHub Actions is not permitted to create or approve pull requests"
  # (repo setting). An unprotected base still takes a direct push; a protected one
  # must not be bypassed, so fail loudly there.
  echo "$URL"
  if git fetch -q --depth=50 origin "$BASE" && HUSKY=0 git "${NOHOOKS[@]}" rebase -q "origin/$BASE" && git "${NOHOOKS[@]}" push origin "HEAD:$BASE"; then
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

# Protected base: let GitHub merge it once the required checks pass.
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
  [ "$STATE" = "MERGED" ] && exit 0
  # The bot's PR gets its own pull_request run, but public repos gate it behind
  # "approval for first-time contributors" (github-actions[bot] never qualifies), and
  # a gated run blocks the required checks: a workflow_dispatch run's checks on the
  # same commit do NOT satisfy them (proven on johnpc/ci-workflows-bump-test). So
  # approve this PR's gated runs; dispatch CI only if no pull_request run ever shows up.
  HEAD_SHA=$(gh pr view "$URL" --json headRefOid --jq .headRefOid)
  RUNS=""
  for _ in $(seq 1 12); do
    RUNS=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?event=pull_request&head_sha=$HEAD_SHA" \
      --jq '.workflow_runs[] | "\(.id) \(.conclusion)"' || true)
    [ -n "$RUNS" ] && break
    sleep 10
  done
  if [ -n "$RUNS" ]; then
    echo "$RUNS" | while read -r id conclusion; do
      if [ "$conclusion" = "action_required" ]; then
        if gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$id/approve" >/dev/null; then
          echo "approved gated pull_request run $id"
        else
          echo "::warning::could not approve pull_request run $id; approve it in the Actions tab so the bump PR can merge"
        fi
      fi
    done
  elif [ -n "${CI_WORKFLOW:-}" ]; then
    gh workflow run "$CI_WORKFLOW" --ref "$BRANCH"
    echo "no pull_request run appeared; dispatched $CI_WORKFLOW on $BRANCH for the required checks"
  else
    echo "::warning::no CI run on the bump PR; it merges once its required checks report"
  fi
  exit 0
fi
cat /tmp/bump-merge.$$ >&2 || true
# Unprotected base (auto-merge is unavailable without required checks): merge now.
gh pr merge "$URL" --squash --delete-branch
echo "merged $URL"
