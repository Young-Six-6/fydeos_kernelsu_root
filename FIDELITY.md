# 与官方镜像的差异

记录 `iris`、`apu` 产物相对对应 FydeOS 官方镜像的差异及已知影响。

## 内核配置与构建

| 差异 | iris | apu | 影响 |
|---|---|---|---|
| KernelSU | 内置 `CONFIG_KSU` 与 syscall dispatcher 补丁；官方没有 | 同左 | 增加 KernelSU 及 kprobes 等依赖 |
| `CONFIG_KALLSYMS_ALL` | 本项目 `y`，官方 `n` | 同左 | 提供 LSM hook 所需的数据符号，镜像约增加 600 KiB |
| 配置符号差异数 | 220：项目独有 82、官方独有 15、取值不同 123 | 629：项目独有 179、官方独有 254、取值不同 196 | 官方独有且启用的符号分别为 11、32；其余官方独有符号主要为未设置项的记录差异 |
| `CONFIG_PM_GENERIC_DOMAINS` | 本项目未设，官方 `y` | — | 可能影响电源域及挂起、唤醒，尚未评估 |
| `CONFIG_SPI_INTEL` | 本项目未设，官方 `y` | — | Intel SPI 闪存控制器支持不同 |
| `CONFIG_DRM_FBDEV_EMULATION` | 本项目 `y`，官方 `n` | 同左 | 启用 framebuffer 辅助功能并增加相关模块 |
| `CONFIG_HPET_MMAP_DEFAULT` | 本项目未设，官方 `y` | 同左 | HPET 默认映射配置不同 |
| `CONFIG_EFI_MIXED` | — | 本项目 `y`，官方 `n` | PE 增加 `.compat` 节，提供 32 位 EFI 入口 |
| `CONFIG_LSM` | — | 官方额外启用 `yama` | 可选 LSM 不同 |
| 编译工具链 | 本项目 Android Clang 19，官方 ChromiumOS Clang 21 | 同左 | 工具链元数据不同，内核与随包模块使用同一套工具链 |
| `PAHOLE_VERSION` | 本项目 125，官方 127 | 同左 | 构建工具版本不同 |
| `CONFIG_LOCALVERSION_AUTO` | 本项目关闭，官方开启 | 同左 | 本项目通过构建参数指定版本后缀 |

## ARC 适配

| 位置 | 改动 | 作用 |
|---|---|---|
| `security/chromiumos/android_whitelists.h` | `android_whitelist[]` 放行 `reboot` | 支持 ksud 获取内核 fd |
| KernelSU `kernel/hook/x86_64/syscall_hook.c` | 直接表 hook 优先选择 `android` | 支持 ARC 的 init.rc 注入和启动事件 |

适配步骤见 [BUILD.md](BUILD.md)第 4.5 节。

## 产物格式

内核镜像的 ELF 节区名列表与官方**逐项一致**：

| 变体 | 本项目 | 官方 | 节区名 |
|---|---:|---:|---|
| iris | 46 | 46 | 相同（`identical list: True`） |
| apu | 50 | 50 | 相同 |

版本串与 vermagic 也逐字节相同（含结尾空格）。所以上表的差异都在**配置与模块归属**层面，不在产物格式层面。

**不要拿目录里其它镜像样本比对节区。** 例如 10,781,696 B 那份既不是官方 iris 也不是官方 apu（官方 iris 11,707,392 B、官方 apu 13,624,320 B），拿它比会得到 `.BTF`/`.BTF_ids` 之类的假差异。复核：`python _verify/secnames.py`。

## 模块包

| 变体 | 本项目 / 官方 | 差异 |
|---|---|---|
| iris | 1190 / 1192，少 2 个 | `drm_kms_helper.ko`、`governor_performance.ko` 改为内建 |
| apu | 1575 / 1579，少 4 个 | `extcon-core.ko`、`usbserial.ko` 改为内建；缺少 `gpio-crystalcove.ko`、`intel_bytcrc_pwrsrc.ko` |

内建与模块归属存在差异，内核和模块包必须一起更换。
