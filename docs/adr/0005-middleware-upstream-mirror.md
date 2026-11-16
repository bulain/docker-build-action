# 中间件上游发布件镜像（middleware 通道）

SILO（`pgsty/silo`）与 mcli（`pgsty/mc`）、RustFS 服务端与 CLI（`rustfs/rustfs`、`rustfs/cli`）、RabbitMQ（`rabbitmq/rabbitmq-server`）、Nacos（`alibaba/nacos`）都只通过 GitHub Releases 分发预编译产物，目标机在境外链路上下载不稳。本仓库为它们增加第四条通道，机制与 ADR 0004 的监控组件镜像完全一致：**下载、按官方校验文件验证后原样**放到 OSS，不编译、不分档位、不解压、不改名。

## 为什么不并入 monitoring 段

镜像驱动本身与组件语义无关，monitoring 通道的代码就是一个通用的「GitHub release 资产 → 校验 → OSS」搬运器。但把 RabbitMQ、Nacos、对象存储放进 `monitoring.components` 有三个实际问题：

- 全量入口 `monitoring.yml` 与 `scripts/monitoring.sh --all` 的爆炸半径被迫覆盖非监控组件，一次手动触发会镜像十几个不相干的东西；
- workflow 命名（`mirror monitoring (all)`）、Step Summary 标题、本地输出目录 `out/monitoring/` 全部名不副实；
- 后续通道差异化（例如中间件要加 GPG 签名校验）没有干净的落点。

因此选择**泛化驱动、新增段**，而不是把语义塞进旧段。

## 决定

- **驱动泛化为 `scripts/mirror.sh` + `scripts/mirror_resolve.py`，用 `--section` 选段**（默认 `monitoring`）。`scripts/monitoring.sh` 保留为薄 shim（`exec mirror.sh --section monitoring "$@"`），既有的十个监控组件 wrapper 与 workflow 零改动；新通道入口是 `scripts/middleware.sh`。resolver 的 TSV 增加第 7 列 `algorithm`，旧调用方不受影响。
- **配置落在 `config.yaml` 的 `middleware` 段**，schema 与 `monitoring` 相同：分架构组件给 `assets.amd64/arm64`，与架构无关的组件用 `single: true` + `assets.default`；每组件仍只允许一个版本，规则同 ADR 0004。
- **原样搬运、扁平放在 `linux/` 根下、OSS 已存在即跳过、仅手动 `workflow_dispatch`**——全部沿用 ADR 0004，不另立规则。
- **pgsty 的双版本身份**：release tag 是 `RELEASE.2026-11-12T00-00-00Z`，资产名里的包版本是紧凑串 `20261112000000.0.0`，两者无法互相推导。`version` 写包版本（资产模板用），`tag` 写 release tag（API 查询与校验文件 URL 用）；校验文件 URL 模板在 `{version}` 之外新增 `{tag}` 占位符。
- **RustFS 的两个命名坑**：服务端资产按 `x86_64/aarch64` 命名（本仓库统一用 `amd64/arm64`），靠显式 `assets` 模板消化，不引入全局架构别名；服务端发的是 zip，保持原压缩类型（alloy 已有先例）。服务端与 CLI 都同时提供 gnu / musl 变体，**统一选 gnu（glibc）**，与目标 EL 系统及自编译产物的 libc 环境一致，musl 变体不镜像。
- **RabbitMQ 无哈希校验文件**：generic-unix tar.xz 是 BEAM 字节码，`single: true` 一套覆盖双架构；GitHub release 只附 GPG `.asc` 签名、没有 sha256/md5 文件，走既有「告警 + 自算 sha256 侧车」路径（与 grafana 同等待遇）。运行期依赖目标机 Erlang，由本仓库 `packages.erlang` 自编译产物提供。
- **Nacos 只有 md5，扩展而不是绕过校验**：Nacos 是 Java 产物（`single: true`），上游只给 BSD 格式的 `.md5`（`MD5 (file) = <hash>`）。resolver 新增 `checksums.algorithm: md5`，驱动的 `verify_official` 用 `md5sum` 校验，awk 同时兼容 coreutils（`hash  name`）与 BSD 两种行格式；官方 md5 强校验照过，我们自己的 `.sha256` 侧车仍照常生成上传。
- **本地离线验证沿用 `--local`**：校验文件名不再硬编码 `SHA256SUMS`，改为取配置里校验文件 URL 的 basename，因此 `nacos-server-3.3.0.tar.gz.md5`、`sha256sums.txt` 等命名都能离线复现校验。

## MySQL：catalog 解析与 minimal 自制（首个转换型组件）

MySQL Community Server 不经 GitHub 分发，且需求与其他组件不同：目标环境统一消费 `-minimal` 包（ansible-deploy 的 `mysql_inplace_upgrade.sh` 按 `mysql-*-minimal.tar.*` 匹配），而上游只给 x86_64 的 8.4/9.7 提供官方 minimal，arm64 与 8.0 全是 full 包。因此 mysql 是本通道第一个「下载后还要转换」的组件。

- **目录页即 catalog**。`dev.mysql.com/downloads/mysql/<major_minor>.html?os=2`（os=2 = Linux Generic）的 HTML 表格内嵌每个资产的 MD5（`<code class="md5">`），没有独立校验文件。resolver 新增 `catalog: mysql`，抓页面正则解析「资产名 → MD5」，按大版本线缓存，每个页面只请求一次；下载走 `cdn.mysql.com//Downloads/MySQL-<mm>/<asset>` 稳定直链。注意站点前置 Akamai，自定义 UA 与浏览器 UA 都返回 403，只有 curl 风格 UA 放行，resolver 对该站点固定用 `curl/8.5.0`。
- **显式 `files` 清单取代 assets 模板**。一个组件横跨三个版本、两种包型、两种处理方式，模板表达不了。每条 `files` 元素显式写 `version / arch / source / filename / transform / strip`：`source` 是实际下载并接受官方 MD5 校验的上游资产，`filename` 是落 OSS 的产物名；无 `transform` 时二者同名、原样搬运。resolver TSV 增加 `source / transform / strip / expected_hash` 四列，普通组件填默认值（source=filename、transform 空、expected 空）。
- **minimal 规则与上游官方包逐项对齐**。转换脚本 `scripts/transforms/make_mysql_minimal.sh` vendor 自 ansible-deploy 同名脚本：解到隔离 mktemp 目录（不执行包内任何程序），删 `bin/mysqld-debug`、清空 `lib/plugin/debug/*.so` 并保留空目录条目，再按原压缩格式（xz 多线程）重打包，产物名在后缀前插入 `-minimal`。打包后做内容自检（debug 文件不得残留、空目录条目必须存在）。
- **arm64 与 8.0 额外做 ELF strip**。所有自制 minimal 都带 `--strip`：对包内 ELF 跑 `strip --strip-unneeded`，机器类型用 readelf 跨架构识别，AArch64 走 `aarch64-linux-gnu-strip`（CI 由 `_middleware.yml` 安装 `binutils-aarch64-linux-gnu`，本地可用 `~/.local/bin` 下的用户态工具或 `STRIP_BIN` 覆盖）。官方 minimal（8.4/9.7 x86_64）不重新打包，字节不变，MD5 直接对得上。
- **版本与档位选择**。镜像 8.0.46 / 8.4.13 LTS / 9.7.4 LTS 三个版本，全部选 glibc2.28 包——8.0.46 刻意不选 glibc2.17，避免同组件混档；el7 不在 MySQL 覆盖范围内。共 6 个产物（3 版本 × 2 架构），其中 2 个官方直拷、4 个自制。
- **校验边界**。官方 MD5 只校验下载源（full 或官方 minimal）；自制产物没有也不可能有上游哈希，沿用自算 sha256 侧车 + OSS 重跑比对的既有约定，Step Summary 的备注列标明「官方 MD5 校验源包后自制 minimal」。

## 触发

- 与 monitoring 通道一致：单组件 workflow（`silo.yml` 等六个）只跑该组件，可勾选 `force`；`middleware.yml` 跑全量（`scripts/middleware.sh --all`）。
- 全部入口仅手动 `workflow_dispatch`，不做定时任务：没有「探测最新版本」的输入，定时跑只会空转。

## 本地验证

- `scripts/middleware.sh --all --dry-run`：不联网回显十个待镜像文件（四组件 × 双架构 + 两个 single）。
- 去掉 `--dry-run` 后 resolver 会实查每个 repo+tag 的 release 资产，资产名对不上立即失败（本次准备阶段就靠它拦下了 `silo-` / `silo_` 连字符错误）。
- `scripts/<name>.sh --local <dir>` 不联网：从目录读取上游资产与同名官方校验文件，校验后原样写到 `out/middleware/packages/`，输出与输入逐字节相同。

## 相关

- `config.yaml` 的 `middleware` 段
- `scripts/mirror_resolve.py`（配置段 → 文件清单，查询上游资产；由 `monitoring_resolve.py` 泛化而来）
- `scripts/mirror.sh`（下载、校验、上传；由 `monitoring.sh` 泛化而来）
- `scripts/middleware.sh`、`scripts/monitoring.sh`（两个段的 shim 入口）
- `scripts/{silo,mcli,rustfs,rustfs-cli,rabbitmq-server,nacos-server,mysql}.sh`
- `scripts/transforms/make_mysql_minimal.sh`（MySQL full -> minimal 转换，含可选跨架构 strip）
- `.github/workflows/_middleware.yml`、`.github/workflows/middleware.yml` 与七个单组件入口
- ADR 0004（被本 ADR 泛化的前身，规则默认继承）
