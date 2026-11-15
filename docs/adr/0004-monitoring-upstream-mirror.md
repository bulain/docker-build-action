# 监控组件上游发布件镜像

Alertmanager、Grafana、Alloy、VictoriaMetrics / VictoriaLogs（含工具集与 Grafana 数据源插件）都只从 GitHub Releases 或 grafana.com 分发，目标机在境外链路上下载不稳、速度慢。本仓库为它们增加第三条通道：把上游发布件**下载、按官方校验文件验证后原样**放到 OSS。

三条通道的分工：

| | `packages` | `upstream` (Percona) | `monitoring` |
|---|---|---|---|
| 内容 | 我们编译的产物 | 上游原件，字节不变 | 上游发布件，字节不变 |
| 命名 | `{pkg}-{ver}-linux-glibc{X.Y}-{arch}.tar.gz` | 上游原始文件名 | 上游原始文件名 |
| 维度 | 档位 × 架构 | 上游 glibc 档 | 架构（Go 静态二进制，不分档位） |
| 校验 | 源码 sha256 必检 | 上游无校验文件，自算 | 官方 `SHA256SUMS` / grafana.com API 给出的 sha256 |

## 决定

- **分架构，不分档位**。这些产物是 Go 编译的静态二进制（grafana 是前端 + 少量 C 库，官方 tar.gz 同样跨发行版可用），一套 Linux 文件覆盖 el7–el10 与 Ubuntu。`monitoring.architectures` 默认 `[amd64, arm64]`；Grafana 数据源插件只有一份 zip，用 `single: true` 标注。
- **一组件一脚本一 workflow**。与 `packages` 的约定一致，`scripts/<name>.sh` 是入口；共用逻辑在 `scripts/monitoring.sh`，配置解析在 `scripts/monitoring_resolve.py`，后者顺带查上游资产列表，每个 repo+tag 只查一次；请求带 `GITHUB_TOKEN`，否则匿名配额（60 次/小时）不够用。
- **官方校验必过**。每个组件声明 `checksums.url`，下载原件后按上游记录的 sha256 校验，不过就失败；`--skip-checksums` 只用于上游临时缺校验文件的排查。Grafana 走 grafana.com 的版本 API：同一份 API 响应同时给出包地址与 sha256，下载后按它校验。上游发布件若被重新打包，校验会失败，此时需要人工确认后升级版本。
- **原样搬运，不解压不改名**。OSS 上的 key 就是上游资产名（`vmutils-linux-amd64-v1.156.0.tar.gz`、`alloy-linux-amd64.zip`、`victoriametrics-logs-datasource-v0.34.0.zip`，adapter 的资产本来没有扩展名就保持没有）。与参考目录 `ansible-deploy/files/linux` 的组织方式一致，目标机按需自行选择解压方式；zip 不必再转 tar.gz，也不需要 binutils。
- **扁平放在 `linux/` 根下**（延伸 ADR 0002 / 0003）。文件名自带组件名与版本，可与自编译产物、Percona 原件共存，靠前缀区分。
- **Grafana 的包清单只用来确认版本/架构存在，不直接采用其 URL**。13.x 起 grafana.com API 返回的文件名带构建号并改用下划线（`grafana_13.3.1_<build>_linux_amd64.tar.gz`），会随每次构建变化；实际下载走稳定规范地址 `https://dl.grafana.com/oss/release/grafana-<version>.linux-<arch>.tar.gz`，OSS key 保持规范名。两个地址指向同一份上游产物。
- **OSS 已存在即跳过**。产物名带版本，同一版本不重传；需要重传时手动触发并勾选 `force`。哈希与 OSS 记录不一致时告警，便于发现上游重打包。
- **版本只允许一个**。公用的扫描目录按组件名前缀与版本过滤，多版本会让「已存在即跳过」失去意义；要保留多个版本时，把旧产物改名归档后再升级配置。
- **仓库归属的两个坑**：原 `catatnight/alertmanager-webhook-adapter` 已不存在，改用 `bougou/alertmanager-webhook-adapter`；Grafana 插件在 `VictoriaMetrics/victorialogs-datasource` 与 `VictoriaMetrics/victoriametrics-datasource`（metrics 插件自 v0.12 起换了插件 ID，仓库名未变）。
- **tag 与版本号不同名时用 `tag` 显式声明**。prometheus 系（alertmanager）release tag 带 `v` 前缀而资产名不带，`version` 必须保持无 `v` 才能拼出正确资产名，tag 查询走单独的 `tag` 字段；缺省回落到 `version`。

## 触发

- push 到 `config.yaml`、`scripts/monitoring.sh`、`scripts/monitoring_resolve.py`、`scripts/<name>.sh` 或对应 workflow → 对应组件的 workflow 触发，其余组件保持不动。
- `monitoring.yml` 手动触发 → 全量（`scripts/monitoring.sh --all`）。
- 各组件 workflow 手动触发 → 只跑该组件，可勾选 `force`。

与 ADR 0003 一样不做定时任务：没有「探测最新版本」的输入，定时跑只会空转。

## 本地验证

`scripts/<name>.sh --local <dir>` 不联网：从目录读取上游资产，做官方校验（此处没有校验文件则跳过），原样写到 `out/monitoring/packages/`。写出的文件应当与输入逐字节相同，可用于在上传前确认资产名是否仍然匹配。

## 相关

- `config.yaml` 的 `monitoring` 段
- `scripts/monitoring_resolve.py`（配置 → 文件清单，查询上游资产）
- `scripts/monitoring.sh`（下载、校验、上传）
- `scripts/<name>.sh`（十个组件入口）
- `.github/workflows/_monitoring.yml`、`.github/workflows/monitoring.yml`