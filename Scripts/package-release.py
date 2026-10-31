#!/usr/bin/env python3
"""在临时副本中签名、公证并生成发行 DMG，始终保留原始构建。

省略应用路径时自动查找最近的 Release 构建；证书取钥匙串中唯一的 Developer ID，
公证配置默认 LeapNotary，下载地址按本仓库 Releases 与版本生成，产物写入 ./build。
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RELEASE_REPO = "yuyedaidao/Leap"
DEFAULT_NOTARY_PROFILE = "LeapNotary"
# 已知 Release 产物位置；按修改时间取最新一个，避免默认值命中过期构建。
APP_SEARCH = (
    (ROOT, "build/releases/run-*/DerivedData/Build/Products/Release/Leap.app"),
    (Path.home(), "Library/Developer/Xcode/DerivedData/Leap-*/Build/Products/Release/Leap.app"),
    (Path("/private/tmp"), "leap-release-build/Build/Products/Release/Leap.app"),
)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def default_app():
    candidates = []
    for base, pattern in APP_SEARCH:
        candidates.extend(path for path in base.glob(pattern)
                          if path.is_dir() and path.suffix == ".app")
    if not candidates:
        raise ValueError("未找到 Release 构建的 Leap.app，请显式传入应用路径。")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def default_download_url(version):
    return (f"https://github.com/{DEFAULT_RELEASE_REPO}/releases/download/"
            f"v{version}/Leap-{version}-arm64.dmg")


def validate_download_url(download_url):
    url = urlsplit(download_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password or not url.path.endswith(".dmg"):
        raise ValueError("下载地址必须是无凭据的 HTTPS DMG 地址。")


def inspect_app(app, download_url):
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("请提供存在的 Release .app 目录。")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if not isinstance(info, dict):
        raise ValueError("应用 Info.plist 必须是字典。")
    version = info.get("CFBundleShortVersionString", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("应用版本必须是三段数字。")
    if info.get("CFBundleIdentifier") != "com.padding.leap":
        raise ValueError("只能打包 Leap 应用。")
    if list(app.rglob("*.debug.dylib")) or list(app.rglob("__preview.dylib")):
        raise ValueError("不能发布 Debug/预览构建，请使用 Release 配置。")
    if download_url:
        validate_download_url(download_url)
    minimum = info.get("LSMinimumSystemVersion", "")
    if minimum not in ("26.0", "26.0.0"):
        raise ValueError("应用最低系统版本必须是 macOS 26.0。")
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("应用主可执行文件名称无效。")
    main = app / "Contents/MacOS" / executable
    runtime = app / "Contents/Resources/Runtimes"
    node = runtime / "node-24.21.0/bin/node"
    python = runtime / "python-3.14.7/Versions/3.14/bin/python3.14"
    for binary in (main, node, python):
        if not binary.is_file() or "arm64" not in run("lipo", "-archs", str(binary)).split():
            raise ValueError(f"缺少 arm64 可执行文件：{binary}")
    if run(str(node), "--version") != "v24.21.0" or run(str(python), "--version") != "Python 3.14.7":
        raise ValueError("随包运行时版本不符合当前发布要求。")
    return version


def sign_app(app, identity, work):
    node_entitlements = work / "node-entitlements.plist"
    # 只为 Node 的 JIT 开放执行内存；不沿用上游 get-task-allow 调试授权。
    node_entitlements.write_bytes(plistlib.dumps({
        "com.apple.security.cs.allow-jit": True,
        "com.apple.security.cs.allow-unsigned-executable-memory": True,
    }))
    app_entitlements = work / "app-entitlements.plist"
    app_entitlements.write_bytes(plistlib.dumps({"com.apple.security.automation.apple-events": True}))
    binaries = []
    mach_o_magic = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    for candidate in app.rglob("*"):
        if candidate.is_file() and not candidate.is_symlink():
            # Python 随包有大量文本文件，先读魔数，避免为每个文件启动 file 子进程。
            with candidate.open("rb") as source:
                header = source.read(4)
            if header in mach_o_magic and "Mach-O" in run("file", "-b", str(candidate)):
                binaries.append(candidate)
    # 临时签名不请求时间戳，也不启用只有正式发行才需要的 Hardened Runtime。
    signing = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        signing += ["--timestamp", "--options", "runtime"]
    for binary in sorted(binaries, key=lambda item: len(item.parts), reverse=True):
        python_version = app / "Contents/Resources/Runtimes/python-3.14.7/Versions/3.14"
        if binary.is_relative_to(python_version):
            # Python 的扩展库也引用系统安装路径，必须在签名前改成包内相对路径。
            prefix = "/Library/Frameworks/Python.framework/Versions/3.14/"
            for line in run("otool", "-L", str(binary)).splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                if dependency.startswith(prefix):
                    target = python_version / dependency[len(prefix):]
                    if not target.is_file():
                        raise ValueError(f"Python 包内缺少动态库：{target}")
                    if target != binary:
                        relative = os.path.relpath(target, binary.parent)
                        run("install_name_tool", "-change", dependency, f"@loader_path/{relative}", str(binary))
        args = list(signing)
        if binary.name == "node":
            args += ["--entitlements", str(node_entitlements)]
        run(*args, str(binary))
    # 内层代码先签，再封装 bundle；--deep 只用于验证，避免统一授权递归签名。
    bundles = [item for item in app.rglob("*") if item.is_dir() and not item.is_symlink()
               and item.suffix in (".app", ".framework", ".xpc", ".appex")]
    for bundle in sorted(bundles, key=lambda item: len(item.parts), reverse=True):
        run(*signing, str(bundle))
    run(*signing, "--entitlements", str(app_entitlements), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))


def notarize(artifact, profile):
    print(f"提交公证：{artifact.name}", flush=True)
    result = json.loads(run("xcrun", "notarytool", "submit", str(artifact),
                            "--keychain-profile", profile, "--wait", "--output-format", "json"))
    if result.get("status") != "Accepted":
        raise ValueError(f"Apple 未接受公证：{result.get('status')}，提交 ID：{result.get('id')}。")


def package(app, identity, profile, output, download_url, test=False):
    if output == app or app in output.parents:
        raise ValueError("输出目录不能位于原始应用内部。")
    if test:
        identity = "-"
        print("测试包：仅临时签名，不经过 Apple 公证，可能被 Gatekeeper 拦截。", flush=True)
    else:
        profile = profile.strip() or DEFAULT_NOTARY_PROFILE
        identities = re.findall(r'"(Developer ID Application:[^"]+)"',
                                run("security", "find-identity", "-v", "-p", "codesigning"))
        if not identity:
            if len(identities) > 1:
                raise ValueError("钥匙串中有多张 Developer ID Application 证书，请用 --identity 指定。")
            if not identities:
                raise ValueError("钥匙串中没有有效的 Developer ID Application 证书。")
            identity = identities[0]
            print(f"自动选择证书：{identity}", flush=True)
        if identity not in identities:
            raise ValueError("钥匙串中不存在指定的有效 Developer ID Application 证书。")
    version = inspect_app(app, download_url)
    if not test and not download_url:
        download_url = default_download_url(version)
        validate_download_url(download_url)
        print(f"未指定 --download-url，使用默认下载地址：{download_url}", flush=True)
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"Leap-{version}-arm64{'-test' if test else ''}.dmg"
    metadata_path = output / f"Leap-{version}-release.json"
    if destination.exists() or metadata_path.exists():
        raise ValueError("该版本产物已存在；请使用新目录，不能覆盖已发布安装包。")
    with tempfile.TemporaryDirectory(prefix="leap-release-", dir=output) as temporary:
        work = Path(temporary)
        staging = work / "staging"
        staging.mkdir()
        copied_app = staging / "Leap.app"
        print("复制应用并签名嵌套代码…", flush=True)
        run("ditto", str(app), str(copied_app))
        # 官方 Python 的 Tcl/Tk 带有失效开发头文件链接，会令深度验签报 ENOENT；只清理发行副本。
        frameworks = copied_app / "Contents/Resources/Runtimes/python-3.14.7/Versions/3.14/Frameworks"
        for name in ("Tcl", "Tk"):
            headers = frameworks / f"{name}.framework/PrivateHeaders"
            if headers.is_symlink() and not headers.exists():
                headers.unlink()
        sign_app(copied_app, identity, work)
        # 在发行副本运行解释器，防止开发机安装的 Python 掩盖包内库缺失。
        runtime = copied_app / "Contents/Resources/Runtimes"
        run(str(runtime / "node-24.21.0/bin/node"), "-e", "console.log([1,2,3].reduce((a,b)=>a+b,0))")
        run(str(runtime / "python-3.14.7/Versions/3.14/bin/python3.14"), "-I", "-B", "-c", "import ssl, sqlite3")
        run("codesign", "--verify", "--deep", "--strict", str(copied_app))
        if not test:
            archive = work / "Leap.zip"
            run("ditto", "-c", "-k", "--keepParent", str(copied_app), str(archive))
            notarize(archive, profile)
            run("xcrun", "stapler", "staple", str(copied_app))
            run("xcrun", "stapler", "validate", str(copied_app))
            run("spctl", "--assess", "--type", "execute", "--verbose", str(copied_app))
        (staging / "Applications").symlink_to("/Applications")
        dmg = work / destination.name
        run("hdiutil", "create", "-volname", "Leap", "-srcfolder", str(staging),
            "-format", "UDZO", str(dmg))
        run("codesign", "--sign", identity, *([] if test else ["--timestamp"]), str(dmg))
        if not test:
            notarize(dmg, profile)
            run("xcrun", "stapler", "staple", str(dmg))
            run("xcrun", "stapler", "validate", str(dmg))
        run("hdiutil", "verify", str(dmg))
        if not test:
            run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(dmg))
        digest = hashlib.sha256()
        with dmg.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        metadata = {"version": version, "minimumMacOS": "26.0", "architecture": "arm64",
                    "sizeBytes": dmg.stat().st_size, "sha256": digest.hexdigest(), "notarized": not test}
        if download_url:
            metadata["downloadURL"] = download_url
        dmg.rename(destination)
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"发行包已生成：{destination}\n候选元数据：{metadata_path}\n上传 Release 并回读校验、完成安装验收后再公开。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, help="Release 构建的 Leap.app；省略时查找最近的构建产物")
    parser.add_argument("--test", action="store_true", help="仅生成临时签名、未公证的测试 DMG")
    parser.add_argument("--identity", default="", help="Developer ID Application 身份；省略时自动选择唯一证书")
    parser.add_argument("--notary-profile", default=DEFAULT_NOTARY_PROFILE,
                        help=f"钥匙串公证配置，默认 {DEFAULT_NOTARY_PROFILE}")
    # 默认输出到仓库根的 ./build；该目录已在 .gitignore 中，产物不入库。
    parser.add_argument("--output", type=Path, default=Path("build"), help="输出目录，默认 ./build")
    parser.add_argument("--download-url", help="正式包下载地址；省略时按本仓库 Releases 与版本生成")
    args = parser.parse_args()
    try:
        app = (args.app or default_app()).resolve()
        package(app, args.identity, args.notary_profile,
                args.output.resolve(), args.download_url, test=args.test)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"发行失败：{error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
