# FydeOS for PC + KernelSU（iris / apu）

适用于 FydeOS for PC v23.0-SP1，包含 `iris` 与 `apu` 两个变体。内核版本为 `6.12.54-01180-gb4e10020ba49-dirty`，内置 KernelSU。

## 文档

| 内容 | 文档 |
|---|---|
| 安装与故障排查 | [USER-MANUAL.md](USER-MANUAL.md) |
| 源码构建 | [BUILD.md](BUILD.md) |
| 与官方镜像的差异 | [FIDELITY.md](FIDELITY.md) |
| 文件核验 | [快速核验](#快速核验) |

**你必须知道各个命令的意图，否则不仅 安装大概率失败 而且可能损失数据 **
## 验证状态

| 变体 | 硬件 | 状态 |
|---|---|---|
| `iris` | Intel | 已在真机启动并通过验证 |
| `apu` | AMD | 尚未完成真机验证 |

部署前应备份数据，确认命令用途并准备恢复介质。

## 文件清单

| 路径 | 用途 |
|---|---|
| `iris/`、`apu/` | 对应变体的 `vmlinuz.A` 和模块包 |
| `deploy.sh` | 部署内核与配套模块 |
| `verify.sh` | 部署后验证 |
| `build.sh` | 构建、配置和打包 |
| `MD5SUMS`、`SHA256SUMS` | 文件校验清单 |
| `config-iris.txt`、`config-apu.txt` | 交付产物的构建配置 |
| `config-official-iris.txt`、`config-official-apu.txt` | 官方配置基准 |
| `tools/inspect-artifact.py` | 离线产物核验 |
| `tools/config-diff.py` | 配置差异统计 |
| `tools/check-links.py` | 文档链接检查 |
| `tools/lint-shell.py` | 脚本静态检查 |
| `fixes/install-arc-race-fix.sh` | ARC 启动竞态修复的安装与卸载 |
| `fixes/arc-boot-continue-wait.sh` | 等待 ARC 属性服务就绪 |
| `fixes/install-metadata-fix.sh` | 旧内核临时修复的回滚工具 |
| `_verify/` | 产物与官方镜像的对比工具 |

## 快速核验

在仓库根目录执行：

```bash
python tools/inspect-artifact.py iris
python tools/inspect-artifact.py apu
md5sum -c MD5SUMS
sha256sum -c SHA256SUMS
```

| 文件 | 大小 / B | MD5 |
|---|---:|---|
| `iris/vmlinuz.A` | 13,456,384 | `7349572f53dd3c9f7b852a29816fb1dc` |
| `iris/modules-iris.tar.gz` | 33,369,701 | `f4a6760dc29f5aeb00eedeeb3c959e98` |
| `apu/vmlinuz.A` | 15,102,976 | `9ea04b3dce1de20feb0754fd962dc629` |
| `apu/modules-apu.tar.gz` | 41,597,536 | `a24ab5afa75555adec4e73d03e10e91e` |

## 已知限制

- `iris` 的 `CONFIG_PM_GENERIC_DOMAINS` 与官方不同，挂起影响尚未评估。
- `apu` 缺少两个 Intel Bay Trail 平台模块。
- 本项目与官方使用不同版本的 Clang，内核与模块包必须配套部署。
- KernelSU 需要另装 Zygisk 实现。本项目已验证 ZygiskNext 1.5.0 与 LSPosed v1.9.2，LSPosed v2.0.3 在测试设备上出现 `Unknown ISA` 崩溃。处理方法见 [用户手册](USER-MANUAL.md)第 10.4 节。
