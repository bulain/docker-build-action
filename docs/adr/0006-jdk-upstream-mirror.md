# JDK 上游发布件镜像（jdk 通道）

Adoptium Temurin 的 JDK tarball 通过官方站点 <https://adoptium.net/temurin/releases> 分发，目标机在境外链路上取包不稳。本仓库为它增加第五个通道，机制与 ADR 0004 / 0005 一致：**下载、校验后原样**放到 OSS，不编译、不解压、不改名。

## 为什么走 Adoptium API，而不是 GitHub release 资产表

- 官网是版本与资产的权威入口；页面本身是前端应用，数据来自 `api.adoptium.net`。resolver 直接查 API，拿到资产名、下载直链与官方 sha256，**一次请求解决三件事**，不需要再拼 GitHub 资产名或抓 `.sha256.txt`。
- JDK 的文件名同时带 `x64` / `aarch64`、`+` 号与构建号（`OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz`），用配置模板拼容易和服务端实际发布漂移；交给 API 返回最稳。
- 校验值直接取自 API 的 `package.checksum`，走驱动已有的 `expected_hash` 路径（与 MySQL 相同），不依赖 GitHub 下载校验文件。

因此新增 `catalog: adoptium`，而不是把 JDK 塞进 middleware 段或继续用 release 资产表。

## 决定

- **配置落在 `config.yaml` 的 `jdk` 段**，每组件写 `catalog: adoptium` 与完整 `version`（semver，如 `21.0.13+9`、`8.0.504+1`）。8 的 release 标识是 `jdk8u504-b01`，与 17+ 的 `jdk-<semver>` 不通用，额外写 `release_name`；缺省时由 `jdk-` + `version` 拼出。
- **版本必须两个架构都有**。Adoptium 的补丁/构建号可能只发某一个架构：查询时 `17.0.21.1+2` 只有 x64、`21.0.13.1+2` 只有 x64、8 的 latest 在 x64 是 `8u514b01` 而 aarch64 是 `8u512b09`。若按架构各取 latest，同一机群会混用不同构建；所以配置钉死两架构共有的版本。当前：Temurin 8 `8u504-b01`、17 `17.0.21+9`、21 `21.0.13+9`、25 `25.0.5+8`。
- **在线解析**：`GET /v3/assets/release_name/eclipse/{release_name}`，带 `architecture`（`x64` / `aarch64`）、`image_type=jdk`、`os=linux`、`vendor=eclipse`；取 `binaries` 里对应条目。
- **离线与 dry-run**：不联网，按 Adoptium 命名规则从 release 标识推导文件名：去掉 `jdk` 前缀，`+` 换 `_`、`-` 删掉（`jdk-21.0.13+9` → `21.0.13_9`，`jdk8u504-b01` → `8u504b01`）。用于预演清单与 `--local` 查找；在线跑时以 API 返回的名字为准。
- **原样搬运、扁平放在 `linux/` 根下、OSS 已存在即跳过、仅手动 `workflow_dispatch`**——全部沿用 ADR 0004。文件名带完整版本，升级版本即换新 key。
- **架构映射**：配置沿用本仓库的 `amd64` / `arm64`，仅在 API 查询与文件名推导时映射成 `x64` / `aarch64`。

## 触发与本地验证

- 单组件入口 `temurin8.yml` / `temurin17.yml` / `temurin21.yml` / `temurin25.yml`，全量入口 `temurin.yml`，均可勾选 `force`。
- 预演：`scripts/jdk.sh --all --dry-run` 只回显清单，不查上游、不联网。
- 本地验证：`scripts/temurin21.sh --local /home/bulain/ansible-deploy/files/linux` 不联网，从目录读取资产；目录里有同名 `.sha256.txt` 时校验，否则告警跳过。结果写到 `out/jdk/packages/`。

## 相关

- `config.yaml` 的 `jdk` 段
- `scripts/jdk.sh`（段入口）、`scripts/temurin8.sh` / `temurin17.sh` / `temurin21.sh` / `temurin25.sh`（组件入口）
- `scripts/mirror.sh`、`scripts/mirror_resolve.py`（共用驱动与解析器，后者含 `catalog: adoptium`）
- `.github/workflows/_jdk.yml`、`temurin.yml`、`temurin8.yml`、`temurin17.yml`、`temurin21.yml`、`temurin25.yml`
