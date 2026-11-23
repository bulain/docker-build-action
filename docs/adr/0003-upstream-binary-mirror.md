# 上游二进制原件镜像

Percona 官网（`downloads.percona.com`）带宽差，目标机直接下载 Percona Server / XtraBackup / Toolkit 的二进制 tarball 动辄耗掉整个装机窗口。本仓库因此额外维护一条「原件镜像」通道：把 Percona 发布的 tarball **原样**搬到 OSS，`upstream.components` 声明要镜像哪些文件。

与 `packages` 的关键差别：

| | `packages` | `upstream` |
|---|---|---|
| 内容 | 我们编译的产物 | 上游发布的原件 |
| 命名 | `{pkg}-{ver}-linux-glibc{X.Y}-{arch}.tar.gz` | 上游原始文件名 |
| 打包 | 剥离 `data/` 层（条目 `<pkg>/...`，解压到 `/data`） | 不重打包 |
| 校验 | 源码 sha256 必检 | 上游无校验文件，首次下载自算 |
| 维度 | 档位(el7–el10) × 架构 | 上游 glibc 档 × 版本 |

## 决定

- **扁平放在 `linux/` 根下，保留原始文件名**（延伸 ADR 0002）。文件名自带 `Percona-` / `percona-xtrabackup-` 前缀与 `glibc2.x` 标识，不会与自编译产物混淆，也就没必要多一层目录。代价与 0002 相同：目录里两类文件混放，只能靠前缀搜索区分。
- **不重打包**。上游给的是 `*.tar.gz`，再压一层会改变哈希，失去「与官网字节一致」的意义，也会让人误以为是自编译产物。
- **只镜像 x86_64 minimal**。Percona 的 Linux 通用 tarball 没有 aarch64 构建（实测全 404），完整版单份 1.5 GB（minimal 约 170 MB），生产用不上调试符号与测试套件。
- **glibc 档位按上游实际发布取，不照搬 RHEL**。el8=2.28、el9=2.34、el10=2.39(xb)；2.35 只服务 Ubuntu 22.04，不在目标范围；el7(2.17) 上游已不发布，走官方 RPM。
- **哈希自算**。Percona 不提供独立的 `.sha256`（请求会 302 回下载落地页），因此首次下载后计算 sha256、随文件上传为同名 `.sha256`，重跑时与远端记录比对、不一致则告警。**这个值不是官方校验值**，只能证明「我们首次拿到的是什么」，不能证明上游未被篡改。
- **按组件 × 完整版本串声明**。构建号无法从大版本推断（PS `9.7.2-3` 对应 XtraBackup `9.7.2-2`），所以版本必须写全；`workflow_dispatch` 的 `version` 输入也只接受完整串，不猜构建号。

> 更新（2026-11）：新增 `percona-xtrabackup-8.0` 组件，镜像 8.0 维护线 `8.0.35-31`。
> 上文「el7(2.17) 上游已不发布」只对 8.4 / 9.x 新线成立；8.0 线的 tarball 仍发
> glibc 2.17 / 2.28 / 2.34 三档（覆盖 el7–el9），这正是保留该线的理由。组件用显式
> `tiers` 接管档位，不继承全局 2.28/2.34 与 2.39 extra（2.39 在 8.0 线不存在）。
> 注意 8.0.35 的 tarball 只发到构建号 -31；-32 至 -36 只有 RPM 重建，无 tarball。
> 组件按维护主线拆分（与 ADR 0005 的 rabbitmq 多线同思路），OSS 文件名自带完整版本，
> 与 percona-xtrabackup 的 8.4/9.x 产物共存不冲突。

## 触发

- 全部仅手动 `workflow_dispatch`，OSS 已存在的文件跳过。
- 拆成四个单组件入口 `percona-server.yml` / `percona-xtrabackup.yml` / `percona-xtrabackup-8.0.yml` / `percona-toolkit.yml`，固定 `--component`，可带 `version` 覆盖与 `force`；公共逻辑在可复用工作流 `_upstream-percona.yml`。
- `upstream-percona.yml` 为全量入口，不带组件筛选，只支持 `force`。

不做定时任务：没有「探测最新版本」的输入，定时跑只会空转。

## 相关

- `config.yaml` 的 `upstream` 段
- `scripts/upstream_resolve.py`（配置 → 文件清单）
- `scripts/upstream-percona.sh`（下载、校验、上传）
- `.github/workflows/_upstream-percona.yml`（可复用工作流）与各入口 workflow
