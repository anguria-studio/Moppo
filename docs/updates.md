# Moppo updates

Sparkle 2.10.0 provides update checks and the standard installation interface.
See [Sparkle setup](https://sparkle-project.org/documentation/) and [publishing updates](https://sparkle-project.org/documentation/publishing/).

## Configuration

`project.yml` contains the public Ed25519 key in `MOPPO_UPDATE_PUBLIC_KEY`.
The matching private key is in the login Keychain under account `anguria-studio.Moppo`.
Keep this private key outside the repository and the update host.
Back up the private key before distribution.
A key loss can prevent existing installations from accepting later updates.

The update feed address is `https://anguria.studio/moppo/appcast.xml`.
The landing page is `https://anguria.studio/moppo/`.
Publish privacy information at `https://anguria.studio/moppo/privacy/` before distribution.
The website currently redirects the Moppo landing page to Paguro.
Website publication must preserve Paguro routes.
Release builds reject missing or invalid update settings.
Debug builds without update settings make no update requests.

The generated Info.plist requires signed feeds and verification before archive extraction.
Moppo disables Sparkle automatic installation and system profile reporting.
Automatic checks are optional and initially disabled.
The controller starts after onboarding finishes.
The Updates pane stores the automatic check preference through Sparkle.

## Build

```sh
xcodegen generate
xcodebuild -project Moppo.xcodeproj -scheme Moppo -configuration Release \
  CODE_SIGN_IDENTITY='Developer ID Application' build
```

Use increasing `CURRENT_PROJECT_VERSION` values for distributed builds.
Use the same application name, bundle identifier, and signing team for updates.
Issue #15 covers the final signed and notarized release package.
Use the [package tool](distribution.md) to create notarized DMGs and signed update assets.

## Publish

Sparkle tools are in `SourcePackages/artifacts/sparkle/Sparkle/bin` under the Xcode package cache.
Set `SPARKLE_BIN` to this folder.
Set `UPDATE_ARCHIVES` to a local folder for release archives and notes.
Set `UPDATE_DOWNLOAD_URL` to the HTTPS release archive folder.
Paguro uses GitHub Releases for archives and its signed feed.
Moppo uses the same signing checks with its feed on the selected Anguria website.
If archives use GitHub Releases, their repository must allow public downloads before distribution.

Create an archive that preserves framework symbolic links:

```sh
ditto -c -k --sequesterRsrc --keepParent /path/to/Moppo.app "$UPDATE_ARCHIVES/Moppo-0.2.0.zip"
```

Put release notes beside the archive with the same base name and an `.html` or `.md` extension.
Generate and sign the feed with the Moppo Keychain account:

```sh
"$SPARKLE_BIN/generate_appcast" --account anguria-studio.Moppo \
  --download-url-prefix "$UPDATE_DOWNLOAD_URL" \
  --release-notes-url-prefix "$UPDATE_DOWNLOAD_URL" "$UPDATE_ARCHIVES"
```

Verify the generated feed:

```sh
"$SPARKLE_BIN/sign_update" --account anguria-studio.Moppo --verify "$UPDATE_ARCHIVES/appcast.xml"
```

The app requires signed update archives, feeds, and external release notes.
Publish the generated appcast, archives, delta files, and release notes at their HTTPS addresses.
Do not change signed files after generation.
Publish the included [privacy information](../App/Resources/Privacy.md) on the website.
Keep `hello@anguria.studio` available for support and privacy requests.

## Installation and support

The installation guard waits for the current operation to finish.
It reserves the shared operation coordinator before continuing installation.
New scans, removal, and Put Back cannot start during installation.
A canceled or failed installation releases the reservation.
App termination waits for active disk work.

The Help menu opens the included privacy information and a support report.
The report contains only Moppo and macOS versions and empty fields for the problem description.
It does not attach files, photos, logs, or measurements.
Email Support opens a draft for review and does not send it.

## Release checks

Track outstanding checks in GitHub issues #16 and #15.
Check signed feeds, release notes, invalid feeds, and unavailable servers.
Check an update between two installed signed and notarized versions.
Confirm that settings, History, access permissions, and the Homebrew password helper work after the update.
