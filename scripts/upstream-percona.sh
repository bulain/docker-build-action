#!/usr/bin/env bash
# 把 Percona 官网的二进制 tarball 原样镜像到 OSS。
#
# 与 scripts/<pkg>.sh 的区别：这里不编译、不打包、不改名，只做「下载 + 上传 + 记录哈希」。
# 本地与 CI 共用：凭证走环境变量，缺失时回落到 ossutil 自身的配置文件。
#
# 用法：
#   scripts/upstream-percona.sh                    # 全部组件、全部版本
#   scripts/upstream-percona.sh --component percona-xtrabackup
#   scripts/upstream-percona.sh --version 9.7.2-2  # 需同时给 --component
#   scripts/upstream-percona.sh --dry-run          # 只列出将要处理的文件
#   FORCE=true scripts/upstream-percona.sh         # 覆盖 OSS 上已存在的文件
#
# 环境变量：
#   OSS_BUCKET / OSS_ENDPOINT / OSS_REGION / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET
#   OSSUTIL         ossutil 可执行文件路径（默认从 PATH 里找 ossutil）
#   DOWNLOAD_DIR    下载缓存目录（默认 ./out/upstream）
#   FORCE           true 时覆盖 OSS 上已存在的文件
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

log() { printf '[upstream] %s\n' "$*" >&2; }
die() { printf '[upstream] ERROR: %s\n' "$*" >&2; exit 1; }

component=""
version=""
dry_run="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --component) component="${2:?--component 需要值}"; shift 2 ;;
    --version) version="${2:?--version 需要值}"; shift 2 ;;
    --config) config_file="${2:?--config 需要值}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    -h | --help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done
config_file="${config_file:-$REPO_ROOT/config.yaml}"

[ -f "$config_file" ] || die "找不到配置文件: $config_file"

# --version 只能配合 --component：全局覆盖会把同一版本号套到所有组件上
if [ -n "$version" ] && [ -z "$component" ]; then
  die "--version 必须与 --component 一起使用"
fi

python_bin="${PYTHON:-python3}"
command -v "$python_bin" >/dev/null 2>&1 || die "缺少 python3（解析 config.yaml 用）"

resolve_args=(--config "$config_file")
if [ -n "$component" ]; then resolve_args+=(--component "$component"); fi
if [ -n "$version" ]; then resolve_args+=(--version "$version"); fi

if [ "$dry_run" = "true" ]; then
  # dry-run 只用 python 回显，不要求 jq / curl / ossutil
  exec "$python_bin" "$SCRIPT_DIR/upstream_resolve.py" "${resolve_args[@]}" --dry-run
fi

resolved=$("$python_bin" "$SCRIPT_DIR/upstream_resolve.py" "${resolve_args[@]}" --tsv)
count=$(printf '%s\n' "$resolved" | grep -c . || true)
[ "$count" -gt 0 ] || die "没有解析出任何待镜像文件（检查 upstream.components 配置）"
log "解析出 ${count} 个文件"

# ---------- 依赖 ----------
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"

OSSUTIL="${OSSUTIL:-$(command -v ossutil || true)}"
[ -n "$OSSUTIL" ] && [ -x "$OSSUTIL" ] || die "找不到 ossutil（设置 OSSUTIL 或放进 PATH）"

: "${OSS_BUCKET:?缺少 OSS_BUCKET}"
: "${OSS_ENDPOINT:?缺少 OSS_ENDPOINT}"

oss_auth=()
if [ -n "${OSS_ACCESS_KEY_ID:-}" ] && [ -n "${OSS_ACCESS_KEY_SECRET:-}" ]; then
  # ossutil v2 的 V4 签名必须带 region；未配置时从 endpoint 推导
  region="${OSS_REGION:-}"
  if [ -z "$region" ]; then
    region="${OSS_ENDPOINT#oss-}"
    region="${region%%.*}"
  fi
  oss_auth=(-e "$OSS_ENDPOINT" --region "$region" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET")
else
  # 无显式凭证时由 ossutil 读 ~/.ossutilconfig
  oss_auth=(-e "$OSS_ENDPOINT")
  log "未提供 AK/SK 环境变量，使用 ossutil 自身配置"
fi

oss_prefix=$("$python_bin" -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); print((c.get("upstream") or {}).get("prefix") or (c.get("oss") or {}).get("prefix") or "linux")' "$config_file")

# ossutil 进度条只用 \r 刷新，GitHub Actions 按 \n 摄取日志，大文件上传时
# 会长时间无输出；转成换行让进度实时可见。进度走 stderr，保持函数 stdout
# 干净（汇总只认 ok|/skip| 状态行）。
# 分片用 ossutil 默认（自动约 32Mi/片），不显式指定 --part-size；默认分片下
# 总进度只在整片完成时跳动，慢链路首片完成前会持续输出相同百分比，由 awk
# 按百分比折叠重复 tick。
# pipefail 已开，失败照常传播；awk 语法限定 POSIX，mawk/gawk 均可。
oss_cp() {
  "$OSSUTIL" cp -f "$@" 2>&1 \
    | stdbuf -oL tr '\r' '\n' \
    | stdbuf -oL awk '/Upload\.\.\. done:/ {
        p = ""
        for (i = 1; i <= NF; i++) if ($i ~ /%,?$/) { p = $i; break }
        if (p == lastp) next
        lastp = p
      }
      { print }' >&2
}

download_dir="${DOWNLOAD_DIR:-$REPO_ROOT/out/upstream}"
mkdir -p "$download_dir"

# ---------- 单文件处理 ----------
# 上游不提供校验文件（.sha256 会 302 回下载落地页），所以哈希只能自算，
# 首次上传后用 OSS 上的 .sha256 做重跑比对。
download() {
  local url="$1" dest="$2"
  log "下载: $(basename "$dest")"
  # 不用 --max-time：Percona 慢在带宽而非卡死，靠低速阈值判定真正无响应
  curl -fSL --retry 5 --retry-delay 10 --connect-timeout 30 \
    --speed-limit 10240 --speed-time 60 --continue-at - \
    -o "$dest" "$url"
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# 若 OSS 上已有 .sha256，返回其中记录的哈希；没有则返回空
remote_sha() {
  local key="$1" tmp
  tmp=$(mktemp)
  if "$OSSUTIL" cp -f "$key.sha256" "$tmp" "${oss_auth[@]}" >/dev/null 2>&1; then
    cut -d' ' -f1 "$tmp" | head -n1
  fi
  rm -f "$tmp"
}

sync_one() {
  local filename="$1" url="$2"
  local key="oss://${OSS_BUCKET}/${oss_prefix}/${filename}"
  local dest="$download_dir/$filename"
  local status_file="$download_dir/.status-${filename}"
  rm -f "$status_file"

  if "$OSSUTIL" stat "$key" "${oss_auth[@]}" >/dev/null 2>&1 && [ "${FORCE:-false}" != "true" ]; then
    log "跳过（OSS 已存在）: $filename"
    printf 'skip|%s|%s||已存在\n' "$filename" "$key" > "$status_file"
    return 0
  fi

  download "$url" "$dest" || return 1
  [ -s "$dest" ] || { log "下载结果为空: $filename"; return 1; }

  local sha
  sha=$(sha_of "$dest")

  # 已有远端哈希且不一致：上游可能重打包过，报警但不阻断（FORCE 时本就预期覆盖）
  local prev
  prev=$(remote_sha "$key")
  if [ -n "$prev" ] && [ "$prev" != "$sha" ]; then
    log "警告: ${filename} 哈希与 OSS 记录不一致（远端 ${prev} / 本次 ${sha}）"
  fi

  printf '%s  %s\n' "$sha" "$filename" > "$dest.sha256"

  log "上传: ${filename}"
  oss_cp "$dest" "$key" "${oss_auth[@]}" || return 1
  oss_cp "$dest.sha256" "$key.sha256" "${oss_auth[@]}" || return 1
  rm -f "$dest" "$dest.sha256"

  log "已上传: $key (sha256 ${sha})"
  printf 'ok|%s|%s|%s|自算，上游未提供官方校验文件\n' "$filename" "$key" "$sha" > "$status_file"
}

# ---------- 主循环 ----------
failures=0
results=()

while IFS=$'\t' read -r comp ver tier url filename; do
  [ "$tier" = "-" ] && tier=""
  log "---- ${comp} ${ver} ${tier:-无档位} ----"
  status_file="$download_dir/.status-${filename}"
  if sync_one "$filename" "$url"; then
    results+=("$(cat "$status_file")")
    rm -f "$status_file"
  else
    failures=$((failures + 1))
    results+=("fail|$filename|oss://${OSS_BUCKET}/${oss_prefix}/${filename}||失败")
    log "失败: $filename"
  fi
done < <(printf '%s\n' "$resolved")

log "完成：成功 $((count - failures)) / 总计 ${count}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Percona 上游镜像"
    echo ""
    echo "| 状态 | 文件 | OSS 路径 | sha256 |"
    echo "|---|---|---|---|"
    for line in "${results[@]}"; do
      IFS='|' read -r st file key sha _ <<<"$line"
      [ -n "$sha" ] || sha="—"
      printf '| %s | `%s` | `%s` | `%s` |\n' "$st" "$file" "$key" "$sha"
    done
    echo ""
    echo "> sha256 由本脚本首次下载后自算并上传为同名 \`.sha256\`；Percona 不提供独立校验文件。"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$failures" -gt 0 ]; then
  die "${failures} 个文件失败"
fi
