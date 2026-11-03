#!/usr/bin/env bash
# 在目标档位容器内编译 OpenResty 并打包。
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
: "${VENDOR_OPENSSL:?缺少 VENDOR_OPENSSL}"
: "${VENDOR_OPENSSL_URL:?缺少 VENDOR_OPENSSL_URL}"
: "${VENDOR_PCRE2:?缺少 VENDOR_PCRE2}"
: "${VENDOR_PCRE2_URL:?缺少 VENDOR_PCRE2_URL}"
: "${VENDOR_ZLIB_PACKAGE:?缺少 VENDOR_ZLIB_PACKAGE}"
: "${VENDOR_ZLIB_VERSION:?缺少 VENDOR_ZLIB_VERSION}"
: "${VENDOR_ZLIB_URL:?缺少 VENDOR_ZLIB_URL}"
: "${VENDOR_ZLIB_DIR:?缺少 VENDOR_ZLIB_DIR}"
: "${VENDOR_LIBCRYPT:?缺少 VENDOR_LIBCRYPT}"
: "${VENDOR_LIBCRYPT_URL:?缺少 VENDOR_LIBCRYPT_URL}"

SOURCE_ROOT="${BUILD_SOURCE_DIR:-/data/src}"
mkdir -p "$SOURCE_ROOT" "$PKG_PREFIX"

configure_repos
install_packages gcc make perl tar gzip xz ca-certificates patch autoconf automake libtool
ensure_curl

cd "$SOURCE_ROOT"

fetch_source "$SOURCE_URL" "$PKG-$PKG_VERSION.tar.gz" "${SOURCE_SHA256:-}" "$PKG"
extract_source "$PKG-$PKG_VERSION.tar.gz" "$SOURCE_ROOT"

fetch_source "$VENDOR_OPENSSL_URL" "openssl-$VENDOR_OPENSSL.tar.gz" "" "openssl"
extract_source "openssl-$VENDOR_OPENSSL.tar.gz" "$SOURCE_ROOT"

fetch_source "$VENDOR_PCRE2_URL" "pcre2-$VENDOR_PCRE2.tar.gz" "" "pcre2"
extract_source "pcre2-$VENDOR_PCRE2.tar.gz" "$SOURCE_ROOT"

fetch_source "$VENDOR_ZLIB_URL" "$VENDOR_ZLIB_DIR.tar.gz" "" "$VENDOR_ZLIB_PACKAGE"
extract_source "$VENDOR_ZLIB_DIR.tar.gz" "$SOURCE_ROOT"

LIBCRYPT_ARCHIVE=$(basename "$VENDOR_LIBCRYPT_URL")
fetch_source "$VENDOR_LIBCRYPT_URL" "$LIBCRYPT_ARCHIVE" "" "libxcrypt"
extract_source "$LIBCRYPT_ARCHIVE" "$SOURCE_ROOT"

OPENSSL_DIR="$SOURCE_ROOT/openssl-$VENDOR_OPENSSL"
PCRE2_DIR="$SOURCE_ROOT/pcre2-$VENDOR_PCRE2"
ZLIB_DIR="$SOURCE_ROOT/$VENDOR_ZLIB_DIR"
LIBCRYPT_DIR="$SOURCE_ROOT/libxcrypt-$VENDOR_LIBCRYPT"

build_libxcrypt "$LIBCRYPT_DIR"

cd "$SOURCE_ROOT/$SOURCE_DIR_NAME"

# shellcheck disable=SC2086  # configure 参数需要按空格拆分
./configure --prefix="$PKG_PREFIX" \
  --with-openssl="$OPENSSL_DIR" \
  --with-openssl-opt="no-shared no-tests" \
  --with-pcre="$PCRE2_DIR" \
  --with-pcre-jit --with-pcre-opt=-fPIC \
  --with-zlib="$ZLIB_DIR" \
  --with-cc-opt="-I$LIBCRYPT_DIR/build/include" \
  --with-ld-opt="-Wl,--as-needed $LIBCRYPT_DIR/build/lib/libcrypt.a" \
  ${PKG_CONFIGURE_ARGS:-}

# el7 的 gcc 4.8 默认不是 C99，OpenResty 的 lua-cjson 需要补 -std=gnu99
if [ "${TARGET_OS}" = "el7" ]; then
  sed -i 's/CJSON_CFLAGS="-g -fpic"/CJSON_CFLAGS="-g -fpic -std=gnu99"/' Makefile
fi

# zlib-ng 必须用 --zlib-compat 预编译 libz.a；放在 configure 之后，
# 保证 libz.a 比 objs/Makefile 新，make 时不会触发 distclean 重建。
if [ "$VENDOR_ZLIB_PACKAGE" = "zlib-ng" ]; then
  (
    cd "$ZLIB_DIR"
    CFLAGS="-fPIC" ./configure --zlib-compat
    make -j"$(nproc_jobs)" libz.a
  )
fi

make -j"$(nproc_jobs)"
make install

NGINX_BIN="$PKG_PREFIX/nginx/sbin/nginx"
verify_static_embed "$NGINX_BIN" openresty
"$NGINX_BIN" -V 2>&1 | head -n 3 >&2 || true

package_install_dir "$PKG_PREFIX" "$OUTPUT_DIR"
