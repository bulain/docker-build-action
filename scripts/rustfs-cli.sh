#!/usr/bin/env bash
# 镜像 RustFS CLI（rustfs/cli）上游 tarball 到 OSS。
# 由 .github/workflows/rustfs-cli.yml 或 middleware.sh --all 调用。
# 具体逻辑与参数见 scripts/mirror.sh。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/middleware.sh" rustfs-cli "$@"
