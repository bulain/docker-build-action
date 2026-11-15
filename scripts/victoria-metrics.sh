#!/usr/bin/env bash
# 镜像 VictoriaMetrics 上游 tarball 到 OSS。由 .github/workflows/victoria-metrics.yml 或 --all 调用。
# 具体逻辑与参数见 scripts/monitoring.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/monitoring.sh" victoria-metrics "$@"
