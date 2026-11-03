#!/usr/bin/env bash
# 公共构建函数。由 scripts/<pkg>.sh source，不直接执行。
#
# 所需环境变量（workflow 通过 --env-file 注入）：
#   TARGET_OS        el7 | el8 | el9 | el10
#   BUILD_SOURCE_DIR 源码目录（默认 /data/src）
#   OUTPUT_DIR       产物输出目录（挂载回宿主机）

set -euo pipefail

log() { printf '[build] %s\n' "$*" >&2; }
die() { printf '[build] ERROR: %s\n' "$*" >&2; exit 1; }

nproc_jobs() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; }

# 配置 yum/dnf 源。el7 官方源已下线，重写为 vault；el8+ 启用 CRB/PowerTools。
configure_repos() {
  case "${TARGET_OS:?}" in
    el7)
      # x86_64 在 /centos/7.9.2009 下，aarch64 在 /altarch/7.9.2009 下
      local vault="${EL7_VAULT_BASE:-https://vault.centos.org}" base
      if [ "$(uname -m)" = "aarch64" ]; then
        base="${vault}/altarch/7.9.2009"
      else
        base="${vault}/centos/7.9.2009"
      fi
      rm -f /etc/yum.repos.d/CentOS-*.repo
      cat > /etc/yum.repos.d/CentOS-Vault.repo <<REPO
[base]
name=CentOS-7 Vault - Base
baseurl=${base}/os/\$basearch/
gpgcheck=0
enabled=1

[updates]
name=CentOS-7 Vault - Updates
baseurl=${base}/updates/\$basearch/
gpgcheck=0
enabled=1

[extras]
name=CentOS-7 Vault - Extras
baseurl=${base}/extras/\$basearch/
gpgcheck=0
enabled=1
REPO
      ;;
    el8)
      dnf -y -q install dnf-plugins-core >/dev/null
      dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
        || dnf config-manager --set-enabled PowerTools >/dev/null 2>&1 || true
      ;;
    el9 | el10)
      dnf -y -q install dnf-plugins-core >/dev/null
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      ;;
    *)
      die "不支持的目标档位: ${TARGET_OS}"
      ;;
  esac
}

install_packages() {
  log "安装系统依赖: $*"
  if [ "${TARGET_OS}" = "el7" ]; then
    yum install -y -q "$@"
  else
    dnf install -y -q "$@"
  fi
}

# fetch_source <url> <dest> <sha256 或空> <显示名>
fetch_source() {
  local url="$1" dest="$2" sha="$3" name="$4"
  log "下载 ${name}: ${url}"
  curl -fSL --retry 3 --connect-timeout 20 --max-time 900 -o "$dest" "$url"
  if [ -n "${sha:-}" ]; then
    printf '%s  %s\n' "$sha" "$dest" | sha256sum -c - >/dev/null
    log "${name} sha256 校验通过"
  else
    log "警告: ${name} 未配置 sha256，跳过完整性校验"
  fi
}

# extract_source <archive> <destdir>
extract_source() {
  local archive="$1" dest="$2"
  tar -xf "$archive" -C "$dest"
}

# build_libxcrypt <解压后的源码目录>
# 静态构建 libcrypt.a，供 nginx 静态链接；el7 的 automake 1.13 需放宽 Makefile.am 要求。
build_libxcrypt() {
  local src="$1"
  cd "$src"
  if [ ! -f configure ]; then
    if [ "${TARGET_OS}" = "el7" ]; then
      sed -i 's/^\([[:space:]]*\)1\.14/\11.13/' Makefile.am || true
    fi
    autoreconf -fiv
  fi
  ./configure --prefix="$src/build" --enable-static --disable-shared --with-pic
  make -j"$(nproc_jobs)"
  make install
}

# 校验二进制未动态依赖本应静态植入的库。判定依据是 readelf 的 NEEDED 项。
verify_static_embed() {
  local bin="$1" name="$2" needed
  needed=$(readelf -d "$bin" | grep -E '\(NEEDED\)' || true)
  if printf '%s\n' "$needed" | grep -E 'lib(ssl|crypto|pcre2?(-[0-9]+)?|z|crypt)\.so' >/dev/null; then
    printf '%s\n' "$needed" >&2
    die "${name} 仍动态依赖应静态植入的库"
  fi
  log "${name} 静态植入校验通过"
}

glibc_tag() {
  local out v
  out=$(ldd --version 2>&1 || true)
  # 用 awk 一次读完输入，避免 head/grep -q 提前退出在 pipefail 下触发 SIGPIPE
  v=$(printf '%s\n' "$out" \
    | awk 'match($0, /[0-9]+\.[0-9]+/) { print substr($0, RSTART, RLENGTH); exit }')
  [ -n "$v" ] || die "无法从 ldd --version 解析 glibc 版本: ${out}"
  printf 'glibc%s' "$v"
}

# package_install_dir <安装前缀> <输出目录>
# 归档时保留绝对路径结构（tar -C / data/nginx），解压到 / 即落到原前缀。
package_install_dir() {
  local prefix="$1" outdir="$2" file tag arch
  tag=$(glibc_tag)
  arch=$(uname -m)
  file="${PKG}-${PKG_VERSION}-linux-${tag}-${arch}.tar.gz"

  mkdir -p "$outdir"
  tar -czf "$outdir/$file" -C / "${prefix#/}"
  (cd "$outdir" && sha256sum "$file" > "$file.sha256")

  cat > "$outdir/manifest.env" <<EOF
ARTIFACT_FILE=$file
ARTIFACT_SHA256=$(cut -d' ' -f1 "$outdir/$file.sha256")
GLIBC_TAG=$tag
ARCH_NAME=$arch
EOF
  log "产物: ${file}"
}
