#!/usr/bin/env bash
# 在目标档位容器内编译 Erlang/OTP 并打包。
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

SOURCE_ROOT="${BUILD_SOURCE_DIR:-/data/src}"
mkdir -p "$SOURCE_ROOT" "$INSTALL_PREFIX"

log "构建 ${PKG} ${PKG_VERSION} @ ${TARGET_OS}/${PKG_ARCH:-unknown}，前缀 ${INSTALL_PREFIX}"

configure_repos
install_packages gcc gcc-c++ make ncurses-devel perl tar gzip xz ca-certificates
ensure_curl

# el7 的 OpenSSL 1.0.2 缺少 OTP 26/27 crypto 需要的 1.1+ API，
# 与 ansible-build 一致：自编译共享 OpenSSL 并装到 erlang 前缀下。
if [ "${TARGET_OS}" = "el7" ]; then
  : "${VENDOR_OPENSSL:?缺少 VENDOR_OPENSSL}"
  : "${VENDOR_OPENSSL_URL:?缺少 VENDOR_OPENSSL_URL}"
  log "el7 自编译 OpenSSL ${VENDOR_OPENSSL}（安装到 ${INSTALL_PREFIX}）"
  cd "$SOURCE_ROOT"
  fetch_source "$VENDOR_OPENSSL_URL" "openssl-$VENDOR_OPENSSL.tar.gz" "" openssl
  extract_source "openssl-$VENDOR_OPENSSL.tar.gz" "$SOURCE_ROOT"
  cd "$SOURCE_ROOT/openssl-$VENDOR_OPENSSL"
  ./config --prefix="$INSTALL_PREFIX" --libdir=lib shared no-tests
  make -j"$(nproc_jobs)"
  make install_sw
else
  install_packages openssl-devel
fi

cd "$SOURCE_ROOT"
fetch_source "$SOURCE_URL" "$SOURCE_DIR_NAME.tar.gz" "${SOURCE_SHA256:-}" "$PKG"
extract_source "$SOURCE_DIR_NAME.tar.gz" "$SOURCE_ROOT"

cd "$SOURCE_ROOT/$SOURCE_DIR_NAME"

# el7 用自编译 OpenSSL，并显式写入 rpath（非标准路径不会被默认探测到）；
# 其他档位用系统 OpenSSL。
if [ "${TARGET_OS}" = "el7" ]; then
  ./configure --prefix="$INSTALL_PREFIX" \
    --with-ssl="$INSTALL_PREFIX" \
    --with-ssl-rpath="$INSTALL_PREFIX/lib"
else
  # 显式指定系统 OpenSSL。不指定时 OTP 探测失败只会写 SKIP 然后静默跳过
  # ssl/crypto，构建仍然"成功"；指定路径则探测失败会直接报错。
  ./configure --prefix="$INSTALL_PREFIX" --with-ssl=/usr
fi
make -j"$(nproc_jobs)"
make install

# 冒烟：ssl/crypto 应用存在，且 crypto NIF 能真正加载（验证 el7 的 rpath）
erlang_lib="$INSTALL_PREFIX/lib/erlang/lib"
log "已安装应用: $(ls "$erlang_lib" 2>/dev/null | tr '\n' ' ')"
for app in ssl crypto ssh; do
  if [ -f "$SOURCE_ROOT/$SOURCE_DIR_NAME/lib/$app/SKIP" ]; then
    log "lib/$app 被跳过，原因: $(cat "$SOURCE_ROOT/$SOURCE_DIR_NAME/lib/$app/SKIP")"
  fi
done
if [ -f "$SOURCE_ROOT/$SOURCE_DIR_NAME/lib/crypto/config.log" ]; then
  log "crypto configure 摘要:"
  grep -iE 'openssl|SSL|checking' "$SOURCE_ROOT/$SOURCE_DIR_NAME/lib/crypto/config.log" | tail -30 >&2 || true
fi

test -d "$erlang_lib"/ssl-* || die "ssl 应用未安装（见上面的 SKIP/config 摘要）"
test -d "$erlang_lib"/crypto-* || die "crypto 应用未安装（见上面的 SKIP/config 摘要）"
"$INSTALL_PREFIX/bin/erl" -noshell -eval \
  '{ok, _} = application:ensure_all_started(crypto), io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().' \
  >&2

package_install_dir "$INSTALL_PREFIX" "$OUTPUT_DIR"
