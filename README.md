# ci-workflows

Shared GitHub Actions for johnpc's apps: one copy of the iOS deploy, the launch
smoke, CI-keychain signing, the version-bump flow, the Amplify ephemeral-sandbox
CI and the deploy/publish jobs, instead of a dozen drifting copies.

Public on purpose (callers in public and private repos can use it). It holds no
secrets: callers pass their own with `secrets: inherit` (or explicitly). Machine
state for signing (CI keychain, certificates, backups) stays on the Mac mini.

Pin callers to **`@v1`**. `v1` moves only with backwards-compatible changes; each
release is also tagged `v1.x.y` if you need to freeze. Inside this repo the
reusable workflows reference the composite actions at `@v1` too.

## Reusable workflows (`.github/workflows/`)

| Workflow | What it does | Runner |
| --- | --- | --- |
| `ios-deploy-capacitor.yml` | web build, `cap sync ios`, pods, **launch smoke**, sign, archive, upload, bump PR, optional external TestFlight | `[self-hosted, mac-mini]` |
| `ios-deploy-native.yml` | optional setup (xcodegen, xcconfig), sign, archive, upload, bump PR, optional external TestFlight | `[self-hosted, mac-mini]` |
| `android-deploy-capacitor.yml` | web build, `cap sync android`, debug APK, GitHub Release; skips non-native commits | `ubuntu-latest` |
| `amplify-sandbox.yml` | deploy + seed (`action: deploy`) or delete (`action: teardown`) the run's own Amplify sandbox | `ubuntu-latest` |
| `node-checks.yml` | one Node gate job, or an acceptance-area matrix, optionally against the run's sandbox | `ubuntu-latest` (any JSON `runner`) |
| `sandbox-cleanup.yml` | scheduled sweep of leaked CI sandboxes (repo's own sweep script) | `ubuntu-latest` |
| `docker-publish.yml` | multi-arch Docker Hub build + push with metadata tags | `ubuntu-latest` |

## Composite actions (`actions/`)

| Action | Notes |
| --- | --- |
| `ios-launch-smoke` | Starts the real binary in a throwaway simulator; fails on no UIScene manifest, no "WebView loaded", early death, scene fault or crash report. `remove-pods` builds a scratch copy without pods that have no arm64 simulator slice (jpc-noms' ML Kit). Uploads `launch.png` + logs. |
| `ios-signing` | The mini's `ios_manual_signing.py` (+ `asc_api.py`): manual signing from `ci-signing.keychain-db` with per-bundle `<bundle id> CI AppStore` profiles; `profiles` pins existing ones (FinanceKit). |
| `keychain-unlock` | No-op when the CI keychain is already unlocked (the mini's runner hooks unlock it per job); unlocks with the password otherwise. |
| `ios-release` | Key in `$RUNNER_TEMP`, unique build number (exported as `BUILD_NUM`), unlock, sign, archive/export/upload under `$RUNNER_TEMP`, bump-on-conflict (patch or minor), bump PR, external beta. |
| `version-bump-pr` | Commits the bump on `ci/bump-version-<v>`, opens a PR, auto-merges it on protected repos (dispatching CI on the branch if asked) or squash-merges it at once on unprotected ones. |
| `aws-profile` | Writes the `personal` AWS profile the repos' npm scripts use. |
| `export-secrets` | Exports named caller secrets (from `toJSON(secrets)`) as env. |

## Secrets callers provide

iOS: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `CI_KEYCHAIN_PASSWORD`
(optional once the runner hooks unlock the keychain). Capacitor builds:
`AMPLIFY_OUTPUTS_BASE64` or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, plus any
build-time names listed in `secret-env`. Docker: `DOCKERHUB_USERNAME`,
`DOCKERHUB_TOKEN`.

## Permissions callers must grant

Reusable jobs cannot exceed the caller's token permissions. iOS deploy callers:

```yaml
permissions:
  contents: write       # bump branch / direct merge
  pull-requests: write  # bump PR
  actions: write        # approve the bump PR's gated CI run (protected repos)
```

Repos that should get the bump as a PR also need *Settings → Actions → General →
Allow GitHub Actions to create and approve pull requests*. Without it the bump is
pushed straight to an unprotected main with a warning (a protected main fails loudly).

See [MIGRATION.md](MIGRATION.md) for the per-repo plan.
