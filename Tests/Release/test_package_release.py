"""不使用真实签名凭据，验证发布边界和嵌套签名顺序。"""
import importlib.util
import plistlib
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "package_release", Path(__file__).resolve().parents[2] / "Scripts/package-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Leap.app"
        self.info = {"CFBundleIdentifier": "com.padding.leap", "CFBundleExecutable": "Leap",
                     "CFBundleShortVersionString": "1.2.0", "LSMinimumSystemVersion": "26.0"}
        for name in ("Contents/MacOS/Leap", "Contents/Resources/Runtimes/node-24.21.0/bin/node",
                     "Contents/Resources/Runtimes/python-3.14.7/Versions/3.14/bin/python3.14"):
            file = self.app / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(bytes.fromhex("cffaedfe") + b"test")
        self.save_info()

    def save_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    @staticmethod
    def binary_result(*args):
        if args[0] == "lipo":
            return "arm64"
        return "v24.21.0" if args[0].endswith("/node") else "Python 3.14.7"

    def test_release_inputs(self):
        with patch.object(release, "run", side_effect=self.binary_result):
            self.assertEqual(release.inspect_app(self.app, "https://download.leap.cn/Leap.dmg"), "1.2.0")
            for url in ("http://download.leap.cn/Leap.dmg", "https://user:pass@leap.cn/a.dmg", "https://leap.cn/a.zip"):
                with self.assertRaises(ValueError):
                    release.inspect_app(self.app, url)
            (self.app / "Contents/MacOS/Leap.debug.dylib").touch()
            with self.assertRaisesRegex(ValueError, "Debug"):
                release.inspect_app(self.app, "https://leap.cn/a.dmg")

    def test_missing_certificate_leaves_no_artifact(self):
        with patch.object(release, "run", return_value="0 valid identities"):
            with self.assertRaisesRegex(ValueError, "证书"):
                release.package(self.app, "Developer ID Application: Test", "profile",
                                self.root / "output", "https://leap.cn/a.dmg")
        self.assertFalse((self.root / "output").exists())

    def test_output_cannot_modify_source_bundle(self):
        with self.assertRaisesRegex(ValueError, "内部"):
            release.package(self.app, "Developer ID Application: Test", "profile",
                            self.app / "output", "https://leap.cn/a.dmg")

    def test_sign_inside_out_and_limit_jit_entitlements(self):
        work = self.root / "work"
        work.mkdir()
        text = self.app / "Contents/Resources/example.py"
        text.write_text("print('hello')", encoding="utf-8")
        calls = []
        def command(*args):
            calls.append(args)
            return "Mach-O 64-bit executable arm64" if args[0] == "file" else ""
        with patch.object(release, "run", side_effect=command):
            release.sign_app(self.app, "Developer ID Application: Test", work)
        signing = [args for args in calls if args[0] == "codesign" and "--sign" in args]
        self.assertEqual(signing[-1][-1], str(self.app))
        self.assertTrue(all("--deep" not in args for args in signing))
        self.assertEqual(len(signing), 4)
        self.assertFalse(any(args[0] == "file" and args[-1] == str(text) for args in calls))
        entitlements = plistlib.loads((work / "node-entitlements.plist").read_bytes())
        self.assertNotIn("com.apple.security.get-task-allow", entitlements)
        self.assertTrue(entitlements["com.apple.security.cs.allow-jit"])
        self.assertEqual(calls[-1][1:4], ("--verify", "--deep", "--strict"))

    def test_rejected_notarization_stops(self):
        with patch.object(release, "run", return_value='{"status":"Invalid","id":"test-id"}'):
            with self.assertRaisesRegex(ValueError, "未接受"):
                release.notarize(self.root / "Leap.dmg", "profile")

    def test_python_extension_libraries_are_relocated_before_signing(self):
        version = self.app / "Contents/Resources/Runtimes/python-3.14.7/Versions/3.14"
        module = version / "lib/python3.14/lib-dynload/_ssl.so"
        library = version / "lib/libssl.3.dylib"
        for file in (module, library):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(bytes.fromhex("cffaedfe"))
        work = self.root / "work"
        work.mkdir()
        calls = []
        def command(*args):
            calls.append(args)
            if args[0] == "file":
                return "Mach-O 64-bit executable arm64"
            if args[:2] == ("otool", "-L") and args[-1] == str(module):
                return f"{module}:\n /Library/Frameworks/Python.framework/Versions/3.14/lib/libssl.3.dylib (compatibility version 3.0.0)"
            return ""
        with patch.object(release, "run", side_effect=command):
            release.sign_app(self.app, "-", work)
        change = next(args for args in calls if args[0] == "install_name_tool")
        self.assertEqual(change[3], "@loader_path/../../libssl.3.dylib")
        signing = next(args for args in calls if args[0] == "codesign" and "--sign" in args and args[-1] == str(module))
        self.assertLess(calls.index(change), calls.index(signing))
        library.unlink()
        with patch.object(release, "run", side_effect=command):
            with self.assertRaisesRegex(ValueError, "动态库"):
                release.sign_app(self.app, "-", work)

    def test_test_package_skips_notary_and_gatekeeper_and_preserves_source(self):
        calls = []
        headers = self.app / "Contents/Resources/Runtimes/python-3.14.7/Versions/3.14/Frameworks/Tk.framework/PrivateHeaders"
        headers.parent.mkdir(parents=True)
        headers.symlink_to("Versions/Current/PrivateHeaders")
        def command(*args):
            calls.append(args)
            if args[0] in ("lipo",) or args[0].endswith(("/node", "/python3.14")):
                return self.binary_result(*args)
            if args[0] == "file":
                return "Mach-O 64-bit executable arm64"
            if args[0] == "ditto":
                shutil.copytree(args[1], args[2], symlinks=True)
            if args[0] == "hdiutil" and args[1] == "create":
                staging = Path(args[args.index("-srcfolder") + 1])
                self.assertFalse((staging / "Leap.app" / headers.relative_to(self.app)).is_symlink())
                Path(args[-1]).write_bytes(b"test dmg")
            return ""
        original = (self.app / "Contents/Info.plist").read_bytes()
        output = self.root / "output"
        with patch.object(release, "run", side_effect=command), patch.object(release, "notarize") as notary:
            release.package(self.app, "", "", output, None, test=True)
            notary.assert_not_called()
        self.assertTrue((output / "Leap-1.2.0-arm64-test.dmg").exists())
        metadata = release.json.loads((output / "Leap-1.2.0-release.json").read_text())
        self.assertNotIn("downloadURL", metadata)
        self.assertFalse(metadata["notarized"])
        self.assertFalse(any(args[0] in ("security", "xcrun", "spctl") for args in calls))
        signing = [args for args in calls if args[0] == "codesign" and "--sign" in args]
        self.assertTrue(all(args[args.index("--sign") + 1] == "-" for args in signing))
        self.assertTrue(all("--timestamp" not in args and "runtime" not in args for args in signing))
        self.assertTrue(any(args[:4] == ("codesign", "--verify", "--deep", "--strict") for args in calls))
        self.assertEqual((self.app / "Contents/Info.plist").read_bytes(), original)
        self.assertTrue(headers.is_symlink())
        self.assertTrue(any("import ssl, sqlite3" in args for args in calls))
        self.assertTrue(any("import ssl, sqlite3" in args and "-B" in args for args in calls))
        self.assertEqual(sum(args[:4] == ("codesign", "--verify", "--deep", "--strict") for args in calls), 2)

    def test_formal_package_requires_download_url(self):
        with self.assertRaisesRegex(ValueError, "下载地址"):
            release.package(self.app, "Developer ID Application: Test", "profile", self.root / "output", None)


if __name__ == "__main__":
    unittest.main()
