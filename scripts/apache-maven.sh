#!/usr/bin/env bash
# 镜像 apache-maven 上游发布件到 OSS。由 .github/workflows/apache-maven.yml 或 --all 调用。
# 具体逻辑与参数见 scripts/monitoring.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/monitoring.sh" apache-maven "$@"
