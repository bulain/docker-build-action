#!/usr/bin/env bash
# 镜像 MySQL Community Server generic tarball（dev.mysql.com）到 OSS。
# x86_64 的 8.4/9.7 取上游官方 minimal；其余 full 包下载后自制 minimal（含 strip）。
# 由 .github/workflows/mysql.yml 或 middleware.sh --all 调用。
# 具体逻辑与参数见 scripts/mirror.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/middleware.sh" mysql "$@"
