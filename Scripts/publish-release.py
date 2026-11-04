#!/usr/bin/env python3
"""本机构建 Leap，打包并发布到 GitHub Releases。"""
import argparse
import base64
import html
import xml.etree.ElementTree as ET
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REPO = "yuyedaidao/Leap"


def run(*args, log=None):
    """长任务写入日志，短查询捕获结果；参数列表避免 Shell 插值。"""
    if log is None:
        return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    print(f"执行 {args[0]}，日志：{log}", flush=True)
    with log.open("a", encoding="utf-8") as output:
        output.write(f"\n执行 {args[0]}\n")
        output.flush()
        subprocess.run(args, cwd=ROOT, check=True, stdout=output, stderr=subprocess.STDOUT, text=True)
    return ""


def github(path):
    try:
        return json.loads(run("gh", "api", path))
    except subprocess.CalledProcessError as error:
        # 只有明确的 404 才代表不存在，不能在断网或权限不足时创建替代仓库。
        if "(HTTP 404)" in (error.stderr or ""):
            return None
        raise


def require_clean():
    if run("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("源码工作区有未提交改动，请先提交或自行整理；脚本不会自动提交或清理。")


def tuist_executable():
    # 旧 tuistenv 会截获 install，优先调用它已选择的真实版本以安装项目依赖。
    version = run("tuist", "version")
    if re.fullmatch(r"\d+\.\d+\.\d+", version):
        executable = Path.home() / ".tuist/Versions" / version / "tuist"
        if executable.is_file() and os.access(executable, os.X_OK):
            return str(executable)
    return "tuist"


def check_repo(repo):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", repo) or repo.split("/")[1] in (".", ".."):
        raise ValueError("仓库必须使用 owner/repo 格式。")
    data = github(f"repos/{repo}")
    if data is None:
        raise ValueError("发行仓库不存在或不可访问，请先创建源码仓库。")
    if data.get("private") or data.get("archived") or data.get("disabled"):
        raise ValueError("发行仓库必须公开且可写；脚本不会修改仓库可见性。")
    if not data.get("permissions", {}).get("push"):
        raise ValueError("当前 GitHub 账号没有目标仓库的写入权限。")
    return data


def preflight(args):
    if args.local_only and not args.test:
        raise ValueError("本地打包请显式搭配 --test；正式发行继续使用公证发布流程。")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("发布脚本仅支持 Apple Silicon Mac。")
    commands = ("git", "tuist", "xcodebuild", "swiftlint", "codesign", "xcrun",
                "hdiutil", "ditto", "curl", "file", "lipo", "otool", "install_name_tool", "security", "spctl")
    for command in commands + (() if args.local_only else ("gh",)):
        if shutil.which(command) is None:
            raise ValueError(f"缺少必要工具：{command}")
    if args.notes_file:
        # 发布说明必须在任何远端写操作之前读成功。
        args.notes_file = args.notes_file.resolve()
        args.notes_file.read_text(encoding="utf-8")
    if not (args.local_only and args.test):
        require_clean()
    if not args.local_only:
        run("gh", "auth", "status", "--hostname", "github.com")
    identity, profile = "", ""
    if not args.test:
        identities = re.findall(r'"(Developer ID Application:[^"]+)"',
                                run("security", "find-identity", "-v", "-p", "codesigning"))
        identity = os.environ.get("LEAP_SIGN_IDENTITY", "")
        if not identity and len(identities) == 1:
            identity = identities[0]
        if not identity or identity not in identities:
            raise ValueError("需要有效的 Developer ID Application 证书；多张证书时请设置 LEAP_SIGN_IDENTITY。")
        profile = os.environ.get("LEAP_NOTARY_PROFILE", "LeapNotary").strip()
        if not profile:
            raise ValueError("LEAP_NOTARY_PROFILE 不能为空。")
        run("xcrun", "notarytool", "history", "--keychain-profile", profile, "--output-format", "json")
    return (None if args.local_only else check_repo(args.repo)), identity, profile


def release_info(app, test):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if not isinstance(info, dict):
        raise ValueError("应用 Info.plist 必须是字典。")
    version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("应用版本必须是三段数字。")
    if not isinstance(build, str) or not re.fullmatch(r"\d+", build):
        raise ValueError("应用构建号必须是非负整数。")
    tag = f"v{version}" + (f"-test.{build}" if test else "")
    filename = f"Leap-{version}-arm64{'-test' if test else ''}.dmg"
    return version, build, tag, filename


def require_new_tag(repo, tag):
    if github(f"repos/{repo}/releases/tags/{tag}") is not None:
        raise ValueError(f"发行版 {tag} 已存在，不能覆盖；若是失败草稿，请按文档手动恢复。")
    if github(f"repos/{repo}/git/ref/tags/{tag}") is not None:
        raise ValueError(f"标签 {tag} 已存在，不能覆盖；请使用新版本或新构建号。")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_public_feed(repo, tag, artifacts):
    """匿名检查客户端真正使用的 latest 地址，不能仅依赖已认证的附件回读。"""
    expected = next(path for path in artifacts if path.name == "appcast.xml").read_bytes()
    url = f"https://github.com/{repo}/releases/latest/download/appcast.xml"
    for attempt in range(3):
        try:
            # 系统 curl 使用本机证书信任配置，避免发行脚本所用 Python 缺少 CA 根证书。
            with tempfile.TemporaryDirectory(prefix="leap-public-feed-") as temporary:
                downloaded = Path(temporary) / "appcast.xml"
                run("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
                    "--proto-redir", "=https", "--max-time", "30", "--max-filesize", "2097152",
                    "--output", str(downloaded), url)
                if downloaded.read_bytes() != expected:
                    raise ValueError("公开更新订阅与本次发行不一致。")
            print(f"公开更新订阅已验证：{tag} / {url}", flush=True)
            return
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            if attempt == 2:
                raise ValueError(f"Release 已公开，但线上订阅验收失败：{error}") from error
            time.sleep(2)


def publish(repo, tag, test, artifacts, notes, target):
    print(f"上传 {repo} / {tag}…", flush=True)
    require_new_tag(repo, tag)
    try:
        run("gh", "release", "create", tag, "--repo", repo, "--target", target,
            "--draft", f"--prerelease={'true' if test else 'false'}", "--title", f"Leap {tag}",
            "--notes-file", str(notes))
        run("gh", "release", "upload", tag, *(str(path) for path in artifacts), "--repo", repo)
        # 草稿还没有公开下载地址，通过已认证 CLI 回读全部附件再公开。
        with tempfile.TemporaryDirectory(prefix="leap-download-", dir=notes.parent) as temporary:
            downloaded = Path(temporary)
            run("gh", "release", "download", tag, "--repo", repo, "--dir", str(downloaded))
            for original in artifacts:
                copy = downloaded / original.name
                if not copy.is_file() or copy.stat().st_size != original.stat().st_size or sha256(copy) != sha256(original):
                    raise ValueError(f"远端附件校验失败：{original.name}")
        run("gh", "release", "edit", tag, "--repo", repo, "--draft=false",
            f"--prerelease={'true' if test else 'false'}", f"--latest={'false' if test else 'true'}")
    except (ValueError, OSError, subprocess.CalledProcessError):
        print(f"发布未完成，本地产物保留在 {notes.parent}。\n"
              f"请检查 https://github.com/{repo}/releases；若已创建草稿，将缺少的附件上传后，"
              "按发行手册回读校验，再手动公开。脚本不会删除或覆盖远端附件。", file=sys.stderr)
        raise
    if not test:
        verify_public_feed(repo, tag, artifacts)
    return f"https://github.com/{repo}/releases/tag/{tag}"


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE_ACCOUNT = "com.padding.leap.sparkle"


def check_update_build(repo, build):
    """旧发行版没有订阅文件时允许首次接入，其他网络错误仍应终止发行。"""
    latest = github(f"repos/{repo}/releases/latest")
    if latest is None:
        return
    assets = [asset for asset in latest.get("assets", []) if asset["name"] == "appcast.xml"]
    if not assets:
        return
    feed = run("gh", "api", f"repos/{repo}/releases/assets/{assets[0]['id']}",
               "-H", "Accept: application/octet-stream")
    versions = ET.fromstring(feed).findall(f".//{{{SPARKLE_NAMESPACE}}}version")
    if not versions or any(not (item.text or "").isdigit() for item in versions):
        raise ValueError("远端更新订阅的构建号无效。")
    if int(build) <= max(int(item.text) for item in versions):
        raise ValueError("正式发行 CFBundleVersion 必须大于上一份更新订阅的构建号。")


def generate_update_feed(app, dmg, notes, repo, tag, output):
    tools = ROOT / "Tuist/.build/artifacts/sparkle/Sparkle/bin"
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    public_key = run(str(tools / "generate_keys"), "--account", SPARKLE_ACCOUNT, "-p")
    if len(base64.b64decode(public_key, validate=True)) != 32 or public_key != info.get("SUPublicEDKey"):
        raise ValueError("钥匙串更新签名公钥与应用 SUPublicEDKey 不匹配。")
    expected_feed = f"https://github.com/{repo}/releases/latest/download/appcast.xml"
    if info.get("SUFeedURL") != expected_feed:
        raise ValueError("应用更新订阅地址与发行仓库不匹配。")
    check_update_build(repo, info["CFBundleVersion"])
    feed = output / "appcast.xml"
    # 目录中只有最终公证 DMG，避免生成器误收集构建缓存或测试产物。
    with tempfile.TemporaryDirectory(prefix="leap-appcast-", dir=output) as temporary:
        archives = Path(temporary)
        (archives / dmg.name).hardlink_to(dmg)
        (archives / dmg.with_suffix(".html").name).write_text(
            "<pre>" + html.escape(notes.read_text(encoding="utf-8")) + "</pre>", encoding="utf-8")
        run(str(tools / "generate_appcast"), "--account", SPARKLE_ACCOUNT,
            "--download-url-prefix", f"https://github.com/{repo}/releases/download/{tag}/",
            "--maximum-deltas", "0", "--embed-release-notes", "--link",
            f"https://github.com/{repo}/releases/tag/{tag}", "-o", str(feed), str(archives))
    items = ET.parse(feed).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("更新订阅必须且只能包含本次正式发行。")
    item = items[0]
    enclosure = item.find("enclosure")
    expected_url = f"https://github.com/{repo}/releases/download/{tag}/{dmg.name}"
    if (item.findtext(f"{{{SPARKLE_NAMESPACE}}}version") != info["CFBundleVersion"]
            or enclosure is None or enclosure.get("url") != expected_url
            or enclosure.get("length") != str(dmg.stat().st_size)
            or not enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")):
        raise ValueError("生成的更新订阅版本、附件或签名不完整。")
    return feed


def release(args):
    repository, identity, profile = preflight(args)
    commit = run("git", "rev-parse", "HEAD")
    source_diff = run("git", "diff", "HEAD") if args.local_only and args.test else ""
    output_root = ROOT / "build/releases"
    output_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="run-", dir=output_root))
    log = output / "build.log"
    print(f"本次产物和日志：{output}", flush=True)
    log.write_text(f"源码提交：{commit}\n模式：{'测试' if args.test else '正式'}\n", encoding="utf-8")
    if args.local_only and args.test:
        (output / "source.patch").write_text(source_diff + "\n", encoding="utf-8")
    try:
        run(str(ROOT / "Scripts/prepare-runtimes.sh"), log=log)
        tuist = tuist_executable()
        run(tuist, "install", "--no-update", log=log)
        run(tuist, "generate", "--no-open", log=log)
        run("swiftlint", "lint", "Sources", "Tests/LeapTests", "Project.swift", log=log)
        derived = output / "DerivedData"
        build_args = ("-workspace", "Leap.xcworkspace", "-scheme", "Leap",
                      "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
                      "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=NO")
        run("xcodebuild", "build", *build_args, "-configuration", "Release", log=log)
        # @testable 依赖 Debug 的 enable-testing，不能用测试构建覆盖待发行的 Release。
        run("xcodebuild", "test", *build_args, "-configuration", "Debug", "-only-testing:LeapTests", log=log)
        run(sys.executable, "-m", "unittest", "discover", "-s", "Tests/Release", "-v", log=log)
        # Tuist 解析依赖可能改动锁文件；有变化就停止，不能发行无法复现的源码状态。
        if args.local_only and args.test:
            if run("git", "diff", "HEAD") != source_diff:
                raise ValueError("构建期间源码或锁文件改变，请检查改动后重新打包。")
        else:
            require_clean()
        if run("git", "rev-parse", "HEAD") != commit:
            raise ValueError("构建期间源码提交已改变，请重新运行，不能发布混合源码状态。")
        app = derived / "Build/Products/Release/Leap.app"
        version, build, tag, filename = release_info(app, args.test)
        if repository is not None:
            require_new_tag(args.repo, tag)
        download_url = f"https://github.com/{args.repo}/releases/download/{tag}/{filename}"
        package_args = [sys.executable, str(ROOT / "Scripts/package-release.py"), str(app),
                        "--output", str(output)]
        if not args.local_only or not args.test:
            package_args += ["--download-url", download_url]
        if args.test:
            package_args += ["--test"]
        else:
            package_args += ["--identity", identity, "--notary-profile", profile]
        run(*package_args, log=log)
        dmg = output / filename
        metadata = output / f"Leap-{version}-release.json"
        checksum = output / "SHA256SUMS.txt"
        checksum.write_text(f"{sha256(dmg)}  {filename}\n", encoding="utf-8")
        notes = output / "release-notes.md"
        supplied = args.notes_file.read_text(encoding="utf-8") if args.notes_file else "Leap macOS 应用发行。"
        warning = "\n\n测试包：未经过 Apple 公证，可能被 Gatekeeper 拦截。" if args.test else ""
        notes.write_text(f"{supplied}{warning}\n\n版本：{version}（构建 {build}）\n"
                         f"系统要求：macOS 26+ / Apple Silicon\n源码提交：{commit}\n"
                         f"{'本地测试包包含 source.patch 中的未提交改动。' if args.local_only and args.test else '发行标签指向本次发行的源码提交。'}\n\n"
                         f"DMG SHA256：`{sha256(dmg)}`\n", encoding="utf-8")
        if args.local_only:
            print(f"本地安装包已生成：{dmg}\n校验文件：{checksum}\n未上传或发布。", flush=True)
            return
        # 发行仓库就是源码仓库：标签指向本地已验证的 HEAD，即被构建的源码提交。
        artifacts = [dmg, metadata, checksum]
        if not args.test:
            artifacts.append(generate_update_feed(app, dmg, notes, args.repo, tag, output))
        url = publish(args.repo, tag, args.test, artifacts, notes, commit)
        print(f"发布成功：{url}\nDMG 下载：{download_url}\n本地产物：{output}", flush=True)
    except (ValueError, OSError, subprocess.CalledProcessError):
        print(f"本次失败；产物和日志保留在 {output}，请查看 build.log。", file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true", help="发布临时签名、未公证的预发布版本")
    parser.add_argument("--local-only", action="store_true", help="仅生成本地安装包，不连接 GitHub；搭配 --test 可打包未提交改动")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="发布 Releases 的仓库，格式 owner/repo")
    parser.add_argument("--notes-file", type=Path, help="UTF-8 更新说明文件")
    args = parser.parse_args()
    try:
        release(args)
    except (ValueError, KeyError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        # 不输出完整命令或环境，避免认证信息进入日志。
        message = f"命令 {error.cmd[0]} 失败（退出码 {error.returncode}）" if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"发行失败：{message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
