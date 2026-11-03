#!/usr/bin/env bash
# 在目标档位容器内编译 redis 并打包。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

: "${PKG:?缺少 PKG}"
: "${PKG_VERSION:?缺少 PKG_VERSION}"
: "${SOURCE_URL:?缺少 SOURCE_URL}"
: "${SOURCE_DIR_NAME:?缺少 SOURCE_DIR_NAME}"
: "${INSTALL_PREFIX:?缺少 INSTALL_PREFIX}"
: "${OUTPUT_DIR:?缺少 OUTPUT_DIR}"

# redis 8+ 需要 C11 atomics，gcc 4.8.5 编不过；el7 必须锁在 7.2 线。
if [ "${TARGET_OS}" = "el7" ]; then
  case "$PKG_VERSION" in
    7.*) ;;
    *) die "el7 的 gcc 4.8.5 无法编译 redis ${PKG_VERSION}，请在 config.yaml 的 versions.el7 指定 7.x" ;;
  esac
fi

SOURCE_ROOT="${BUILD_SOURCE_DIR:-/data/src}"
mkdir -p "$SOURCE_ROOT" "$INSTALL_PREFIX"

configure_repos
install_packages gcc make tar gzip xz ca-certificates
ensure_curl

cd "$SOURCE_ROOT"

fetch_source "$SOURCE_URL" "$PKG-$PKG_VERSION.tar.gz" "${SOURCE_SHA256:-}" "$PKG"
extract_source "$PKG-$PKG_VERSION.tar.gz" "$SOURCE_ROOT"

cd "$SOURCE_ROOT/$SOURCE_DIR_NAME"

major="${PKG_VERSION%%.*}"
if [ "$major" -ge 8 ] 2>/dev/null; then
  # redis 8 的默认 make 目标会连带构建随仓库附带的模块
  # （redisearch/redisjson/redisbloom/redistimeseries），模块编译失败会拖垮构建。
  # 这里显式指定只构建核心服务器："build redis"。
  # shellcheck disable=SC2086  # make 参数需要按空格拆分
  make -j"$(nproc_jobs)" build redis ${PKG_MAKE_ARGS:-}
else
  # shellcheck disable=SC2086
  make -j"$(nproc_jobs)" ${PKG_MAKE_ARGS:-}
fi
make PREFIX="$INSTALL_PREFIX" install

verify_static_embed "$INSTALL_PREFIX/bin/redis-server" redis-server
"$INSTALL_PREFIX/bin/redis-server" --version >&2

package_install_dir "$INSTALL_PREFIX" "$OUTPUT_DIR"
