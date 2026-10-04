#!/bin/bash
# 在设备上验证部署结果。
# 用法：sudo bash verify.sh [iris|apu]
# 退出码：0 表示关键项通过；1 表示有失败项。

set -u

VARIANT="${1:-}"
VER="6.12.54-01180-gb4e10020ba49-dirty"
PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[1;32m[ OK ]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
meh()  { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
head_() { echo; printf '\033[1;36m=== %s ===\033[0m\n' "$*"; }

[ "$(id -u)" = "0" ] || { echo "请用 sudo 运行"; exit 1; }

head_ "0. 设备与内核版本"
echo "  发行版: $(grep -h CHROMEOS_RELEASE_DESCRIPTION /etc/lsb-release 2>/dev/null | cut -d= -f2- | tr -d '\"')"
REL="$(uname -r)"
echo "  uname -r : $REL"
echo "  uname -v : $(uname -v)"

if [ "$REL" = "$VER" ]; then
  ok "内核版本串正确"
else
  bad "内核版本串不符（期望 $VER）—— 内核可能没换成功，或换成了别的版本"
fi

head_ "1. 内核是带 EFI stub 的 bzImage"
ESP_DEV=""
for p in /dev/nvme0n1p12 /dev/sda12 /dev/mmcblk0p12 /dev/vda12; do
  [ -b "$p" ] && ESP_DEV="$p" && break
done
[ -n "$ESP_DEV" ] || ESP_DEV=$(blkid -t LABEL=EFI-SYSTEM -o device 2>/dev/null | head -1)

if [ -n "$ESP_DEV" ]; then
  MNT=$(mktemp -d /tmp/espv.XXXXXX)
  if mount "$ESP_DEV" "$MNT" 2>/dev/null; then
    echo "  ESP: $ESP_DEV"
    if [ -f "$MNT/syslinux/vmlinuz.A" ]; then
      echo "  vmlinuz.A: $(stat -c%s "$MNT/syslinux/vmlinuz.A") B  md5 $(md5sum "$MNT/syslinux/vmlinuz.A" | cut -d' ' -f1)"
      python3 - "$MNT/syslinux/vmlinuz.A" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(0x300)
mz  = d[:2] == b'MZ'
e   = struct.unpack_from('<I', d, 0x3C)[0]
pe  = d[e:e+4] == b'PE\x00\x00'
hdr = d.find(b'HdrS') == 0x202
boot= struct.unpack_from('<H', d, 0x1FE)[0] == 0xAA55
print("  MZ=%s PE=%s HdrS@0x202=%s boot_flag=%s" % (mz, pe, hdr, boot))
sys.exit(0 if (mz and pe and hdr and boot) else 1)
PY
      if [ $? -eq 0 ]; then ok "ESP 上的内核是合法的 bzImage + EFI stub"; else bad "ESP 上的内核格式不对"; fi
    else
      bad "$MNT/syslinux/vmlinuz.A 不存在"
    fi
    [ -f "$MNT/syslinux/vmlinuz.B" ] && echo "  vmlinuz.B: 存在（官方回退槽）" || echo "  vmlinuz.B: 不存在"
    umount "$MNT"
  else
    meh "无法挂载 ESP（$ESP_DEV）"
  fi
  rmdir "$MNT" 2>/dev/null
else
  meh "找不到 EFI-SYSTEM 分区，跳过 ESP 检查"
fi

head_ "2. 模块树"
if [ -d "/lib/modules/$VER" ]; then
  N=$(find "/lib/modules/$VER" -name '*.ko' | wc -l)
  echo "  /lib/modules/$VER: $N 个 .ko, $(du -sh "/lib/modules/$VER" | cut -f1)"
  case "$VARIANT" in
    iris) [ "$N" -ge 1180 ] && ok "模块数量正常（iris 期望 ~1190）" || bad "模块数量偏少（$N，期望 ~1190）" ;;
    apu)  [ "$N" -ge 1560 ] && ok "模块数量正常（apu 期望 ~1575）" || bad "模块数量偏少（$N，期望 ~1575）" ;;
    *)    [ "$N" -ge 1000 ] && ok "模块数量正常（$N）" || meh "模块数量偏少（$N）" ;;
  esac
  for m in e1000 i915 amdgpu radeon; do
    f=$(find "/lib/modules/$VER" -name "$m.ko" 2>/dev/null | head -1)
    if [ -n "$f" ]; then
      echo "  $m.ko: $(modinfo -F vermagic "$f" 2>/dev/null)"
    fi
  done
  [ -f "/lib/modules/$VER/kernel/drivers/net/ethernet/intel/e1000/e1000.ko" ] \
    && ok "e1000.ko 在位（网卡驱动）" || bad "e1000.ko 缺失 —— 重启后会失去网络"
  [ -e "/lib/modules/$VER/build" ] && meh "build 符号链接仍存在（指向构建机路径，无害但建议删除）"
else
  bad "/lib/modules/$VER 不存在"
fi

head_ "3. 内核日志：加载与符号"
IR=$(dmesg 2>/dev/null | grep -c 'Invalid relocation' || true)
UN=$(dmesg 2>/dev/null | grep -c 'Unknown symbol' || true)
echo "  'Invalid relocation' : $IR"
echo "  'Unknown symbol'     : $UN"
[ "$IR" -eq 0 ] && ok "无重定位错误（模块与内核同源）" || bad "有 $IR 条 Invalid relocation —— 模块与内核不是同一次构建"
[ "$UN" -eq 0 ] && ok "无未知符号" || bad "有 $UN 条 Unknown symbol"

head_ "4. KernelSU（内核侧）"
KS=$(dmesg 2>/dev/null | grep -c 'KernelSU' || true)
echo "  dmesg 中 'KernelSU' 行数: $KS"
[ "$KS" -gt 0 ] && ok "内核里有 KernelSU 日志" || bad "内核里没有 KernelSU 日志 —— CONFIG_KSU 可能没生效"

for pat in 'alt_syscall: dispatcher' 'alt slot' 'dispatcher installed'; do
  c=$(dmesg 2>/dev/null | grep -c "$pat" || true)
  echo "  '$pat': $c"
done

# CONFIG_KSU 是否真的编进了内核
if grep -q ' ksu_' /proc/kallsyms 2>/dev/null; then
  KSN=$(grep -c ' ksu_' /proc/kallsyms)
  ok "内核符号表里有 $KSN 个 ksu_* 符号（CONFIG_KSU=y 生效）"
else
  meh "/proc/kallsyms 里看不到 ksu_* 符号（KALLSYMS_ALL 关闭时数据符号不可见，属正常）"
fi

head_ "5. 显卡驱动"
case "$VARIANT" in
  iris) PAT='i915' ;;
  apu)  PAT='amdgpu|radeon' ;;
  *)    PAT='i915|amdgpu|radeon' ;;
esac
LOADED=$(lsmod | grep -E "$PAT" | awk '{print $1}' | tr '\n' ' ')
if [ -n "$LOADED" ]; then
  ok "已加载: $LOADED"
else
  bad "没有加载任何目标显卡驱动（$PAT）—— 检查 /lib/firmware 与 dmesg"
fi
for d in i915 amdgpu radeon; do
  [ -d "/lib/firmware/$d" ] && echo "  /lib/firmware/$d: $(find "/lib/firmware/$d" -type f | wc -l) 文件"
done

head_ "6. 网络（部署后最容易断的一环）"
IFACE=$(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2; exit}')
if [ -n "$IFACE" ]; then
  ok "网络接口 $IFACE: $(ip -o -4 addr show "$IFACE" | awk '{print $4}')"
else
  bad "没有任何非 lo 接口拿到 IPv4 地址 —— 网络可能已断"
fi

head_ "7. Android 容器（xt_quota2 netns 回归）"
IPID=$(pgrep -f '^/system/bin/init' | head -1)
if [ -n "$IPID" ]; then
  echo "  Android init pid: $IPID"
  OUT=$(nsenter -t "$IPID" -m -p -U --root -- /system/bin/ndc bandwidth setglobalalert 1073741824 2>&1 || true)
  echo "  ndc bandwidth setglobalalert: $OUT"
  case "$OUT" in
    *succeeeded*|*succeeded*) ok "xt_quota2 netns 正常（不会出现 114 秒重启循环）" ;;
    *) bad "ndc 调用失败 —— xt_quota2 的 netns 支持可能丢失，容器会周期性自杀重启" ;;
  esac
  BC=$(nsenter -t "$IPID" -m -p -U --root -- getprop sys.boot_completed 2>/dev/null | tr -d '\r')
  echo "  sys.boot_completed: ${BC:-<空>}"
  [ "$BC" = "1" ] && ok "Android 已启动完成" || meh "Android 尚未启动完成（约需 2-3 分钟，稍后再看）"
else
  meh "找不到 Android init 进程（容器可能未运行）"
fi

head_ "8. 授权名单"
if [ -e "/data/adb/ksu/.allowlist" ]; then
  SZ=$(stat -c%s /opt/google/containers/android/rootfs/android-data/data/adb/ksu/.allowlist 2>/dev/null || echo "?")
  echo "  .allowlist 大小: $SZ B"
  if [ "$SZ" = "0" ]; then
    bad ".allowlist 是 0 字节 —— 格式非法，会导致授权彻底失效。删掉它并重启"
  else
    ok ".allowlist 存在且非空"
  fi
else
  echo "  .allowlist: 尚未创建"
  echo "  （正常 —— 内核在第一次真实授权请求时才创建它。不要手动 touch）"
fi
if dmesg 2>/dev/null | grep -q 'save allow list'; then
  ok "内核日志里有 'save allow list' —— 授权写入成功过"
else
  meh "尚未看到 'save allow list'（还没授权过任何应用）"
fi

echo
echo "================================================================"
printf '  通过 %d 项，失败 %d 项，提示 %d 项\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then
  echo "  结论：关键项全部通过。"
else
  echo "  结论：有失败项，请按上面的 [FAIL] 逐条处理。"
fi
echo "================================================================"
[ "$FAIL" -eq 0 ] || exit 1
