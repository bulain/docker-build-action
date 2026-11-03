# 构建产物流水线

把 nginx、valkey 等 C 服务从官方源码编译成可在 el7–el10、amd64/aarch64 上直接运行的 tar.gz 产物，并发布到阿里云 OSS。

## Language

**目标 (Target)**:
一个「发行版档位 + CPU 架构」组合，例如 el8/amd64。
_Avoid_: 平台、环境

**档位 (Tier)**:
按系统年代划分的依赖选择类别：el7、el8、el9/el10（现代档）。
_Avoid_: 版本组

**产物 (Artifact)**:
一次成功构建输出的 tar.gz 及其 sha256 校验文件。
_Avoid_: 安装包（易被误读为 rpm）

**libc 标签**:
产物文件名中的 `glibcX.Y` 段，取自构建环境实际的 glibc 版本，决定产物可运行的最低发行版。
_Avoid_: 系统标签、OS 版本

**静态植入**:
把 openssl、pcre2、zlib、libxcrypt 编进二进制，产物不依赖目标机上的这些动态库。
_Avoid_: 静态链接（会与「整个二进制全静态」混淆）

**构建镜像**:
每个档位对应的容器基础镜像，编译发生在其中；镜像架构由 runner 决定。
_Avoid_: 编译机

**OSS 前缀**:
产物在 bucket 内的目录前缀，默认 `linux`，可配置。
_Avoid_: 路径

**开关**:
`config.yaml` 中每个软件的 `enabled` 字段，决定该软件是否进入构建矩阵。
_Avoid_: 启用状态
