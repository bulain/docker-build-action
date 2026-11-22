#!/usr/bin/env bash
# 镜像 Sonatype Nexus Repository Manager 的 unix tarball（目标机解压安装用）到 OSS。
# 由 .github/workflows/nexus.yml 或 middleware.sh --all 调用。
# 具体逻辑与参数见 scripts/mirror.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/middleware.sh" nexus "$@"
