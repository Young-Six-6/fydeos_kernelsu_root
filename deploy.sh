#!/bin/bash
#
# 部署内核与配套模块（在 FydeOS 终端中以 sudo 运行）。
# 用法：
#     sudo bash deploy.sh iris /path/to/iris/vmlinuz.A /path/to/iris/modules-iris.tar.gz
#     sudo bash deploy.sh apu  /path/to/apu/vmlinuz.A  /path/to/apu/modules-apu.tar.gz
#
# 预检查（不写入）：
#     sudo bash deploy.sh iris <vmlinuz.A> <modules-iris.tar.gz> --dry-run
#
# 指定 ESP：
#     sudo bash deploy.sh iris <vmlinuz.A> <modules-iris.tar.gz> --esp=/dev/loop0p12
#
# 自动探测的 ESP 必须包含 syslinux/vmlinuz.A 或 vmlinuz.B。
# 回滚备份路径会在脚本结束时显示。

set -u

VARIANT="${1:-}"
KERNEL_IMG="${2:-}"
MODULES_TGZ="${3:-}"
DRY_RUN=0
ESP_WANT=""
SLOT_WANT=""
for a in "$@"; do
  [ "$a" = "--dry-run" ] && DRY_RUN=1
  case "$a" in
    --esp=*)  ESP_WANT="${a#--esp=}" ;;
    --slot=*) SLOT_WANT="${a#--slot=}" ;;
  esac
done

VER="6.12.54-01180-gb4e10020ba49-dirty"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/home/chronos/ksu-deploy-backup-$STAMP"

die() { echo "错误: $*" >&2; exit 1; }
say() { echo; echo "=== $* ==="; }
warn() { echo "  ! $*"; }

[ "$(id -u)" = "0" ] || die "请用 sudo 运行"
[ -n "$VARIANT" ] && [ -n "$KERNEL_IMG" ] && [ -n "$MODULES_TGZ" ] \
  || die "用法: sudo bash deploy.sh <iris|apu> <vmlinuz.A> <modules-X.tar.gz> [--dry-run]"
[ "$VARIANT" = "iris" ] || [ "$VARIANT" = "apu" ] || die "variant 必须是 iris 或 apu"
[ -f "$KERNEL_IMG" ] || die "找不到内核文件: $KERNEL_IMG"
[ -f "$MODULES_TGZ" ] || die "找不到模块包: $MODULES_TGZ"

# 按变体选择预期校验值（与 MD5SUMS、SHA256SUMS 一致）。
case "$VARIANT" in
  iris)
    WANT_KMD5="c8c6b467819fc2272667f3a77ac62b67"
    WANT_KSHA="cf08bd763b7b6d35ad5baa5962261fe4a76f74c21b1adb7f82a880477bf8883d"
    WANT_MMD5="c2af400294fdd51122a7e1ffd83d0797"
    WANT_MSHA="3d9afe50b56c75d446477c288585b5a54728181f594a18613517e2ff1ed7e1ac"
    # iris 也包含 amdgpu.ko；Intel 机器必须加载 i915。
    REQ_MODULES="kernel/drivers/gpu/drm/i915/i915.ko"
    ;;
  apu)
    WANT_KMD5="4bcab93f3f763dabedd4eb662fe6fccf"
    WANT_KSHA="d764d9059e2f122f8e245755adde1d5135d5a29ee5aba8c2bb55174e845d8446"
    WANT_MMD5="f24faeab0fe86cab5aedcd5086b27e63"
    WANT_MSHA="21a684285de0d4b923b366ada5568a8c6f71d53d24995e881b3bf85cd0d2321a"
    REQ_MODULES="kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko kernel/drivers/gpu/drm/radeon/radeon.ko"
    ;;
esac

md5of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
shaof() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

say "0. 前置检查"
echo "  变体:        $VARIANT"
echo "  内核:        $KERNEL_IMG ($(stat -c%s "$KERNEL_IMG") B)"
echo "  模块包:      $MODULES_TGZ ($(stat -c%s "$MODULES_TGZ") B)"
[ "$DRY_RUN" = 1 ] && echo "  模式:        --dry-run（只检查，不写任何东西）"

GOT_KMD5=$(md5of "$KERNEL_IMG")
GOT_KSHA=$(shaof "$KERNEL_IMG")
GOT_MMD5=$(md5of "$MODULES_TGZ")
GOT_MSHA=$(shaof "$MODULES_TGZ")

if [ "$GOT_KMD5" != "$WANT_KMD5" ] || [ "$GOT_KSHA" != "$WANT_KSHA" ]; then
  echo "  ! 内核校验值不匹配"
  echo "      期望 md5   : $WANT_KMD5"
  echo "      实际 md5   : $GOT_KMD5"
  echo "      期望 sha256: $WANT_KSHA"
  echo "      实际 sha256: $GOT_KSHA"
  die "文件可能损坏，或变体选错了（iris/apu 的内核不能互换）。"
fi
echo "  内核 md5:    $GOT_KMD5  OK"

if [ "$GOT_MMD5" != "$WANT_MMD5" ] || [ "$GOT_MSHA" != "$WANT_MSHA" ]; then
  echo "  ! 模块包校验值不匹配"
  echo "      期望 md5   : $WANT_MMD5"
  echo "      实际 md5   : $GOT_MMD5"
  die "模块包可能损坏，或与内核不是同一变体。"
fi
echo "  模块 md5:    $GOT_MMD5  OK"

# 检查内核为带 EFI stub 的 bzImage。
python3 - "$KERNEL_IMG" <<'PYEOF' || die "内核格式不对（缺 EFI stub / 不是 bzImage）"
import struct, sys
d = open(sys.argv[1], 'rb').read(0x300)
assert d[:2] == b'MZ', "不是 MZ/PE 格式（缺 EFI stub，GRUB 无法加载）"
e = struct.unpack_from('<I', d, 0x3C)[0]
assert d[e:e+4] == b'PE\x00\x00', "PE 头缺失"
assert d.find(b'HdrS') == 0x202, "不是合法 bzImage（HdrS 不在 0x202）"
assert struct.unpack_from('<H', d, 0x1FE)[0] == 0xAA55, "boot_flag 不是 0xAA55"
print("  格式:        bzImage + EFI stub  OK (PE machine=0x%04x)" %
      struct.unpack_from('<H', d, e + 4)[0])
PYEOF

# 模块包必须以 lib/modules/<ver>/ 为根，才能直接解到 /。
say "1. 模块包结构检查"
if ! tar -tzf "$MODULES_TGZ" | head -1 | grep -q "^lib/modules/$VER/"; then
  die "模块包顶层不是 lib/modules/$VER/ —— 解包后路径会错"
fi
NKO=$(tar -tzf "$MODULES_TGZ" | grep -c '\.ko$' || true)
echo "  包内 .ko:    $NKO 个"
[ "$NKO" -gt 500 ] || die "包内模块数量异常（$NKO），包可能不完整"

# 确认网络和目标显卡驱动都在模块包中。
MISSING=""
for m in $REQ_MODULES kernel/drivers/net/ethernet/intel/e1000/e1000.ko; do
  tar -tzf "$MODULES_TGZ" | grep -q "/$m$" || MISSING="$MISSING $m"
done
if [ -n "$MISSING" ]; then
  die "模块包缺少必需模块:$MISSING  —— 装上去会导致失网或显卡起不来"
fi
echo "  必需模块:    全部在位 (e1000$([ "$VARIANT" = iris ] && echo ' + i915' || echo ' + amdgpu + radeon'))"

say "2. 定位 ESP 分区"

# 按优先级检查候选，并确认挂载后包含启动槽，避免误写其他分区。
# 双引导镜像中的 EFI-SYSTEM 可能位于 loopNp12，而非物理分区。
esp_candidates() {
  # 1. 显式指定
  [ -n "$ESP_WANT" ] && echo "$ESP_WANT"

  # 2. 当前根分区所在磁盘的第 12 分区（FydeOS 的 ESP 固定是 12 号）
  local src parent
  src=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
  if [ -n "$src" ] && [ -b "$src" ]; then
    parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    if [ -n "$parent" ]; then
      case "$parent" in
        *[0-9]) echo "/dev/${parent}p12" ;;   # nvme0n1 → nvme0n1p12
        *)      echo "/dev/${parent}12"  ;;   # sda     → sda12
      esac
    fi
  fi

  # 3. 按标签
  blkid -t LABEL=EFI-SYSTEM -o device 2>/dev/null

  # 4. 常见物理位置
  echo /dev/nvme0n1p12
  echo /dev/sda12
  echo /dev/mmcblk0p12
  echo /dev/vda12

  # 5. loop 设备（双引导镜像布局）
  ls /dev/loop*p12 2>/dev/null
}

ESP_DEV=""
ESP_TRIED=""
MNT=$(mktemp -d /tmp/espx.XXXXXX)
trap 'umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null' EXIT

while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  [ -b "$cand" ] || continue
  case " $ESP_TRIED " in *" $cand "*) continue ;; esac    # 去重
  ESP_TRIED="$ESP_TRIED $cand"

  mount -o ro "$cand" "$MNT" 2>/dev/null || continue
  # FydeOS 的 ESP 里一定有 syslinux/ 且至少有一个 vmlinuz 槽
  if [ -d "$MNT/syslinux" ] && \
     { [ -f "$MNT/syslinux/vmlinuz.A" ] || [ -f "$MNT/syslinux/vmlinuz.B" ]; }; then
    ESP_DEV="$cand"
    umount "$MNT" 2>/dev/null
    break
  fi
  umount "$MNT" 2>/dev/null
done < <(esp_candidates)

if [ -z "$ESP_DEV" ]; then
  echo "  已试过:${ESP_TRIED:- (无可用候选)}"
  die "找不到含 syslinux/vmlinuz.? 的 ESP。
  自动探测没找到时，请自己确认后用 --esp= 指定：
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
    # FydeOS 双引导镜像：找 loopNp12
    sudo bash deploy.sh iris <vmlinuz.A> <modules-iris.tar.gz> --esp=/dev/loop0p12"
fi
echo "  ESP:         $ESP_DEV$([ -n "$ESP_WANT" ] && echo '  (由 --esp= 指定)')"

# 显示 ESP 位于物理分区还是 loop 镜像。
ESP_PARENT=$(lsblk -no PKNAME "$ESP_DEV" 2>/dev/null | head -1)
case "$ESP_DEV" in
  /dev/loop*)
    BACKING=$(cat "/sys/block/$ESP_PARENT/loop/backing_file" 2>/dev/null || echo '?')
    echo "  承载:        loop 设备（FydeOS 双引导镜像）"
    echo "  镜像文件:    $BACKING"
    echo "  提示:        写入会落进这个 .img 文件，经 loop 回环生效"
    ;;
  *) echo "  承载:        物理分区" ;;
esac

# 写入当前引导槽：优先使用 --slot，其次读取 BOOT_IMAGE；无法判断时按 A 处理。
# 不根据 cgpt 优先级推断槽位，该字段编码了 tries 与 priority。

# 以只读方式重新挂载 ESP，再检查槽文件。
mount -o ro "$ESP_DEV" "$MNT" || die "以只读方式挂载 $ESP_DEV 失败"

TARGET=""
OTHER=""
SLOT=""
SLOT_OTHER=""

# 从 BOOT_IMAGE 读取当前槽；取不到时按 A 处理。
_bi=$(sed -n 's/.*BOOT_IMAGE=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null | head -1)
if [ -n "$SLOT_WANT" ]; then
  SLOT="$SLOT_WANT"
  echo "  槽位:        $SLOT（由 --slot= 指定）"
elif [ "${_bi##*/}" = "vmlinuz.B" ]; then
  SLOT=B
  echo "  槽位:        B（BOOT_IMAGE=$_bi）"
elif [ "${_bi##*/}" = "vmlinuz.A" ]; then
  SLOT=A
  echo "  槽位:        A（BOOT_IMAGE=$_bi）"
else
  SLOT=A
  warn "读不到 BOOT_IMAGE，按 A 处理。若不是这个槽，请用 --slot=B 重跑。"
fi
case "$SLOT" in
  A) SLOT_OTHER=B ;;
  B) SLOT_OTHER=A ;;
  *) die "--slot= 只能是 A 或 B（收到 '$SLOT'）" ;;
esac

TARGET="$MNT/syslinux/vmlinuz.$SLOT"
OTHER="$MNT/syslinux/vmlinuz.$SLOT_OTHER"
echo "  目标文件:    vmlinuz.$SLOT"
[ -f "$TARGET" ] || die "syslinux/vmlinuz.$SLOT 不存在 —— 这台机器的引导布局和预期不同"
if [ -f "$OTHER" ]; then
  echo "  另一个槽:    vmlinuz.$SLOT_OTHER（保留作回退，不动）"
else
  echo "  另一个槽:    vmlinuz.$SLOT_OTHER 不存在"
fi

if [ "$DRY_RUN" = 1 ]; then
  # ESP 保持只读；预先核算内核与模块安装所需空间。
  AVAIL=$(df -k "$MNT" | awk 'NR==2{print $4}')
  KSZ=$(( $(stat -c%s "$KERNEL_IMG") / 1024 ))
  TSZ=$(( $(stat -c%s "$TARGET") / 1024 ))
  MARGIN=2048
  NEED=$(( KSZ + MARGIN ))
  echo "  可用空间:    ${AVAIL} KiB"
  echo "  内核大小:    ${KSZ} KiB"
  echo "  需含余量:    ${NEED} KiB"
  if [ "$AVAIL" -ge "$NEED" ]; then
    echo "  写入方式:    临时文件 → 原地覆盖（最稳，两个槽都不动）"
  elif [ $(( AVAIL + TSZ )) -ge "$NEED" ]; then
    echo "  写入方式:    原地覆盖（省空间）"
    echo "                截断 vmlinuz.$SLOT 会先释放 ${TSZ} KiB，"
    echo "                加上可用 ${AVAIL} KiB = $(( AVAIL + TSZ )) KiB ≥ ${NEED} KiB —— 可行"
    echo "                vmlinuz.$SLOT_OTHER 保持不动 —— 官方回退槽保住"
  elif [ -f "$OTHER" ] && [ $(( AVAIL + $(stat -c%s "$OTHER") / 1024 )) -ge "$NEED" ]; then
    O_SZ=$(( $(stat -c%s "$OTHER") / 1024 ))
    echo "  写入方式:    删除另一个槽 vmlinuz.$SLOT_OTHER（${O_SZ} KiB）腾空间"
    warn "这会失去官方回退槽（会先备份到 \$BACKUP，回滚时可用）"
    echo "                当前引导槽 vmlinuz.$SLOT 不受影响"
  else
    echo "  ！空间不足，且没有可安全删除的槽 —— 无法在本 ESP 上部署"
    exit 1
  fi

  # 模块暂存于 stateful，旧树也会先移出 rootfs；按此核算空间。
  MOD_UNPACK_KB=$(tar -tvzf "$MODULES_TGZ" 2>/dev/null | awk '{s+=$3} END {print int(s/1024)}')
  MOD_UNPACK_KB=${MOD_UNPACK_KB:-160000}
  ROOT_AVAIL_KB=$(df -k / | awk 'NR==2{print $4}')
  MOD_CUR_KB=0
  [ -d "/lib/modules/$VER" ] && MOD_CUR_KB=$(du -sk "/lib/modules/$VER" 2>/dev/null | cut -f1)
  MOD_CUR_KB=${MOD_CUR_KB:-0}
  MOD_EFFECTIVE_KB=$(( ROOT_AVAIL_KB + MOD_CUR_KB ))
  STAGE_AVAIL_KB=$(df -k /mnt/stateful_partition 2>/dev/null | awk 'NR==2{print $4}')
  STAGE_AVAIL_KB=${STAGE_AVAIL_KB:-0}
  echo
  echo "  --- 模块安装空间 ---"
  echo "  模块树展开约: $(( MOD_UNPACK_KB / 1024 )) MiB"
  echo "  根分区可用:   $(( ROOT_AVAIL_KB / 1024 )) MiB"
  echo "  旧树占用:     $(( MOD_CUR_KB / 1024 )) MiB（换入前会挪到 stateful）"
  echo "  实际可达:     $(( MOD_EFFECTIVE_KB / 1024 )) MiB   （只需容纳一份）"
  echo "  暂存区可用:   $(( STAGE_AVAIL_KB / 1024 )) MiB   （/mnt/stateful_partition）"
  if [ "$MOD_EFFECTIVE_KB" -lt "$MOD_UNPACK_KB" ]; then
    echo "  ！根分区放不下一份模块树 —— 请先清理 /lib/modules 下的 .orig-* 残留："
    echo "      du -sh /lib/modules/*.orig-* 2>/dev/null"
    echo "      sudo rm -rf /lib/modules/*.orig-*"
    exit 1
  fi
  if [ "$STAGE_AVAIL_KB" -lt $(( MOD_UNPACK_KB * 2 + 10240 )) ]; then
    echo "  ！暂存区（stateful）空间不足，无法安全解包（新树 + 旧树备份）"
    exit 1
  fi
  echo "  模块安装方式: 解到 stateful 暂存 → 校验 → 换入（rootfs 峰值只占一份）"

  say "dry-run 结束"
  echo "  ESP 探测、槽位判定、挂载、空间核算、模块空间核算均正常；"
  echo "  备份与写入未执行。去掉 --dry-run 即可真正写入。"
  exit 0
fi
mount -o remount,rw "$MNT" || die "把 $MNT 重新挂载为可写失败"

say "3. 备份"
mkdir -p "$BACKUP"
BK="$BACKUP/vmlinuz.$SLOT.orig"
cp -f "$TARGET" "$BK" || die "备份 $TARGET 失败 —— 中止，未做任何改动"
echo "  已备份引导槽内核  ->  $BK"
echo "    ($TARGET, $(md5of "$BK"))"
# 备份另一个槽，以便回滚。
if [ -f "$OTHER" ]; then
  cp -f "$OTHER" "$BACKUP/vmlinuz.$SLOT_OTHER.orig"
  echo "  已备份另一槽内核  ->  $BACKUP/vmlinuz.$SLOT_OTHER.orig ($(md5of "$BACKUP/vmlinuz.$SLOT_OTHER.orig"))"
fi
if [ -d "/lib/modules/$VER" ]; then
  # 记录原模块清单，避免复制整棵目录。
  (cd "/lib/modules/$VER" && find . | sort) > "$BACKUP/modules-orig-list.txt"
  echo "  已记录原模块清单  ->  $BACKUP/modules-orig-list.txt ($(wc -l < "$BACKUP/modules-orig-list.txt") 项)"
fi

say "4. 写入内核到 ESP"
AVAIL=$(df -k "$MNT" | awk 'NR==2{print $4}')
KSZ=$(( $(stat -c%s "$KERNEL_IMG") / 1024 ))
TSZ=$(( $(stat -c%s "$TARGET") / 1024 ))
MARGIN=2048
NEED=$(( KSZ + MARGIN ))
echo "  ESP 可用: ${AVAIL} KiB   内核: ${KSZ} KiB   需(m含余量): ${NEED} KiB"

# 按可用空间选择临时文件覆盖、原地覆盖或删除另一槽后写入。
MODE=""
if [ "$AVAIL" -ge "$NEED" ]; then
  MODE=temp
elif [ $(( AVAIL + TSZ )) -ge "$NEED" ]; then
  MODE=inplace
elif [ -f "$OTHER" ] && [ $(( AVAIL + $(stat -c%s "$OTHER") / 1024 )) -ge "$NEED" ]; then
  MODE=dropother
else
  die "ESP 空间不足（可用 ${AVAIL} KiB，需 ${NEED} KiB），且没有可安全删除的槽。中止，未改动任何东西。"
fi

case "$MODE" in
  temp)
    echo "  写入方式:    临时文件 → 原地覆盖（最稳）"
    ;;
  inplace)
    echo "  写入方式:    原地覆盖（省空间；截断会先释放 vmlinuz.$SLOT 自己的 "
    echo "               ${TSZ} KiB，够写 ${KSZ} KiB）"
    echo "              vmlinuz.$SLOT_OTHER 保持不动 —— 官方回退槽保住了"
    ;;
  dropother)
    echo "  写入方式:    删除另一个槽 vmlinuz.$SLOT_OTHER 腾空间（它的备份在"
    echo "               $BACKUP/vmlinuz.$SLOT_OTHER.orig，回滚时可用）"
    rm -f "$OTHER"
    sync
    AVAIL=$(df -k "$MNT" | awk 'NR==2{print $4}')
    echo "              删除后可用: ${AVAIL} KiB"
    ;;
esac

if [ "$MODE" = "dropother" ] || [ "$MODE" = "temp" ]; then
  cp -f "$KERNEL_IMG" "$MNT/syslinux/vmlinuz.new" || die "写入临时文件失败"
  sync
  cat "$MNT/syslinux/vmlinuz.new" > "$TARGET" || die "覆盖 $TARGET 失败"
  rm -f "$MNT/syslinux/vmlinuz.new"
else
  # FAT 上原地覆盖会先截断目标文件并释放空间。
  cat "$KERNEL_IMG" > "$TARGET" || die "覆盖 $TARGET 失败"
fi
sync

NEW_MD5=$(md5of "$TARGET")
[ "$NEW_MD5" = "$WANT_KMD5" ] || die "写入后 md5 不符（$NEW_MD5）—— ESP 可能已损坏，请用 $BK 恢复"
echo "  写入完成并校验: $NEW_MD5  OK"
echo "  (vmlinuz.$SLOT)"
umount "$MNT"; rmdir "$MNT"; trap - EXIT

say "5. 安装模块"
if ! touch /lib/modules/.wtest 2>/dev/null; then
  echo "  根文件系统只读，尝试重新挂载为可写..."
  mount -o remount,rw / 2>/dev/null || true
fi
if ! touch /lib/modules/.wtest 2>/dev/null; then
  echo
  echo "  ！！ 无法写入 /lib/modules —— 根文件系统是只读的（rootfs verification 开启）"
  echo
  echo "  请先关闭 rootfs 校验，二选一："
  echo "    A) 确认已进入开发者模式，然后运行："
  echo "         sudo /usr/share/vboot/bin/make_dev_ssd.sh --remove_rootfs_verification --partitions 2"
  echo "         sudo reboot"
  echo "       重启后再运行本脚本。"
  echo "    B) 进入 GRUB 菜单，选择不带 \"verified\" 的 \"FydeOS image A\" 启动，"
  echo "       然后再运行本脚本。"
  echo
  echo "    内核已写入 ESP。此时直接重启会启动带 KernelSU 的内核，"
  echo "    但模块仍是官方的 —— 显示/网络驱动可能加载异常。"
  echo "    建议先不重启，处理完只读问题后再跑一次本脚本。"
  echo
  echo "  如需立刻退回："
  echo "    sudo mkdir -p /tmp/e && sudo mount $ESP_DEV /tmp/e"
  echo "    sudo cp $BK /tmp/e/syslinux/vmlinuz.$SLOT && sudo umount /tmp/e && sync"
  exit 2
fi
rm -f /lib/modules/.wtest

# 先解包并校验 stateful 暂存区，再移入模块树，避免 rootfs 同时存放两份。
STAGE=${KSU_STAGE_DIR:-/mnt/stateful_partition/ksu-modules-staging}
UNPACKED_KB=$(tar -tvzf "$MODULES_TGZ" 2>/dev/null | awk '{s+=$3} END {print int(s/1024)}')
UNPACKED_KB=${UNPACKED_KB:-150000}
ROOT_AVAIL_KB=$(df -k / | awk 'NR==2{print $4}')
CUR_TREE_KB=0
[ -d "/lib/modules/$VER" ] && CUR_TREE_KB=$(du -sk "/lib/modules/$VER" 2>/dev/null | cut -f1)
CUR_TREE_KB=${CUR_TREE_KB:-0}

# 旧树会先移到 stateful，因此可用空间包含旧树腾出的空间。
EFFECTIVE_KB=$(( ROOT_AVAIL_KB + CUR_TREE_KB ))
echo "  模块树展开约: $(( UNPACKED_KB / 1024 )) MiB"
echo "  根分区可用:   $(( ROOT_AVAIL_KB / 1024 )) MiB"
echo "  旧树占用:     $(( CUR_TREE_KB / 1024 )) MiB（换入前会挪走）"
echo "  实际可达:     $(( EFFECTIVE_KB / 1024 )) MiB"

if [ "$EFFECTIVE_KB" -lt "$UNPACKED_KB" ]; then
  die "根分区放不下一份模块树（需约 $(( UNPACKED_KB / 1024 )) MiB，最多可达 $(( EFFECTIVE_KB / 1024 )) MiB）。
  请先清理 /lib/modules 下的 .orig-* 残留后重试：
    du -sh /lib/modules/*.orig-* 2>/dev/null
    sudo rm -rf /lib/modules/*.orig-*
  内核已写入 ESP（vmlinuz.$SLOT），模块未改动 —— 现在重启会用原厂模块，可以正常启动。"
fi

echo "  暂存目录:     $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE" || die "无法创建暂存目录 $STAGE"

echo "  解包到暂存区（不动 /lib/modules）..."
tar xzf "$MODULES_TGZ" -C "$STAGE" || die "解包到暂存区失败 —— /lib/modules 未改动，系统仍可用"

# 模块包内路径以 lib/modules/<ver>/ 开始。
STAGED="$STAGE/lib/modules/$VER"
[ -d "$STAGED" ] || die "暂存区里没有 lib/modules/$VER 目录 —— /lib/modules 未改动
  实际内容：$(ls "$STAGE" 2>/dev/null | head -5 | tr '\n' ' ')"
STAGED_KO=$(find "$STAGED" -name '*.ko' | wc -l)
echo "  暂存区模块数: $STAGED_KO"

MISSING=""
for m in $REQ_MODULES kernel/drivers/net/ethernet/intel/e1000/e1000.ko; do
  [ -f "$STAGED/$m" ] || MISSING="$MISSING $m"
done
[ -z "$MISSING" ] || die "暂存区缺少必需模块:$MISSING —— /lib/modules 未改动，系统仍可用"
echo "  必需模块:     全部在位"

# 删除指向构建机路径的悬空 build 符号链接。
[ -L "$STAGED/build" ] && { rm -f "$STAGED/build"; echo "  已移除悬空的 build 符号链接"; }

# 将旧树移到 stateful，换入失败时可恢复。
if [ -d "/lib/modules/$VER" ]; then
  (cd "/lib/modules/$VER" && find . | sort) > "$BACKUP/modules-orig-list.txt"
  echo "  已记录原模块清单 ($(wc -l < "$BACKUP/modules-orig-list.txt") 项)"
  PREV=$(find "/lib/modules/$VER" -name '*.ko' | wc -l)
  OLDSTASH="$STAGE/../ksu-modules-previous-$STAMP"
  rm -rf "$OLDSTASH"
  if mv "/lib/modules/$VER" "$OLDSTASH" 2>/dev/null; then
    echo "  原模块树已挪到 stateful（${PREV} 个 .ko）: $OLDSTASH"
  else
    warn "挪到 stateful 失败，改为直接删除（rootfs 放不下两份）"
    rm -rf "/lib/modules/$VER"
    OLDSTASH=""
  fi
  OLD_TREE_KO=$PREV
else
  echo "  ! /lib/modules/$VER 不存在 —— 直接安装"
  OLDSTASH=""
fi

if mv "$STAGED" "/lib/modules/$VER"; then
  echo "  新模块树已就位"
else
  # 还原
  if [ -n "$OLDSTASH" ] && [ -d "$OLDSTASH" ]; then
    warn "移入失败，正在还原原模块树..."
    mv "$OLDSTASH" "/lib/modules/$VER" && echo "  已还原"
  fi
  die "移入 /lib/modules/$VER 失败"
fi
# 暂存区还剩 lib/modules 空壳，一并清掉（OLDSTASH 在上一级，不受影响）
rm -rf "$STAGE"

INSTALLED=$(find "/lib/modules/$VER" -name '*.ko' | wc -l)
echo "  安装完成: $INSTALLED 个模块"
[ "$INSTALLED" -gt 500 ] || die "安装后模块数异常（$INSTALLED）"

echo "  depmod..."
depmod -a "$VER" 2>&1 | head -5
echo "  modules.dep: $(wc -l < "/lib/modules/$VER/modules.dep") 行"
echo "  根分区可用:  $(( $(df -k / | awk 'NR==2{print $4}') / 1024 )) MiB"

say "6. 结果校验"

say "6. 结果校验"
echo "  --- ESP ---"
mount "$ESP_DEV" "$MNT" 2>/dev/null && {
  echo "    引导槽 ($SLOT): vmlinuz.$SLOT md5: $(md5of "$MNT/syslinux/vmlinuz.$SLOT")"
  if [ -f "$MNT/syslinux/vmlinuz.$SLOT_OTHER" ]; then
    echo "    另一槽:        vmlinuz.$SLOT_OTHER 存在（官方回退，未改动）"
  else
    echo "    另一槽:        已删除（备份在 $BACKUP/vmlinuz.B.orig）"
  fi
  umount "$MNT"; rmdir "$MNT"
}
echo "  --- 模块 ---"
for m in i915 amdgpu radeon e1000; do
  f=$(find "/lib/modules/$VER" -name "$m.ko" 2>/dev/null | head -1)
  [ -n "$f" ] && echo "    $m.ko: $(modinfo -F vermagic "$f" 2>/dev/null)"
done
echo "    KernelSU: 内核内置 (CONFIG_KSU=y)，无独立模块"
echo "  --- firmware（不需要替换，仅确认在位）---"
for d in i915 amdgpu radeon; do
  [ -d "/lib/firmware/$d" ] && echo "    /lib/firmware/$d: $(find "/lib/firmware/$d" -type f | wc -l) 文件"
done

echo
echo "================================================================"
echo "  部署完成。请重启： sudo reboot"
echo
echo "  重启后验证（推荐直接跑仓库里的 verify.sh）："
echo "    uname -r                          # 应为 $VER"
echo "    dmesg | grep -i KernelSU          # 应见 KernelSU 初始化"
echo "    lsmod | grep -E 'i915|amdgpu'     # 显卡驱动应加载"
echo "    dmesg | grep -c 'Unknown symbol'  # 应为 0"
echo "    dmesg | grep -c 'Invalid relocation'  # 应为 0"
echo
echo "  回滚（如果需要）："
echo "    内核: mount $ESP_DEV /tmp/e && cp $BK /tmp/e/syslinux/vmlinuz.$SLOT && umount /tmp/e && sync"
echo "    模块: 原模块树在换入时已被删除（rootfs 放不下两份），"
echo "          需要时从官方镜像恢复，或用备份里的 modules-orig-list.txt 核对内容。"
echo "          备份目录: $BACKUP"
echo "================================================================"
