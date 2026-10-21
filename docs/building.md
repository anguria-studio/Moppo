# Build and test Moppo

[Back to the project overview](../README.md).

Run the commands from the repository root unless a command changes the folder.

## Requirements

- Xcode with Swift 6 and Icon Composer support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple Development signing certificate and its team identifier

Current development checks use Xcode 27.
The generated app targets macOS 15 and later.
Vale checks the documentation style.

## Build and test

```sh
git clone https://github.com/anguria-studio/Moppo.git
cd Moppo
```

Set `DEVELOPMENT_TEAM` in `project.yml` to your team identifier.
Keep `CODE_SIGN_IDENTITY` set to `Apple Development`.
Then generate and open the project:

```sh
xcodegen generate
open Moppo.xcodeproj
```

Choose the **Moppo** scheme.
Press **⌘R**.
The app requires code signing because macOS associates privacy access with the signed app identity.
Do not build the app with `CODE_SIGNING_ALLOWED=NO`.

For a command-line build:

```sh
xcodebuild \
  -project Moppo.xcodeproj \
  -scheme Moppo \
  -configuration Debug \
  build
```

Run the tests and writing checks from the repository root:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
swift test --package-path Core --no-parallel \
  --filter 'ReviewFindingsTests/(processCancellationKillsChild|descendantHoldingStdoutDoesNotHang)|AllocatedSizeMeasurerTests/cloudReadsReserveLocalWorkers|HiddenDataScanTests/archivesOverlapCloud|CodexSessionsTests|GitWorktreeTests'
swift test --package-path Core \
  --skip 'ReviewFindingsTests/(processCancellationKillsChild|descendantHoldingStdoutDoesNotHang)|AllocatedSizeMeasurerTests/cloudReadsReserveLocalWorkers|HiddenDataScanTests/archivesOverlapCloud|CodexSessionsTests|GitWorktreeTests'
xcodegen generate
xcodebuild -project Moppo.xcodeproj -scheme MoppoAppTests -destination 'platform=macOS' test
vale README.md AGENTS.md WRITING_STYLE.md
```

Timing and process integration tests run separately to avoid interference from other test fixtures.
These tests check worker limits, process deadlines, Git commands, and Codex deletion.
The remaining core tests run in parallel.

The app state tests use temporary files and a separate test process.
They do not launch Moppo or delete personal photos.
In these tests, operation progress does not stay on screen for the minimum display time.

GitHub Actions runs these tests and writing checks for pull requests that target `main`.
Merging a pull request does not start another CI run.
CI uses Xcode 27 and an ad hoc signature for the separate test bundle.
CI runs the core tests and the app state tests in separate jobs at the same time.
CI runs timing and process integration tests sequentially before the parallel core tests.
The app state tests job keeps the Xcode compilation cache between runs of the same pull request.
If a pull request changes only Markdown files, `docs/`, or Vale rules, CI does not run the tests.
The **Tests and writing** check passes only when all other CI jobs pass.
CI does not build or launch the signed Moppo app.
Pull request checks also validate branch names and Conventional Commit titles.

When billing or quota limits prevent Actions jobs from starting, run the checks above locally before merging.
Run the branch and title check with the final pull request title:

```sh
PR_BRANCH="$(git branch --show-current)" \
PR_TITLE='feat: describe the change' \
python3 .github/scripts/check-conventions.py
```

Record the tested commit SHA, commands, results, and blocked jobs in the pull request.
Before merging, confirm that the pull request still points to the tested commit.
If the commit changes, repeat the local checks.
Code, test, build, and writing failures still block merging.
Local checks do not consume GitHub Actions minutes.
When Actions can run again, require its checks to pass.
See the [project instructions](../AGENTS.md#local-validation-during-actions-billing-limits) for the complete fallback rules.

Use the **Moppo Onboarding** scheme to show the welcome guide on every Debug launch.
This scheme keeps saved settings and system permissions.
See the [development notes](README.md) for the command-line scanner, source layout, and measurement rules.
