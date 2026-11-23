#!/usr/bin/env python3
"""把 config.yaml 的镜像段（monitoring / middleware / jdk）解析成待镜像文件清单。

输出 TSV（--tsv）或 JSON（默认）：
  component  version  arch  url  filename  checksums  algorithm  source  transform  strip  expected_hash

- section 由 --section 选择，默认 monitoring；各段结构相同，区别只在语义
  （监控组件 / 中间件 / JDK 运行时），见 docs/adr/0004、0005、0006。
- catalog: adoptium 的组件（JDK）按官方 API 解析：资产名、直链与 sha256 都来自
  api.adoptium.net。17+ 的 release 是 jdk-<semver>（如 jdk-21.0.13+9），8 是
  jdk8u504-b01，无法互相推导，故支持显式 release_name。离线与 dry-run 按命名规则推导文件名。
  sonatype（nexus）不查 API：直链按 config.yaml 模板拼（3.98 起分 x86_64 /
  aarch_64 双架构包），sha256 取自同名 .sha256 边车（内容为裸哈希），
  经 expected_hash 通道下发。
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
from urllib.parse import quote, urlencode

import yaml

GITHUB_API = "https://api.github.com"
ADOPTIUM_API = "https://api.adoptium.net"
# 本仓库统一用 amd64 / arm64；Adoptium 的 API 与文件名用 x64 / aarch64
ADOPTIUM_ARCH = {"amd64": "x64", "arm64": "aarch64"}
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


def adoptium_release_name(comp: dict) -> str:
    """release 标识：8 的是 jdk8u504-b01，17+ 的是 jdk-21.0.13+9，无法互相推导。"""
    return str(comp.get("release_name") or f"jdk-{comp['version']}")


def adoptium_asset_name(release_name: str, version: str, arch: str) -> str:
    """按 Adoptium 命名规则推导文件名（离线与 dry-run 用）。

    在线解析以 API 返回的 package.name 为准；这里只保证预演清单显示的名字
    与实际上传一致。8 与 17+ 的写法不同：
      jdk8u504-b01   -> 8u504b01
      jdk-21.0.13+9  -> 21.0.13_9
    去掉 jdk 前缀后，+ 换 _、- 删掉即可。
    """
    major = version.split(".")[0]
    token = release_name[3:] if release_name.startswith("jdk") else release_name
    token = token.lstrip("-").replace("+", "_").replace("-", "")
    return (
        f"OpenJDK{major}U-jdk_{ADOPTIUM_ARCH[arch]}_linux_hotspot_{token}.tar.gz"
    )


def adoptium_package(release_name: str, arch: str) -> dict[str, str]:
    """查 Adoptium API，返回某 release 某架构 Linux JDK 包的名字 / 直链 / 官方 sha256。

    用 release_name 端点而不是 assets/latest：latest 在两个架构上可能不是同一个
    构建（补丁或构建只发某一个架构时），配置钉死版本才不会让同一机群混版。
    """
    api_arch = ADOPTIUM_ARCH.get(arch)
    if not api_arch:
        raise SystemExit(f"adoptium: 不支持的架构 {arch}")
    release = quote(release_name, safe="")
    query = urlencode(
        {
            "architecture": api_arch,
            "image_type": "jdk",
            "os": "linux",
            "vendor": "eclipse",
        }
    )
    data = http_json(f"{ADOPTIUM_API}/v3/assets/release_name/eclipse/{release}?{query}")
    bins = data.get("binaries") if isinstance(data, dict) else None
    for binfo in bins or []:
        pkg = binfo.get("package") or {}
        if (
            binfo.get("os") == "linux"
            and binfo.get("image_type") == "jdk"
            and binfo.get("architecture") == api_arch
            and pkg.get("name")
            and pkg.get("link")
        ):
            return {
                "name": str(pkg["name"]),
                "link": str(pkg["link"]),
                "checksum": str(pkg.get("checksum") or ""),
            }
    raise SystemExit(f"adoptium: {release_name} {arch} 找不到 Linux JDK 包")


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


def parse_bare_hash(text: str) -> str:
    """解析裸哈希边车，兼容两种 Apache 风格：
    1. 单行连续哈希（Maven / Sonatype 的 .sha512/.sha256）；
    2. gpg --print-md 分组格式（RocketMQ：'filename: AB12 CD34 ...'，
       大写、按空格与换行分组、带文件名前缀）。
    统一归一化成连续小写 hex，交给 sha256sum/sha512sum 校验。
    """
    s = text.strip()
    if s.split(None, 1)[0].endswith(":"):
        s = s.split(":", 1)[1]
    return "".join(s.split()).lower()


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
    expected_hash = ""

    # 产物保持上游原名与原压缩类型：不解压、不剥离、不改名
    if comp.get("catalog") == "adoptium":
        # 离线先按命名规则推导；在线解析会替换成 API 返回的权威名字
        release = adoptium_release_name(comp)
        asset = adoptium_asset_name(release, version, arch)
    else:
        asset = (
            raw_assets.get(key) or default_name(name, key, version)
        ).format(version=version, tag=tag)
    local_name = asset
    url = ""

    if local:
        url = f"{local}/{asset}"
    elif not dry and comp.get("catalog") == "adoptium":
        pkg = adoptium_package(release, arch)
        asset = pkg["name"]
        url = pkg["link"]
        expected_hash = pkg["checksum"]
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
    elif not dry and comp.get("catalog") == "sonatype":
        # Sonatype CDN 直链稳定，版本钉死在 config.yaml，无需资产查询；
        # asset 已按架构从 assets 模板格式化（x86_64 / aarch_64）
        url = str(comp["url"]).format(version=version, tag=tag, asset=asset)
        ck0 = comp.get("checksums") or {}
        if ck0.get("url"):
            # 边车是裸 sha256（无文件名列），走 expected_hash 通道
            expected_hash = http_text(
                ck0["url"].format(version=version, tag=tag, asset=asset)
            ).strip().split()[0]
    elif comp.get("catalog") == "direct":
        # 固定 URL 直链（非 GitHub release：官方 CDN / dlcdn 等），不查任何 API。
        # urls 给下载地址、assets 给落 OSS 的产物名，两者可以不同名——
        # 例如 opentelemetry-javaagent 上游资产不带版本号，落 OSS 时补上。
        # dry-run 也回放 URL：纯模板拼接，不联网。
        raw_urls = comp.get("urls") or {}
        url = str(raw_urls.get(key) or "").format(version=version, tag=tag)
        if not url:
            raise SystemExit(f"{name} {version} {arch}: direct 组件缺少 urls.{key}")
        ck0 = comp.get("checksums") or {}
        if not local and not dry and ck0.get("bare") and ck0.get("url"):
            # 裸哈希边车：Maven 是单行 hex，RocketMQ 是 Apache 分组格式，统一归一化
            expected_hash = parse_bare_hash(
                http_text(ck0["url"].format(version=version, tag=tag))
            )
    elif not dry:
        url = (assets or {}).get(asset, "")
        if not url:
            raise SystemExit(f"{name} {version} {arch}: 上游资产里找不到 {asset}")

    checksums = ""
    algorithm = "sha256"
    ck = comp.get("checksums") or {}
    # sonatype / direct+bare 的边车是裸哈希，已在上面进 expected_hash；
    # 不再作为校验文件 URL 下发给 mirror.sh
    if ck.get("url") and not ck.get("bare") and comp.get("catalog") != "sonatype":
        checksums = ck["url"].format(version=version, tag=tag)
        algorithm = str(ck.get("algorithm") or "sha256")
    elif ck.get("bare") and ck.get("algorithm"):
        algorithm = str(ck["algorithm"])

    # direct 组件可用 source_assets 声明上游原名（下载与官方校验按它匹配），
    # asset 仍作 OSS 产物名；缺省回落到 asset，adoptium 在线改写 asset 不受影响
    source_assets = comp.get("source_assets") or {}
    source = (
        str(source_assets[key]).format(version=version, tag=tag)
        if key in source_assets
        else asset
    )

    return {
        "component": name,
        "version": version,
        "arch": "" if single else arch,
        "url": url,
        "filename": asset,
        "checksums": checksums,
        "algorithm": algorithm,
        # 普通组件：下载名即产物名；direct + source_assets 时两者不同
        "source": source,
        "transform": "",
        "strip": False,
        "expected_hash": expected_hash,
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

        # Adoptium（JDK）：资产元数据来自官方 API，不走 GitHub/grafana 资产表；
        # dry-run 与 --local 时 build_entry 内部按命名规则推导文件名，不联网
        if comp.get("catalog") == "adoptium":
            for arch in targets:
                files.append(
                    build_entry(name, comp, arch, None, [], local=args.local, dry=args.dry_run)
                )
            continue

        if args.dry_run:
            # dry-run 不查上游：url 留空，filename 按配置回放
            for arch in targets:
                files.append(build_entry(name, comp, arch, None, [], dry=True))
            continue

        if args.local:
            for arch in targets:
                files.append(build_entry(name, comp, arch, None, [], local=args.local))
            continue

        catalog = comp.get("catalog")
        if catalog == "grafana":
            key = ("grafana", str(comp["version"]))
        elif catalog == "sonatype":
            # 直链在 build_entry 里拼，没有可缓存的上游资产表
            key = ("sonatype", str(comp["version"]))
        elif catalog == "direct":
            # 固定 URL 直链，build_entry 里纯模板拼接，无任何上游查询
            key = ("direct", str(comp["version"]))
        else:
            # key 必须带 tag：同一 repo 可挂多个组件（如 rabbitmq 的 4.4 / 4.2 / 3.13
            # 三条维护主线），只按 repo 缓存会串用第一个 tag 的资产表
            key = ("gh", comp.get("repo"), str(comp.get("tag") or comp["version"]))
        if key not in cache:
            if key[0] == "grafana":
                cache[key] = {"packages": grafana_packages(str(comp["version"]))}
            elif key[0] in ("sonatype", "direct"):
                cache[key] = {}
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
                extra = f["transform"] or "rename"
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
