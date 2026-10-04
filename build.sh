#!/bin/bash
#
#   构建脚本
#
#
#   用法:
#     bash build.sh <iris|apu> [--workdir DIR] [--jobs N] [--stage STAGE]
#
#   阶段（可单独跑，便于失败后从中断处继续）:
#     clone     只克隆内核树并检出目标提交
#     prepare   应用 FydeOS 补丁 + 集成 KernelSU
#     config    生成 .config 并与官方对照
#     build     编译 bzImage 与 modules
#     package   打包成交付目录
#     all       全部（默认）
#
#   例:
#     bash build.sh iris                       # 完整构建
#     bash build.sh apu --jobs 24              # 用 24 个任务
#     bash build.sh iris --stage config        # 只重做配置
#
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- 定义常量
KERNEL_REPO="https://chromium.googlesource.com/chromiumos/third_party/kernel"
KERNEL_BRANCH="chromeos-6.12"
KERNEL_COMMIT="b4e10020ba49ded48a0e34144c5eb2fbc813cc2b"
KERNEL_SHORT="b4e10020ba49"
KSU_REPO="https://github.com/tiann/KernelSU"
KSU_TAG="v3.3.0"

KREL="6.12.54-01180-${KERNEL_SHORT}-dirty"
LOCALVER="-01180-${KERNEL_SHORT}-dirty"

PATCH_BASE="https://raw.githubusercontent.com/openFyde/project-openfyde-patches/r144-dev/sys-kernel/chromeos-kernel-6_6/files"
PATCH_BASE_61="https://raw.githubusercontent.com/openFyde/project-openfyde-patches/r132-dev/sys-kernel/chromeos-kernel-6_1/files"

VARIANT=""
WORKDIR="$HOME/ksu-build"
JOBS="$(nproc 2>/dev/null || echo 8)"
STAGE="all"
CLANG_DIR="${CLANG_DIR:-/opt/ddk/clang/clang-r536225/bin}"

# 参数
while [ $# -gt 0 ]; do
  case "$1" in
    iris|apu)  VARIANT="$1"; shift ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --jobs)    JOBS="$2"; shift 2 ;;
    --stage)   STAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
  esac
done

[ -n "$VARIANT" ] || { echo "必须指定变体: iris 或 apu" >&2; exit 1; }

TREE="$WORKDIR/kernel-$VARIANT"
OUT="$WORKDIR/modout-$VARIANT"
DIST="$WORKDIR/dist-$VARIANT"

say()  { echo; echo "================================================================"; echo "  $*"; echo "================================================================"; }
step() { echo; echo "--- $* ---"; }
die()  { echo "错误: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

  # LOCALVERSION 决定模块安装目录名。
setup_env() {
  export PATH="$CLANG_DIR:$PATH"
  export ARCH=x86_64
  export LLVM=1
  export LLVM_IAS=1
  export LOCALVERSION="$LOCALVER"
  # 手工指定版本后缀，关闭 Kbuild 自动追加 dirty。
  export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-builder}"
  export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-buildhost}"
}

# 0. 前置
stage_precheck() {
  say "0. 环境检查"
  step "必需工具"
  for t in git make tar gzip python3 patch curl; do
    have "$t" && echo "  ✓ $t" || die "缺少 $t"
  done

  step "编译器"
  if [ -x "$CLANG_DIR/clang" ]; then
    echo "  clang: $("$CLANG_DIR/clang" --version | head -1)"
    echo "  路径 : $CLANG_DIR"
  else
    echo "  ! 在 $CLANG_DIR 找不到 clang"
    echo "    请设置 CLANG_DIR，或安装 Android clang r536225："
    echo "      https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/main/clang-r536225/"
    echo "    系统 clang 也能编，但模块的 retpoline 代码可能与官方不一致。"
    have clang || die "系统里也没有 clang"
    CLANG_DIR="$(dirname "$(command -v clang)")"
  fi

  step "磁盘空间"
  mkdir -p "$WORKDIR"
  AVAIL=$(df -Pk "$WORKDIR" | awk 'NR==2{print $4}')
  # 源码、构建产物和模块输出约需 7 GB。
  NEED=$((7 * 1024 * 1024))
  echo "  可用: $((AVAIL / 1024)) MiB   建议: $((NEED / 1024)) MiB"
  [ "$AVAIL" -ge "$NEED" ] || echo "  ! 空间偏紧，构建可能中途失败"

  step "并行度"
  echo "  make -j$JOBS"
  setup_env
  echo "  ARCH=$ARCH  LLVM=$LLVM  LOCALVERSION=$LOCALVERSION"
}

# 1. clone
stage_clone() {
  say "1. 克隆内核源码树"
  step "仓库"
  echo "  $KERNEL_REPO"
  echo "  分支: $KERNEL_BRANCH"
  echo "  提交: $KERNEL_COMMIT"

  # 浅克隆以避免下载庞大的仓库历史；按需抓取会产生过多对象。
  if [ -d "$TREE/.git" ]; then
    echo "  已存在: $TREE"
    step "核对当前提交"
    CUR=$(git -C "$TREE" rev-parse HEAD 2>/dev/null || echo unknown)
    echo "  当前: $CUR"
    [ "$CUR" = "$KERNEL_COMMIT" ] || echo "  ! 与目标提交不同"
  else
    step "克隆（--depth 1，只取一个提交的树）"
    git clone --depth 1 --branch "$KERNEL_BRANCH" --single-branch \
        "$KERNEL_REPO" "$TREE" || die "克隆失败"

    step "检出目标提交"
    cd "$TREE"
    if ! git cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
      echo "  --depth 1 里没有这个提交，按 SHA 单独取一次"
      git fetch --depth 1 origin "$KERNEL_COMMIT" || die "取提交失败"
    fi
    git checkout "$KERNEL_COMMIT" || die "检出失败"
  fi

  cd "$TREE"
  step "版本核对"
  echo "  HEAD          : $(git rev-parse HEAD)"
  echo "  Makefile 版本 : $(make -s kernelversion 2>/dev/null || echo '?')"
  grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) =' Makefile | sed 's/^/    /'

  step "确认 6.12 里确实缺那四个子系统（这是要打补丁的理由）"
  for p in drivers/staging/android/ashmem.c fs/esdfs security/chromiumos/alt-syscall.c net/netfilter/xt_quota2.c; do
    [ -e "$p" ] && echo "  ✓ 存在: $p" || echo "  ✗ 缺失: $p  ← 需要补丁"
  done
}

# 2. prepare
stage_prepare() {
  say "2. 应用 FydeOS 补丁 + 集成 KernelSU"
  cd "$TREE" || die "找不到源码树 $TREE，先跑 --stage clone"

  PDIR="$WORKDIR/patches"
  mkdir -p "$PDIR"

  step "下载补丁"
  # openFyde 没有 6.12 补丁集；以下补丁来自 6.6/6.1，需手工 rebase。
  fetch() {  # fetch <url> <outfile>
    [ -s "$2" ] && { echo "  已缓存: $(basename "$2")"; return 0; }
    curl -sfL "$1" -o "$2" && echo "  已下载: $(basename "$2") ($(stat -c%s "$2") B)" \
      || { echo "  ✗ 下载失败: $1"; return 1; }
  }
  fetch "$PATCH_BASE/063-altcall.patch"        "$PDIR/063-altcall.patch"
  fetch "$PATCH_BASE/065-add-esdfs.patch"      "$PDIR/065-add-esdfs.patch"
  fetch "$PATCH_BASE_61/040-add-ashmem.patch"  "$PDIR/040-add-ashmem.patch"

  step "应用补丁（--forward：已打过会安全跳过）"
  for p in 063-altcall 065-add-esdfs 040-add-ashmem; do
    f="$PDIR/$p.patch"
    [ -s "$f" ] || { echo "  跳过 $p（未下载）"; continue; }
    echo "  --- $p ---"
    if patch -p1 --forward --dry-run < "$f" >/dev/null 2>&1; then
      patch -p1 --forward < "$f" >/dev/null && echo "      ✓ 全部应用"
    else
      # 未应用的 hunk 会生成 .rej，需按 BUILD.md 清单手工处理。
      patch -p1 --forward < "$f" 2>&1 | grep -E 'FAILED|Hunk|patching' | head -20 | sed 's/^/      /'
      echo "      ! 有 hunk 未应用，见各目标文件旁的 .rej"
    fi
  done

  step "手工 rebase 检查（这些 hunk 在 6.12 上必然冲突）"
  cat <<'EOT'
  需要人工处理的注册行（6.12 上下文已变）：
    drivers/staging/Kconfig    + source "drivers/staging/android/Kconfig"
    drivers/staging/Makefile   + obj-y += android/
    fs/Kconfig                 + source "fs/esdfs/Kconfig"
    fs/Makefile                + obj-$(CONFIG_ESD_FS) += esdfs/
    init/init_task.c           + #include <linux/alt-syscall.h>
    include/net/netns/core.h   + int sysctl_android_paranoid;
    net/core/sysctl_net_core.c + ctl_table 条目
    arch/x86/include/asm/thread_info.h   ← 最麻烦，6.12 挪过位置
    security/Kconfig           + ARCH_HAS_ALT_SYSCALL / ALT_SYSCALL
    security/chromiumos/Kconfig + ALT_SYSCALL_CHROMIUMOS

  查剩余 .rej：
    find . -name '*.rej' -not -path './.git/*'
EOT

  step "xt_quota2（没有公开的 6.12 补丁，从 ACK android16-6.12 取）"
  # 6.6 版本调用了已在 6.8 删除的 strlcpy()，因此改用 Android 6.12 源码。
  Q="$WORKDIR/quota2"
  mkdir -p "$Q"
  ACK="https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12"
  for path in net/netfilter/xt_quota2.c include/linux/netfilter/xt_quota2.h; do
    out="$Q/$(basename "$path")"
    [ -s "$out" ] && { echo "  已缓存: $(basename "$path")"; continue; }
    curl -sfL "$ACK/$path?format=TEXT" | base64 -d > "$out" 2>/dev/null \
      && echo "  已下载: $(basename "$path") ($(stat -c%s "$out") B)" \
      || echo "  ✗ 下载失败: $path"
  done
  if [ -s "$Q/xt_quota2.c" ]; then
    grep -q 'strscpy' "$Q/xt_quota2.c" && echo "  ✓ 确认使用 strscpy（6.12 兼容）" \
      || echo "  ! 这份源码没有 strscpy —— 可能是 6.6 的版本，检查一下"
    mkdir -p net/netfilter include/linux/netfilter
    cp -f "$Q/xt_quota2.c" net/netfilter/
    cp -f "$Q/xt_quota2.h" include/linux/netfilter/
    echo "  已放置到 net/netfilter/ 与 include/linux/netfilter/"
  fi

  step "集成 KernelSU"
  KS="$WORKDIR/KernelSU"
  if [ ! -d "$KS/.git" ]; then
    git clone --depth 1 --branch "$KSU_TAG" "$KSU_REPO" "$KS" || die "KernelSU 克隆失败"
  fi
  echo "  KernelSU: $(git -C "$KS" describe --tags --always 2>/dev/null)"

  # 每个变体使用独立的 KernelSU 副本，避免构建树互相污染。
  if [ -e "$TREE/KernelSU" ] && [ ! -L "$TREE/KernelSU" ]; then
    echo "  本树已有独立 KernelSU 副本"
  else
    rm -f "$TREE/KernelSU"
    cp -a "$KS" "$TREE/KernelSU"
    echo "  已复制独立副本到 $TREE/KernelSU"
  fi

  # 确保相对链接从当前 drivers/ 指向源码树内的 KernelSU 副本。
  ln -sfn ../KernelSU/kernel "$TREE/drivers/kernelsu"
  RESOLVED=$(readlink -f "$TREE/drivers/kernelsu")
  echo "  drivers/kernelsu -> $(readlink "$TREE/drivers/kernelsu")"
  echo "  解析为           : $RESOLVED"
  [ "$RESOLVED" = "$TREE/KernelSU/kernel" ] \
    && echo "  ✓ symlink 指向本树" \
    || die "symlink 指向了别的树 —— 必须修正，否则会串味"

  step "KernelSU 需要的内核侧改动"
  cat <<'EOT'
  以下改动在 KernelSU 源码侧（$TREE/KernelSU/kernel/），详见 BUILD.md：
    include/ksu_uid.h                    新增：命名空间感知的 uid 转换
    23 处 current_uid().val              改用 ksu_task_uid()
    hook/x86_64/syscall_hook.c           alt 表装载器 + pristine 指针
    feature/sucompat.c                   改用 ksu_call_orig_syscall()
    runtime/boot_event.c                 track_throne(true) -> (false)
  以及内核侧：
    kernel/alt-syscall.c                 两个 EXPORT_SYMBOL_GPL 访问器
    security/chromiumos/alt-syscall.c    同上
    include/linux/alt-syscall.h          原型（否则 -Wmissing-prototypes 报错）
EOT
}

# 3. config
stage_config() {
  say "3. 生成 .config"
  cd "$TREE" || die "找不到源码树"
  setup_env

  step "从官方镜像的 configs.ko 提取基准配置"
  BASE_CFG="$WORKDIR/official-$VARIANT.config"
  if [ -s "$BASE_CFG" ]; then
    echo "  已存在: $BASE_CFG ($(wc -l < "$BASE_CFG") 行)"
  else
    cat <<EOT
  ! 没有找到 $BASE_CFG

   最可靠的做法是从官方镜像里提取，而不是从 chromeos/config/ 拼装。
    官方用的是整份 config（CHROMEOS_KERNEL_CONFIG 直接 cp），不是 fragment 合并。

  在官方 FydeOS 设备上（或从官方模块包里）：
    # 设备上：
    sudo modprobe configs && zcat /proc/config.gz > official-$VARIANT.config
    # 或从模块包里的 kernel/kernel/configs.ko 提取 IKCFG_ST..IKCFG_ED 之间的 gzip

  本仓库的 tools/inspect-artifact.py 也能提取（用官方产物）：
    python tools/inspect-artifact.py $VARIANT --config-out official-$VARIANT.config
EOT
    die "请先准备基准配置 $BASE_CFG"
  fi

  cp -f "$BASE_CFG" .config
  echo "  已载入基准: $(wc -l < .config) 行"

  step "关闭 VMware 专属项（物理机不需要）"
  SC=./scripts/config
  for o in HYPERVISOR_GUEST PARAVIRT PARAVIRT_SPINLOCKS PARAVIRT_CLOCK KVM_GUEST XEN \
           DRM_VMWGFX DRM_VMWGFX_MKSSTATS VMWARE_BALLOON VMWARE_PVSCSI VMWARE_VMCI \
           VMWARE_VMCI_VSOCKETS VIRTIO VIRTIO_MENU VIRTIO_PCI VIRTIO_PCI_LIB \
           VIRTIO_PCI_LIB_LEGACY VIRTIO_PCI_LEGACY VIRTIO_PCI_ADMIN_LEGACY \
           VIRTIO_MMIO VIRTIO_MMIO_CMDLINE_DEVICES VIRTIO_BLK VIRTIO_BALLOON \
           VIRTIO_NET VIRTIO_CONSOLE VIRTIO_INPUT VIRTIO_FS VIRTIO_IOMMU \
           VIRTIO_DMA_SHARED_BUFFER VIRTIO_VSOCKETS VIRTIO_VSOCKETS_COMMON \
           VIRTIO_ANCHOR BLK_MQ_VIRTIO NET_9P_VIRTIO SND_VIRTIO DRM_VIRTIO_GPU; do
    $SC --disable "$o" 2>/dev/null || true
  done
  echo "  完成"

  step "开启 host 化 + KVM"
  $SC --enable KVM
  for o in HAVE_KVM VIRTUALIZATION KVM_MMIO KVM_ASYNC_PF KVM_COMPAT KVM_IRQFD \
           KVM_VFIO KVM_SMM KVM_XFER_TO_GUEST_WORK KVM_GENERIC_DIRTYLOG_READ_PROTECT \
           KVM_GENERIC_HARDWARE_ENABLING KVM_GENERIC_MEMORY_MAPPING; do
    $SC --enable "$o" 2>/dev/null || true
  done

  if [ "$VARIANT" = "iris" ]; then
    step "iris：i915 + Intel 平台"
    $SC --module DRM_I915
    for o in DRM_ACCEL DRM_I915_USERPTR DRM_I915_PXP DRM_I915_DP_TUNNEL \
             X86_INTEL_LPSS X86_INTEL_PSTATE INTEL_MEI INTEL_MEI_ME; do
      $SC --enable "$o" 2>/dev/null || true
    done
    $SC --module KVM_INTEL 2>/dev/null || true
    $SC --enable X86_AMD_PLATFORM_DEVICE
  else
    step "apu：amdgpu + radeon + AMD 平台"
    $SC --module DRM_AMDGPU
    $SC --module DRM_RADEON
    for o in DRM_AMDGPU_SI DRM_AMDGPU_CIK DRM_AMDGPU_USERPTR DRM_AMD_DC \
             DRM_AMD_DC_FP DRM_AMD_DC_SI DRM_RADEON_USERPTR; do
      $SC --enable "$o" 2>/dev/null || true
    done
    $SC --module KVM_AMD 2>/dev/null || true
    $SC --enable KVM_AMD_SEV 2>/dev/null || true
    $SC --enable X86_AMD_PLATFORM_DEVICE
    $SC --set-val NR_CPUS 64
  fi

  step "两边都要的项"
  # 笔记本背光支持。
  $SC --enable BACKLIGHT_CLASS_DEVICE
  # 官方固件使用 .xz。
  $SC --enable FW_LOADER_COMPRESS
  $SC --enable FW_LOADER_COMPRESS_XZ
  # 官方内核使用 gzip。
  for o in KERNEL_LZMA KERNEL_XZ KERNEL_LZO KERNEL_ZSTD; do $SC --disable "$o" 2>/dev/null || true; done
  $SC --enable KERNEL_GZIP 2>/dev/null || true
  # GRUB 通过 EFI stub 加载 vmlinuz.A。
  for o in EFI_STUB EFI_MIXED EFI_HANDOVER_PROTOCOL RELOCATABLE RANDOMIZE_BASE; do
    $SC --enable "$o"
  done
  # KernelSU 及其依赖；KALLSYMS_ALL 提供 LSM hook 所需的数据符号。
  for o in KSU KSU_X86_PATCH_SYSCALL_DISPATCHER KPROBES KPROBES_ON_FTRACE \
           KRETPROBES OPTPROBES KPROBE_EVENTS RETHOOK KRETPROBE_ON_RETHOOK \
           KALLSYMS KALLSYMS_ALL; do
    $SC --enable "$o" 2>/dev/null || true
  done
  # 版本串。
  $SC --set-str LOCALVERSION ""
  $SC --disable LOCALVERSION_AUTO

  step "olddefconfig（让 Kconfig 解析出 6.12 的完整依赖）"
  make -j"$JOBS" olddefconfig 2>&1 | tail -5

  step "关键项核对"
  check() {
    local v
    v=$(grep -E "^CONFIG_$1=" .config | head -1)
    [ -z "$v" ] && { grep -qE "^# CONFIG_$1 is not set" .config && v="# CONFIG_$1 is not set" || v="(缺失)"; }
    printf '  %-44s %s\n' "$1" "${v#CONFIG_}"
  }
  for s in KSU KSU_X86_PATCH_SYSCALL_DISPATCHER KPROBES KRETPROBES OPTPROBES RETHOOK \
           EFI_STUB EFI_MIXED EFI_HANDOVER_PROTOCOL RELOCATABLE RANDOMIZE_BASE \
           KERNEL_GZIP MODULES MODVERSIONS MODULE_SIG IKCONFIG KALLSYMS KALLSYMS_ALL \
           ASHMEM ESD_FS ALT_SYSCALL ALT_SYSCALL_CHROMIUMOS ARCH_HAS_ALT_SYSCALL \
           NETFILTER_XT_MATCH_QUOTA2 NETFILTER_XT_MATCH_QUOTA2_LOG \
           BACKLIGHT_CLASS_DEVICE FW_LOADER_COMPRESS FW_LOADER_COMPRESS_XZ \
           LOCALVERSION LOCALVERSION_AUTO; do
    check "$s"
  done
  if [ "$VARIANT" = "iris" ]; then
    for s in DRM_I915 DRM_AMDGPU DRM_KMS_HELPER NR_CPUS; do check "$s"; done
  else
    for s in DRM_AMDGPU DRM_RADEON DRM_KMS_HELPER NR_CPUS DEBUG_INFO_BTF; do check "$s"; done
  fi

  step "版本串核对（模块目录名由它决定）"
  REL=$(make -s LOCALVERSION="$LOCALVER" kernelrelease 2>/dev/null)
  echo "  实际: $REL"
  echo "  期望: $KREL"
  [ "$REL" = "$KREL" ] && echo "  ✓ 一致" || die "版本串不一致 —— 模块目录名会错，不能继续"

  cat <<'EOT'

   关于 -dirty 后缀：
    scripts/setlocalversion 只在 scm_version() 里追加它，而一旦设置了 make 变量
    LOCALVERSION，scm_version() 根本不会被调用。官方内核是 eapply 打过补丁的
    脏树，所以版本串带 -dirty。我们必须手工把它写进 LOCALVERSION。

   make kernelrelease 读的是 include/config/auto.conf，不是 .config。
    改了 .config 之后要先 make syncconfig（olddefconfig 会顺带做）。
EOT
}

# 4. build
stage_build() {
  say "4. 编译"
  cd "$TREE" || die "找不到源码树"
  setup_env

  step "清理可能残留的旧模块产物"
  # 清理旧模块，避免 modules_install 混入上一次构建的产物。
  N=$(find . -name '*.ko' -not -path './.git/*' 2>/dev/null | wc -l)
  if [ "$N" -gt 0 ]; then
    find . -name '*.ko' -not -path './.git/*' -delete
    find . -name '*.ko.gz' -not -path './.git/*' -delete 2>/dev/null || true
    echo "  已删除 $N 个旧 .ko"
  else
    echo "  没有旧 .ko"
  fi

  step "编译内核与模块（make -j$JOBS）"
  echo "  日志: $WORKDIR/build-$VARIANT.log"
  # 同一次 make 构建 bzImage 和 modules。
  if make -j"$JOBS" > "$WORKDIR/build-$VARIANT.log" 2>&1; then
    echo "  ✓ 编译成功"
  else
    echo "  ✗ 编译失败，最后 30 行："
    tail -30 "$WORKDIR/build-$VARIANT.log" | sed 's/^/    /'
    die "编译失败，完整日志见 $WORKDIR/build-$VARIANT.log"
  fi
  echo "  警告/错误统计: $(grep -cE 'error:|warning:' "$WORKDIR/build-$VARIANT.log" || true)"

  step "核对产物"
  [ -f arch/x86/boot/bzImage ] || die "没有生成 bzImage"
  echo "  bzImage      : $(stat -c%s arch/x86/boot/bzImage) B"
  echo "  bzImage md5  : $(md5sum arch/x86/boot/bzImage | cut -d' ' -f1)"
  echo "  vmlinux      : $(stat -c%s vmlinux 2>/dev/null || echo '?') B"
  echo "  System.map   : $(grep -c ' ksu_' System.map 2>/dev/null || echo 0) 个 ksu_ 符号"

  step " 校验 bzImage 带 EFI stub（缺了 GRUB 加载不了）"
  python3 - arch/x86/boot/bzImage <<'PY' || die "bzImage 缺 EFI stub"
import struct, sys
d = open(sys.argv[1], 'rb').read(0x300)
ok = d[:2] == b'MZ'
e = struct.unpack_from('<I', d, 0x3C)[0] if ok else 0
ok = ok and d[e:e+4] == b'PE\x00\x00'
ok = ok and d.find(b'HdrS') == 0x202
ok = ok and struct.unpack_from('<H', d, 0x1FE)[0] == 0xAA55
print("  MZ=%s  PE=%s  HdrS@0x202=%s  boot_flag=%s" % (
    d[:2] == b'MZ', d[e:e+4] == b'PE\x00\x00', d.find(b'HdrS') == 0x202,
    hex(struct.unpack_from('<H', d, 0x1FE)[0])))
sys.exit(0 if ok else 1)
PY

  step "编译出的模块数"
  find . -name '*.ko' -not -path './.git/*' | wc -l | sed 's/^/  .ko: /'

  step "安装模块到独立目录（strip 掉调试信息）"
  rm -rf "$OUT"; mkdir -p "$OUT"
  make -j"$JOBS" INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$OUT" modules_install \
    2>&1 | grep -viE 'warning|needs unknown' | tail -3 | sed 's/^/  /'
  M="$OUT/lib/modules/$KREL"
  [ -d "$M" ] || die "模块没有安装到 $M"
  echo "  .ko 数量: $(find "$M" -name '*.ko' | wc -l)"
  echo "  目录大小: $(du -sh "$M" | cut -f1)"

  step " 必需模块在位检查"
  REQ="kernel/drivers/net/ethernet/intel/e1000/e1000.ko"
  if [ "$VARIANT" = "iris" ]; then
    REQ="$REQ kernel/drivers/gpu/drm/i915/i915.ko"
  else
    REQ="$REQ kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko kernel/drivers/gpu/drm/radeon/radeon.ko"
  fi
  for m in $REQ; do
    [ -f "$M/$m" ] && echo "  ✓ $m" || die "缺少必需模块 $m"
  done

  step "vermagic 核对（必须与官方逐字节一致）"
  for m in $(find "$M" -name 'e1000.ko' -o -name 'i915.ko' -o -name 'amdgpu.ko' | head -3); do
    printf '  %-16s %s\n' "$(basename "$m")" "$(modinfo -F vermagic "$m" 2>/dev/null || echo '?')"
  done
  echo "  期望: $KREL SMP preempt mod_unload （注意末尾有个空格）"
}

# 5. package
stage_package() {
  say "5. 打包"
  cd "$TREE" || die "找不到源码树"
  M="$OUT/lib/modules/$KREL"
  [ -d "$M" ] || die "找不到模块输出 $M，先跑 --stage build"

  rm -rf "$DIST"; mkdir -p "$DIST"

  step "内核"
  cp -f arch/x86/boot/bzImage "$DIST/vmlinuz.A"
  echo "  vmlinuz.A: $(stat -c%s "$DIST/vmlinuz.A") B"
  echo "  md5      : $(md5sum "$DIST/vmlinuz.A" | cut -d' ' -f1)"

  step "模块包"
  # 从 modout 打包，保留 lib/modules/<ver>/ 目录结构。
  ( cd "$OUT" && tar czf "$DIST/modules-$VARIANT.tar.gz" "lib/modules/$KREL" )
  echo "  modules-$VARIANT.tar.gz: $(stat -c%s "$DIST/modules-$VARIANT.tar.gz") B"
  echo "  md5                    : $(md5sum "$DIST/modules-$VARIANT.tar.gz" | cut -d' ' -f1)"

  step "包内核对"
  tar -tzf "$DIST/modules-$VARIANT.tar.gz" | head -2 | sed 's/^/  /'
  echo "  .ko 数量: $(tar -tzf "$DIST/modules-$VARIANT.tar.gz" | grep -c '\.ko$')"

  step "生成校验清单"
  ( cd "$DIST" && md5sum vmlinuz.A "modules-$VARIANT.tar.gz" > MD5SUMS && \
    sha256sum vmlinuz.A "modules-$VARIANT.tar.gz" > SHA256SUMS )
  cat "$DIST/MD5SUMS" | sed 's/^/  /'

  step "把构建配置也存一份（便于复现与对照）"
  cp -f .config "$DIST/config-$VARIANT.txt"
  echo "  config-$VARIANT.txt: $(wc -l < "$DIST/config-$VARIANT.txt") 行"

  say "完成"
  cat <<EOT
  产物目录: $DIST

    vmlinuz.A                  $(stat -c%s "$DIST/vmlinuz.A") B
    modules-$VARIANT.tar.gz     $(stat -c%s "$DIST/modules-$VARIANT.tar.gz") B
    MD5SUMS / SHA256SUMS
    config-$VARIANT.txt

  下一步 —— 在设备上部署：
    sudo bash deploy.sh $VARIANT ./vmlinuz.A ./modules-$VARIANT.tar.gz --dry-run
    sudo bash deploy.sh $VARIANT ./vmlinuz.A ./modules-$VARIANT.tar.gz
    sudo reboot
    sudo bash verify.sh $VARIANT

   内核与模块必须成对安装。只换内核会导致系统彻底失去网络。
EOT
}

# main
case "$STAGE" in
  clone)   stage_precheck; stage_clone ;;
  prepare) stage_prepare ;;
  config)  stage_config ;;
  build)   stage_build ;;
  package) stage_package ;;
  all)     stage_precheck; stage_clone; stage_prepare; stage_config; stage_build; stage_package ;;
  *)       die "未知阶段: $STAGE（可选 clone/prepare/config/build/package/all）" ;;
esac
