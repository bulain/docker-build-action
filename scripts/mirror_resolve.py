#!/usr/bin/env python3
"""把 config.yaml 的镜像段（monitoring / middleware）解析成待镜像文件清单。

输出 TSV（--tsv）或 JSON（默认）：
  component  version  arch  url  filename  checksums  algorithm  source  transform  strip  expected_hash

- section 由 --section 选择，默认 monitoring；两个段结构相同，区别只在语义
  （监控组件 vs 中间件/基础服务），见 docs/adr/0004、0005。
- arch 为 - 表示该组件不分架构（single）。
- url：上游资产地址。dry-run 与 --local 不查上游，此时分别留空 / 填本地目录。
- filename：落到 OSS 的名字。普通组件等于上游资产名（原样搬运）；带 transform
  的组件（mysql minimal 自制）是转换后的产物名，源资产名在 source 列。
- checksums: 官方校验文件 URL，可为空（输出为 -）。
- algorithm: 校验哈希算法，sha256（默认）或 md5（nacos / mysql 目录页只有 md5）。
- source: 实际下载的上游资产名；无转换时与 filename 相同。
- transform: 下载后执行的转换名（mysql-minimal），无则 -。
- strip: 转换时是否对 ELF 做 --strip-unneeded，true / false。
- expected_hash: catalog 类组件在页面里直接给出的官方哈希（无独立校验文件），无则 -。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

import yaml

GITHUB_API = "https://api.github.com"
GRAFANA_API = "https://grafana.com/api"
MYSQL_DOWNLOAD_BASE = "https://dev.mysql.com/downloads/mysql"
# 下载页表格里 (文件名) ... <code class="md5">32 位十六进制</code>
MYSQL_MD5_RE = re.compile(
    r"\((mysql-[^)]+\.tar\.(?:xz|gz))\).*?<code class=\"md5\">([0-9a-fA-F]{32})</code>",
    re.S,
)


def default_name(name: str, key: str, version: str) -> str:
    # 单架构组件（key=default）没有架构段
    if key == "default":
        return f"{name}-{version}.tar.gz"
    return f"{name}-{key}-{version}.tar.gz"


def http_json(url: str) -> dict:
    headers = {"User-Agent": "docker-build-action"}
    # 匿名 GitHub API 限 60 次/小时，CI 一次解析会查多个 repo+tag。
    # 只发给 api.github.com：grafana.com 收到 GitHub token 会 401
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if token and url.startswith(GITHUB_API):
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def release_assets(repo: str, tag: str) -> dict[str, str]:
    """tag -> {资产名: 下载地址}。只查单次 release，省匿名 API 配额。"""
    try:
        data = http_json(f"{GITHUB_API}/repos/{repo}/releases/tags/{tag}")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise SystemExit(f"{repo}: 找不到 release tag {tag}（检查 config.yaml 的 version/tag）") from exc
        raise
    return {a["name"]: a["browser_download_url"] for a in data["assets"]}


def grafana_packages(version: str) -> list[dict]:
    data = http_json(f"{GRAFANA_API}/grafana/versions/{version}")
    return data.get("packages") or []


def http_text(url: str, user_agent: str = "docker-build-action") -> str:
    headers = {"User-Agent": user_agent}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", errors="replace")


def major_minor(version: str) -> str:
    parts = version.split(".")
    if len(parts) < 2:
        raise ValueError(f"版本号需要形如 8.4.13，实际为 {version}")
    return f"{parts[0]}.{parts[1]}"


def mysql_md5_table(version: str, page_url_tpl: str) -> dict[str, str]:
    """抓 MySQL 下载页（os=2 = Linux Generic），解析文件名 -> 官方 MD5。

    MySQL 不提供独立校验文件，MD5 内嵌在 HTML 表格；同一大版本线共用一个页面。
    """
    mm = major_minor(version)
    url = page_url_tpl.format(major_minor=mm, version=version)
    # dev.mysql.com 前面是 Akamai，自定义/浏览器 UA 均 403，curl 风格 UA 放行
    html = http_text(url, user_agent="curl/8.5.0")
    return dict(MYSQL_MD5_RE.findall(html))


def build_entry(
    name: str,
    comp: dict,
    arch: str,
    assets: dict[str, str] | None,
    packages: list[dict],
    local: str = "",
    dry: bool = False,
) -> dict:
    version = str(comp["version"])
    tag = str(comp.get("tag") or version)
    single = bool(comp.get("single"))
    key = "default" if single else arch
    raw_assets = comp.get("assets") or {}

    # 产物保持上游原名与原压缩类型：不解压、不剥离、不改名
    asset = (
        raw_assets.get(key) or default_name(name, key, version)
    ).format(version=version, tag=tag)
    local_name = asset
    url = ""

    if local:
        url = f"{local}/{asset}"
    elif not dry and comp.get("catalog") == "grafana":
        # 包清单里的 os 字段对 tar.gz 记为 linux，与 rpm/deb 区分靠文件名。
        # 新版清单文件名带构建号且改用下划线（grafana_13.3.1_<build>_linux_amd64.tar.gz），
        # 不能再拿配置里的规范名做匹配；清单只用于确认版本/架构确实存在，
        # 下载走稳定的 oss/release 规范地址（文件名保持 grafana-<v>.linux-<arch>.tar.gz）。
        pkg = next(
            (p for p in packages if p.get("os") == "linux" and p.get("arch") == arch),
            None,
        )
        if pkg is None:
            raise SystemExit(f"{name} {version} {arch}: grafana 包清单里找不到该 os/arch 组合")
        url = f"https://dl.grafana.com/oss/release/{local_name}"
    elif not dry:
        url = (assets or {}).get(asset, "")
        if not url:
            raise SystemExit(f"{name} {version} {arch}: 上游资产里找不到 {asset}")

    checksums = ""
    algorithm = "sha256"
    ck = comp.get("checksums") or {}
    if ck.get("url"):
        checksums = ck["url"].format(version=version, tag=tag)
        algorithm = str(ck.get("algorithm") or "sha256")

    return {
        "component": name,
        "version": version,
        "arch": "" if single else arch,
        "url": url,
        "filename": asset,
        "checksums": checksums,
        "algorithm": algorithm,
        # 普通组件：下载名即产物名，无转换
        "source": asset,
        "transform": "",
        "strip": False,
        "expected_hash": "",
    }


def build_explicit_entry(
    name: str,
    item: dict,
    comp: dict,
    md5_table: dict[str, str] | None,
    local: str = "",
    dry: bool = False,
) -> dict:
    """files 显式清单条目（目前仅 MySQL：源 full/minimal 包 -> 自制 minimal 产物）。"""
    version = str(item["version"])
    source = str(item["source"])
    filename = str(item.get("filename") or source)
    transform = str(item.get("transform") or "")
    strip = bool(item.get("strip"))
    expected = ""
    url = ""

    if local:
        url = f"{local}/{source}"
    elif not dry:
        if comp.get("catalog") != "mysql":
            raise SystemExit(f"{name}: files 显式清单目前只支持 catalog: mysql")
        table = md5_table or {}
        if source not in table:
            raise SystemExit(f"{name} {version}: MySQL 下载页找不到 {source} 的 MD5 行")
        expected = table[source]
        mm = major_minor(version)
        url = str(comp["cdn_url"]).format(
            major_minor=mm, version=version, source=source
        )

    return {
        "component": name,
        "version": version,
        "arch": str(item.get("arch") or ""),
        "url": url,
        "filename": filename,
        # MySQL 的官方哈希来自页面解析（expected_hash），没有独立校验文件 URL
        "checksums": "",
        "algorithm": "md5",
        "source": source,
        "transform": transform,
        "strip": strip,
        "expected_hash": expected,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument(
        "--section",
        default="monitoring",
        help="config.yaml 的镜像段名：monitoring（默认）或 middleware",
    )
    parser.add_argument(
        "--component", action="append", default=[], help="只解析某个组件，可重复；留空则全部"
    )
    parser.add_argument("--tsv", action="store_true", help="输出 TSV 行")
    parser.add_argument("--dry-run", action="store_true", help="人类可读清单，不查询上游")
    parser.add_argument(
        "--local", default="", help="离线模式：资产取自本地目录，不查询上游"
    )
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)

    section = cfg.get(args.section) or {}
    components = section.get("components") or {}
    if not components:
        print(json.dumps({"files": [], "count": 0}))
        return 0
    unknown = [c for c in args.component if c not in components]
    if unknown:
        print(
            f"未知组件: {', '.join(unknown)}（{args.section} 段可选: {', '.join(components)}）",
            file=sys.stderr,
        )
        return 2

    arches = [str(a) for a in section.get("architectures") or ["amd64", "arm64"]]
    names = args.component or list(components)

    files = []
    cache: dict[tuple, dict] = {}
    for name in names:
        comp = components[name]

        # 显式 files 清单（MySQL）：每条自带版本/架构/源资产/转换规则，
        # 不走 assets 模板与 GitHub/grafana 资产查询
        if comp.get("files"):
            if args.dry_run:
                for item in comp["files"]:
                    files.append(build_explicit_entry(name, item, comp, None, dry=True))
                continue
            if args.local:
                for item in comp["files"]:
                    files.append(build_explicit_entry(name, item, comp, None, local=args.local))
                continue
            page_tpl = str(comp.get("page_url") or "")
            for item in comp["files"]:
                mm = major_minor(str(item["version"]))
                cache_key = ("mysql-page", mm)
                if cache_key not in cache:
                    cache[cache_key] = mysql_md5_table(str(item["version"]), page_tpl)
                files.append(
                    build_explicit_entry(name, item, comp, cache[cache_key])
                )
            continue

        if comp.get("single"):
            targets = ["default"]
        else:
            targets = arches

        if args.dry_run:
            # dry-run 不查上游：url 留空，filename 按配置回放
            for arch in targets:
                files.append(build_entry(name, comp, arch, None, [], dry=True))
            continue

        if args.local:
            for arch in targets:
                files.append(build_entry(name, comp, arch, None, [], local=args.local))
            continue

        key = ("grafana", str(comp["version"])) if comp.get("catalog") else ("gh", comp.get("repo"))
        if key not in cache:
            if key[0] == "grafana":
                cache[key] = {"packages": grafana_packages(str(comp["version"]))}
            else:
                # tag 可能与版本号不同名（prometheus 系 tag 带 v，资产名不带；
                # pgsty 的 tag 是 RELEASE.<ISO>，资产名用紧凑包版本）
                tag = str(comp.get("tag") or comp["version"])
                cache[key] = {"assets": release_assets(comp["repo"], tag)}
        entry = cache[key]

        for arch in targets:
            files.append(build_entry(name, comp, arch, entry.get("assets"), entry.get("packages") or []))

    if args.dry_run:
        for f in files:
            print(f"{f['component']}\t{f['version']}\t{f['arch'] or '-'}\t{f['filename']}")
            if f["source"] != f["filename"]:
                extra = f["transform"] or "?"
                strip_note = " +strip" if f["strip"] else ""
                print(f"  source: {f['source']} -> transform {extra}{strip_note}")
            else:
                print(f"  source: {f['url'] or f['component']}")
        print(f"共 {len(files)} 个文件", file=sys.stderr)
        return 0

    if args.tsv:
        for f in files:
            # 空字段可能被 bash read 折叠，但后续字段都在末尾，按位置读不会错位
            print(
                "\t".join(
                    [
                        f["component"],
                        f["version"],
                        f["arch"] or "-",
                        f["url"],
                        f["filename"],
                        f["checksums"] or "-",
                        f["algorithm"],
                        f["source"],
                        f["transform"] or "-",
                        "true" if f["strip"] else "false",
                        f["expected_hash"] or "-",
                    ]
                )
            )
        return 0

    print(json.dumps({"files": files, "count": len(files)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
