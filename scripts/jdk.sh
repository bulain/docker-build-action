#!/usr/bin/env bash
# JDK（Adoptium Temurin）上游发布件镜像入口。通用逻辑在 mirror.sh，配置在
# config.yaml 的 jdk 段，设计见 docs/adr/0006-jdk-upstream-mirror.md。
#
# 用法（通常经由 scripts/<component>.sh 调用）：
#   scripts/jdk.sh <component> [--option ...]
#   scripts/jdk.sh --all [--dry-run]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/mirror.sh" --section jdk "$@"
