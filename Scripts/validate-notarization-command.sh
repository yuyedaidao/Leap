#!/bin/zsh

# 此脚本只校验待公证归档路径，不接触 Apple ID、私钥、密码或任何凭据。
set -euo pipefail

readonly archive_path="${1:-}"
[[ "$archive_path" == *.zip ]] || {
    print -u2 -- "请提供待公证的 .zip 归档路径。"
    exit 64
}

print -- "公证归档路径已通过参数校验：$archive_path"
print -- "请在受控发布环境中使用 notarytool 和独立凭据执行实际提交。"
