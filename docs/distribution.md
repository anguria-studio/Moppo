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
Debug builds keep their existing development signing settings.
The archive export signs Sparkle and its embedded services with the application team.
The package tool verifies the main app, Sparkle services, and Homebrew password helper before submission.

Set `SPARKLE_BIN` to the pinned Sparkle package's `bin` folder.
Run the package tool from the repository root:

```sh
scripts/package-dmg.sh --version 0.2.0 --build 2 \
  --output dist/releases/Moppo-0.2.0-2 \
  --sparkle-tools "$SPARKLE_BIN" \
  --notes docs/releases/0.2.0.md
```

The output folder must not exist for a new build.
Use `--package-cache` to reuse an existing Xcode package cache.
Use `--download-url` to select another HTTPS folder for release downloads.
The default download folder is `https://anguria.studio/moppo/releases/v<VERSION>/`.

The tool submits the app to Apple and attaches its notarization ticket.
It creates a signed DMG with the app and an Applications link.
It submits the DMG to Apple and attaches its ticket.
It then signs the Sparkle feed and release notes.
Each release asset has a matching `.sha256` file.
The tool publishes no files.

## Prepare before credentials are available

An unnotarized candidate must remain local.
Do not distribute a candidate until notarization and the required release checks pass.

```sh
scripts/package-dmg.sh --prepare --version 0.2.0 --build 2 \
  --output dist/releases/Moppo-0.2.0-2
```

Use `--archive` to export an existing Release archive.
Finish the prepared candidate with the same version, build, and output folder:

```sh
scripts/package-dmg.sh --finish --version 0.2.0 --build 2 \
  --output dist/releases/Moppo-0.2.0-2 \
  --sparkle-tools "$SPARKLE_BIN" \
  --notes docs/releases/0.2.0.md
```

The local `release.json` file records the source commit and whether the source had uncommitted changes.
It marks notarization complete after both tickets, signed update assets, and checksums pass.
An Apple rejection leaves the submission result and log in the output folder.

## Versioning and publication

Use three-part version numbers, such as `0.2.0`.
Increase the build number for every distributed build.
Build numbers must increase even when the visible version stays the same.
Keep the bundle identifier, signing team, update address, and update key stable.
Update the release notes before each distribution.

Before publication, complete the remaining checks in issues #15 and #16.
Use two installed notarized versions for the Sparkle update check.
Check settings, History, Full Disk Access, Photos access, and Homebrew authentication after the update.
Check normal removal, denied access, partial results, and Put Back with disposable files.
Check installation on a clean Mac.
Issues #11 and #13 hold the other required acceptance and accessibility checks.

Publish the versioned assets under the selected HTTPS download folder.
Publish the signed `appcast.xml` at `https://anguria.studio/moppo/appcast.xml`.
Publish privacy information before distribution.
Do not edit signed files after generation.
Keep the website's Paguro redirects until the Moppo landing page is ready for publication.
