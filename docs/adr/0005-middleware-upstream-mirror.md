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
- `scripts/{silo,mcli,rustfs,rustfs-cli,rabbitmq-server,nacos-server}.sh`
- `.github/workflows/_middleware.yml`、`.github/workflows/middleware.yml` 与六个单组件入口
- ADR 0004（被本 ADR 泛化的前身，规则默认继承）
