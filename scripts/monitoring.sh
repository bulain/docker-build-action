#!/usr/bin/env bash
# 把监控组件的上游发布件镜像到 OSS。由 scripts/<component>.sh 调用，不直接执行。
#
# 与 upstream-percona.sh 的区别：产物分架构、用上游官方校验文件、tar.gz 统一
# 改名并剥离调试符号。与 scripts/<pkg>.sh（packages）的区别：不编译、不分档位。
# 设计见 docs/adr/0004-monitoring-upstream-mirror.md。
#
# 用法（通常经由 scripts/<component>.sh 调用）：
#   scripts/monitoring.sh <component> [--option ...] [镜像参数]
#   镜像参数：
#     --all                  镜像全部组件（忽略 component 位置参数与 --component）
#     --component <name>     只镜像某个组件，可多次
#     --local <dir>          不联网：从目录读取上游资产，只做校验/剥离/改名后写到输出目录
#     --output-dir <dir>     本地输出目录（默认 $REPO_ROOT/out/monitoring）
#     --dry-run              只解析并列出清单
#     --skip-checksums       上游校验文件缺失时跳过，而不是失败
#
# 环境变量：
#   OSS_BUCKET / OSS_ENDPOINT / OSS_REGION / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET
#   OSS_PREFIX     覆盖 config.yaml 的 monitoring.prefix
#   OSSUTIL        ossutil 可执行文件路径（默认从 PATH 里找）
#   GITHUB_TOKEN   可选，匿名 GitHub API 限 60 次/小时，每个 repo+tag 查一次
#   WORK_DIR       下载与解包缓存目录（默认 ./out/monitoring）
#   FORCE          true 时覆盖 OSS 上已存在的文件
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

log() { printf '[monitoring] %s\n' "$*" >&2; }
die() { printf '[monitoring] ERROR: %s\n' "$*" >&2; exit 1; }

components=()
case "${1:-}" in
  "" | --*) ;;
  *) components+=("$1"); shift ;;
esac

all="false"
local_dir=""
dry_run="false"
skip_checksums="false"
config_file="$REPO_ROOT/config.yaml"
output_dir_override=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all) all="true"; shift ;;
    --component) components+=("${2:?--component 需要值}"); shift 2 ;;
    --config) config_file="${2:?--config 需要值}"; shift 2 ;;
    --local) local_dir="${2:?--local 需要值}"; shift 2 ;;
    --output-dir) output_dir_override="${2:?--output-dir 需要值}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --skip-checksums) skip_checksums="true"; shift ;;
    -h | --help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -f "$config_file" ] || die "找不到配置文件: $config_file"

python_bin="${PYTHON:-python3}"
command -v "$python_bin" >/dev/null 2>&1 || die "缺少 python3（解析 config.yaml 用）"

script_name=$(basename "${BASH_SOURCE[0]}")
if [ "$all" = "true" ] && [ "$dry_run" != "true" ]; then
  # 交给各组件自己的脚本执行，保证入口统一（手动触发与 push 走同一条路径）。
  # dry-run 不走这里：它不联网，也不该因某个组件脚本缺少参数而失败
  mapfile -t every < <("$python_bin" -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); print("\n".join((c.get("monitoring") or {}).get("components") or {}))' "$config_file")
  [ "${#every[@]}" -gt 0 ] || die "config.yaml 的 monitoring.components 为空"
  # $@ 在解析阶段已被消费，转发参数要用解析后的变量重建
  fwd=(--config "$config_file")
  [ -n "$local_dir" ] && fwd+=(--local "$local_dir")
  [ -n "$output_dir_override" ] && fwd+=(--output-dir "$output_dir_override")
  [ "$skip_checksums" = "true" ] && fwd+=(--skip-checksums)
  status=0
  for comp in "${every[@]}"; do
    log "==== ${comp} ===="
    if ! bash "$SCRIPT_DIR/${comp}.sh" "${fwd[@]}"; then
      status=1
    fi
  done
  exit "$status"
fi

if [ "$all" = "true" ]; then
  components=()
  mapfile -t components < <("$python_bin" -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); print("\n".join((c.get("monitoring") or {}).get("components") or {}))' "$config_file")
  [ "${#components[@]}" -gt 0 ] || die "config.yaml 的 monitoring.components 为空"
fi

if [ "${#components[@]}" -eq 0 ]; then
  [ "$script_name" != "monitoring.sh" ] || die "需要组件名：scripts/monitoring.sh <component>，或用 --all"
  # 由 scripts/<component>.sh 调用：把 $0 的基名当组件名
  components=("${script_name%.sh}")
fi

prefix="${OSS_PREFIX:-}"
if [ -z "$prefix" ]; then
  prefix=$("$python_bin" -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); print((c.get("monitoring") or {}).get("prefix") or (c.get("oss") or {}).get("prefix") or "linux")' "$config_file")
fi

resolve_args=(--config "$config_file")
for c in "${components[@]}"; do resolve_args+=(--component "$c"); done
if [ -n "$local_dir" ]; then
  [ -d "$local_dir" ] || die "--local 目录不存在: $local_dir"
  resolve_args+=(--local "$local_dir")
fi

if [ "$dry_run" = "true" ]; then
  # dry-run 只用 python 回显，不要求 jq / curl / ossutil
  exec "$python_bin" "$SCRIPT_DIR/monitoring_resolve.py" "${resolve_args[@]}" --dry-run
fi

# ---------- 依赖 ----------
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"
command -v strip >/dev/null 2>&1 || die "缺少 strip（binutils）"

work_dir="${WORK_DIR:-$REPO_ROOT/out/monitoring}"
output_dir="${output_dir_override:-$work_dir/packages}"
mkdir -p "$work_dir" "$output_dir"

resolved=$("$python_bin" "$SCRIPT_DIR/monitoring_resolve.py" "${resolve_args[@]}" --tsv)
count=$(printf '%s\n' "$resolved" | grep -c . || true)
[ "$count" -gt 0 ] || die "没有解析出任何待镜像文件"

# ---------- OSS ----------
oss_auth=()
if [ -z "$local_dir" ]; then
  OSSUTIL="${OSSUTIL:-$(command -v ossutil || true)}"
  [ -n "$OSSUTIL" ] && [ -x "$OSSUTIL" ] || die "找不到 ossutil（设置 OSSUTIL 或放进 PATH）"
  : "${OSS_BUCKET:?缺少 OSS_BUCKET}"
  : "${OSS_ENDPOINT:?缺少 OSS_ENDPOINT}"
  if [ -n "${OSS_ACCESS_KEY_ID:-}" ] && [ -n "${OSS_ACCESS_KEY_SECRET:-}" ]; then
    # ossutil v2 的 V4 签名必须带 region；未配置时从 endpoint 推导
    region="${OSS_REGION:-}"
    if [ -z "$region" ]; then
      region="${OSS_ENDPOINT#oss-}"
      region="${region%%.*}"
    fi
    oss_auth=(-e "$OSS_ENDPOINT" --region "$region" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET")
  else
    oss_auth=(-e "$OSS_ENDPOINT")
    log "未提供 AK/SK 环境变量，使用 ossutil 自身配置"
  fi
fi

remote_sha() {
  local key="$1" tmp
  tmp=$(mktemp)
  if "$OSSUTIL" cp -f "$key.sha256" "$tmp" "${oss_auth[@]}" >/dev/null 2>&1; then
    cut -d' ' -f1 "$tmp" | head -n1
  fi
  rm -f "$tmp"
}

# ---------- 上游获取 ----------
token_args=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  token_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

download() {
  local url="$1" dest="$2"
  log "下载: ${url##*/}"
  # objstore 曾出现只给低速不给断开的情况，用低速阈值兜底；断点续传支持大文件重试
  curl -fSL --retry 5 --retry-delay 10 --connect-timeout 30 \
    --speed-limit 10240 --speed-time 60 --continue-at - \
    -o "$dest" "$url"
}

# 上游校验文件 -> $work_dir/checksums/<sha256 前缀>.txt
fetch_checksums() {
  local url="$1" dest
  dest="$work_dir/checksums/$(printf '%s' "$url" | sha256sum | cut -c1-16).txt"
  if [ ! -s "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    log "获取校验文件: $url"
    curl -fSL --retry 3 --connect-timeout 20 -o "$dest.tmp" "$url" >/dev/null || {
      rm -f "$dest.tmp"
      return 1
    }
    mv "$dest.tmp" "$dest"
  fi
  printf '%s\n' "$dest"
}

verify_official() {
  local archive="$1" checksums="$2" name="$3" expected
  expected=$(awk -v n="$name" '$2 == n { print $1; exit }' "$checksums")
  [ -n "$expected" ] || die "校验文件里没有 $name"
  printf '%s  %s\n' "$expected" "$archive" | sha256sum -c - >/dev/null \
    || die "${name} 官方 sha256 校验失败"
}

# ---------- 打包 ----------
# transform_archive <输入> <kind> <输出> <剥离列表，逗号分隔>
# tar.gz 解开后原结构重打；zip 解压后打成 tar.gz。剥离只作用于解包副本，
# 已下载的上游原件保持字节不变；任何一步失败都保留解包目录便于排查。
strip_count=0
transform_archive() {
  local in="$1" kind="$2" out="$3" strip_list="$4"
  local stage="$work_dir/stage"
  rm -rf "$stage"
  mkdir -p "$stage"

  if [ "$kind" = "zip" ]; then
    command -v unzip >/dev/null 2>&1 || die "缺少 unzip（处理 alloy zip 用）"
    unzip -q "$in" -d "$stage"
    topdir=$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n1)
  else
    tar -xf "$in" -C "$stage"
    topdir=$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n1)
  fi

  # 剥离目标相对顶层目录；没有顶层目录的（单文件 tarball）相对解包根
  strip_count=0
  local strip_root="${topdir:-$stage}" name path
  IFS=',' read -ra names <<<"$strip_list"
  local -a hits
  for name in "${names[@]}"; do
    [ -n "$name" ] || continue
    path="$strip_root/$name"
    hits=()
    if [ ! -f "$path" ]; then
      # 平铺包（adapter）二进制名 = 顶层目录名；zip 里带层级时（alloy）按文件名
      # 递归找唯一匹配。只取唯一结果，避免同名多份时剥错文件
      mapfile -t hits < <(find "$stage" -mindepth 1 -type f -name "$(basename "$name")")
      if [ "${#hits[@]}" -eq 1 ]; then
        path="${hits[0]}"
      fi
    fi
    if [ ! -f "$path" ]; then
      log "警告: 剥离目标不存在，跳过: ${name}（解包树里找到 ${#hits[@]} 处同名文件）"
      continue
    fi
    strip --strip-all "$path"
    strip_count=$((strip_count + 1))
  done

  # 保留解包出来的顶层目录名，解压到 /data 即得到上游同名目录
  if [ -n "$topdir" ]; then
    tar -czf "$out.tmp" -C "$stage" "$(basename "$topdir")"
  else
    tar -czf "$out.tmp" -C "$stage" .
  fi
  mv "$out.tmp" "$out"
}

# ---------- 单文件 ----------
publish_one() {
  local asset_name="$1" arch="$2" local_name="$3"
  local url="$4" checksums_url="$5" strip_list="$6" kind="$7"
  local dest="$output_dir/$local_name"

  rm -f "$dest" "$dest.sha256"

  if [ -z "$local_dir" ] && "$OSSUTIL" stat "oss://${OSS_BUCKET}/${prefix}/${local_name}" "${oss_auth[@]}" >/dev/null 2>&1 \
     && [ "${FORCE:-false}" != "true" ]; then
    log "跳过（OSS 已存在）: $local_name"
    printf 'skip|%s|||已存在\n' "$local_name"
    return 0
  fi

  local src_asset="$work_dir/downloads/$asset_name"
  mkdir -p "$(dirname "$src_asset")"

  if [ -n "$local_dir" ]; then
    # 离线验证允许放上游原名或改名后的名字
    if [ -f "$local_dir/$asset_name" ]; then
      cp -f "$local_dir/$asset_name" "$src_asset"
    elif [ -f "$local_dir/$local_name" ]; then
      cp -f "$local_dir/$local_name" "$src_asset"
    else
      die "--local 目录里没有 $asset_name（或改名后的 $local_name）"
    fi
  elif [ ! -s "$src_asset" ]; then
    download "$url" "$src_asset"
  else
    log "复用已下载文件: ${src_asset##*/}"
  fi

  local checksums
  if [ -n "$local_dir" ]; then
    # 离线模式：把下载的官方校验文件一起放进来才校验
    if checksums=$(fetch_checksums "file://$local_dir/SHA256SUMS"); then
      verify_official "$src_asset" "$checksums" "$asset_name"
      log "官方 sha256 校验通过: $asset_name"
    else
      log "警告: 本地目录无 SHA256SUMS，跳过校验"
    fi
  elif [ "$checksums_url" != "-" ]; then
    if checksums=$(fetch_checksums "$checksums_url"); then
      verify_official "$src_asset" "$checksums" "$asset_name"
      log "官方 sha256 校验通过: $asset_name"
    elif [ "$skip_checksums" = "true" ]; then
      log "警告: 拿不到校验文件，跳过校验（--skip-checksums）"
    else
      die "拿不到官方校验文件: $checksums_url"
    fi
  else
    # grafana 的 sha256 只存在于包清单 API（与下载地址同源），不单独下发校验文件
    log "警告: ${asset_name} 没有独立校验文件，跳过校验"
  fi

  transform_archive "$src_asset" "$kind" "$dest" "$strip_list"
  local sha
  sha=$(sha256sum "$dest" | cut -d' ' -f1)
  printf '%s  %s\n' "$sha" "$local_name" > "$dest.sha256"

  if [ -n "$local_dir" ]; then
    log "已生成: $dest (sha256 ${sha})"
    printf 'local|%s|%s||本地输出\n' "$local_name" "$sha"
    return 0
  fi

  local key="oss://${OSS_BUCKET}/${prefix}/${local_name}"
  local prev
  prev=$(remote_sha "$key")
  if [ -n "$prev" ] && [ "$prev" != "$sha" ]; then
    log "警告: ${local_name} 哈希与 OSS 记录不一致（远端 ${prev} / 本次 ${sha}）"
  fi

  "$OSSUTIL" cp -f "$dest" "$key" "${oss_auth[@]}" >/dev/null || die "上传失败: $key"
  "$OSSUTIL" cp -f "$dest.sha256" "$key.sha256" "${oss_auth[@]}" >/dev/null || die "上传失败: $key.sha256"
  log "已上传: $key (sha256 ${sha})"
  printf 'ok|%s|%s|%s|官方校验 + 剥离 %s 个二进制\n' "$local_name" "$key" "$sha" "$strip_count"
}

# ---------- 主循环 ----------
failures=0
results=()
while IFS=$'\t' read -r comp ver arch url filename local_name strip_list kind checksums; do
  case "$arch" in -) arch="" ;; esac
  case "$strip_list" in -) strip_list="" ;; esac
  log "---- ${comp} ${ver} ${arch:-无架构} ----"
  if out=$(publish_one "$filename" "$arch" "$local_name" "$url" "$checksums" "$strip_list" "$kind"); then
    results+=("$out")
  else
    failures=$((failures + 1))
    results+=("fail|$local_name|||失败")
    log "失败: $local_name"
  fi
done < <(printf '%s\n' "$resolved")

log "完成：成功 $((count - failures)) / 总计 ${count}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 监控组件镜像"
    echo ""
    echo "| 状态 | 文件 | OSS 路径 | sha256 | 说明 |"
    echo "|---|---|---|---|---|"
    for line in "${results[@]}"; do
      IFS='|' read -r st file key sha note <<<"$line"
      [ -n "$sha" ] || sha="—"
      [ -n "$key" ] || key="—"
      printf '| %s | `%s` | `%s` | `%s` | %s |\n' "$st" "$file" "$key" "$sha" "$note"
    done
    echo ""
    echo "> sha256 为剥离调试符号并改名后的产物的哈希；上游原件哈希已在下载时按官方校验文件验证。"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$failures" -gt 0 ]; then
  die "${failures} 个文件失败"
fi