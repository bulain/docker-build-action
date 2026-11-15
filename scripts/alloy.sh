#!/usr/bin/env bash
# 镜像 Grafana Alloy 上游 zip（转 tar.gz）到 OSS。由 .github/workflows/alloy.yml 或 --all 调用。
# 具体逻辑与参数见 scripts/monitoring.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/monitoring.sh" alloy "$@"
