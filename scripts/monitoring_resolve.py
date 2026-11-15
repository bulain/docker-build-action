#!/usr/bin/env python3
"""把 config.yaml 的 monitoring 段解析成待镜像文件清单。

输出 TSV（--tsv）或 JSON（默认）：
  component  version  arch  url  filename  local_name  strip_binaries  kind  checksums

- arch 为 - 表示该组件不分架构（single）。
- url：上游资产地址。dry-run 与 --local 不查上游，此时分别填组件名 / 本地目录。
- filename：上游资产名；local_name：落到 OSS 的名字（改过名则两者不同）。
- kind: tar.gz | zip（按上游资产名判断，zip 会转成 tar.gz）。
- checksums: 官方校验文件 URL，可为空（输出为 -）。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
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
    # 匿名 GitHub API 限 60 次/小时，CI 一次解析会查多个 repo+tag
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or ""
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def release_assets(repo: str, version: str) -> dict[str, str]:
    """tag -> {资产名: 下载地址}。只查单次 release，省匿名 API 配额。"""
    data = http_json(f"{GITHUB_API}/repos/{repo}/releases/tags/{version}")
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
    raw_names = comp.get("asset_names") or {}

    # 产物名（落到 OSS 的名字）：默认 {name}-{arch}-{version}.tar.gz（单架构组件
    # 没有架构段）；上游名不符合这个格式的（alertmanager 用点分隔、adapter 没有
    # 扩展名、grafana 走包清单、数据源插件是 zip）用 asset_names 显式给出
    fallback = default_name(name, key, version)
    local_name = (raw_names.get(key) or fallback).format(version=version)

    # 上游资产名：assets 显式列出（上游名与产物名不同的组件必须写）；
    # 否则认为上游名与产物名同构（alloy / 数据源插件）。
    # fallback 固定是 .tar.gz，单架构且产物是 zip 时（数据源插件）用产物名兜底
    asset = (raw_assets.get(key) or (local_name if single else fallback)).format(version=version)
    # kind 按上游资产判断：zip 要解压后重打成 tar.gz，产物名一定是 .tar.gz，
    # 用产物名判断会把 alloy 这类 zip 上游误当 tar.gz
    kind = "zip" if asset.endswith(".zip") else "tar.gz"
    url = ""

    if local:
        url = f"{local}/{asset}"
    elif not dry and comp.get("catalog") == "grafana":
        # 包清单里的 os 字段对 tar.gz 记为 linux，与 rpm/deb 区分靠文件名
        pkg = next(
            (
                p
                for p in packages
                if p.get("os") == "linux"
                and p.get("arch") == arch
                and p["url"].rsplit("/", 1)[-1] == local_name
            ),
            None,
        )
        if pkg is None:
            raise SystemExit(f"{name} {version} {arch}: grafana 包清单里找不到 {local_name}")
        url = pkg["url"]
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
        "local_name": local_name,
        "kind": kind,
        "strip": ",".join(comp.get("strip_binaries") or []),
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
                cache[key] = {"assets": release_assets(comp["repo"], str(comp["version"]))}
        entry = cache[key]

        for arch in targets:
            files.append(build_entry(name, comp, arch, entry.get("assets"), entry.get("packages") or []))

    if args.dry_run:
        for f in files:
            print(f"{f['component']}\t{f['version']}\t{f['arch'] or '-'}\t{f['local_name']}")
            print(f"  source: {f['url'] or f['component']}")
        print(f"共 {len(files)} 个文件", file=sys.stderr)
        return 0

    if args.tsv:
        for f in files:
            # 空字段可能被 bash read 折叠，但后续字段都在末尾，abuild 按位置读不会错位
            print(
                "\t".join(
                    [
                        f["component"],
                        f["version"],
                        f["arch"] or "-",
                        f["url"],
                        f["filename"],
                        f["local_name"],
                        f["strip"] or "-",
                        f["kind"],
                        f["checksums"] or "-",
                    ]
                )
            )
        return 0

    print(json.dumps({"files": files, "count": len(files)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())