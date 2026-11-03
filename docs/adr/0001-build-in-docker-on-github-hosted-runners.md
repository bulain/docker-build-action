# 在 GitHub 托管 runner 上用 Docker 完成编译

每个「档位 + 架构」目标都用一个对应的发行版容器作为编译环境，容器跑在原生架构的 GitHub 托管 runner 上（amd64 用 `ubuntu-24.04`，arm64 用 `ubuntu-24.04-arm`），而不是在宿主机直接装工具链，也不用 QEMU 交叉/模拟编译。

这样做的原因：产物必须与目标系统的 glibc 和 rpm 生态匹配，容器是唯一能在一台 runner 上同时提供 el7–el10 四套环境的轻量手段；原生 arm64 runner 让 arm64 构建与 amd64 同等速度，避免 QEMU 下 autoconf 探测与长时间模拟带来的不确定性。

代价：每个目标都要拉取基础镜像，构建逻辑必须写成容器内可执行的 shell；镜像 tag 成为需要维护的配置项。

## Considered Options

- 自托管构建机：环境可控但要长期维护四套系统、两种架构，且与 GitHub Actions 触发链耦合更深。
- 单 amd64 runner + QEMU：省 runner 成本，但 arm64 构建慢数倍，且模拟环境下部分 configure 探测不可靠。
