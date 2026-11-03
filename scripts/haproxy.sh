#!/usr/bin/env bash
# 在目标档位容器内编译 HAProxy 并打包。
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

# 静态 OpenSSL：只产出 .a，make 时 -lssl/-lcrypto 在 build/lib 里只能取到静态库。
# el7 额外加 no-async（与 ansible-build 保持一致）。
cd "$OPENSSL_DIR"
openssl_opts=(--prefix="$OPENSSL_DIR/build" --libdir=lib no-shared no-tests)
if [ "${TARGET_OS}" = "el7" ]; then
  openssl_opts+=(no-async)
fi
./config "${openssl_opts[@]}"
make -j"$(nproc_jobs)"
make install_sw

# 静态 PCRE2 + JIT；USE_STATIC_PCRE2 下 HAProxy 用 pcre2-config 取 -Wl,-Bstatic 的链接方式。
cd "$PCRE2_DIR"
CFLAGS="-fPIC -O2" ./configure --prefix="$PCRE2_DIR/build" \
  --disable-shared --enable-static --enable-jit
make -j"$(nproc_jobs)"
make install

# zlib 经典包与 zlib-ng 兼容层都能在源码目录就地产出 libz.a / zlib.h
cd "$ZLIB_DIR"
if [ "$VENDOR_ZLIB_PACKAGE" = "zlib-ng" ]; then
  CFLAGS="-fPIC" ./configure --zlib-compat
else
  CFLAGS="-fPIC" ./configure --static
fi
make -j"$(nproc_jobs)" libz.a

cd "$SOURCE_ROOT/$SOURCE_DIR_NAME"

# QUIC 由 config.yaml 的 make_args 控制：el7 的 OpenSSL 1.1.1w 不启用。
# *_LIB 传目录，目录内只有 .a；LIBCRYPT_LDFLAGS 用全路径覆盖默认的 -lcrypt。
# shellcheck disable=SC2086  # make 参数需要按空格拆分
make -j"$(nproc_jobs)" TARGET=linux-glibc \
  USE_OPENSSL=1 \
  SSL_INC="$OPENSSL_DIR/build/include" \
  SSL_LIB="$OPENSSL_DIR/build/lib" \
  USE_STATIC_PCRE2=1 USE_PCRE2_JIT=1 \
  PCRE2_INC="$PCRE2_DIR/build/include" \
  PCRE2_LIB="$PCRE2_DIR/build/lib" \
  PCRE2_CONFIG="$PCRE2_DIR/build/bin/pcre2-config" \
  USE_ZLIB=1 \
  ZLIB_INC="$ZLIB_DIR" \
  ZLIB_LIB="$ZLIB_DIR" \
  LIBCRYPT_LDFLAGS="$LIBCRYPT_DIR/build/lib/libcrypt.a" \
  ADDLIB="-ldl -lpthread" \
  ${PKG_MAKE_ARGS:-} \
  PREFIX="$PKG_PREFIX"

make install PREFIX="$PKG_PREFIX"

HAPROXY_BIN="$PKG_PREFIX/sbin/haproxy"
[ -x "$HAPROXY_BIN" ] || die "未找到 ${HAPROXY_BIN}"

verify_static_embed "$HAPROXY_BIN" haproxy
"$HAPROXY_BIN" -v >&2

package_install_dir "$PKG_PREFIX" "$OUTPUT_DIR"
