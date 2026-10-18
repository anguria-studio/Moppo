"""Check diagnostic settings before release packaging."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("package_release", Path(__file__).with_name("package-release.py"))
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class ScanLoggingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="moppo-package-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "candidate/app/Moppo.app"

    def write_app(self, setting):
        self.app.joinpath("Contents").mkdir(parents=True, exist_ok=True)
        info = {} if setting is None else {"MoppoDetailedScanLogging": setting}
        self.app.joinpath("Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def test_matching_modes_and_legacy_archives(self):
        for setting, requested in [(None, False), ("NO", False), ("YES", True), ("yes", True)]:
            with self.subTest(setting=setting):
                self.write_app(setting)
                self.assertEqual(PACKAGE.validate_scan_logging(self.app, requested), requested)

    def test_mismatched_modes_are_rejected(self):
        for setting, requested in [("YES", False), ("yes", False), ("NO", True), (None, True)]:
            with self.subTest(setting=setting, requested=requested):
                self.write_app(setting)
                with self.assertRaises(RuntimeError):
                    PACKAGE.validate_scan_logging(self.app, requested)

    def test_invalid_settings_are_rejected(self):
        for setting in [True, False, 1, "", "$(MOPPO_DETAILED_SCAN_LOGGING)"]:
            with self.subTest(setting=setting):
                self.write_app(setting)
                with self.assertRaisesRegex(RuntimeError, "invalid"):
                    PACKAGE.validate_scan_logging(self.app, False)

    def test_archive_and_finish_reject_diagnostic_apps_before_packaging(self):
        notes = self.root / "notes.md"
        notes.write_text("Test release.\n")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ["generate_keys", "generate_appcast", "sign_update"]:
            tools.joinpath(name).touch()

        for mode in ["archive", "finish"]:
            with self.subTest(mode=mode):
                output = self.root / mode
                self.app = output / "app/Moppo.app"
                arguments = ["package-release.py", "--version", "0.2.0", "--build", "30",
                             "--output", str(output)]
                if mode == "finish":
                    self.write_app("YES")
                    output.joinpath("release.json").write_text(json.dumps({
                        "version": "0.2.0", "build": 30, "notarized": False,
                        "identity": "Test", "team": "TESTTEAM", "detailed_scan_logging": False,
                    }))
                    arguments += ["--finish", "--sparkle-tools", str(tools), "--notes", str(notes)]
                else:
                    arguments += ["--prepare", "--archive", str(self.root / "Moppo.xcarchive")]

                def run(*command, **options):
                    if command[0] == "security":
                        return '"Developer ID Application: Test (TESTTEAM)"'
                    if command[:2] == ("xcodebuild", "-exportArchive"):
                        self.write_app("YES")
                    return ""

                with patch("sys.argv", arguments), patch.object(PACKAGE, "run", side_effect=run), \
                     patch.object(PACKAGE, "validate_app") as validate, \
                     patch.object(PACKAGE, "create_dmg") as create, \
                     patch.object(PACKAGE, "notarize") as notarize:
                    with self.assertRaisesRegex(RuntimeError, "Normal packages cannot"):
                        PACKAGE.main()
                    validate.assert_not_called()
                    create.assert_not_called()
                    notarize.assert_not_called()
                self.assertFalse(output.joinpath("assets").exists())


if __name__ == "__main__":
    unittest.main()
