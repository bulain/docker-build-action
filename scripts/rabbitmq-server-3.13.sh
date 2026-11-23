#!/usr/bin/env bash
# 镜像 RabbitMQ generic-unix tar.xz（rabbitmq-server-3.13）到 OSS。
# 由 .github/workflows/rabbitmq-server-3.13.yml 或 middleware.sh --all 调用。
# 具体逻辑与参数见 scripts/middleware.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/middleware.sh" rabbitmq-server-3.13 "$@"
