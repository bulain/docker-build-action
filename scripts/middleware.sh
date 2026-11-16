#!/usr/bin/env bash
# 中间件/基础服务上游发布件镜像入口。通用逻辑在 mirror.sh，配置在 config.yaml
# 的 middleware 段，设计见 docs/adr/0005-middleware-upstream-mirror.md。
#
# 用法（通常经由 scripts/<component>.sh 调用）：
#   scripts/middleware.sh <component> [--option ...]
#   scripts/middleware.sh --all [--dry-run] [--force 由 FORCE 环境变量控制]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/mirror.sh" --section middleware "$@"
