# 与官方镜像的差异（iris / apu）

记录本项目产物相对对应 FydeOS 官方镜像的差异，以及已知影响。

## 内核配置与构建

| 差异 | iris | apu | 影响 |
|---|---|---|---|
| KernelSU | 本项目内置 `CONFIG_KSU` 与 syscall dispatcher 补丁；官方没有 | 同左 | 本项目的主要改动；`CONFIG_KPROBES` 等为其依赖 |
| 配置符号差异数 | 218（仅本项目 81、仅官方 15、取值不同 122） | 627（仅本项目 178、仅官方 254、取值不同 195） | 官方独有且启用的符号分别为 11、32；其余主要是配置文件对“未设置”符号的记录方式不同 |
| `CONFIG_PM_GENERIC_DOMAINS` | 本项目未设，官方为 `y` | — | 可能影响电源域及挂起/唤醒行为，尚未评估 |
| `CONFIG_SPI_INTEL` | 本项目未设，官方为 `y` | — | Intel SPI 闪存控制器支持不同 |
| `CONFIG_DRM_FBDEV_EMULATION` | 本项目为 `y`，官方为 `n` | 同左 | 本项目会启用 framebuffer 辅助功能并多出相关模块 |
| `CONFIG_HPET_MMAP_DEFAULT` | 官方为 `y`，本项目未设 | 同左 | 影响很小 |
| `CONFIG_EFI_MIXED` | — | 本项目为 `y`，官方为 `n` | apu 多出 PE `.compat` 节，提供 32 位 EFI 入口；不影响目标 64 位 EFI 启动 |
| `CONFIG_LSM` | — | 官方额外启用 `yama` | 可选 LSM 差异 |
| 编译工具链 | 本项目使用 Android clang 19；官方使用 Chromium OS clang 21 | 同左 | 工具链版本不同；内核与随包模块由同一套构建产出 |
| 工具版本记录 | 官方 `PAHOLE_VERSION=127`，本项目为 125 | 同左 | 构建工具版本不同 |
| `CONFIG_LOCALVERSION_AUTO` | 本项目关闭，官方开启 | 同左 | 本项目手工指定版本串，最终版本串相同 |

## 模块包

| 变体 | 数量差异 | 具体差异 |
|---|---|---|
| iris | 本项目 1190 个，官方 1192 个（少 2 个） | `drm_kms_helper.ko`、`governor_performance.ko` 在本项目中编进内核，官方将其作为模块发布 |
| apu | 本项目 1575 个，官方 1579 个（少 4 个） | `extcon-core.ko`、`usbserial.ko` 在本项目中编进内核；缺少 `gpio-crystalcove.ko` 和 `intel_bytcrc_pwrsrc.ko` |

由于部分模块的内建/模块归属不同，内核与模块包必须一起更换
