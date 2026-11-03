#!/usr/bin/env bash
# 在目标档位容器内编译 PostgreSQL 并打包。
# 依赖 config.yaml 经 gen_matrix.py 解析后通过环境变量注入，见 .github/workflows/_build.yml。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

: "${PKG:?缺少 PKG}"
: "${PKG_VERSION:?缺少 PKG_VERSION}"
: "${SOURCE_URL:?缺少 SOURCE_URL}"
: "${SOURCE_DIR_NAME:?缺少 SOURCE_DIR_NAME}"
: "${PKG_PREFIX:?缺少 PKG_PREFIX}"
: "${OUTPUT_DIR:?缺少 OUTPUT_DIR}"

SOURCE_ROOT="${BUILD_SOURCE_DIR:-/data/src}"
mkdir -p "$SOURCE_ROOT" "$PKG_PREFIX"

configure_repos
# bison/flex 只有从 git 构建才需要，源码包自带生成的解析器；装上无害。
# --with-icu 需要 libicu-devel，--with-systemd 需要 systemd-devel（el7 均已具备）。
install_packages gcc gcc-c++ make bison flex perl \
  readline-devel zlib-devel openssl-devel libicu-devel systemd-devel
ensure_curl

cd "$SOURCE_ROOT"

fetch_source "$SOURCE_URL" "$PKG-$PKG_VERSION.tar.gz" "${SOURCE_SHA256:-}" "$PKG"
extract_source "$PKG-$PKG_VERSION.tar.gz" "$SOURCE_ROOT"

cd "$SOURCE_ROOT/$SOURCE_DIR_NAME"

# OpenSSL / readline / zlib / ICU / systemd 链接系统动态库，不做静态植入：
# 目标机需自带 openssl-libs、readline、zlib、libicu、systemd-libs。
# shellcheck disable=SC2086  # configure 参数需要按空格拆分
./configure --prefix="$PKG_PREFIX" ${PKG_CONFIGURE_ARGS:-}

make -j"$(nproc_jobs)"
# contrib 提供 pg_stat_statements 等常用扩展
make -j"$(nproc_jobs)" -C contrib
make install
make -C contrib install

PG_BIN="$PKG_PREFIX/bin/postgres"
[ -x "$PG_BIN" ] || die "未找到 ${PG_BIN}"
[ -x "$PKG_PREFIX/bin/initdb" ] || die "未找到 initdb"
[ -f "$PKG_PREFIX/lib/postgresql/pg_stat_statements.so" ] || die "contrib 未安装：pg_stat_statements.so 缺失"

"$PG_BIN" --version >&2
"$PKG_PREFIX/bin/pg_config" --configure >&2

package_install_dir "$PKG_PREFIX" "$OUTPUT_DIR"
