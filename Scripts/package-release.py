#!/usr/bin/env python3
"""在临时副本中签名、公证并生成发行 DMG，始终保留原始构建。"""
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


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


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
        url = urlsplit(download_url)
        if url.scheme != "https" or not url.hostname or url.username or url.password or not url.path.endswith(".dmg"):
            raise ValueError("下载地址必须是无凭据的 HTTPS DMG 地址。")
    minimum = info.get("LSMinimumSystemVersion", "")
    if minimum not in ("26.0", "26.0.0"):
        raise ValueError("应用最低系统版本必须与官网的 macOS 26.0 一致。")
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
        if not download_url:
            raise ValueError("正式发行包必须指定下载地址。")
        if not identity.startswith("Developer ID Application:") or not profile.strip():
            raise ValueError("必须指定 Developer ID Application 身份和钥匙串公证配置。")
        identities = run("security", "find-identity", "-v", "-p", "codesigning")
        if f'"{identity}"' not in identities:
            raise ValueError("钥匙串中不存在指定的有效 Developer ID Application 证书。")
    version = inspect_app(app, download_url)
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
    print(f"发行包已生成：{destination}\n候选元数据：{metadata_path}\n上传校验并完成安装验收后，再更新 Website/release.json。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--test", action="store_true", help="仅生成临时签名、未公证的测试 DMG")
    parser.add_argument("--identity", default="")
    parser.add_argument("--notary-profile", default="")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--download-url", help="正式发行必填；本地测试包可省略")
    args = parser.parse_args()
    try:
        package(args.app.resolve(), args.identity, args.notary_profile,
                args.output.resolve(), args.download_url, test=args.test)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"发行失败：{error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
