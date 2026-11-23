#!/usr/bin/env bash
# 镜像 Nacos Server 3.2 维护线（alibaba/nacos）上游 tar.gz 到 OSS。
# 由 .github/workflows/nacos-server-3.2.yml 或 middleware.sh --all 调用。
# 具体逻辑与参数见 scripts/mirror.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/middleware.sh" nacos-server-3.2 "$@"
