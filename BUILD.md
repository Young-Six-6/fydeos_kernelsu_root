# FydeOS for PC 内核构建指南

本指南说明如何从固定版本的 ChromiumOS 内核源码构建 FydeOS `iris` 与 `apu` 变体，并生成可部署的内核和模块包。

未另行说明时，命令从仓库根目录执行。

## 1. 构建目标

| 项目 | 配置 |
|---|---|
| 内核源码 | ChromiumOS `chromeos-6.12`，提交 `b4e10020ba49ded48a0e34144c5eb2fbc813cc2b` |
| 目标内核版本 | `6.12.54-01180-gb4e10020ba49-dirty` |
| KernelSU | `v3.3.0`，内置模式 |
| `iris` | Intel 显示驱动 `i915`；`NR_CPUS=24` |
| `apu` | AMD 显示驱动 `amdgpu`、`radeon`；`NR_CPUS=64` |
| 主要产物 | `vmlinuz.A` 与 `modules-<variant>.tar.gz` |

内核由 ChromiumOS 基线、FydeOS 子系统补丁、平台补丁、对应变体配置和 KernelSU 适配组成。仅构建上游源码不能生成与本项目功能相同的内核。

`build.sh` 自动处理克隆、部分补丁下载与应用、配置、编译和打包。补丁移植、部分 Kconfig/Makefile 注册，以及 KernelSU 的本地适配仍需按本指南完成。建议分阶段构建，以便在编译前检查这些修改。

## 2. 构建环境

### 2.1 系统与资源

| 项目 | 最低要求 | 建议 |
|---|---:|---:|
| 系统 | x86_64 Linux | Ubuntu 22.04 或 Debian 12 |
| CPU | 4 核 | 12 核或以上 |
| 内存 | 8 GB | 16 GB 或以上 |
| 可用磁盘 | 12 GB | 20 GB 或以上 |
| 网络 | 可访问 googlesource.com、github.com 和 android.googlesource.com | 稳定连接 |

### 2.2 系统依赖

Debian/Ubuntu 可安装以下依赖：

```bash
sudo apt-get update
sudo apt-get install -y \
  git make gcc bc bison flex libssl-dev libelf-dev \
  python3 curl xz-utils zstd cpio rsync kmod file patch dwarves \
  tar gzip
```

### 2.3 LLVM/Clang

本项目使用 Android Clang r536225，版本为 19.0.1。默认路径为 `/opt/ddk/clang/clang-r536225/bin`；其他安装位置可通过 `CLANG_DIR` 指定。

```bash
sudo mkdir -p /opt/ddk/clang
sudo curl -fL -o /opt/ddk/clang/clang-r536225.tar.gz \
  'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r536225.tar.gz'
sudo mkdir -p /opt/ddk/clang/clang-r536225
sudo tar xzf /opt/ddk/clang/clang-r536225.tar.gz -C /opt/ddk/clang/clang-r536225
/opt/ddk/clang/clang-r536225/bin/clang --version
```

官方镜像使用 ChromiumOS Clang 21。使用 Clang 19 会造成配置中的工具链版本字段不同；内核和模块应由同一次构建生成并配套使用。

构建脚本使用 `ARCH=x86_64`、`LLVM=1` 和 `LLVM_IAS=1`，并从 `CLANG_DIR` 加载 LLVM 工具链。

### 2.4 工作目录

```bash
export REPO="$PWD"
export W="$HOME/ksu-build"
export CLANG_DIR=/opt/ddk/clang/clang-r536225/bin
mkdir -p "$W"
```

`build.sh` 默认工作目录为 `$HOME/ksu-build`。如使用其他目录，在每次调用时传入 `--workdir "$W"`。并行任务数可由 `--jobs N` 指定，默认使用 `nproc` 返回的 CPU 数量。

## 3. 准备官方基准配置

配置阶段需要完整的 FydeOS 官方配置，文件名必须为：

- `$W/official-iris.config`
- `$W/official-apu.config`

从本仓库根目录执行以下命令，可将随附的官方配置快照复制到工作目录：

```bash
cp config-official-iris.txt "$W/official-iris.config"
cp config-official-apu.txt "$W/official-apu.config"
```

如需从设备获取配置，可在对应官方系统中运行：

```bash
VARIANT=iris
sudo modprobe configs
zcat /proc/config.gz > "official-$VARIANT.config"
```

也可从对应官方模块包的 `kernel/kernel/configs.ko` 提取配置。应使用完整配置作为基线；不要用 ChromiumOS 配置片段自行合并替代。

## 4. 标准构建流程

以下流程以 `iris` 为例。构建 `apu` 时将参数中的 `iris` 替换为 `apu`。

### 4.1 克隆并检出内核源码

```bash
bash build.sh iris --workdir "$W" --jobs 12 --stage clone
```

脚本会克隆 `chromeos-6.12` 分支并检出固定提交。源码目录为 `$W/kernel-iris`。确认版本为 `6.12.54`，并检查脚本列出的四个 FydeOS 子系统在基线源码中缺失：

- `drivers/staging/android/ashmem.c`
- `fs/esdfs/`
- `security/chromiumos/alt-syscall.c`
- `net/netfilter/xt_quota2.c`

如果目标源码目录已存在，脚本会报告当前提交；应在继续前确认其提交号与本指南一致。

### 4.2 下载和移植 FydeOS 子系统补丁

```bash
bash build.sh iris --workdir "$W" --jobs 12 --stage prepare
```

准备阶段下载并应用以下 openFyde 补丁：

| 补丁 | 来源 | 内容 |
|---|---|---|
| `063-altcall.patch` | `r144-dev` / `chromeos-kernel-6_6` | ChromiumOS alt-syscall |
| `065-add-esdfs.patch` | `r144-dev` / `chromeos-kernel-6_6` | esdfs |
| `040-add-ashmem.patch` | `r132-dev` / `chromeos-kernel-6_1` | ashmem |

这些补丁不是针对 6.12 发布的。对未应用的 hunk，检查对应 `.rej` 文件并将改动移植到 6.12 源码。完成后确认没有未处理的 `.rej`：

```bash
find "$W/kernel-iris" -name '*.rej' -not -path '*/.git/*'
```

需要将相关 Kconfig 与构建规则注册到 6.12：

| 文件 | 注册项 |
|---|---|
| `drivers/staging/Kconfig` | `source "drivers/staging/android/Kconfig"` |
| `drivers/staging/Makefile` | `obj-y += android/` |
| `fs/Kconfig` | `source "fs/esdfs/Kconfig"` |
| `fs/Makefile` | `obj-$(CONFIG_ESD_FS) += esdfs/` |
| `init/init_task.c` | 引入 `<linux/alt-syscall.h>` |
| `include/net/netns/core.h` | 增加 `int sysctl_android_paranoid;` |
| `net/core/sysctl_net_core.c` | 注册 `sysctl_android_paranoid` 条目 |
| `arch/x86/include/asm/thread_info.h` | 移植 alt-syscall 的线程表字段、类型和初始化宏 |
| `security/Kconfig` | 注册 `ARCH_HAS_ALT_SYSCALL` 与 `ALT_SYSCALL` |
| `security/chromiumos/Kconfig` | 注册 `ALT_SYSCALL_CHROMIUMOS` |

### 4.3 添加 `xt_quota2`

准备阶段会从 Android Common Kernel `android16-6.12` 下载 `xt_quota2.c` 和头文件，并将它们复制到内核源码树。需要确认源码使用 `strscpy()`，并在以下文件中注册构建项：

```text
net/netfilter/Kconfig:
  NETFILTER_XT_MATCH_QUOTA2
  NETFILTER_XT_MATCH_QUOTA2_LOG

net/netfilter/Makefile:
  obj-$(CONFIG_NETFILTER_XT_MATCH_QUOTA2) += xt_quota2.o
```

`chromeos-6.6` 中的旧实现调用已从 Linux 6.8 删除的 `strlcpy()`，不应用于 6.12。Android Common Kernel 的 ashmem 实现与 FydeOS 所需的 C 实现不同；ashmem 应使用上表中的 openFyde 补丁。

### 4.4 应用物理机平台补丁

本项目的平台补丁来源为 openFyde `r144-dev`。根据目标硬件和交付配置，移植并应用以下补丁：

```text
001-hid-sensor-cros-compat
003-add-marvell-bluetooth
006-intel-hid-tablet-mode
007-add-lenovo-keyboard
009-knote5-touchscrean
010-fix-ideapad-i2c-touchpad
027-set-split-lock-detct-off
028-fix-localverion
030-fix-amd-suspend-issue
033-disable-ahci-suspend
```

`011-for-old-intel-graphic` 仅用于 `iris`。以上补丁面向较早的内核版本，应用前应使用 `git apply --check` 或 `patch --dry-run` 检查，并按 6.12 源码调整 hunk。`027` 在 6.12 上可能不再产生代码改动。

`030-fix-amd-suspend-issue` 应同时检查 `iris` 与 `apu`。移植时需保留以下语义：

- `acpi_get_lps0_constraint()` 返回值为 255，即 `ACPI_STATE_UNKNOWN` 时，应视为没有有效约束并返回 `false`；不能只检查负数。
- 有效约束应与 `ACPI_STATE_D3_HOT` 比较。
- `pci_bridge_d3_possible()` 应使用平台约束检查替代 BIOS 年份启发式，不应保留旧 fallback。

### 4.5 集成 KernelSU 并完成适配

准备阶段会克隆 KernelSU `v3.3.0`，为内核树创建独立副本，并设置 `drivers/kernelsu` 相对链接。两个变体必须分别使用自己的 KernelSU 副本：

```bash
readlink -f "$W/kernel-iris/drivers/kernelsu"
```

解析结果应指向 `$W/kernel-iris/KernelSU/kernel`。对 `apu` 应对应指向 `$W/kernel-apu/KernelSU/kernel`。

FydeOS 启用了 `CONFIG_ALT_SYSCALL`，还需完成下列适配。

#### 内核导出接口

在 `kernel/alt-syscall.c` 中导出 alt-syscall 表列表访问器：

```c
struct list_head *ksu_get_alt_sys_call_tables(void)
{
	return &alt_sys_call_tables;
}
EXPORT_SYMBOL_GPL(ksu_get_alt_sys_call_tables);
```

在 `security/chromiumos/alt-syscall.c` 中导出 pristine syscall 表访问器：

```c
sys_call_ptr_t *ksu_get_pristine_sys_call_table(void)
{
	return default_table.table;
}
EXPORT_SYMBOL_GPL(ksu_get_pristine_sys_call_table);
```

在 `include/linux/alt-syscall.h` 对应的 `CONFIG_ALT_SYSCALL` 条件块中声明两个原型。两个访问器必须分别放在能访问其数据对象的源文件中。

#### syscall dispatcher

在 `KernelSU/kernel/hook/x86_64/syscall_hook.c` 中实现 alt 表遍历、dispatcher 槽位选择和当前任务检查。槽位只有在所有 alt 表中均为 `ni_syscall` 时才能使用。dispatcher 检查应确认当前任务的 `sys_call_table` 指向本项目的 dispatcher，以避免重定向仍使用默认表的宿主任务。

将用于安装 hook 的表指针与用于调用原始系统调用的 pristine 表指针分开。`ksu_syscall_table` 用于写入 hook；`ksu_call_orig_syscall()` 应通过 `ksu_get_pristine_sys_call_table()` 获得的表调用原始系统调用，并在表或系统调用号无效时返回 `-ENOSYS`。更新 `feature/sucompat.c`、`hook/syscall_event_bridge.c` 和 `hook/x86_64/syscall_hook.c` 中调用原始系统调用的代码。

#### 直接表 hook

ARC 配置 `/opt/google/containers/android/config.json` 使用 `"altSyscall": "android"`。在 `KernelSU/kernel/hook/x86_64/syscall_hook.c` 中，`read`、`fstat` 的直接表 hook 应优先选择 `android`，未找到时再回退到 `android_permissive`。合并两个名称后取首个匹配项可能误选表，导致 init.rc 注入失败。

```c
list_for_each(pos, head) {
    t = list_entry(pos, struct alt_sys_call_table, node);
    if (!strcmp(t->name, "android")) {
        pick = t;
        break;
    }
}
if (!pick) {
    list_for_each(pos, head) {
        t = list_entry(pos, struct alt_sys_call_table, node);
        if (!strcmp(t->name, "android_permissive")) {
            pick = t;
            break;
        }
    }
}
```

设备端检查表选择及 init.rc 读取日志：

```bash
sudo dmesg | grep 'direct-hook table'
sudo dmesg | grep 'read init.rc'
```

表名称应为 `android`。未出现读取日志时，结合 ARC 启动状态及日志保留情况继续排查；dispatcher 槽位和读取计数以当前构建为准。

#### reboot 白名单

ksud 通过 `reboot` 系统调用传递 KernelSU 魔数以获取内核 fd。ARC 的 alt-syscall 白名单若阻断该调用，内核 kprobe 无法收到请求，ksud 可能报告 `UAPI version mismatch: kernel=0, ksud=2`。

在 `security/chromiumos/android_whitelists.h` 的 `android_whitelist[]` 中加入：

```c
    SYSCALL_ENTRY(reboot),
```

设备端检查是否仍有拦截记录，并结合 ksud 的 UAPI 查询确认调用成功：

```bash
sudo dmesg | grep 'blocked syscall 169'
```

放行 `reboot` 不等于让容器进程能重启机器：`reboot(2)` 内部仍检查
`capable(CAP_SYS_BOOT)`，而该检查针对 **init user namespace**；容器 uid 0
在宿主侧是 655360，在 init userns 里没有这个能力，会被 `EPERM` 挡掉。
`android_permissive` 表原本就放行它，所以这里只是把 `android` 表对齐到相同行为。

#### 用户命名空间 UID

在 `KernelSU/kernel/include/ksu_uid.h` 增加命名空间感知的 UID 转换，并将 KernelSU 中直接使用 `current_uid().val` 的用户身份检查改为调用此 helper：

```c
static inline uid_t ksu_task_uid(void)
{
	uid_t uid = from_kuid(current_user_ns(), current_uid());
	if (uid == (uid_t)-1)
		return current_uid().val;
	return uid;
}
```

不可映射时应回退到内核 UID 原值，以保持内核 root 权限检查有效。

#### 内置模式的管理器加冕

在 `KernelSU/kernel/runtime/boot_event.c` 中，将内置模式所需的 `track_throne(true)` 调整为 `track_throne(false)`，使启动阶段执行管理器搜索逻辑。

### 4.6 准备官方配置并生成变体配置

确认 `$W/official-<variant>.config` 已按第 3 节准备，再运行：

```bash
bash build.sh iris --workdir "$W" --jobs 12 --stage config
```

配置阶段从完整官方配置开始，关闭 VMware/virtio 客体配置，启用 KVM、KernelSU、EFI 启动项和相应硬件驱动，然后运行 `olddefconfig` 解析依赖。

| 项目 | `iris` | `apu` |
|---|---|---|
| 图形驱动 | `DRM_I915=m` | `DRM_AMDGPU=m`、`DRM_RADEON=m` |
| KVM 驱动 | `KVM_INTEL=m` | `KVM_AMD=m` |
| `NR_CPUS` | 24 | 64 |
| `CONFIG_EFI_MIXED` | `y` | `y` |

两个变体还需启用 EFI stub、EFI handover、relocatable、KASLR、gzip 内核压缩、固件 xz 解压以及 KernelSU 所需的 kprobes 选项。`LOCALVERSION` 配置为空，构建环境变量提供版本后缀：

```text
-01180-gb4e10020ba49-dirty
```

配置阶段还会启用 `CONFIG_KALLSYMS` 和 `CONFIG_KALLSYMS_ALL`，为 KernelSU 的 LSM hook 提供 `static_calls_table`、`lsm_active_cnt` 等数据符号。确认生成的配置包含：

```bash
grep -E '^CONFIG_KALLSYMS(_ALL)?=' "$W/kernel-iris/.config"
```

设备端可通过 `/proc/kallsyms` 核对数据符号：

```bash
grep -wE 'static_calls_table|lsm_active_cnt' /proc/kallsyms
```

`selinux_hide: sel_handle_status_ops not found` 表示相关 hook 未生效。`tracked hooks=0` 是初始化时的计数；模块 `mount` 字段的含义见 [用户手册](USER-MANUAL.md)第 10.2 节。

配置阶段会检查关键符号和 `kernelrelease`。继续前确认版本串为 `6.12.54-01180-gb4e10020ba49-dirty`，并查看生成的 `.config`。与官方配置的已知差异和影响见 [FIDELITY.md](FIDELITY.md)。

### 4.7 编译内核并安装模块到暂存目录

```bash
bash build.sh iris --workdir "$W" --jobs 12 --stage build
```

此阶段会清理源码树中的旧 `.ko`，执行一次 `make` 构建内核和模块，检查 EFI stub 和必需模块，显示 `vermagic`，再将模块安装到独立输出目录。不要只运行 `make bzImage` 后安装模块；这会留下未随配置更新的模块。

默认模块输出目录为：

```text
$W/modout-iris/lib/modules/6.12.54-01180-gb4e10020ba49-dirty/
```

`apu` 对应 `$W/modout-apu/`。内核与模块必须来自同一次构建。

### 4.8 打包

```bash
bash build.sh iris --workdir "$W" --jobs 12 --stage package
```

输出目录为 `$W/dist-iris/`，包含：

```text
vmlinuz.A
modules-iris.tar.gz
MD5SUMS
SHA256SUMS
config-iris.txt
```

模块包保留 `lib/modules/<version>/` 目录结构，可按用户手册中的流程部署。`apu` 的包名和目录名相应为 `modules-apu.tar.gz`、`dist-apu` 与 `config-apu.txt`。

### 4.9 连续执行阶段

以下命令展示完整的分阶段顺序。首次克隆后，应完成第 4.2 至 4.5 节列出的人工移植与 KernelSU 适配，再继续配置和编译：

```bash
bash build.sh iris --workdir "$W" --jobs 12 --stage clone
bash build.sh iris --workdir "$W" --jobs 12 --stage prepare
# 完成补丁移植、Kconfig/Makefile 注册及 KernelSU 适配
bash build.sh iris --workdir "$W" --jobs 12 --stage config
bash build.sh iris --workdir "$W" --jobs 12 --stage build
bash build.sh iris --workdir "$W" --jobs 12 --stage package
```

可用阶段为 `clone`、`prepare`、`config`、`build`、`package` 和 `all`。`all` 会连续执行全部阶段，不会在人工移植步骤处暂停；仅当工作树和所需人工修改已准备妥当时使用。

## 5. 构建结果核验

### 5.1 文件和校验和

```bash
cd "$W/dist-iris"
sha256sum -c SHA256SUMS
md5sum -c MD5SUMS
```

确认模块包包含目标版本目录及必要模块：

```bash
tar -tzf modules-iris.tar.gz | head
tar -tzf modules-iris.tar.gz | grep -E '/(e1000|i915)\.ko$'
```

`apu` 应包含 `e1000.ko`、`amdgpu.ko` 和 `radeon.ko`。检查代表模块的 vermagic：

```bash
modinfo -F vermagic "$W/modout-iris/lib/modules/6.12.54-01180-gb4e10020ba49-dirty/kernel/drivers/net/ethernet/intel/e1000/e1000.ko"
```

输出应包含目标版本、`SMP preempt mod_unload`，并与内核配套。

### 5.2 产物结构

确认 `vmlinuz.A` 是带 EFI stub 的 x86 bzImage，且 KernelSU、ashmem、esdfs、alt-syscall 与 xt_quota2 的关键标记存在。构建脚本会执行启动头和模块检查；项目中的 `tools/inspect-artifact.py` 可用于核验放在仓库 `iris/`、`apu/` 目录下的已交付产物：

```bash
cd "$REPO"
python3 tools/inspect-artifact.py iris
python3 tools/inspect-artifact.py apu
```

该工具读取仓库固定路径中的交付文件，不直接读取 `$W/dist-<variant>/`。对工作目录中的新产物，应先完成上述校验和、包内路径及模块检查。

### 5.3 配置与官方差异

按 [FIDELITY.md](FIDELITY.md) 核对配置和模块差异，包括 KernelSU 依赖、工具链元数据、平台选项及模块归属。

### 5.4 与上一版产物对比

保留上一版输出，并将下列路径设置为待比较的目录：

```bash
OLD_DIST="$W/dist-iris-old"
NEW_DIST="$W/dist-iris"
T=$(mktemp -d)
mkdir -p "$T/old" "$T/new"

"$W/kernel-iris/scripts/extract-vmlinux" "$OLD_DIST/vmlinuz.A" > "$T/old/vmlinux"
"$W/kernel-iris/scripts/extract-vmlinux" "$NEW_DIST/vmlinuz.A" > "$T/new/vmlinux"
for side in old new; do
  readelf -SW "$T/$side/vmlinux" |
    sed -n 's/^ *\[ *[0-9]\+\] *//p' |
    awk '{print $1, $5}' | sort > "$T/$side/sections.txt"
done
diff -u "$T/old/sections.txt" "$T/new/sections.txt"

tar -xzf "$OLD_DIST/modules-iris.tar.gz" -C "$T/old"
tar -xzf "$NEW_DIST/modules-iris.tar.gz" -C "$T/new"
diff -qr "$T/old/lib/modules" "$T/new/lib/modules"
printf '对比文件目录：%s\n' "$T"
```

节区名称与大小用于检查产物结构，模块目录对比用于识别内容及文件清单变化。`configs.ko` 内嵌构建配置，配置变化会影响该模块。其他差异应结合源码、配置和工具链改动逐项确认；模块字节相同不能单独证明 ABI 兼容。符号比较使用构建目录中的 `System.map`。

### 5.5 增量构建

在同一源码树中运行 `make` 会增量编译受影响对象。重新执行第 4.7、4.8 节可生成配套产物；脚本会清理旧模块并重新安装到暂存目录。

仅替换内核时，必须确认配置、工具链和模块接口兼容，并重新生成校验清单。`CONFIG_MODVERSIONS=n` 本身不能证明旧模块可复用。

## 6. 常见构建问题

| 现象 | 处理方式 |
|---|---|
| `kernelrelease` 与目标版本不符 | 设置正确的 `LOCALVERSION`，运行 `olddefconfig` 后重新核对。 |
| `patch` 生成 `.rej` | 按第 4.2 节将 hunk 移植到 6.12 源码，并处理所有 `.rej`。 |
| 两个变体解析到同一 KernelSU 目录 | 分别检查 `drivers/kernelsu` 的真实路径，确保链接指向各自源码树中的副本。 |
| 模块包缺少图形或网络驱动 | 检查目标变体配置、重新构建模块，并确认打包来自对应的 `modout-<variant>`。 |
| EFI 启动头检查失败 | 检查 `CONFIG_EFI_STUB`、`CONFIG_EFI_HANDOVER_PROTOCOL` 和生成的 `bzImage`。 |
| 模块加载出现未知符号或重定位错误 | 确认内核和模块由同一次构建生成，并作为一组部署。 |
| 克隆占用过多磁盘或耗时过长 | 使用 `--depth 1` 浅克隆。`build.sh` 已采用该选项。 |
| 模块停留在 `modules_update/` 或报告 UAPI 不匹配 | 按第 4.5 节检查直接表 hook 与 `reboot` 白名单，核对 ARC 启动状态和 ksud 日志。 |

真机部署和启动验证不属于构建步骤，操作方法见 [USER-MANUAL.md](USER-MANUAL.md)。`iris` 与 `apu` 的真机验证状态见 [README.md](README.md)。
