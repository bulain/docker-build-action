#!/usr/bin/env python3
"""把 config.yaml 的 upstream 段解析成待镜像文件清单。

输出 JSON：{"files": [{"component", "version", "tier", "filename", "url"}], "count": N}
tier 为空字符串表示该组件不分 glibc 档。
"""
from __future__ import annotations

import argparse
import json
import posixpath
import sys

import yaml


def major_minor(version: str) -> str:
    """8.4.10-10 -> 8.4；Percona 目录按大版本线分层。"""
    parts = version.split(".")
    if len(parts) < 2:
        raise ValueError(f"版本号需要形如 8.4.10-10，实际为 {version}")
    return f"{parts[0]}.{parts[1]}"


def tiers_for(comp: dict, version: str, default_tiers: list[str]) -> list[str]:
    # tiers 显式写（哪怕是空列表）就完全接管，否则用全局默认 + extra_glibc_tiers
    if "tiers" in comp:
        base = list(comp["tiers"] or [])
    else:
        base = list(default_tiers)
    if "tiers" not in comp or comp["tiers"]:
        for tier in comp.get("extra_glibc_tiers", []) or []:
            if tier not in base:
                base.append(tier)
    return base


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--component", default="", help="只解析某个组件，留空则全部")
    parser.add_argument("--version", default="", help="覆盖该组件的版本列表（单值）")
    parser.add_argument(
        "--dry-run", action="store_true", help="输出人类可读清单而非 JSON"
    )
    parser.add_argument(
        "--tsv", action="store_true", help="输出 component\\tversion\\ttier\\turl\\tfilename 行"
    )
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)

    upstream = cfg.get("upstream") or {}
    components = upstream.get("components") or {}
    if not components:
        print(json.dumps({"files": [], "count": 0}))
        return 0

    if args.component:
        if args.component not in components:
            print(f"未知组件: {args.component}（可选: {', '.join(components)}）", file=sys.stderr)
            return 2
        names = [args.component]
    else:
        names = list(components)

    default_tiers = [str(t) for t in upstream.get("glibc_tiers", [])]

    files = []
    for name in names:
        comp = components[name]
        versions = [args.version] if args.version else [str(v) for v in comp["versions"]]

        tiers = tiers_for(comp, "", default_tiers)
        for version in versions:
            mm = major_minor(version)
            # 不分档的组件只产出一条，tier 留空
            for tier in tiers or [""]:
                url = comp["url"].format(version=version, major_minor=mm, tier=tier)
                files.append(
                    {
                        "component": name,
                        "version": version,
                        "tier": tier,
                        "filename": posixpath.basename(url),
                        "url": url,
                    }
                )

    if args.tsv:
        for f in files:
            # tier 为空时输出 "-"：连续制表符会被 bash read 折叠，字段会左移
            print(
                "\t".join(
                    [
                        f["component"],
                        f["version"],
                        f["tier"] or "-",
                        f["url"],
                        f["filename"],
                    ]
                )
            )
        return 0

    if args.dry_run:
        for f in files:
            print(f"{f['component']}\t{f['version']}\t{f['tier'] or '-'}\t{f['filename']}")
            print(f"  {f['url']}")
        print(f"共 {len(files)} 个文件", file=sys.stderr)
        return 0

    print(json.dumps({"files": files, "count": len(files)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
