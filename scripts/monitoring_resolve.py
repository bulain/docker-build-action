#!/usr/bin/env python3
"""把 config.yaml 的 monitoring 段解析成待镜像文件清单。

输出 TSV（--tsv）或 JSON（默认）：
  component  version  arch  url  filename  checksums

- arch 为 - 表示该组件不分架构（single）。
- url：上游资产地址。dry-run 与 --local 不查上游，此时分别留空 / 填本地目录。
- filename：上游资产名，同时是落到 OSS 的名字。上游原件原样搬运，
  不解压、不剥离、不改名，压缩类型也保持上游的。
- checksums: 官方校验文件 URL，可为空（输出为 -）。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

import yaml

GITHUB_API = "https://api.github.com"
GRAFANA_API = "https://grafana.com/api"


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
    single = bool(comp.get("single"))
    key = "default" if single else arch
    raw_assets = comp.get("assets") or {}

    # 产物保持上游原名与原压缩类型：不解压、不剥离、不改名
    asset = (
        raw_assets.get(key) or default_name(name, key, version)
    ).format(version=version)
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
    ck = comp.get("checksums") or {}
    if ck.get("url"):
        checksums = ck["url"].format(version=version)

    return {
        "component": name,
        "version": version,
        "arch": "" if single else arch,
        "url": url,
        "filename": asset,
        "checksums": checksums,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
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

    mon = cfg.get("monitoring") or {}
    components = mon.get("components") or {}
    if not components:
        print(json.dumps({"files": [], "count": 0}))
        return 0
    unknown = [c for c in args.component if c not in components]
    if unknown:
        print(
            f"未知组件: {', '.join(unknown)}（可选: {', '.join(components)}）", file=sys.stderr
        )
        return 2

    arches = [str(a) for a in mon.get("architectures") or ["amd64", "arm64"]]
    names = args.component or list(components)

    files = []
    cache: dict[tuple, dict] = {}
    for name in names:
        comp = components[name]
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
                # tag 可能与版本号不同名（prometheus 系 tag 带 v，资产名不带）
                tag = str(comp.get("tag") or comp["version"])
                cache[key] = {"assets": release_assets(comp["repo"], tag)}
        entry = cache[key]

        for arch in targets:
            files.append(build_entry(name, comp, arch, entry.get("assets"), entry.get("packages") or []))

    if args.dry_run:
        for f in files:
            print(f"{f['component']}\t{f['version']}\t{f['arch'] or '-'}\t{f['filename']}")
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
                    ]
                )
            )
        return 0

    print(json.dumps({"files": files, "count": len(files)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())