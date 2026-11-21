#!/usr/bin/env bash
# 把上游发布件镜像到 OSS 的通用驱动。由 scripts/monitoring.sh / scripts/middleware.sh /
# scripts/jdk.sh（经 --section）或 scripts/<component>.sh 调用，不直接执行。
#
# 与 upstream-percona.sh 的区别：产物分架构、用上游官方校验文件。与
# scripts/<pkg>.sh（packages）的区别：不编译、不分档位。产物就是上游原件：
# 保持原名与原压缩类型，不解压、不剥离、不改名。
# 设计见 docs/adr/0004-monitoring-upstream-mirror.md、
# docs/adr/0005-middleware-upstream-mirror.md。
#
# 用法（通常经由 scripts/<section>.sh 或 scripts/<component>.sh 调用）：
#   scripts/mirror.sh --section <monitoring|middleware|jdk> <component> [--option ...] [镜像参数]
#   镜像参数：
#     --all                  镜像该段全部组件（忽略 component 位置参数与 --component）
#     --component <name>     只镜像某个组件，可多次
#     --section <name>       config.yaml 的镜像段，默认 monitoring
#     --local <dir>          不联网：从目录读取上游资产，校验后原样写到输出目录
#     --output-dir <dir>     本地输出目录（默认 $REPO_ROOT/out/<section>）
#     --dry-run              只解析并列出清单
#     --skip-checksums       上游校验文件缺失时跳过，而不是失败
#
# 环境变量：
#   OSS_BUCKET / OSS_ENDPOINT / OSS_REGION / OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET
#   OSS_PREFIX     覆盖 config.yaml 该段的 prefix
#   OSSUTIL        ossutil 可执行文件路径（默认从 PATH 里找）
#   GITHUB_TOKEN   可选，匿名 GitHub API 限 60 次/小时，每个 repo+tag 查一次
#   WORK_DIR       下载缓存目录（默认 ./out/<section>）
#   FORCE          true 时覆盖 OSS 上已存在的文件
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

log() { printf '[mirror] %s\n' "$*" >&2; }
die() { printf '[mirror] ERROR: %s\n' "$*" >&2; exit 1; }

section="monitoring"
components=()

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
    --section) section="${2:?--section 需要值}"; shift 2 ;;
    --config) config_file="${2:?--config 需要值}"; shift 2 ;;
    --local) local_dir="${2:?--local 需要值}"; shift 2 ;;
    --output-dir) output_dir_override="${2:?--output-dir 需要值}"; shift 2 ;;
    --dry-run) dry_run="true"; shift ;;
    --skip-checksums) skip_checksums="true"; shift ;;
    -h | --help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "未知选项: $1" ;;
    # 组件名允许出现在任意位置：shim 会把 --section 放在参数序列最前面
    *) components+=("$1"); shift ;;
  esac
done

[ -f "$config_file" ] || die "找不到配置文件: $config_file"

python_bin="${PYTHON:-python3}"
command -v "$python_bin" >/dev/null 2>&1 || die "缺少 python3（解析 config.yaml 用）"

# 段名白名单：它会被拼进 python 取值与输出目录路径，不接受任意值
case "$section" in
  monitoring|middleware|jdk) ;;
  *) die "不支持的镜像段: ${section}（可选 monitoring / middleware / jdk）" ;;
esac

script_name=$(basename "${BASH_SOURCE[0]}")
if [ "$all" = "true" ] && [ "$dry_run" != "true" ]; then
  # 交给各组件自己的脚本执行，保证入口统一（手动触发与 push 走同一条路径）。
  # dry-run 不走这里：它不联网，也不该因某个组件脚本缺少参数而失败
  mapfile -t every < <("$python_bin" -c 'import sys,yaml; sec=sys.argv[1]; c=yaml.safe_load(open(sys.argv[2])); print("\n".join((c.get(sec) or {}).get("components") or {}))' "$section" "$config_file")
  [ "${#every[@]}" -gt 0 ] || die "config.yaml 的 ${section}.components 为空"
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
  mapfile -t components < <("$python_bin" -c 'import sys,yaml; sec=sys.argv[1]; c=yaml.safe_load(open(sys.argv[2])); print("\n".join((c.get(sec) or {}).get("components") or {}))' "$section" "$config_file")
  [ "${#components[@]}" -gt 0 ] || die "config.yaml 的 ${section}.components 为空"
fi

if [ "${#components[@]}" -eq 0 ]; then
  [ "$script_name" != "mirror.sh" ] || die "需要组件名：scripts/mirror.sh --section ${section} <component>，或用 --all"
  # 由 scripts/<component>.sh 调用：把 $0 的基名当组件名
  components=("${script_name%.sh}")
fi

prefix="${OSS_PREFIX:-}"
if [ -z "$prefix" ]; then
  prefix=$("$python_bin" -c 'import sys,yaml; sec=sys.argv[1]; c=yaml.safe_load(open(sys.argv[2])); print((c.get(sec) or {}).get("prefix") or (c.get("oss") or {}).get("prefix") or "linux")' "$section" "$config_file")
fi

resolve_args=(--config "$config_file" --section "$section")
for c in "${components[@]}"; do resolve_args+=(--component "$c"); done
if [ -n "$local_dir" ]; then
  [ -d "$local_dir" ] || die "--local 目录不存在: $local_dir"
  resolve_args+=(--local "$local_dir")
fi

if [ "$dry_run" = "true" ]; then
  # dry-run 只用 python 回显，不要求 jq / curl / ossutil
  exec "$python_bin" "$SCRIPT_DIR/mirror_resolve.py" "${resolve_args[@]}" --dry-run
fi

# ---------- 依赖 ----------
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"

work_dir="${WORK_DIR:-$REPO_ROOT/out/${section}}"
output_dir="${output_dir_override:-$work_dir/packages}"
mkdir -p "$work_dir" "$output_dir"

resolved=$("$python_bin" "$SCRIPT_DIR/mirror_resolve.py" "${resolve_args[@]}" --tsv)
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

# ossutil 进度条只用 \r 刷新，GitHub Actions 按 \n 摄取日志，大文件上传时
# 会长时间无输出；转成换行让进度实时可见。进度走 stderr：publish_one 的
# stdout 只允许出现 ok| 汇总行，主循环靠命令替换捕获它生成 Step Summary。
# 分片策略用 ossutil 默认（自动约 32Mi/片），不显式指定 --part-size。
# 默认分片下总进度只在整片完成时跳动，慢链路首片完成前会持续输出相同的
# 0.000%，由 awk 按百分比折叠重复 tick（同百分比但 avg 在变的行只留首条）。
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

# ---------- 上游获取 ----------
# GITHUB_TOKEN 只给 resolver 的 GitHub API 查询用（见 mirror_resolve.py）；
# release 资产下载走签名直链，curl 不需要额外头
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

# verify_official <archive> <checksums 文件> <资产名> [sha256|md5]
# sha256 校验文件是 coreutils 格式（hash  name）；nacos 的 md5 是 BSD 格式
# （MD5 (name) = hash），awk 两种格式都认。
verify_official() {
  local archive="$1" checksums="$2" name="$3" algo="${4:-sha256}" expected sumtool
  case "$algo" in
    sha256) sumtool=sha256sum ;;
    md5)
      command -v md5sum >/dev/null 2>&1 || die "缺少 md5sum，无法校验 ${name}"
      sumtool=md5sum
      ;;
    *) die "不支持的校验算法: ${algo}（${name}）" ;;
  esac
  expected=$(awk -v n="$name" '
    $1 == "MD5" && $2 == "(" n ")" { print $4; exit }
    $2 == n { print $1; exit }
  ' "$checksums")
  [ -n "$expected" ] || die "校验文件里没有 $name"
  printf '%s  %s\n' "$expected" "$archive" | "$sumtool" -c - >/dev/null \
    || die "${name} 官方 ${algo} 校验失败"
}

# 直接按 resolver 给出的官方哈希校验（MySQL 目录页 MD5，无独立校验文件）
verify_expected() {
  local archive="$1" expected="$2" name="$3" algo="${4:-sha256}" sumtool
  case "$algo" in
    sha256) sumtool=sha256sum ;;
    md5)
      command -v md5sum >/dev/null 2>&1 || die "缺少 md5sum，无法校验 ${name}"
      sumtool=md5sum
      ;;
    *) die "不支持的校验算法: ${algo}（${name}）" ;;
  esac
  printf '%s  %s\n' "$expected" "$archive" | "$sumtool" -c - >/dev/null \
    || die "${name} 官方 ${algo} 校验失败"
}

# ---------- 单文件 ----------
publish_one() {
  local asset_name="$1" url="$2" checksums_url="$3" algorithm="$4" \
        source_name="$5" transform="$6" do_strip="$7" expected_hash="$8"
  # asset_name 是落 OSS 的产物名；转换组件的下载源名在 source_name
  local dest="$output_dir/$asset_name"

  rm -f "$dest" "$dest.sha256"

  if [ -z "$local_dir" ] && "$OSSUTIL" stat "oss://${OSS_BUCKET}/${prefix}/${asset_name}" "${oss_auth[@]}" >/dev/null 2>&1 \
     && [ "${FORCE:-false}" != "true" ]; then
    log "跳过（OSS 已存在）: $asset_name"
    printf 'skip|%s|||已存在\n' "$asset_name"
    return 0
  fi

  local src_asset="$work_dir/downloads/$source_name"
  mkdir -p "$(dirname "$src_asset")"

  if [ -n "$local_dir" ]; then
    [ -f "$local_dir/$source_name" ] || die "--local 目录里没有 $source_name"
    cp -f "$local_dir/$source_name" "$src_asset"
  elif [ ! -s "$src_asset" ]; then
    download "$url" "$src_asset"
  else
    log "复用已下载文件: ${src_asset##*/}"
  fi

  # 校验对象永远是下载源（转换前的上游原件），不是转换产物
  local checksums note
  if [ "$expected_hash" != "-" ]; then
    verify_expected "$src_asset" "$expected_hash" "$source_name" "$algorithm"
    log "官方 ${algorithm} 校验通过: $source_name"
  elif [ -n "$local_dir" ]; then
    # 离线模式：把上游同名的官方校验文件一起放进目录才校验
    if [ "$checksums_url" != "-" ] && checksums=$(fetch_checksums "file://$local_dir/$(basename "$checksums_url")"); then
      verify_official "$src_asset" "$checksums" "$source_name" "$algorithm"
      log "官方 ${algorithm} 校验通过: $source_name"
    else
      log "警告: 本地模式无官方哈希来源，跳过校验: $source_name"
    fi
  elif [ "$checksums_url" != "-" ]; then
    if checksums=$(fetch_checksums "$checksums_url"); then
      verify_official "$src_asset" "$checksums" "$source_name" "$algorithm"
      log "官方 ${algorithm} 校验通过: $source_name"
    elif [ "$skip_checksums" = "true" ]; then
      log "警告: 拿不到校验文件，跳过校验（--skip-checksums）"
    else
      die "拿不到官方校验文件: $checksums_url"
    fi
  else
    # grafana 的 sha256 只存在于包清单 API（与下载地址同源），不单独下发校验文件；
    # rabbitmq 的 GitHub release 只有 GPG .asc，没有哈希文件
    log "警告: ${source_name} 没有独立校验文件，跳过校验"
  fi

  if [ "$transform" != "-" ]; then
    local made
    case "$transform" in
      mysql-minimal)
        local targs=(-f)
        [ "$do_strip" = "true" ] && targs+=(--strip)
        # 显式接住退出码：本函数可能运行在 if 条件里，set -e 不会传播失败
        bash "$SCRIPT_DIR/transforms/make_mysql_minimal.sh" "${targs[@]}" "$src_asset" \
          || die "minimal 转换失败: $source_name"
        case "$source_name" in
          *.tar.xz) made="${src_asset%.tar.xz}-minimal.tar.xz" ;;
          *.tar.gz) made="${src_asset%.tar.gz}-minimal.tar.gz" ;;
          *) die "不支持的转换源后缀: $source_name" ;;
        esac
        ;;
      *) die "未知转换: ${transform}" ;;
    esac
    [ -f "$made" ] || die "转换未产出预期文件: $made"
    [ "$(basename "$made")" = "$asset_name" ] \
      || die "转换产物名 $(basename "$made") 与配置 filename ${asset_name} 不一致"
    cp -f "$made" "$dest"
    note="官方 ${algorithm} 校验源包后自制 minimal"
  else
    cp -f "$src_asset" "$dest"
    note="官方校验后原样上传"
  fi

  local sha
  sha=$(sha256sum "$dest" | cut -d' ' -f1)
  printf '%s  %s\n' "$sha" "$asset_name" > "$dest.sha256"

  if [ -n "$local_dir" ]; then
    log "已生成: $dest (sha256 ${sha})"
    printf 'local|%s|%s||本地输出\n' "$asset_name" "$sha"
    return 0
  fi

  local key="oss://${OSS_BUCKET}/${prefix}/${asset_name}"
  local prev
  prev=$(remote_sha "$key")
  if [ -n "$prev" ] && [ "$prev" != "$sha" ]; then
    log "警告: ${asset_name} 哈希与 OSS 记录不一致（远端 ${prev} / 本次 ${sha}）"
  fi

  log "上传: ${asset_name}"
  oss_cp "$dest" "$key" "${oss_auth[@]}" || die "上传失败: $key"
  oss_cp "$dest.sha256" "$key.sha256" "${oss_auth[@]}" || die "上传失败: $key.sha256"
  log "已上传: $key (sha256 ${sha})"
  printf 'ok|%s|%s|%s|%s\n' "$asset_name" "$key" "$sha" "$note"
}

# ---------- 主循环 ----------
failures=0
results=()
while IFS=$'\t' read -r comp ver arch url filename checksums algorithm source transform strip expected_hash; do
  case "$arch" in -) arch="" ;; esac
  log "---- ${comp} ${ver} ${arch:-无架构} ----"
  if out=$(publish_one "$filename" "$url" "$checksums" "$algorithm" \
                          "$source" "$transform" "$strip" "$expected_hash"); then
    results+=("$out")
  else
    failures=$((failures + 1))
    results+=("fail|$filename|||失败")
    log "失败: $filename"
  fi
done < <(printf '%s\n' "$resolved")

log "完成：成功 $((count - failures)) / 总计 ${count}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## ${section} 上游镜像"
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
    echo "> 产物为上游原件原样上传；sha256 与官方校验文件一致（无校验文件的组件除外）。"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$failures" -gt 0 ]; then
  die "${failures} 个文件失败"
fi
