#!/bin/zsh

# 仅检查发布时需要签名的嵌套可执行文件；不在没有 Developer ID 证书时伪造签名。
set -euo pipefail

readonly app_path="${1:-}"
[[ -n "$app_path" && -d "$app_path" ]] || {
    print -u2 -- "用法：$0 /path/to/Leap.app"
    exit 64
}

readonly runtime_root="$app_path/Contents/Resources/Runtimes"
[[ -x "$runtime_root/node-24.21.0/bin/node" ]] || { print -u2 -- "缺少随包 Node.js。"; exit 1; }
[[ -x "$runtime_root/python-3.14.7/Versions/3.14/bin/python3.14" ]] || { print -u2 -- "缺少随包 Python。"; exit 1; }

readonly identity="$(security find-identity -v -p codesigning | sed -n 's/.*\"\(Developer ID Application:.*\)\"/\1/p' | head -n 1)"
if [[ -z "$identity" ]]; then
    print -- "已发现 Leap 与两个随包运行时；未发现 Developer ID Application 证书，跳过实际签名。"
    exit 0
fi

print -- "将由 Developer ID 证书签名：$identity"
find "$runtime_root" -type f -perm -111 -print
