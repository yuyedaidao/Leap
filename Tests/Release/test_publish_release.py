"""模拟系统和 GitHub 边界，不使用真实证书、不创建仓库或公开发行版。"""
import argparse
import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "publish_release", Path(__file__).resolve().parents[2] / "Scripts/publish-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.args = argparse.Namespace(repo=release.DEFAULT_REPO, test=True, notes_file=None, local_only=False)
        self.repository = {"private": False, "permissions": {"push": True}, "default_branch": "main"}

    def test_release_names_come_from_built_app(self):
        app = self.root / "Leap.app"
        (app / "Contents").mkdir(parents=True)
        info = {"CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "3"}
        plist = app / "Contents/Info.plist"
        plist.write_bytes(plistlib.dumps(info))
        self.assertEqual(release.release_info(app, False), ("1.2.0", "3", "v1.2.0", "Leap-1.2.0-arm64.dmg"))
        self.assertEqual(release.release_info(app, True), ("1.2.0", "3", "v1.2.0-test.3", "Leap-1.2.0-arm64-test.dmg"))
        for version, build in (("../1", "3"), ("1.2.0", "../3"), (12, "3")):
            info.update(CFBundleShortVersionString=version, CFBundleVersion=build)
            plist.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                release.release_info(app, True)

    def test_github_only_treats_explicit_404_as_missing(self):
        for status in (401, 403, 404, 500):
            error = subprocess.CalledProcessError(1, ["gh"], stderr=f"gh: Not Found (HTTP {status})")
            with patch.object(release, "run", side_effect=error):
                if status == 404:
                    self.assertIsNone(release.github("repos/test/downloads"))
                else:
                    with self.assertRaises(subprocess.CalledProcessError):
                        release.github("repos/test/downloads")

    def test_repo_must_be_public_and_writable(self):
        for data in ({"private": True}, {"archived": True}, {"permissions": {"push": False}}):
            with patch.object(release, "github", return_value=data):
                with self.assertRaises(ValueError):
                    release.check_repo("test/downloads")
        # 发行仓库即源码仓库，不存在时直接报错，不再自动创建
        with patch.object(release, "github", return_value=None):
            with self.assertRaises(ValueError):
                release.check_repo(release.DEFAULT_REPO)
        with self.assertRaises(ValueError):
            release.check_repo("../repo")

    def test_clean_source_is_required(self):
        with patch.object(release, "run", return_value=" M Project.swift"):
            with self.assertRaisesRegex(ValueError, "未提交"):
                release.require_clean()

    def test_local_test_needs_no_github_or_clean_worktree(self):
        self.args.local_only = True
        with patch.object(release.platform, "system", return_value="Darwin"), \
             patch.object(release.platform, "machine", return_value="arm64"), \
             patch.object(release.shutil, "which", side_effect=lambda command: None if command == "gh" else "tool"), \
             patch.object(release, "require_clean") as clean, \
             patch.object(release, "run") as command, \
             patch.object(release, "check_repo") as repo:
            self.assertEqual(release.preflight(self.args), (None, "", ""))
            clean.assert_not_called()
            command.assert_not_called()
            repo.assert_not_called()
        self.args.test = False
        with self.assertRaisesRegex(ValueError, "--test"):
            release.preflight(self.args)

    def test_legacy_tuist_launcher_uses_selected_binary(self):
        executable = self.root / ".tuist/Versions/4.158.0/tuist"
        executable.parent.mkdir(parents=True)
        executable.touch(mode=0o755)
        with patch.object(release.Path, "home", return_value=self.root), \
             patch.object(release, "run", return_value="4.158.0"):
            self.assertEqual(release.tuist_executable(), str(executable))
            executable.unlink()
            self.assertEqual(release.tuist_executable(), "tuist")

    def test_preflight_stops_on_missing_tool_or_login(self):
        with patch.object(release.platform, "system", return_value="Darwin"), \
             patch.object(release.platform, "machine", return_value="arm64"), \
             patch.object(release.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "工具"):
                release.preflight(self.args)
        error = subprocess.CalledProcessError(1, ["gh"])
        with patch.object(release.platform, "system", return_value="Darwin"), \
             patch.object(release.platform, "machine", return_value="arm64"), \
             patch.object(release.shutil, "which", return_value="tool"), \
             patch.object(release, "require_clean"), patch.object(release, "run", side_effect=error), \
             patch.object(release, "check_repo") as repo:
            with self.assertRaises(subprocess.CalledProcessError):
                release.preflight(self.args)
            repo.assert_not_called()

    def test_formal_missing_identity_never_falls_back_to_test(self):
        self.args.test = False
        with patch.object(release.platform, "system", return_value="Darwin"), \
             patch.object(release.platform, "machine", return_value="arm64"), \
             patch.object(release.shutil, "which", return_value="tool"), \
             patch.object(release, "require_clean"), patch.object(release, "run", return_value=""), \
             patch.dict(release.os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "Developer ID"):
                release.preflight(self.args)
        self.assertFalse(self.args.test)

    def test_formal_selects_certificate_and_checks_notary_profile(self):
        self.args.test = False
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            return '1) ABC "Developer ID Application: Test (TEAM)"' if args[0] == "security" else ""
        with patch.object(release.platform, "system", return_value="Darwin"), \
             patch.object(release.platform, "machine", return_value="arm64"), \
             patch.object(release.shutil, "which", return_value="tool"), \
             patch.object(release, "require_clean"), patch.object(release, "run", side_effect=command), \
             patch.object(release, "check_repo", return_value=self.repository), \
             patch.dict(release.os.environ, {}, clear=True):
            _, identity, profile = release.preflight(self.args)
        self.assertEqual(identity, "Developer ID Application: Test (TEAM)")
        self.assertEqual(profile, "LeapNotary")
        self.assertTrue(any(args[:3] == ("xcrun", "notarytool", "history") for args in calls))

    def test_duplicate_release_or_tag_stops(self):
        for results in (({},), (None, {})):
            with patch.object(release, "github", side_effect=results), patch.object(release, "run") as command:
                with self.assertRaisesRegex(ValueError, "已存在"):
                    release.require_new_tag("test/downloads", "v1.2.0")
                command.assert_not_called()

    def publish_fixture(self, test, failure=None):
        files = [self.root / name for name in ("Leap.dmg", "release.json", "SHA256SUMS.txt")]
        for file in files:
            file.write_bytes(b"original bytes")
        notes = self.root / "notes.md"
        notes.write_text("发布说明", encoding="utf-8")
        calls = []
        def command(*args, **kwargs):
            calls.append(args)
            operation = args[2]
            if operation == failure:
                raise subprocess.CalledProcessError(1, list(args))
            if operation == "download":
                destination = Path(args[args.index("--dir") + 1])
                for original in files:
                    (destination / original.name).write_bytes(b"corrupt" if failure == "checksum" else original.read_bytes())
            return ""
        with patch.object(release, "require_new_tag"), patch.object(release, "run", side_effect=command):
            if failure:
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    release.publish("test/downloads", "v1.2.0", test, files, notes, "commit")
            else:
                release.publish("test/downloads", "v1.2.0", test, files, notes, "commit")
        return calls

    def test_publish_only_after_all_assets_match(self):
        calls = self.publish_fixture(False)
        self.assertEqual([args[2] for args in calls], ["create", "upload", "download", "edit"])
        self.assertIn("--draft", calls[0])
        self.assertIn("--draft=false", calls[-1])
        self.assertIn("--latest=true", calls[-1])
        self.assertIn("--target", calls[0])

    def test_test_release_never_becomes_latest(self):
        calls = self.publish_fixture(True)
        self.assertIn("--prerelease=true", calls[0])
        self.assertIn("--latest=false", calls[-1])

    def test_upload_download_or_checksum_failure_keeps_draft(self):
        for failure in ("create", "upload", "download", "checksum"):
            with self.subTest(failure=failure):
                calls = self.publish_fixture(False, failure)
                self.assertFalse(any(args[2] == "edit" for args in calls))
                self.assertTrue((self.root / "Leap.dmg").exists())

    def test_pipeline_order_and_local_failures_never_publish(self):
        for test, failure, local in ((False, None, False), (True, None, False), (True, None, True),
                                     (False, "build", False), (False, "package", False), (False, "source", False)):
            with self.subTest(test=test, failure=failure, local=local):
                self.args.test = test
                self.args.local_only = local
                calls = []
                def command(*args, **kwargs):
                    calls.append(args)
                    if args[0] == "git":
                        return "source-commit"
                    if args[:2] == ("xcodebuild", "build"):
                        if failure == "build":
                            raise subprocess.CalledProcessError(1, list(args))
                        derived = Path(args[args.index("-derivedDataPath") + 1])
                        contents = derived / "Build/Products/Release/Leap.app/Contents"
                        contents.mkdir(parents=True)
                        (contents / "Info.plist").write_bytes(plistlib.dumps({
                            "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "3"}))
                    if len(args) > 1 and args[1].endswith("package-release.py"):
                        if failure == "package":
                            raise subprocess.CalledProcessError(1, list(args))
                        output = Path(args[args.index("--output") + 1])
                        (output / f"Leap-1.2.0-arm64{'-test' if test else ''}.dmg").write_bytes(b"dmg")
                        (output / "Leap-1.2.0-release.json").write_text(json.dumps({"version": "1.2.0"}))
                    return "commit"
                with patch.object(release, "ROOT", self.root), \
                     patch.object(release, "preflight", return_value=(self.repository, "identity", "profile")), \
                     patch.object(release, "require_clean", side_effect=ValueError("锁文件有改动") if failure == "source" else None), \
                     patch.object(release, "require_new_tag"), \
                     patch.object(release, "check_repo", return_value=self.repository), \
                     patch.object(release, "run", side_effect=command), patch.object(release, "publish") as publish:
                    if failure:
                        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                            release.release(self.args)
                        publish.assert_not_called()
                    else:
                        release.release(self.args)
                        if local:
                            publish.assert_not_called()
                            self.assertFalse(any(args[0] == "gh" for args in calls))
                        else:
                            self.assertEqual(publish.call_args.args[1], "v1.2.0-test.3" if test else "v1.2.0")
                        package = next(args for args in calls if len(args) > 1 and args[1].endswith("package-release.py"))
                        self.assertEqual("--download-url" in package, not local)
                        self.assertEqual("--test" in package, test)
                        self.assertEqual("--identity" in package, not test)
                        self.assertLess(next(i for i, args in enumerate(calls) if args[:2] == ("xcodebuild", "test")), calls.index(package))
                        build_command = next(args for args in calls if args[:2] == ("xcodebuild", "build"))
                        test_command = next(args for args in calls if args[:2] == ("xcodebuild", "test"))
                        self.assertEqual(build_command[build_command.index("-configuration") + 1], "Release")
                        self.assertEqual(test_command[test_command.index("-configuration") + 1], "Debug")
                        self.assertIn("Build/Products/Release/Leap.app", package[2])


if __name__ == "__main__":
    unittest.main()
