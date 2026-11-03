# docker-build-action

从官方源码编译 nginx / OpenResty / valkey / redis / Erlang / PostgreSQL / HAProxy / Orchestrator，产出 el7–el10 × amd64/arm64 的 tar.gz，上传阿里云 OSS。

## 工作方式

1. push 修改 `config.yaml` 或对应 `scripts/<pkg>.sh` → 触发该软件的 workflow。
2. 矩阵 job 用 `scripts/gen_matrix.py` 读配置，生成「档位 × 架构」组合。
3. 每个组合在目标发行版容器里编译（amd64 跑 `ubuntu-24.04`，arm64 跑 `ubuntu-24.04-arm`）。
4. 产物回收到宿主机，由宿主机上的 ossutil 上传。

产物命名：`{pkg}-{version}-linux-glibc{X.Y}-{arch}.tar.gz` + 同名 `.sha256`。
OSS 路径：`oss://{bucket}/{prefix}/{filename}`，默认前缀 `linux`。

tar 内保留绝对路径结构（`data/nginx/...`），解压到 `/` 即落到 `/data/nginx`。

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
scripts/gen_matrix.py          config.yaml -> Actions matrix
.github/workflows/_build.yml   可复用工作流（矩阵 -> 容器编译 -> OSS）
.github/workflows/nginx.yml    nginx 触发入口
.github/workflows/openresty.yml OpenResty 触发入口
.github/workflows/valkey.yml   valkey 触发入口
.github/workflows/redis.yml    redis 触发入口
.github/workflows/erlang.yml   erlang 触发入口
.github/workflows/postgresql.yml PostgreSQL 触发入口
.github/workflows/haproxy.yml  HAProxy 触发入口
.github/workflows/orchestrator.yml Orchestrator 触发入口
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
