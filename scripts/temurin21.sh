#!/usr/bin/env bash
# 镜像 Adoptium Temurin 21（adoptium/temurin21-binaries）JDK tarball 到 OSS。
# 由 .github/workflows/temurin21.yml 或 --all 调用；参数见 scripts/jdk.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/jdk.sh" temurin21 "$@"
