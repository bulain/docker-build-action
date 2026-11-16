#!/usr/bin/env bash
# 把 MySQL 官方完整二进制包制作成 minimal 包（vendor 自 ansible-deploy
# tasks/assets/mysql/make_mysql_minimal.sh，逻辑保持一致）。
#
# minimal 规则（与上游 x86_64 官方 minimal 包逐项核对一致）：
#   1. 删除 <root>/bin/mysqld-debug（含调试符号的超大服务端二进制）
#   2. 清空 <root>/lib/plugin/debug/ 下全部 debug 版插件 .so，保留空目录条目
#   其余文件（正常 mysqld、release 插件、头文件、man、share）原样保留，默认不 strip。
#
# 输出包与输入包同目录、同压缩格式，文件名在压缩后缀前插入 -minimal：
#   mysql-8.4.13-linux-glibc2.28-aarch64.tar.xz
#     -> mysql-8.4.13-linux-glibc2.28-aarch64-minimal.tar.xz
#   mysql-5.7.44-linux-glibc2.12-x86_64.tar.gz
#     -> mysql-5.7.44-linux-glibc2.12-x86_64-minimal.tar.gz
# 支持 .tar.xz（8.0/8.4/9.7 minimal 谱系）与 .tar.gz（5.7 glibc2.12 通用包谱系），
# 解压与列目录均由 GNU tar 按格式自动识别；重打包 gz 优先 pigz 多核，缺省回退 gzip。
#
# 用法：
#   scripts/transforms/make_mysql_minimal.sh [-f] [--strip] <full-package.tar.{xz,gz}> [...]
#   -f        覆盖已存在的 minimal 包（默认遇到已存在则报错跳过）
#   --strip   额外对包内 ELF 执行 strip --strip-unneeded（去 .symtab/调试段；
#             默认关闭，官方 minimal 不 strip）
#
# 跨架构 strip 选择（按包内 ELF 机器类型自动判定）：
#   x86-64  -> strip（本机 binutils）
#   AArch64 -> aarch64-linux-gnu-strip（PATH，或 ~/.local/bin 下用户态工具）
# 也可用环境变量 STRIP_BIN 显式指定 strip 可执行文件。
#
# 安全：每个包解到独立新建的 mktemp 空目录，脚本不执行包内任何程序，仅删文件/strip/打包。
set -euo pipefail

force=0
do_strip=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) force=1; shift ;;
    --strip) do_strip=1; shift ;;
    --no-strip) do_strip=0; shift ;;
    --) shift; break ;;
    -*) echo "未知选项: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "用法: $0 [-f] [--strip] <mysql-full.tar.xz|mysql-full.tar.gz> [...]" >&2
  exit 2
fi

# 按输入包后缀选重打包压缩程序：xz 多线程；gz 优先 pigz，缺省 gzip 单线程
compress_program() {
  case "$1" in
    .tar.xz) echo 'xz -6 -T0' ;;
    .tar.gz) if command -v pigz >/dev/null 2>&1; then echo 'pigz -6'; else echo 'gzip -6'; fi ;;
    *) return 1 ;;
  esac
}

# 探测 ELF 机器类型（readelf 跨架构可读），输出 GNU readelf 的 Machine 规范名
elf_machine() {
  readelf -h "$1" 2>/dev/null | awk -F': *' '/Machine:/{print $2; exit}'
}

# 按机器类型选 strip；STRIP_BIN 环境变量可覆盖
pick_strip() {
  local machine="$1"
  if [[ -n "${STRIP_BIN:-}" ]]; then
    echo "$STRIP_BIN"; return
  fi
  case "$machine" in
    "Advanced Micro Devices X86-64") command -v strip ;;
    "AArch64")
      command -v aarch64-linux-gnu-strip \
        || { [[ -x "$HOME/.local/bin/aarch64-linux-gnu-strip" ]] && echo "$HOME/.local/bin/aarch64-linux-gnu-strip"; }
      ;;
    *) return 1 ;;
  esac
}

for src in "$@"; do
  if [[ ! -f "$src" ]]; then
    echo "[跳过] 文件不存在: $src" >&2
    continue
  fi
  base="$(basename "$src")"
  case "$base" in
    *-minimal.tar.xz|*-minimal.tar.gz)
      echo "[跳过] 已是 minimal 包: $base" >&2; continue ;;
    mysql-*.tar.xz) suffix=".tar.xz" ;;
    mysql-*.tar.gz) suffix=".tar.gz" ;;
    *)
      echo "[跳过] 非 MySQL 完整包命名（应为 mysql-*.tar.xz 或 mysql-*.tar.gz 且不含 -minimal）: $base" >&2
      continue ;;
  esac

  dst="$(dirname "$src")/${base%$suffix}-minimal${suffix}"
  compress_prog="$(compress_program "$suffix")" \
    || { echo "[失败] 不支持的压缩后缀: $suffix" >&2; exit 1; }
  if [[ -e "$dst" && $force -eq 0 ]]; then
    echo "[跳过] 目标已存在（加 -f 覆盖）: $dst" >&2
    continue
  fi

  echo "==> 制作 minimal: $base"
  work="$(mktemp -d -t mysqlmin.XXXXXX)"
  trap 'rm -rf "$work"' EXIT

  echo "    解压到隔离临时目录: $work"
  tar -xf "$src" -C "$work"

  # 完整包顶层恰有一个 mysql-<ver>-... 目录
  root="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$root" || "$(find "$work" -mindepth 1 -maxdepth 1 | wc -l)" -ne 1 ]]; then
    echo "[失败] 包顶层结构异常（应有且仅有一个根目录）: $base" >&2
    exit 1
  fi

  if [[ ! -f "$root/bin/mysqld-debug" ]]; then
    echo "[失败] 未找到 bin/mysqld-debug，包结构或规则不符: $base" >&2
    exit 1
  fi

  echo "    删除 bin/mysqld-debug 与 lib/plugin/debug/*.so"
  rm -f "$root/bin/mysqld-debug"
  # -mindepth 1：只清空内容，保留 debug 目录条目本身（与官方 minimal 一致）
  find "$root/lib/plugin/debug" -mindepth 1 -delete

  if [[ $do_strip -eq 1 ]]; then
    machine="$(elf_machine "$root/bin/mysqld")"
    strip_bin="$(pick_strip "$machine" || true)"
    if [[ -z "$strip_bin" ]]; then
      echo "[失败] 机器类型 '$machine' 无可用 strip；装 binutils-aarch64-linux-gnu" >&2
      echo "       或用 STRIP_BIN=/path/to/strip 指定；也可加 --no-strip 跳过" >&2
      exit 1
    fi
    echo "    strip（$machine）: $strip_bin --strip-unneeded"
    # 仅处理 ELF：readelf -h 能读即视为 ELF（跨架构可读，不把二进制读进 shell 变量）
    elf_list="$work/elf.list"
    while IFS= read -r -d '' f; do
      readelf -h "$f" >/dev/null 2>&1 && printf '%s\0' "$f"
    done < <(find "$root" -type f -print0) > "$elf_list"
    xargs -0 -r -n 50 "$strip_bin" --strip-unneeded < "$elf_list"
    elf_cnt="$(tr -cd '\0' < "$elf_list" | wc -c)"
    echo "    已 strip $elf_cnt 个 ELF 文件"
  fi

  echo "    重新压缩（$compress_prog）-> $(basename "$dst")"
  tmp_dst="${dst}.tmp.$$"
  tar -cf "$tmp_dst" --use-compress-program="$compress_prog" \
      -C "$work" "$(basename "$root")"

  echo "    自检产物内容"
  listing="$(tar -tf "$tmp_dst")"
  if grep -Eq '(^|/)bin/mysqld-debug$' <<<"$listing"; then
    rm -f "$tmp_dst"; echo "[失败] 产物仍含 bin/mysqld-debug" >&2; exit 1
  fi
  if grep -Eq 'lib/plugin/debug/.+\.so$' <<<"$listing"; then
    rm -f "$tmp_dst"; echo "[失败] 产物仍含 lib/plugin/debug 下 .so" >&2; exit 1
  fi
  if ! grep -Eq 'lib/plugin/debug/$' <<<"$listing"; then
    rm -f "$tmp_dst"; echo "[失败] 产物缺少 lib/plugin/debug/ 空目录条目" >&2; exit 1
  fi
  if [[ $do_strip -eq 1 ]]; then
    chk="$work/_chk_mysqld"
    tar -xOf "$tmp_dst" "$(basename "$root")/bin/mysqld" > "$chk" 2>/dev/null
    chk_machine="$(elf_machine "$chk")"
    if [[ "$chk_machine" != "$machine" ]]; then
      rm -f "$tmp_dst" "$chk"; echo "[失败] 产物 mysqld 机器类型异常: '$chk_machine'" >&2; exit 1
    fi
    if readelf -S "$chk" 2>/dev/null | grep -q '\.symtab'; then
      rm -f "$tmp_dst" "$chk"; echo "[失败] mysqld 仍含 .symtab（strip 未生效）" >&2; exit 1
    fi
    rm -f "$chk"
  fi

  mv -f "$tmp_dst" "$dst"
  rm -rf "$work"
  trap - EXIT
  echo "    完成: $dst ($(du -h "$dst" | cut -f1))"
done
