# Build and test Moppo

[Back to the documentation index](README.md).

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
python3 scripts/rules.py check
swift test --package-path Core --no-parallel \
  --filter 'ReviewFindingsTests/(processCancellationKillsChild|descendantHoldingStdoutDoesNotHang)|AllocatedSizeMeasurerTests/cloudReadsReserveLocalWorkers|HiddenDataScanTests/archivesOverlapCloud|CodexSessionsTests|GitWorktreeTests|ProjectActivityTests|ToolCommandRemovalTests|VendorFolderTests'
swift test --package-path Core \
  --skip 'ReviewFindingsTests/(processCancellationKillsChild|descendantHoldingStdoutDoesNotHang)|AllocatedSizeMeasurerTests/cloudReadsReserveLocalWorkers|HiddenDataScanTests/archivesOverlapCloud|CodexSessionsTests|GitWorktreeTests|ProjectActivityTests|ToolCommandRemovalTests|VendorFolderTests'
xcodegen generate
xcodebuild -project Moppo.xcodeproj -scheme MoppoAppTests -destination 'platform=macOS' test
vale README.md AGENTS.md WRITING_STYLE.md CHANGELOG.md SECURITY.md docs
```

Timing and process integration tests run separately to avoid interference from other test fixtures.
These tests check worker limits, process deadlines, Git commands, project activity, and Codex deletion.
The remaining core tests run in parallel.

The app state tests use temporary files and a separate test process.
They do not launch Moppo or delete personal photos.
In these tests, operation progress does not stay on screen for the minimum display time.

GitHub Actions runs these tests and writing checks for pull requests that target `main`.
A push to `main` starts the same checks.
CI uses Xcode 27 and an ad hoc signature for the separate test bundle.
CI runs the core tests and the app state tests in separate jobs at the same time.
CI runs timing and process integration tests sequentially before the parallel core tests.
The app state tests job keeps the Xcode compilation cache between runs of the same pull request.
If a change contains only Markdown files, `docs/`, or Vale rules, CI does not run the tests.
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

## Run the app

```sh
xcodegen generate                 # regenerates Moppo.xcodeproj from project.yml
open Moppo.xcodeproj              # ⌘R to run
swift test --package-path Core    # check the engine
swift run --package-path Core moppo-cli scan  # run the scanner
vale README.md AGENTS.md WRITING_STYLE.md CHANGELOG.md SECURITY.md docs  # check project writing
```

`project.yml` generates `Moppo.xcodeproj`, and Git ignores the generated
project. Change targets or build settings only in `project.yml`. XcodeGen includes
new source files from `App/` automatically.

Moppo imports preferences from the previous app identity once. Existing Moppo
preferences take priority. When a Moppo data folder does not exist, Moppo moves
the previous folder to the new name. This preserves caches, measurement history,
and cleanup records for Put Back. If both folders exist, Moppo keeps them and uses
the Moppo folder. macOS can request permissions again because the app identifier
has changed.

`App/Resources/AppIcon.icon` contains the Icon Composer source. It includes light
and dark appearances with neutral background gradients. The menu bar uses a
vector template image that follows the system appearance.

Select the `Moppo Onboarding` scheme to show the welcome guide on every Debug run.
This scheme passes `--show-onboarding`. It keeps saved settings and system permissions.
The `Moppo` scheme shows the guide until you complete it.
If access is missing on a later launch, Moppo shows the access step again.
Select **Enable** to open System Settings, or select **Continue with Limited Access** to enter the app.
At the end of the welcome guide, **Get Started** opens Cleanup, also without Full Disk Access.
The cleanup scan starts when you enter Cleanup, including with limited access.
With limited access, Cleanup scans only the folders that Moppo can read.
Scheduled scans and automatic storage measurements wait for Full Disk Access.
macOS can request folder access during a scan. Moppo requests Photos access when you open
Duplicates > Photos. Returning from System Settings refreshes the permission state.
The photo scan starts only when you select Find Duplicates.
Use **Moppo > Show Welcome Guide** to read the guide again.
Photo download controls and guidance are available in **Settings > Advanced**.

## Permissions

The app measures `~/Documents`, `~/Desktop` and `~/Downloads`, all TCC-gated. The
Debug target uses the stable Apple Development identity configured in `project.yml`,
so TCC grants survive rebuilds. Do not validate the app with
`CODE_SIGNING_ALLOWED=NO`: that replaces the Debug product with an ad-hoc identity
and macOS correctly asks for access again. The app target rejects unsigned builds.

Moppo stores the last breakdown at
`~/Library/Application Support/Moppo/breakdown-cache.json`. This data seeds the
initial layout. The Dashboard refreshes it at launch. A scan also refreshes it with
the category results.

## Scan profiling and diagnostics

```sh
swift build --package-path Core -c release
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker
Core/.build/release/moppo-cli profile-scan dashboard
Core/.build/release/moppo-cli profile-scan cleanup --skip-docker --log-directory /tmp/moppo-scan-logs
```

`profile-scan` compares two runs in one process and prints category times, process CPU time, disk activity, and worker counts.
The first run can use existing macOS file caches, so the report does not claim a cold disk cache.
The output excludes account names, file names, and file paths. The command saves nothing and changes no preference.
Record the Mac model, the macOS version, the access settings, and the build beside a report.

`scripts/package-dmg.sh --scan-logging` builds a private test package that writes detailed logs to `~/Library/Logs/Moppo/Scans`.
Select **Help > Show Scan Logs** to open the folder. Normal packages keep this logging off.
Detailed logs can contain private file paths, project names, command arguments, and error messages. Review a log before you share it.
Logs exclude file contents, conversation messages, passwords, tokens, and environment values.
The research record describes each log record and each profiling figure.

The [CLI guide](cli.md) describes the supported command interface.
The [agent workflow](agent-workflow.md) covers skill installation, confirmation, disclosure, and client validation.
The app and the CLI share exclusion decoding and the macOS scan context. With `settings.showsSmallItems` on, the scan hides only empty rows.
