#!/usr/bin/env bash
# 镜像 mcli（pgsty/mc，SILO 配套 S3 客户端）上游 tarball 到 OSS。
# 由 .github/workflows/mcli.yml 或 middleware.sh --all 调用。
# 具体逻辑与参数见 scripts/mirror.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/middleware.sh" mcli "$@"
