# Signed release packages

Issue #15 tracks release signing, notarization, installation, and update checks.
Issue #16 tracks the update website and support publication.
Keep both issues open until their remaining checks pass.

## Requirements

- Install Xcode, XcodeGen, and Python 3.
- Keep a Developer ID Application certificate in the login Keychain.
- Use an existing Apple notarization Keychain profile.
- Keep the Moppo Sparkle signing key in the login Keychain under account `anguria-studio.Moppo`.

A notarization profile can serve more than one application under the same Apple Developer account.
The profile stores the Apple login separately from the Sparkle signing key.
Use `anguria-studio` as the shared profile name for Paguro and Moppo.
The package tool uses `anguria-studio` by default.
Use `--profile` or `MOPPO_NOTARY_PROFILE` to select another profile.
Do not put passwords or private keys in the repository.

If no profile exists, create one interactively:

```sh
xcrun notarytool store-credentials anguria-studio --team-id L2P2KC4C69
```

Enter the Apple Developer email and app-specific password directly in Terminal.
An existing app-specific password can serve the shared profile.
Validate the shared profile before you change either application release configuration:

```sh
xcrun notarytool history --keychain-profile anguria-studio
```

See [Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Build and notarize

Release builds use Developer ID signing, Hardened Runtime, secure timestamps, and no debug access entitlement.
The main app includes the Photos Library entitlement and its access description.
The package tool rejects an app if either item is missing.
Debug builds keep their existing development signing settings.
The archive export signs Sparkle and its embedded services with the application team.
The package tool verifies the main app, Sparkle services, and Homebrew password helper before submission.

Set `SPARKLE_BIN` to the pinned Sparkle package's `bin` folder.
Run the package tool from the repository root:

```sh
scripts/package-dmg.sh --version 0.4.0 --build 53 \
  --output dist/releases/Moppo-0.4.0-53 \
  --sparkle-tools "$SPARKLE_BIN" \
  --notes docs/releases/0.4.0.md
```

The output folder must not exist for a new build.
Use `--package-cache` to reuse an existing Xcode package cache.
Use `--download-url` to select another HTTPS folder for release downloads.
The default download folder is `https://github.com/anguria-studio/Moppo/releases/download/v<VERSION>/`.

The tool submits the app to Apple and attaches its notarization ticket.
It creates a signed DMG with the app and an Applications link.
It submits the DMG to Apple and attaches its ticket.
It then signs the Sparkle feed and release notes.
The assets folder includes a versioned DMG and an identical `Moppo.dmg` for the fixed download address.
Sparkle uses the versioned DMG.
The tool adds `Moppo.dmg` after feed generation to prevent duplicate Sparkle versions.
Each release asset has a matching `.sha256` file.
`SHA256SUMS` lists checksums for the DMGs, release notes, and signed feed.
The tool publishes no files.

For a private scan investigation, add `--scan-logging` to the package command.
This option enables detailed local logs through the application build setting.
The package manifest records the detailed logging setting.
Keep this option off for normal releases.
Normal packaging rejects an app with detailed scan logging enabled.
This check also applies to existing archives and prepared candidates.
For private diagnostic packages, supply `--scan-logging` again when you use `--archive` or `--finish`.
Git ignores generated scan and application logs.
See [detailed scan test builds](README.md#detailed-scan-test-builds) for log contents and sharing instructions.

## Prepare before credentials are available

An unnotarized candidate must remain local.
Do not distribute a candidate until notarization and the required release checks pass.

```sh
scripts/package-dmg.sh --prepare --version 0.4.0 --build 53 \
  --output dist/releases/Moppo-0.4.0-53
```

Use `--archive` to export an existing Release archive.
Finish the prepared candidate with the same version, build, and output folder:

```sh
scripts/package-dmg.sh --finish --version 0.4.0 --build 53 \
  --output dist/releases/Moppo-0.4.0-53 \
  --sparkle-tools "$SPARKLE_BIN" \
  --notes docs/releases/0.4.0.md
```

The local `release.json` file records the source commit and whether the source had uncommitted changes.
It marks notarization complete after both tickets, signed update assets, and checksums pass.
An Apple rejection leaves the submission result and log in the output folder.

## Versioning and publication

Use three-part version numbers, such as `0.3.0`.
Use patch versions for fixes, minor versions for compatible features, and major versions for incompatible changes.
Give each public release a new version and tag.
Local candidates can share a version with increasing build numbers.
Increase the build number for every distributed build.
Build numbers must increase even when the visible version stays the same.
Keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` aligned with the release package.
Use a build number greater than every earlier candidate.
Keep the bundle identifier, signing team, update address, and update key stable.
Record user changes under **Unreleased** in [CHANGELOG.md](../CHANGELOG.md).
Before each release, move those changes to a version section with the release date and build number.
Copy that section to the versioned release notes file and GitHub release description.
After publication, set the changelog links to the release tag and the comparison with `main`.

Before publication, complete the remaining checks in issues #15 and #16.
Use two installed notarized versions for the Sparkle update check.
Check settings, History, Full Disk Access, Photos access, and Homebrew authentication after the update.
Check normal removal, denied access, partial results, and Put Back with disposable files.
Check installation on a clean Mac.
Issues #11 and #13 hold the other required acceptance and accessibility checks.

Build from the clean, merged release commit.
Create a draft GitHub release with tag `v<VERSION>` at that commit.
Attach all files from the verified package's `assets` folder.
Keep `release.json`, the archive, and notarization receipts outside the release downloads.

For version `0.4.0`, use the commit from the package manifest:

```sh
RELEASE_COMMIT=$(python3 -c 'import json; print(json.load(open("dist/releases/Moppo-0.4.0-53/release.json"))["source_commit"])')
gh release create v0.4.0 dist/releases/Moppo-0.4.0-53/assets/* \
  --repo anguria-studio/Moppo --draft --target "$RELEASE_COMMIT" \
  --title 'Moppo 0.4.0' --notes-file docs/releases/0.4.0.md
```

Before publishing the draft, verify its signatures, checksums, versioned addresses, and remaining release checks.
If the draft already exists, check its source commit and assets before you update it.
Keep old release downloads available. Do not replace a published version's DMG.
After publication, check the downloads without GitHub credentials.
The fixed download address is `https://github.com/anguria-studio/Moppo/releases/latest/download/Moppo.dmg`.
Configure `https://anguria.studio/moppo/appcast.xml` to redirect to `https://github.com/anguria-studio/Moppo/releases/latest/download/appcast.xml`.
Check the website, privacy policy, and support contact before public distribution.
Do not edit signed files after generation.
Keep existing Paguro routes when you change the Moppo website.
