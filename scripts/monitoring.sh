#!/usr/bin/env bash
# 监控组件镜像入口（兼容 shim）。通用驱动已泛化为 mirror.sh，按 --section 区分
# 镜像通道；本文件保留以兼容既有 scripts/<component>.sh 与 workflow，见 docs/adr/0004。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/mirror.sh" --section monitoring "$@"
