#!/bin/zsh

# 将固定版本解释器放入资源目录；插件执行时只从此目录解析运行时。
set -euo pipefail

readonly project_root="${0:A:h:h}"
readonly runtime_root="$project_root/Resources/Leap/Runtimes"
readonly cache_root="$project_root/.runtime-cache"
readonly python_version="3.14.7"
readonly node_version="24.21.0"

function fail() {
    print -u2 -- "错误：$1"
    exit 1
}

function require_command() {
    command -v "$1" >/dev/null || fail "缺少构建运行时所需的工具：$1"
}

for command_name in codesign curl ditto file find install_name_tool otool pkgutil shasum tar; do
    require_command "$command_name"
done

[[ "$(uname -m)" == "arm64" ]] || fail "当前仅支持 Apple Silicon（arm64）运行时打包。"
mkdir -p "$runtime_root" "$cache_root"

readonly work_directory="$(mktemp -d "${TMPDIR:-/tmp}/leap-runtimes.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

readonly node_archive="node-v${node_version}-darwin-arm64.tar.gz"
readonly node_archive_path="$cache_root/$node_archive"
readonly node_destination="$runtime_root/node-${node_version}"
readonly node_executable="$node_destination/bin/node"

if [[ ! -x "$node_executable" ]]; then
    print -- "下载 Node.js ${node_version}…"
    [[ -f "$node_archive_path" ]] || curl --fail --location --retry 3 --output "$node_archive_path" \
        "https://nodejs.org/dist/v${node_version}/$node_archive"
    curl --fail --location --retry 3 --output "$work_directory/SHASUMS256.txt" \
        "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt"
    grep "  $node_archive$" "$work_directory/SHASUMS256.txt" > "$work_directory/node.sha256" \
        || fail "未在官方校验清单中找到 $node_archive"
    (cd "$cache_root" && shasum -a 256 -c "$work_directory/node.sha256")
    tar -xzf "$node_archive_path" -C "$work_directory"
    ditto "$work_directory/${node_archive%.tar.gz}" "$node_destination"
fi

[[ "$("$node_executable" --version)" == "v$node_version" ]] \
    || fail "Node.js 版本校验失败：$node_executable"

readonly python_destination="$runtime_root/python-${python_version}"
readonly python_executable="$python_destination/Versions/3.14/bin/python3.14"
readonly python_app_executable="$python_destination/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
readonly python_library_path="/Library/Frameworks/Python.framework/Versions/3.14/Python"

if [[ ! -x "$python_executable" ]]; then
    readonly python_package="$cache_root/python-${python_version}.pkg"
    print -- "下载 Python ${python_version}…"
    [[ -f "$python_package" ]] || curl --fail --location --retry 3 --output "$python_package" \
        "https://www.python.org/ftp/python/${python_version}/python-${python_version}-macos11.pkg"
    pkgutil --check-signature "$python_package"
    pkgutil --expand-full "$python_package" "$work_directory/python-package"

    readonly framework_payload="$work_directory/python-package/Python_Framework.pkg/Payload"
    [[ -x "$framework_payload/Versions/3.14/bin/python3.14" ]] \
        || fail "Python 安装包中缺少 python3.14 可执行文件"
    ditto "$framework_payload" "$python_destination"
fi

while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q "Mach-O" || continue
    otool -L "$candidate" | grep -Fq "$python_library_path" || continue
    install_name_tool -change "$python_library_path" "@rpath/Python" "$candidate"
done < <(find "$python_destination" -type f -print0)

if ! otool -l "$python_executable" | grep -A 2 "LC_RPATH" | grep -Fq "@loader_path/.."; then
    install_name_tool -add_rpath "@loader_path/.." "$python_executable"
fi

if otool -l "$python_app_executable" | grep -A 2 "LC_RPATH" | grep -Fq "@loader_path/../../../../Python"; then
    install_name_tool -rpath "@loader_path/../../../../Python" "@loader_path/../../../.." "$python_app_executable"
elif ! otool -l "$python_app_executable" | grep -A 2 "LC_RPATH" | grep -Fq "@loader_path/../../../.."; then
    install_name_tool -add_rpath "@loader_path/../../../.." "$python_app_executable"
fi

while IFS= read -r -d '' candidate; do
    file "$candidate" | grep -q "Mach-O" || continue
    codesign --force --sign - "$candidate"
done < <(find "$python_destination" -type f -print0)

[[ "$("$python_executable" --version)" == "Python $python_version" ]] \
    || fail "Python 版本校验失败：$python_executable"

print -- "已准备随包运行时：Python $python_version、Node.js $node_version"
