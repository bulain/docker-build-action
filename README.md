# docker-build-action

从官方源码编译 nginx / OpenResty / valkey / redis / Erlang / PostgreSQL / HAProxy / Orchestrator，产出 el7–el10 × amd64/arm64 的 tar.gz；
同时把 Percona、监控类（Alertmanager、Grafana、Alloy、VictoriaMetrics / VictoriaLogs 等）、中间件类
（SILO / mcli、RustFS / RustFS CLI、RabbitMQ、Nacos）与 JDK 类（Adoptium Temurin 8 / 17 / 21 / 25）的上游发布件镜像到同一个 OSS。

## 工作方式

1. 在 Actions 页手动触发对应软件的 workflow（仅 `workflow_dispatch`，不再随 push 自动跑）。
2. 矩阵 job 用 `scripts/gen_matrix.py` 读配置，生成「档位 × 架构」组合。
3. 每个组合在目标发行版容器里编译（amd64 跑 `ubuntu-24.04`，arm64 跑 `ubuntu-24.04-arm`）。
4. 产物回收到宿主机，由宿主机上的 ossutil 上传。

产物命名：`{pkg}-{version}-linux-glibc{X.Y}-{arch}.tar.gz` + 同名 `.sha256`。
OSS 路径：`oss://{bucket}/{prefix}/{filename}`，默认前缀 `linux`。

tar 内不带 `data/` 这层（条目为 `<pkg>/...`），解压到 `/data`（`tar -xzf <file> -C /data`）即落到 `/data/<pkg>`。

## 一次性配置

1. 仓库 Secrets 加 `OSS_BUCKET`、`OSS_ENDPOINT`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`。
   `OSS_ENDPOINT` 必须是公网 endpoint（GitHub runner 在境外，内网 endpoint 不可达）。
   可选 `OSS_REGION`（如 `cn-hangzhou`）；不配则从 endpoint 推导，`oss-cn-hangzhou.aliyuncs.com` → `cn-hangzhou`。
2. 推送到 `main` 后手动跑一次 `build nginx` 验证全链路。

OSS 前缀不走 Secrets，仍在 `config.yaml` 的 `oss.prefix`。

## 开关与版本

- 软件开关：`packages.<pkg>.enabled`。`false` 时矩阵为空，workflow 直接绿过。
- 软件版本：`packages.<pkg>.version`；按档位覆盖用 `packages.<pkg>.versions.<os>`。
- 目标范围：`os` / `arches` 列表可收窄，例如 valkey 只做 el8 以上。
- 手动指定版本：`workflow_dispatch` 的 `version` 输入覆盖配置值。
- 覆盖 OSS 已有产物：手动触发时勾选 `force`；默认跳过已存在文件。

当前状态：全部软件关闭（`enabled: false`），需要时逐个开启。

erlang 当前版本 `27.3.4.19`。如需一次构建多个版本，可用 `version_matrix` 列出，矩阵会展开成「版本 × 档位 × 架构」。el7 的 OpenSSL 1.0.2 缺少 OTP crypto 需要的 1.1+ API，构建时会自编译 `vendor.openssl`（1.1.1w）共享库并装到 `/data/erlang` 下。

## 上游原件镜像（Percona）

Percona 官网下载慢，`scripts/upstream-percona.sh` 把 Percona Server / XtraBackup / Toolkit 的
二进制 tarball 原样搬到 OSS，目标机改从 OSS 取。与上面的编译流程无关，不打包、不改名、不分档位。

- 配置：`config.yaml` 的 `upstream` 段；每个组件写**完整版本串**（含构建号，`9.7.2-2` 这种，无法从大版本推断）。
- 当前镜像：percona-server 8.4.10-10 / 9.7.2-3，percona-xtrabackup 8.4.0-7 / 9.7.2-2，percona-toolkit 3.7.0；
  x86_64 minimal，glibc 2.28 / 2.34，xtrabackup 另有 2.39。
- 触发：仅手动 `workflow_dispatch`；单组件入口（percona-server / percona-xtrabackup / percona-toolkit）可指定 `version` / `force`，全量入口 `upstream-percona.yml` 只支持 `force`。
- OSS 路径：`oss://{bucket}/linux/{原始文件名}` + 同名 `.sha256`。
- 校验：Percona 不提供校验文件，`.sha256` 由脚本首次下载后自算（非官方值），重跑时与远端比对、不一致则告警。
- 本地跑：`OSS_BUCKET=... OSS_ENDPOINT=... scripts/upstream-percona.sh --dry-run`（预演），
  去掉 `--dry-run` 前需 `ossutil` 可用且凭证就绪（环境变量或 `~/.ossutilconfig`）。

决策与取舍见 `docs/adr/0003-upstream-binary-mirror.md`。

## 监控组件镜像

Alertmanager、alertmanager-webhook-adapter、Alloy、Grafana、VictoriaMetrics / VictoriaLogs 及其工具集（vmutils / vlutils）、
两个 Grafana 数据源插件同样只从 GitHub / grafana.com 分发。这些组件走第二条镜像通道：下载上游发布件 → 按官方校验文件验证 → 原样上传 OSS
（保持上游文件名与压缩类型，不解压、不剥离、不改名）。

- 配置：`config.yaml` 的 `monitoring` 段，每个组件在 `components` 下一条；入口脚本为 `scripts/<name>.sh`。
- 触发：全部仅手动 `workflow_dispatch`；单组件 workflow 只跑该组件，`monitoring.yml` 全量重跑，均可勾选 `force`。
- OSS 路径：`oss://{bucket}/{prefix}/{filename}` + 同名 `.sha256`；默认前缀 `linux`，与自编译产物、Percona 原件同层。
- 校验：下载原件后按上游 `SHA256SUMS`（或 grafana.com API 给出的 sha256）校验，不通过即失败。
- 本地验证：`scripts/<name>.sh --local <dir>` 从目录读取上游资产，结果写到 `out/monitoring/packages/`，不联网、不上传。

决策与取舍见 `docs/adr/0004-monitoring-upstream-mirror.md`。

## 中间件镜像

SILO / mcli（pgsty 的 MinIO 发行线）、RustFS 服务端 / RustFS CLI、RabbitMQ、Nacos、MySQL、Nexus 同样只从上游站点分发。
这些组件走第四个通道（继 packages / upstream / monitoring 之后），机制与监控组件共用同一套驱动
（按 config.yaml 的段区分）：下载上游发布件 → 按官方哈希校验 → 上传 OSS。
GitHub 系组件保持上游文件名与压缩类型原样搬运；MySQL 是例外，产物统一为自制/官方 minimal 包。

- 配置：`config.yaml` 的 `middleware` 段，每个组件在 `components` 下一条；入口脚本为 `scripts/<name>.sh`。
- 当前镜像：silo / mcli `20261112000000.0.0`，rustfs `1.0.6`（gnu zip），rustfs-cli `0.1.37`（gnu tar.gz），
  rabbitmq-server `4.4.0`（generic-unix，单包），nacos-server `3.3.0`（单包），
  mysql `8.0.46 / 8.4.13 / 9.7.4`（均 glibc2.28，3 版本 × 2 架构共 6 个 minimal 包），
  nexus `3.77.1-01`（Sonatype NXRM unix tarball，Java 单包不分架构）。
- MySQL 特殊处理：MD5 内嵌在 dev.mysql.com 下载页（无独立校验文件），resolver 抓页面解析；
  x86_64 的 8.4/9.7 直接用上游官方 minimal，其余 4 个 full 包由 `scripts/transforms/make_mysql_minimal.sh`
  自制（删 `mysqld-debug` 与 debug 插件，保留空目录，并对 ELF `--strip-unneeded`，arm64 用交叉 strip）。
- 校验：silo / mcli / rustfs / rustfs-cli 按上游 sha256 校验文件强校验；nacos 上游只发 BSD 格式 md5，
  驱动按 `algorithm: md5` 走 md5sum 强校验；MySQL 按下载页 MD5 校验源包；nexus 的 Sonatype CDN
  同名 `.sha256` 边车只有裸哈希，resolver 取出后按 expected_hash 强校验；rabbitmq 的 GitHub release
  只有 GPG 签名、无哈希文件，告警后自算 sha256。自制 minimal 产物统一只附自算 sha256 侧车。
- 触发：全部仅手动 `workflow_dispatch`；单组件 workflow 只跑该组件，`middleware.yml` 全量重跑，均可勾选 `force`。
- OSS 路径：`oss://{bucket}/{prefix}/{filename}` + 同名 `.sha256`；默认前缀 `linux`，与其他通道同层。
- 本地验证：`scripts/<name>.sh --local <dir>` 从目录读取上游资产与同名官方校验文件，
  结果写到 `out/middleware/packages/`，不联网、不上传。

决策与取舍见 `docs/adr/0005-middleware-upstream-mirror.md`。

## JDK 镜像

Adoptium Temurin 的 JDK tarball 从官方站点 <https://adoptium.net/temurin/releases> 分发；脚本走其
`api.adoptium.net` 元数据接口，不依赖 GitHub release 资产名。Temurin 8 / 17 / 21 / 25 走第五个通道，
与监控、中间件共用同一套驱动：按官方元数据下载 → 用 API 给出的 sha256 校验 → 原样上传 OSS。

- 配置：`config.yaml` 的 `jdk` 段，每组件 `catalog: adoptium` + 完整版本（如 `21.0.13+9`）；
  8 的 release 标识不通用，额外写 `release_name: jdk8u504-b01`。
- 当前镜像：temurin8 `8.0.504+1`（`8u504b01`）、temurin17 `17.0.21+9`、temurin21 `21.0.13+9`、
  temurin25 `25.0.5+8`，各 x64 / aarch64。
  Adoptium 的补丁版可能只发 x64，配置取两架构共有的版本，避免同一机群混用不同构建。
- 文件名由 API 决定（`OpenJDK<major>U-jdk_<x64|aarch64>_linux_hotspot_<ver>.tar.gz`）；
  checksum 取自 API 的 `package.checksum`，OSS 侧仍附同名 `.sha256`。
- 触发：单组件入口 `temurin8.yml` / `temurin17.yml` / `temurin21.yml` / `temurin25.yml`，
  全量入口 `temurin.yml`，均可勾选 `force`。
- OSS 路径：`oss://{bucket}/{prefix}/{filename}` + 同名 `.sha256`；默认前缀 `linux`。
- 本地验证：`scripts/temurin21.sh --local /home/bulain/ansible-deploy/files/linux`，
  不联网，结果写到 `out/jdk/packages/`。

决策与取舍见 `docs/adr/0006-jdk-upstream-mirror.md`。

## 目录

```
config.yaml                    唯一配置源
scripts/common.sh              源配置、下载校验、静态植入校验、打包
scripts/nginx.sh               nginx 构建（自带 openssl/pcre2/zlib/libxcrypt）
scripts/openresty.sh           OpenResty 构建（同样静态植入）
scripts/valkey.sh              valkey 构建
scripts/redis.sh               redis 构建
scripts/erlang.sh              Erlang/OTP 构建
scripts/postgresql.sh          PostgreSQL 构建（含 contrib）
scripts/haproxy.sh             HAProxy 构建（同样静态植入四库）
scripts/orchestrator.sh        Orchestrator 构建（Go + cgo/vendored sqlite）
scripts/upstream-percona.sh    Percona 原件镜像同步（下载 -> 校验 -> OSS）
scripts/upstream_resolve.py    upstream 段 -> 待镜像文件清单
scripts/mirror.sh              上游发布件镜像通用驱动（下载 -> 校验 -> 上传，--section 选段）
scripts/mirror_resolve.py      monitoring/middleware/jdk 段 -> 待镜像清单（含上游资产查询）
scripts/monitoring.sh          监控段 shim 入口（-> mirror.sh --section monitoring）
scripts/middleware.sh          中间件段 shim 入口（-> mirror.sh --section middleware）
scripts/jdk.sh                 JDK 段 shim 入口（-> mirror.sh --section jdk）
scripts/temurin21.sh           Temurin 21 组件入口（另 temurin8.sh / temurin17.sh / temurin25.sh）
scripts/alertmanager.sh        监控组件入口（另有 alertmanager-webhook-adapter / alloy /
                               grafana / victoria-logs / victoria-metrics / vmutils /
                               vlutils / victoriametrics-logs-datasource /
                               victoriametrics-metrics-datasource）
scripts/silo.sh                中间件组件入口（另有 mcli / rustfs / rustfs-cli /
                               rabbitmq-server / nacos-server / mysql / nexus）
scripts/transforms/            下载后转换脚本（make_mysql_minimal.sh：full -> minimal + strip）
scripts/gen_matrix.py          config.yaml -> Actions matrix
.github/workflows/_build.yml   可复用工作流（矩阵 -> 容器编译 -> OSS）
.github/workflows/nginx.yml    nginx 手动入口
.github/workflows/openresty.yml OpenResty 手动入口
.github/workflows/valkey.yml   valkey 手动入口
.github/workflows/redis.yml    redis 手动入口
.github/workflows/erlang.yml   erlang 手动入口
.github/workflows/postgresql.yml PostgreSQL 手动入口
.github/workflows/haproxy.yml  HAProxy 手动入口
.github/workflows/orchestrator.yml Orchestrator 手动入口
.github/workflows/_upstream-percona.yml Percona 原件镜像可复用工作流
.github/workflows/percona-{server,xtrabackup,toolkit}.yml Percona 单组件镜像入口
.github/workflows/upstream-percona.yml Percona 全量镜像入口
.github/workflows/_monitoring.yml      监控组件镜像可复用工作流
.github/workflows/<component>.yml      监控组件镜像入口（10 个）
.github/workflows/monitoring.yml       监控组件全量镜像入口
.github/workflows/_middleware.yml      中间件镜像可复用工作流（含 MySQL 交叉 strip 工具链）
.github/workflows/<component>.yml      中间件镜像入口（silo / mcli / rustfs /
                                       rustfs-cli / rabbitmq-server / nacos-server / mysql / nexus）
.github/workflows/middleware.yml       中间件全量镜像入口
.github/workflows/_jdk.yml             JDK 镜像可复用工作流
.github/workflows/temurin.yml          JDK 全量镜像入口（temurin8/17/21/25.yml 为单组件入口）
GLOSSARY.md                    术语
docs/adr/                      关键决策记录
```

## 校验步骤（容器内）

- 下载校验：配置了 `sha256` 的源码包必检；未配置时告警后继续。
- 静态植入：`readelf -d` 的 NEEDED 中不得出现 libssl/libcrypto/libpcre2/libz/libcrypt。
- 冒烟：`nginx -V` / `valkey-server --version`。
- 打包后生成 sha256，随产物一起上传。

## 已知限制

- el7 源已下线，构建时重写为 vault；`centos:7` 为官方多架构镜像（amd64 + arm64/v8）。若 runner 访问 vault 受限，改 `targets.el7.vault_base` 为镜像站。
- `--with-http_v3_module` 需要具备 QUIC API 的 OpenSSL，故只在 el9/el10（openssl 3.5.9）启用；el7/el8 的 openssl 版本不满足。
- valkey / redis 仅 7.2 能在 el7 的 gcc 4.8.5 上编译；8+ 需要 gcc ≥ 4.9。
- PostgreSQL 链接系统动态库（openssl / readline / zlib / libicu / systemd），不做静态植入；
  目标机需已安装对应 runtime 库。el7 的 gcc 4.8.5 可以编译 17.x。
- HAProxy 在 el8 及以上启用 QUIC（`USE_QUIC_OPENSSL_COMPAT`）；el7 的 OpenSSL 1.1.1w 不满足，关闭。
  el7 还需显式 `USE_KTLS=`：`TARGET=linux-glibc` 默认开 KTLS，而 3.10 内核头文件没有 `linux/tls.h`。
- HAProxy el7 只做 amd64：gcc 4.8.5 在 aarch64 上编译原子操作会 ICE。用 `arches_by_os.<os>` 可按档位收窄架构。
- Orchestrator 用 `packages.<pkg>.go` 指定 Go SDK（按架构校验 sha256），源码包自带 vendor，
  构建不联网；cgo 依赖 gcc，产物动态依赖 glibc。
- ossutil 固定 2.4.0，双架构、静态链接，可在宿主机直接运行。

## License

MIT，见 [LICENSE](LICENSE)。
