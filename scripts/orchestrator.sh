#!/usr/bin/env bash
# 在目标档位容器内编译 orchestrator 并打包。
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
: "${PKG_GO_VERSION:?缺少 PKG_GO_VERSION}"
: "${PKG_GO_URL:?缺少 PKG_GO_URL}"
: "${PKG_GO_SHA256:?缺少 PKG_GO_SHA256}"

SOURCE_ROOT="${BUILD_SOURCE_DIR:-/data/src}"
mkdir -p "$SOURCE_ROOT" "$PKG_PREFIX"

configure_repos
# cgo（vendored go-sqlite3）需要 gcc；其余只做文件操作
install_packages gcc make tar gzip xz ca-certificates
ensure_curl

cd "$SOURCE_ROOT"

fetch_source "$PKG_GO_URL" "go$PKG_GO_VERSION.linux-$PKG_ARCH.tar.gz" "$PKG_GO_SHA256" "go"
mkdir -p "$SOURCE_ROOT/go-sdk"
extract_source "go$PKG_GO_VERSION.linux-$PKG_ARCH.tar.gz" "$SOURCE_ROOT/go-sdk"
GO_ROOT="$SOURCE_ROOT/go-sdk/go"
[ -x "$GO_ROOT/bin/go" ] || die "Go SDK 解压后缺少 bin/go"

fetch_source "$SOURCE_URL" "$PKG-$PKG_VERSION.tar.gz" "${SOURCE_SHA256:-}" "$PKG"
extract_source "$PKG-$PKG_VERSION.tar.gz" "$SOURCE_ROOT"

cd "$SOURCE_ROOT/$SOURCE_DIR_NAME"

# vendor 目录已随源码提供；GOTOOLCHAIN=local 防止 go 因 go.mod 版本号去联网下载工具链
export PATH="$GO_ROOT/bin:$PATH"
export GOPATH="$SOURCE_ROOT/gopath"
export GOCACHE="$SOURCE_ROOT/gopath/.cache"
export CGO_ENABLED=1
export GOFLAGS=-mod=vendor
export GOPROXY=off
export GOTOOLCHAIN=local

go version >&2
go build \
  -ldflags "-s -w -X main.AppVersion=$PKG_VERSION -X main.GitCommit=tarball-$PKG_VERSION" \
  -o "$PKG_PREFIX/bin/orchestrator" \
  go/cmd/orchestrator/main.go

mkdir -p "$PKG_PREFIX/conf" "$PKG_PREFIX/resources" "$PKG_PREFIX/systemd"
cp -a resources/. "$PKG_PREFIX/resources/"
cp conf/orchestrator-sample*.conf.json "$PKG_PREFIX/conf/"
install -m 0755 resources/bin/orchestrator-client "$PKG_PREFIX/bin/orchestrator-client"

cat > "$PKG_PREFIX/systemd/orchestrator.service" <<UNIT
[Unit]
Description=orchestrator: MySQL replication management and visualization
Documentation=https://github.com/openark/orchestrator
After=syslog.target network.target mysqld.service mysql.service

[Service]
Type=simple
WorkingDirectory=$PKG_PREFIX
ExecStart=$PKG_PREFIX/bin/orchestrator http
EnvironmentFile=-/etc/sysconfig/orchestrator
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT

ORCH_BIN="$PKG_PREFIX/bin/orchestrator"
[ -x "$ORCH_BIN" ] || die "未找到 ${ORCH_BIN}"
version_out=$("$ORCH_BIN" --version 2>&1) || die "orchestrator --version 执行失败"
printf '%s\n' "$version_out" >&2
printf '%s\n' "$version_out" | grep -F "$PKG_VERSION" >/dev/null \
  || die "orchestrator 版本输出不含 ${PKG_VERSION}"

package_install_dir "$PKG_PREFIX" "$OUTPUT_DIR"
