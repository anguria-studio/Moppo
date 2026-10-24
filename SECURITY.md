# Security policy

## Report a vulnerability

Report a security vulnerability in private.
Use [GitHub private vulnerability reporting](https://github.com/anguria-studio/Moppo/security/advisories/new).
If you cannot use that page, email [hello@anguria.studio](mailto:hello@anguria.studio).
Do not open a public issue for a vulnerability.
Include the Moppo version, the steps that show the problem, and the impact.

## Supported versions

Moppo supports the latest release.
The latest release is 0.2.0.
Moppo does not provide security updates for an older release.

## Sensitive surfaces

These notes match the current source.

### Full Disk Access

Moppo runs outside the App Sandbox so it can scan the disk.
Full Disk Access is a separate macOS privacy grant.
Moppo opens System Settings so you can turn the grant on.
Moppo checks the grant by reading the macOS TCC database.
macOS does not show a permission prompt for that read.
With the grant, Moppo can read protected files on your Mac.
Moppo uses those reads for local scans and storage measurements.
Without the grant, some protected folders stay unreadable.
Scheduled scans and automatic storage measurements require the grant.

### Homebrew password

During a Homebrew cask uninstall, Moppo can ask for your login password.
A signed helper sends that password to `sudo`.
The helper writes the password only to the `sudo` input pipe.
Moppo does not save the password.
The helper runs from the Moppo application bundle.
The helper runs as the signed-in user.
The helper refuses to run as root.
The helper accepts a request only from `sudo` under the signed Moppo process.
The request expires in less than five minutes.
Moppo starts Homebrew as the signed-in user.
Homebrew can then call `sudo`.
For other Homebrew commands, `SUDO_ASKPASS` points to `/usr/bin/false`.

### Sparkle updates

Moppo uses Sparkle 2.10.0 to check for updates.
Sparkle reads a signed HTTPS feed at `https://anguria.studio/moppo/appcast.xml`.
Moppo accepts only an HTTPS feed.
Moppo requires a 32-byte Ed25519 public key.
Moppo verifies the update signature before it extracts the archive.
Automatic update checks are on by default.
This default started with the change in pull request #237.
You can turn automatic checks off with the **Check for updates automatically** setting in **Settings > Updates**.
Release 0.2.0 and earlier versions keep automatic update checks off by default.
Moppo starts the update controller after the welcome guide.
Moppo does not download an update in the background.
Moppo asks before it installs an update.
After you approve an update, Moppo waits until active disk work finishes.
Moppo does not send a Sparkle system profile.
The feed host receives the IP address and normal connection information.
A development build without update settings makes no update request.
