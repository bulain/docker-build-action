#!/usr/bin/env bash
# 镜像 Adoptium Temurin 25（adoptium/temurin25-binaries）JDK tarball 到 OSS。
# 由 .github/workflows/temurin25.yml 或 --all 调用；参数见 scripts/jdk.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/jdk.sh" temurin25 "$@"
