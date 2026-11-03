#!/usr/bin/env python3
"""把 config.yaml 解析成 GitHub Actions 构建矩阵。

输出一段 JSON：{"matrix": {"include": [...]}, "count": N}
count 为 0 表示该软件被 enabled 关闭或没有目标。
"""
from __future__ import annotations

import argparse
import json
import sys

import yaml


def pick(value, os_name, default_key="default"):
    """取值：优先匹配具体档位，其次 default；非字典原样返回。"""
    if not isinstance(value, dict):
        return value
    if os_name in value:
        return value[os_name]
    return value.get(default_key)


def fill(template: str, version: str) -> str:
    return template.format(version=version)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--version", default="", help="覆盖 config 中的版本")
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)

    pkg = cfg["packages"][args.package]
    if not pkg.get("enabled", False):
        print(json.dumps({"matrix": {"include": []}, "count": 0}))
        return 0

    architectures = cfg["architectures"]
    vendor = cfg["vendor"]
    oss = cfg.get("oss", {})

    entries = []
    for os_name in pkg.get("os", []):
        target = cfg["targets"][os_name]

        # 版本来源优先级：--version 覆盖 > 多版本列表 > 按档位覆盖 > 默认版本
        if args.version:
            versions = [args.version]
        elif pkg.get("version_matrix"):
            versions = [str(v) for v in pkg["version_matrix"]]
        else:
            versions = [pick(pkg.get("versions"), os_name) or pkg["version"]]

        openssl_version = pick(vendor["openssl"]["versions"], os_name)
        openssl_url_tpl = pick(vendor["openssl"].get("urls", {}), os_name) or vendor["openssl"]["url"]
        pcre2_version = pick(vendor["pcre2"]["versions"], os_name)
        zlib = pick(vendor["zlib"], os_name)
        libxcrypt_version = pick(vendor["libxcrypt"]["versions"], os_name)
        libxcrypt_url_tpl = (
            pick(vendor["libxcrypt"].get("urls", {}), os_name) or vendor["libxcrypt"]["url"]
        )

        for version in versions:
            # sha256 支持三种写法：单个字符串、按版本映射、按档位映射
            sha_raw = pkg.get("sha256", "")
            if isinstance(sha_raw, dict):
                sha256 = sha_raw.get(version) or sha_raw.get(os_name) or sha_raw.get("default", "")
            else:
                sha256 = sha_raw or ""

            for arch in pkg.get("arches", list(architectures)):
                arch_cfg = architectures[arch]
                entries.append(
                    {
                        # 键名会被 workflow 直接转成大写环境变量，故统一用 env 风格小写
                        "pkg": args.package,
                        "target_os": os_name,
                        "target_arch": arch,
                        "arch": arch,
                        "arch_name": arch_cfg["arch_name"],
                        "runner": arch_cfg["runner"],
                        "platform": arch_cfg["platform"],
                        "image": target["images"][arch],
                        "el7_vault_base": target.get("vault_base", ""),
                        "pkg_version": version,
                        "source_url": fill(pkg["source_url"], version),
                        "source_dir_name": fill(pkg["source_dir"], version),
                        "source_sha256": sha256,
                        "install_prefix": pkg["install_prefix"],
                        "build_source_dir": cfg.get("build", {}).get("source_dir", "/data/src"),
                        "output_dir": cfg.get("build", {}).get("output_dir", "/data/files"),
                        "nginx_configure_args": pick(pkg.get("configure_args", ""), os_name) or "",
                        "pkg_make_args": pick(pkg.get("make_args", ""), os_name) or "",
                        "vendor_openssl": openssl_version,
                        "vendor_openssl_url": fill(openssl_url_tpl, openssl_version),
                        "vendor_pcre2": pcre2_version,
                        "vendor_pcre2_url": fill(vendor["pcre2"]["url"], pcre2_version),
                        "vendor_zlib_package": zlib["package"],
                        "vendor_zlib_version": zlib["version"],
                        "vendor_zlib_url": fill(zlib["url"], zlib["version"]),
                        "vendor_zlib_dir": fill(zlib["dir"], zlib["version"]),
                        "vendor_libxcrypt": libxcrypt_version,
                        "vendor_libxcrypt_url": fill(libxcrypt_url_tpl, libxcrypt_version),
                        "oss_prefix": oss.get("prefix", ""),
                    }
                )

    print(json.dumps({"matrix": {"include": entries}, "count": len(entries)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
