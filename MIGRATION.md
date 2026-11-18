# Migrating a repo to johnpc/ci-workflows

Each repo keeps ONE owner: the repo's own agent does its migration, in its own PR,
CI green, then proves the first deploy (launch-smoke screenshot looked at, log says
`Upload succeeded`). Nothing here submits to App Store review.

Pilots (done, proven end to end):

| Repo | Caller | PR |
| --- | --- | --- |
| svelte-crossword (Capacitor, unprotected) | `ios-deploy-capacitor.yml@v1` | johnpc/svelte-crossword#55 |
| jpc.finance.native (native, private, unprotected) | `ios-deploy-native.yml@v1` | johnpc/jpc.finance.native#33 |

## Branch protection (verified against the API, 2026-11-18)

| Repo | main protected | strict | required checks | auto-merge allowed |
| --- | --- | --- | --- | --- |
| cadence | yes | yes | 16 (`Lint, Test, Coverage, CRAP & Build`, `iOS Swift Tests`, 14× `Acceptance Tests (<area>)`) | yes |
| jpc-noms | yes | yes | 16 | yes |
| jpc.fit.native | yes | yes | 5 | yes |
| pipe | yes | yes | 4 (`Build`, `Unit Tests + Coverage`, `CRAP Score Analysis`, `Acceptance`) | yes |
| jpc-countdowns | yes | yes | 2 (`test`, `ios-launch`) | yes |
| peek | yes | yes | 1 (`Build · Unit Tests · Coverage · CRAP · Acceptance`) | yes |
| telly-apple | yes | yes | 1 (`Quality gates`) | yes |
| svelte-crossword, jpc.finance.native, jpc-since, flashstack, phrasepack, spork, stickies, taskflow, travel, holiday-hue, stoop, jpc.eats.native, cadence-ios | no | — | — | no |

No repo uses rulesets. Every protected repo needs the protected-repo bump setup below
(see "Protected repos: the bump PR" below).

## Checklist (every repo)

1. Branch from main. Replace the workflow file(s) with the caller YAML below; delete
   what the shared copy replaces (`scripts/ios-launch-smoke.sh` unless the repo has its
   own smoke, `scripts/ci_manual_signing.py`, inline cert-revoke / external-beta
   Python). Keep the repo's own `prod-config` / `sandbox.mjs` scripts: they stay the
   per-repo logic (the Amplify-deploy race retry lives in `prod-config`).
2. Grant the caller permissions: iOS deploys need `contents: write`,
   `pull-requests: write`, `actions: write` (a reusable job can never exceed them).
3. `secrets: inherit` (the reusables also read `secret-env` names from it).
4. `actionlint` the caller (labels `mac-mini`, `mac-mini-light` are self-hosted).
5. PR → CI green → merge (`gh pr merge --squash --delete-branch`) — except protected
   repos, see their notes (required-check names change).
6. Prove the deploy: the run after merge (or `gh workflow run "iOS Deploy"`), download
   the `ios-launch-smoke` artifact, LOOK at `launch.png`, grep the log for
   `Upload succeeded`. Expect a possible patch/minor bump PR.
7. Report the PR, run URL and evidence back to the parent.

### Things that change vs the old copies

- **Version bump**: no more `git push origin main` / `[skip ci]`. The bump lands as
  `ci/bump-version-<v>` → PR → merges itself (auto-merge on protected main, immediate
  squash merge on unprotected main). If the repo has *Allow GitHub Actions to create
  and approve pull requests* OFF (true today for svelte-crossword, jpc.finance.native,
  peek and most repos), PR creation fails and the action pushes the commit straight to
  an UNPROTECTED main with a warning; on a protected main it fails loudly after the
  upload succeeded. A bot-merged bump triggers no workflows (same as `[skip ci]`).
- **Protected repos: the bump PR** (proven end to end on the scratch repo
  johnpc/ci-workflows-bump-test, strict protected main, PRs #1-#3). The bot's PR DOES
  get its own `pull_request` run, but on public repos it is gated by "approval for
  first-time contributors", and a gated run blocks the required checks: a
  `workflow_dispatch` run's checks on the same commit do NOT count (PR #1 stayed
  BLOCKED until its run was approved). `version-bump-pr` therefore approves its own
  PR's gated runs (needs `actions: write`), runs `gh pr update-branch` when the PR is
  BEHIND a strict main, and first rebases the bump onto the current main (a branch cut
  from the old commit is refused outright when main's move touched
  `.github/workflows`). `ci-workflow:` is only a fallback for when no PR run appears.
  Each protected repo needs: *Allow GitHub Actions to create and approve pull
  requests* ON, *Allow auto-merge* ON (already on for all seven), and CI jobs whose
  owner guard admits `github-actions[bot]` — a job skipped by `if:` reports as passing,
  so a johnpc-only guard (peek, pipe) lets the bump merge untested (acceptable for a
  version-only change, but know it). A `DEPLOY_PAT` secret also works: its PR is not
  gated.
- **Required-check names**: a job that calls a reusable workflow reports as
  `<caller job id> / <reusable job name>` (e.g. `quality / Lint, Test, Coverage, CRAP & Build`).
  Deploy jobs are never required checks, so migrating a deploy is safe everywhere. For
  CI jobs on protected repos, update the required checks in the SAME change window:
  add the new names, merge, then drop the old names.
- **GUI session**: `ios-release` fails fast unless `launchctl print gui/$(id -u)`
  succeeds (no console login for the runner user = the export SIGTRAPs in AppSSO);
  on any export failure it prints the IDEDistribution standard/critical logs and
  xcodebuild crash reports and uploads them as `ios-export-diagnostics`.
- **Keychain**: the unlock step is a no-op when the mini's runner hooks already
  unlocked the CI keychain (seen in the svelte-crossword pilot); keep
  `CI_KEYCHAIN_PASSWORD` until the hooks are confirmed on every lane.
- **Paths**: key, ExportOptions, archive and export dir all live under `$RUNNER_TEMP`;
  nothing writes `~/private_keys`, `/tmp/ExportOptions.plist` or `~/Desktop`.
- **Build number**: `YYYYMMDDHHMMSS` (seconds added), exported as `BUILD_NUM`.

## Standard caller YAML

### Capacitor iOS deploy (`.github/workflows/ios-deploy.yml`)

```yaml
name: iOS Deploy

on:
  workflow_run:
    workflows: ['CI']
    types: [completed]
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write
  actions: write

jobs:
  deploy:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-capacitor.yml@v1
    secrets: inherit
    with:
      bundle-id: com.johncorser.<app>
      archive-name: <App>
      ref: main
      config-command: npm run prod-config     # repos that pull amplify_outputs from prod
      bump: patch
```

### Capacitor Android deploy (`.github/workflows/android-deploy.yml`)

```yaml
name: Android Deploy

on:
  workflow_run:
    workflows: ['CI']
    types: [completed]
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  deploy:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    uses: johnpc/ci-workflows/.github/workflows/android-deploy-capacitor.yml@v1
    secrets: inherit
    with:
      app-name: <app>
      ref: main
      config-command: npm run prod-config
```

### Sandbox cleanup (`.github/workflows/sandbox-cleanup.yml`)

```yaml
name: Sandbox cleanup

on:
  schedule:
    - cron: '17 */6 * * *'
  workflow_dispatch:
    inputs:
      apply:
        description: 'Actually delete (unchecked = dry run)'
        type: boolean
        default: false

jobs:
  sweep:
    uses: johnpc/ci-workflows/.github/workflows/sandbox-cleanup.yml@v1
    secrets: inherit
    with:
      apply: ${{ github.event_name == 'schedule' || inputs.apply }}
      # repos whose sweep is `node scripts/sandbox.mjs sweep` (needs deps):
      # sweep-command: node scripts/sandbox.mjs sweep
      # install: true
```

### Amplify ephemeral-sandbox CI (`.github/workflows/ci.yml`)

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  sandbox:
    uses: johnpc/ci-workflows/.github/workflows/amplify-sandbox.yml@v1
    secrets: inherit
    with:
      action: deploy
      seed-command: |
        npm run ensure-editor
        npm run seed
      secret-env: TEST_USERNAME TEST_PASSWORD

  quality:
    needs: sandbox
    uses: johnpc/ci-workflows/.github/workflows/node-checks.yml@v1
    secrets: inherit
    with:
      name: Lint, Test, Coverage, CRAP & Build
      config-command: npm run e2e-config
      commands: |
        npm run format:check
        npm run lint
        npm run check:lines
        npm run test:coverage
        npm run crap
        npm run build
      artifact-paths: coverage/

  acceptance:
    needs: sandbox
    uses: johnpc/ci-workflows/.github/workflows/node-checks.yml@v1
    secrets: inherit
    with:
      name: Acceptance Tests
      config-command: npm run e2e-config
      playwright: true
      secret-env: TEST_USERNAME TEST_PASSWORD
      areas: >-
        [{"name":"<area>","paths":".features-gen/e2e/features/<area>"}]
      commands: npx bddgen && npx playwright test $AREA_PATHS
      artifact-paths: playwright-report/

  teardown:
    needs: [sandbox, quality, acceptance]
    if: always()
    uses: johnpc/ci-workflows/.github/workflows/amplify-sandbox.yml@v1
    secrets: inherit
    with:
      action: teardown
```

The amplify-sandbox / node-checks / sandbox-cleanup / android / docker reusables are
linted but NOT yet piloted: the first repo to adopt each one is its pilot (prove a
green run, and for sandbox CI check the teardown deleted the stack).

## Per-repo plan

### cadence (Capacitor; main PROTECTED, strict, 16 required checks, auto-merge allowed; also docker-publish + deploy-web)
- iOS: `ios-deploy-capacitor.yml` with `bundle-id: com.johncorser.cadence`,
  `archive-name: Cadence`, `external-beta: true`, `secret-env: VITE_DIAGNOSTICS_KEY VITE_DIAGNOSTICS_URL`.
  Cadence's smoke is app-specific (signs into a Jellyfin test server through
  `scripts/ios-smoke-proxy.py`, Release configuration, per-run tag), so keep it:
  `smoke-command: SMOKE_WEB_BUILD=0 SMOKE_CONFIGURATION=Release SMOKE_RUN_TAG=deploy-${{ github.run_id }}-${{ github.run_attempt }} bash scripts/ios-launch-smoke.sh`
  and keep the default `smoke-artifact-paths` (screenshot, logs, stdout; DerivedData and
  `.app` bundles are always excluded). Copy any env its smoke reads into `secret-env`.
  Being protected, its bump needs the protected-repo setup above; its required checks are CI jobs, so migrating only the
  deploy leaves protection untouched.
- docker-publish: `docker-publish.yml` with `image: <its current image>`; check its
  current tags/platforms match (it uses build-push v6, amd64+arm64).
- Its CI (`quality`, `ios-tests`, `ios-launch-smoke`, `acceptance`, `smoke-live`) is
  bespoke; leave it.

```yaml
jobs:
  deploy:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-capacitor.yml@v1
    secrets: inherit
    with:
      bundle-id: com.johncorser.cadence
      archive-name: Cadence
      ref: main
      external-beta: true
      secret-env: VITE_DIAGNOSTICS_KEY VITE_DIAGNOSTICS_URL
      smoke-command: SMOKE_WEB_BUILD=0 SMOKE_CONFIGURATION=Release SMOKE_RUN_TAG=deploy-${{ github.run_id }}-${{ github.run_attempt }} bash scripts/ios-launch-smoke.sh
      ci-workflow: ci.yml
      bump: patch
```

### jpc-noms (Capacitor; main PROTECTED, 16 required checks, strict; bump-PR flow)
- Migrate the **iOS deploy first** (not a required check, so protection is untouched):

```yaml
jobs:
  deploy:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-capacitor.yml@v1
    secrets: inherit
    with:
      bundle-id: com.johncorser.eats
      archive-name: Noms
      ref: main
      config-command: npm run prod-config
      # Google ML Kit ships no arm64 simulator slice and Xcode 27 has no Rosetta
      # simulators: build the smoke from a scratch copy without the scanner pod.
      smoke-remove-pods: CapacitorMlkitBarcodeScanning
      external-beta: true
      bump: patch
      ci-workflow: ci.yml
```
  Delete `scripts/ios-launch-smoke.sh` (its ML Kit scratch-copy logic is now the
  action's `remove-pods`). The "Revoke stale API-created certificates" step is dropped:
  manual signing uses the CI keychain's long-lived cert and must NOT revoke API certs
  (the helper itself creates team certs through the API). Its own bump flow already used
  a PR + `--auto`, but nothing approved the bot PR's gated run, so it would have sat
  BLOCKED (never exercised: no bump has happened). The shared action approves it. Its CI author guard (`johnpc` or `github-actions[bot]`) already
  lets dispatched/bot runs through; a dispatch is not `pull_request`, so the guard passes.
- `sandbox-cleanup.yml`: standard caller (default `npm run sandbox:sweep --`).
- CI (`sandbox`, `quality`, `acceptance`, `acceptance-fake`, `teardown`): optional second
  step. All 16 required checks rename (`sandbox / Deploy + seed ephemeral sandbox`,
  `quality / …`, `acceptance / Acceptance Tests (smoke)`, `acceptance-fake / …`). Do it in
  one window: add the new names to protection, merge, remove the old ones. Runner for
  the acceptance legs: `runner: '["self-hosted", "mac-mini-light"]'`; the PR owner
  guard goes on each caller job:
  `if: github.event_name != 'pull_request' || contains(fromJSON('["johnpc","github-actions[bot]"]'), github.event.pull_request.user.login)`.
  The "Verify the Tesla Lambda is inert" step moves into `seed-command` (or a script).
  Fake-backend legs: `commands: export FAKE_BACKEND=1 && npx bddgen && npx playwright test $AREA_PATHS`.

### jpc-countdowns (Capacitor; main PROTECTED — required checks `test`, `ios-launch`; checkout with DEPLOY_PAT)
```yaml
jobs:
  deploy:
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-capacitor.yml@v1
    secrets: inherit
    with:
      bundle-id: com.johncorser.countdowns
      archive-name: Countdowns
      ref: main
      config-command: npm run prod-config   # retries DeploymentInProgressError (Amplify race)
      external-beta: true
      bump: patch
```
  `DEPLOY_PAT` (if set) is picked up automatically; with it the bump becomes a PR that
  runs CI, instead of an admin push that bypassed the required check. Its smoke script
  is the generic one (SMOKE_OUT=smoke-results only differs): delete it. Its CI
  (`test`, `ios-launch`) stays as is.

### pipe (native; main PROTECTED, strict, 4 required checks, auto-merge allowed; cloud-signed today)
```yaml
  deploy:
    needs: [unit-tests, crap-analysis, acceptance-tests]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    permissions:
      contents: write
      pull-requests: write
      actions: write
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-native.yml@v1
    secrets: inherit
    with:
      project: pipe.xcodeproj
      scheme: pipe
      bump: minor
      secret-env: PIPE_LOGS_API_KEY
      # Injected via pipe/Config.xcconfig's optional #include; without it the
      # release build ships an empty key and diagnostics upload silently no-ops.
      setup-command: printf 'PIPE_LOGS_API_KEY = %s\n' "$PIPE_LOGS_API_KEY" > pipe/Secrets.xcconfig
```
  Behavior change to verify: pipe archives UNSIGNED and cloud-signs at export today;
  the shared flow signs in the archive with the CI keychain (keeps entitlements).
  Confirm the first upload and that `pipe/Secrets.xcconfig` is not committed by the
  bump (the bump only `git add`s the pbxproj). Protected: needs the protected-repo bump setup above, and note its old `[skip ci]` push to
  main could never have landed.

### jpc.fit.native (native + watch app; main PROTECTED, strict, 5 required checks; auto-merge bump PR)
```yaml
  deploy:
    needs: [unit-tests, crap-analysis, acceptance-tests]
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    permissions:
      contents: write
      pull-requests: write
      actions: write
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-native.yml@v1
    secrets: inherit
    with:
      project: jpc.fit.native.xcodeproj
      scheme: jpc.fit.native
      bump: minor
      ci-workflow: quality-gates.yml
```
  Required checks are unaffected (only `deploy` changes). Its bump PR had the same
  gap (nothing approved the gated bot run); the shared action approves it, and its
  owner guard already admits `github-actions[bot]`. The helper signs the watch app and
  extension targets too (each gets its own `<bundle id> CI AppStore` profile).

### peek (native; main PROTECTED, strict, 1 required check; cloud-signed today)
- **Auto-submit question, answered:** no. Neither peek's workflow (main and its
  `ci/deploy-*` branches) nor any script calls the review-submission API; the deploy
  only uploads to TestFlight. If a peek build ever reached review "on its own", it is
  App Store Connect configuration (a version already submitted / release type), not the
  workflow.
- Its bump is broken today: on a version conflict it `git push`es to a protected main
  (rejected) after uploading. The shared flow opens a PR instead — but peek has
  *Allow GitHub Actions to create PRs* OFF, so turn that on (or add `DEPLOY_PAT`).
  Run 44388581759 hit the real conflict: upload succeeded, then the bump step died
  with `gh: command not found` (peek's runner `.path` has no /opt/homebrew/bin; fixed
  in v1.2.0), so its bumped MARKETING_VERSION is not recorded in git yet.
- It archives unsigned with `-derivedDataPath /Users/john/peek-ci/...` and exports in the
  user session via `sudo launchctl asuser` (the daemon-context export crashed in
  AppSSO with automatic signing). Manual CI-keychain signing (what the shared flow does)
  has exported fine from the daemon context in jpc.fit.native, svelte-crossword and
  jpc.finance.native, so drop the `asuser` hop; keep its derived data with
  `xcodebuild-args`.

```yaml
  deploy:
    needs: gates
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    permissions:
      contents: write
      pull-requests: write
      actions: write
    uses: johnpc/ci-workflows/.github/workflows/ios-deploy-native.yml@v1
    secrets: inherit
    with:
      project: peek.xcodeproj
      scheme: peek
      bump: minor
      timeout-minutes: 60
      xcodebuild-args: -derivedDataPath /Users/john/peek-ci/derived -clonedSourcePackagesDirPath /Users/john/peek-ci/spm
      ci-workflow: quality-gates.yml
```
  Its "no app record yet → warning, stay green" special case is gone: the app record
  exists now (1.0.1 uploaded), so a missing record should fail.

### Web-only repos: jpc-since, flashstack, phrasepack, spork, stickies, taskflow, travel
iOS and Android deploys are disabled (`gh workflow disable`) and stay that way: do NOT
migrate or re-enable them. Only CI and sandbox workflows apply:

| Repo | CI shape | sandbox-cleanup caller |
| --- | --- | --- |
| spork | sandbox / quality / acceptance (15 areas) / teardown — the standard CI caller above | default (`npm run sandbox:sweep --`) |
| flashstack, phrasepack | sandbox / quality / **seed** / acceptance / teardown | default; their cron is every 2 h (`17 */2 * * *`), `install: true` |
| taskflow, travel | sandbox / quality / seed / acceptance / teardown | `sweep-command: node scripts/sandbox.mjs sweep`, `install: true`, cron `23 */3 * * *` |
| stickies | quality / seed / acceptance (shared main-branch backend, no sandbox) | — |
| jpc-since | quality / acceptance (no sandbox) | — |

The separate `seed` job maps to `seed-command` on the `sandbox` call (or a
`node-checks.yml` job with `needs: sandbox`). None of these repos is protected, so the
check-name change needs no protection edit.

### Not in scope yet (inventory only)
- holiday-hue, stoop (+ ~20 stale stoop-* forks): same Capacitor iOS/Android/sandbox
  shapes; stoop is on another Apple team (`ASC_ISSUER_ID` differs — the helper reads it
  from the secret) and sweeps by `--pr-days 2 --days 7` (`sweep-args`).
- jpc.eats.native: native, still writes `/tmp/ExportOptions.plist` and `~/Desktop`:
  the shared-path race. Migrate like pipe.
- telly-apple (main PROTECTED, 1 required check; iOS + tvOS, xcodegen, `/tmp/ExportOptions-*.plist`): two archives per
  run; needs `platform: tvos` and a second call, `setup-command: brew install xcodegen && xcodegen generate`.
- cadence-ios (xcodegen, `~/Desktop` paths): native caller with `setup-command`.
- docker-publish: pixoo-wall, jpc-homie (also deploys to umbrel over ssh), cadence,
  karaoke-for-jellyfin, subsyncarr, jellyfin-wrapped.
