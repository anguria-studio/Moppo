#!/usr/bin/env python3
"""Prepare a signed release, or notarize it and create signed update assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.tommasolaterza.Moppo"
FEED = "https://anguria.studio/moppo/appcast.xml"
ACCOUNT = "anguria-studio.Moppo"
REPOSITORY = "anguria-studio/Moppo"


def run(*command, capture=False):
    result = subprocess.run([str(value) for value in command], check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def validate_scan_logging(app, requested):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    setting = info.get("MoppoDetailedScanLogging", "NO")
    if not isinstance(setting, str) or setting.upper() not in ("YES", "NO"):
        raise RuntimeError("The app has an invalid detailed scan logging setting.")
    enabled = setting.upper() == "YES"
    if enabled and not requested:
        raise RuntimeError("Normal packages cannot enable detailed scan logging. "
                           "Use --scan-logging only for a private diagnostic package.")
    if requested and not enabled:
        raise RuntimeError("The app does not enable detailed scan logging. Build a new diagnostic archive.")
    return enabled


def validate_app(app, version, build, team):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(build),
        "SUFeedURL": FEED,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUAllowsAutomaticUpdates": False,
        "SUSendProfileInfo": False,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise RuntimeError(f"Unexpected release setting: {key}")
    if not info.get("NSPhotoLibraryUsageDescription", "").strip():
        raise RuntimeError("The Photos access description is missing")
    run("python3", ROOT / "scripts/validate-update-configuration.py",
        "--feed", info["SUFeedURL"], "--key", info.get("SUPublicEDKey", ""))
    run("codesign", "--verify", "--deep", "--strict", app)
    framework = app / "Contents/Frameworks/Sparkle.framework/Versions/Current"
    executables = [app, app / "Contents/Helpers/MoppoHomebrewAskpass",
                   framework / "Autoupdate", framework / "Updater.app",
                   framework / "XPCServices/Installer.xpc",
                   framework / "XPCServices/Downloader.xpc"]
    for executable in executables:
        details = subprocess.run(["codesign", "-dv", "--verbose=4", str(executable)],
                                 check=True, capture_output=True, text=True).stderr
        if f"TeamIdentifier={team}\n" not in details:
            raise RuntimeError(f"Unexpected signing team: {executable.name}")
        if "runtime" not in details or "Timestamp=" not in details:
            raise RuntimeError(f"Runtime or timestamp is missing: {executable.name}")
        xml = run("codesign", "-d", "--entitlements", "-", "--xml", executable, capture=True)
        entitlements = plistlib.loads(xml.encode()) if xml.strip() else {}
        if entitlements.get("com.apple.security.get-task-allow", False):
            raise RuntimeError(f"Debug access is enabled: {executable.name}")
        if executable == app and entitlements.get("com.apple.security.personal-information.photos-library") is not True:
            raise RuntimeError("The Photos Library entitlement is missing")
    for architecture in ("arm64", "x86_64"):
        for executable in (app / "Contents/MacOS/Moppo", app / "Contents/Helpers/MoppoHomebrewAskpass"):
            run("lipo", executable, "-verify_arch", architecture)
    if (app / "Contents/MacOS/Moppo.debug.dylib").exists():
        raise RuntimeError("The release contains a Debug library")


def create_dmg(app, dmg, identity):
    with tempfile.TemporaryDirectory(prefix="moppo-dmg-") as temporary:
        stage = Path(temporary)
        run("ditto", app, stage / "Moppo.app")
        (stage / "Applications").symlink_to("/Applications")
        run("hdiutil", "create", "-volname", "Moppo", "-srcfolder", stage,
            "-format", "UDZO", dmg)
    run("codesign", "--sign", identity, "--timestamp", dmg)


def notarize(path, profile, receipt):
    result = json.loads(run("xcrun", "notarytool", "submit", path,
                            "--keychain-profile", profile, "--wait",
                            "--output-format", "json", capture=True))
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    if result.get("status") != "Accepted":
        submission = result.get("id")
        if submission:
            run("xcrun", "notarytool", "log", submission,
                "--keychain-profile", profile, receipt.with_suffix(".log.json"))
        raise RuntimeError(f"Notarization did not accept {path.name}. See {receipt}.")


def validate_update_assets(assets, tools, download_url):
    run(tools / "sign_update", "--account", ACCOUNT, "--verify", assets / "appcast.xml")
    namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    items = ET.parse(assets / "appcast.xml").findall("channel/item")
    if not items:
        raise RuntimeError("The update feed contains no release.")
    for item in items:
        enclosure = item.find("enclosure")
        notes = item.find(f"{{{namespace}}}releaseNotesLink")
        if enclosure is None or notes is None:
            raise RuntimeError("The feed must include an archive and release notes.")
        for element in (enclosure, notes):
            url = element.get("url") or element.text or ""
            path = assets / Path(urlsplit(url).path).name
            if url != download_url + path.name:
                raise RuntimeError("An update asset uses an unexpected download address.")
            signature = element.get(f"{{{namespace}}}edSignature")
            length = element.get("length") or element.get(f"{{{namespace}}}length")
            if not signature or not path.is_file() or length != str(path.stat().st_size):
                raise RuntimeError("An update asset has an invalid signature or length.")
            run(tools / "sign_update", "--account", ACCOUNT, "--verify", path, signature)


def write_release_downloads(assets, dmg):
    # Add the fixed download after feed generation to avoid duplicate Sparkle versions.
    stable = assets / "Moppo.dmg"
    if stable.exists():
        raise RuntimeError("Moppo.dmg already exists in the assets folder.")
    shutil.copy2(dmg, stable)
    if digest(stable) != digest(dmg):
        raise RuntimeError("Moppo.dmg differs from the versioned DMG.")
    checksums = []
    for path in sorted(assets.iterdir()):
        if path.is_file() and path.suffix != ".sha256" and path.name != "SHA256SUMS":
            checksum = f"{digest(path)}  {path.name}\n"
            path.with_name(path.name + ".sha256").write_text(checksum)
            checksums.append(checksum)
    (assets / "SHA256SUMS").write_text("".join(checksums))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare", action="store_true", help="Build a signed candidate without notarization")
    mode.add_argument("--finish", action="store_true", help="Notarize an existing prepared candidate")
    parser.add_argument("--archive", type=Path, help="Export an existing archive instead of building it")
    parser.add_argument("--package-cache", type=Path, help="Reuse an Xcode package cache")
    parser.add_argument("--profile", default=os.environ.get("MOPPO_NOTARY_PROFILE", "anguria-studio"),
                        help="Notarization profile; defaults to MOPPO_NOTARY_PROFILE or anguria-studio")
    parser.add_argument("--sparkle-tools", type=Path, help="Sparkle bin folder; required for notarized assets")
    parser.add_argument("--notes", type=Path, help="Release notes to include in the signed feed")
    parser.add_argument("--scan-logging", action="store_true", help="Enable detailed local scan logs in this private test build")
    parser.add_argument("--download-url", help="HTTPS folder for versioned release downloads")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build < 1:
        parser.error("Use a three-part version and a positive build number.")
    if not args.prepare and (not args.profile or not args.sparkle_tools or not args.notes):
        parser.error("Notarization requires a profile, --sparkle-tools, and --notes.")
    if not args.prepare:
        if not args.notes.is_file() or args.notes.suffix not in (".md", ".html"):
            parser.error("Release notes must be an existing .md or .html file.")
        for name in ("generate_keys", "generate_appcast", "sign_update"):
            if not (args.sparkle_tools / name).is_file():
                parser.error(f"The Sparkle tools folder is missing {name}.")
    if args.finish and args.archive:
        parser.error("Use --archive only when you prepare a new candidate.")
    output = args.output.resolve()
    download_url = args.download_url or f"https://github.com/{REPOSITORY}/releases/download/v{args.version}/"
    if not download_url.endswith("/") or urlsplit(download_url).query or urlsplit(download_url).fragment:
        parser.error("The download address must end with / and contain no query or fragment.")
    manifest = output / "release.json"
    app = output / "app/Moppo.app"
    assets = output / "assets"
    dmg = assets / f"Moppo-{args.version}-{args.build}.dmg"
    if args.finish:
        record = json.loads(manifest.read_text())
        if record["notarized"] or record["version"] != args.version or record["build"] != args.build:
            parser.error("Use the version and build from an unfinished candidate.")
        identity, team = record["identity"], record["team"]
    else:
        if output.exists():
            parser.error("The output folder must not exist. Preserve earlier release files.")
        identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
        match = re.search(r'"(Developer ID Application: [^"\n]+ \(([A-Z0-9]+)\))"', identities)
        if not match:
            parser.error("A Developer ID Application certificate is required.")
        identity, team = match.groups()
        output.mkdir(parents=True)
        if args.archive:
            archive = args.archive.resolve()
        else:
            run("xcodegen", "generate", "--spec", ROOT / "project.yml")
            archive = output / "Moppo.xcarchive"
            command = ["xcodebuild", "-quiet", "-project", ROOT / "Moppo.xcodeproj",
                       "-scheme", "Moppo", "-configuration", "Release",
                       "-destination", "generic/platform=macOS", "-archivePath", archive,
                       "-derivedDataPath", output / "DerivedData",
                       "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
                       f"CODE_SIGN_IDENTITY={identity}", f"DEVELOPMENT_TEAM={team}",
                       f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}",
                       f"MOPPO_DETAILED_SCAN_LOGGING={'YES' if args.scan_logging else 'NO'}"]
            if args.package_cache:
                command += ["-clonedSourcePackagesDirPath", args.package_cache.resolve()]
            run(*command, "archive")
        with tempfile.TemporaryDirectory(prefix="moppo-export-") as temporary:
            options = Path(temporary) / "ExportOptions.plist"
            options.write_bytes(plistlib.dumps({"method": "developer-id", "teamID": team,
                                               "signingStyle": "manual", "signingCertificate": identity,
                                               "stripSwiftSymbols": True}))
            run("xcodebuild", "-exportArchive", "-archivePath", archive,
                "-exportPath", output / "app", "-exportOptionsPlist", options)
        record = {"version": args.version, "build": args.build, "identity": identity, "team": team,
                  "source_commit": run("git", "-C", ROOT, "rev-parse", "HEAD", capture=True).strip(),
                  "source_dirty": bool(run("git", "-C", ROOT, "status", "--porcelain", capture=True).strip()),
                  "notarized": False}
    record["detailed_scan_logging"] = validate_scan_logging(app, args.scan_logging)
    validate_app(app, args.version, args.build, team)
    manifest.write_text(json.dumps(record, indent=2) + "\n")
    assets.mkdir(exist_ok=True)
    if args.prepare:
        create_dmg(app, dmg, identity)
        print(f"Signed candidate: {output}. Notarization is incomplete. Do not distribute it.")
    else:
        tools = args.sparkle_tools.resolve()
        public_key = run(tools / "generate_keys", "--account", ACCOUNT, "-p", capture=True).strip()
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if public_key != info["SUPublicEDKey"]:
            raise RuntimeError("The Keychain update key differs from the app public key.")
        run("python3", ROOT / "scripts/validate-update-configuration.py",
            "--feed", download_url, "--key", public_key)
        with tempfile.TemporaryDirectory(prefix="moppo-notary-") as temporary:
            app_zip = Path(temporary) / "Moppo.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, app_zip)
            notarize(app_zip, args.profile, output / "notary-app.json")
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        run("spctl", "--assess", "--type", "execute", app)
        if dmg.exists():
            dmg.unlink()
        create_dmg(app, dmg, identity)
        notarize(dmg, args.profile, output / "notary-dmg.json")
        run("xcrun", "stapler", "staple", dmg)
        run("xcrun", "stapler", "validate", dmg)
        notes = assets / (dmg.stem + args.notes.suffix)
        shutil.copyfile(args.notes, notes)
        run(tools / "generate_appcast", "--account", ACCOUNT,
            "--download-url-prefix", download_url, "--release-notes-url-prefix", download_url,
            "--maximum-deltas", "0", assets)
        validate_update_assets(assets, tools, download_url)
        write_release_downloads(assets, dmg)
        record.update(notarized=True, repository=REPOSITORY, tag=f"v{args.version}",
                      feed=FEED, download_url=download_url)
    if args.prepare:
        dmg.with_name(dmg.name + ".sha256").write_text(f"{digest(dmg)}  {dmg.name}\n")
    if not args.prepare:
        manifest.write_text(json.dumps(record, indent=2) + "\n")
        print(f"Notarized release: {output}. No files were published.")


if __name__ == "__main__":
    main()
