#!/bin/bash
#
# 修复 ARC 启动竞态导致的 /data 未挂载和 APK 安装失败。
#
#   sudo bash install-arc-race-fix.sh            # 安装
#   sudo bash install-arc-race-fix.sh --status   # 查看状态
#   sudo bash install-arc-race-fix.sh --uninstall
#
# 修复 arc-boot-continue 早于容器 property service 就绪时引发的启动竞态。
# 直接补跑 arcbootcontinue 会跳过后续 arc-sdcard 初始化；本脚本改为等待后
# 执行原始完整命令。等待有上限，超时后仍继续启动。
#
set -u

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WAIT_SRC="$SRC_DIR/arc-boot-continue-wait.sh"

WAIT_DST=/usr/local/sbin/arc-boot-continue-wait.sh
CONF=/etc/init/arc-boot-continue.conf
BACKUP=/mnt/stateful_partition/arc-heal
LOG=/var/log/arc-boot-continue-wait.log

MODE="${1:-install}"

die() { echo "错误: $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || die "请用 sudo 运行"

get_ipid() { pgrep -f '^/system/bin/init' 2>/dev/null | head -1; }

status() {
  echo "=== ARC 启动竞态修复状态 ==="
  printf "  wrapper  %-42s %s\n" "$WAIT_DST" "$([ -x "$WAIT_DST" ] && echo 已安装 || echo 未安装)"
  printf "  已挂钩   %-42s %s\n" "$CONF" \
    "$(grep -q 'arc-boot-continue-wait.sh' "$CONF" 2>/dev/null && echo 是 || echo 否)"
  printf "  备份     %-42s %s\n" "$BACKUP" "$([ -d "$BACKUP" ] && echo 存在 || echo 无)"

  echo
  echo "--- 本次启动的实际效果 ---"
  local p n
  p=$(get_ipid)
  if [ -n "$p" ]; then
    printf "  arc-sdcard job            : %s\n" "$(initctl status arc-sdcard 2>/dev/null | awk '{print $2}')"
    n=$(nsenter -t "$p" -m -p -U --root -- ls /storage/emulated/0/ 2>/dev/null | wc -l)
    printf "  /storage/emulated/0 条目  : %s %s\n" "$n" "$([ "$n" -gt 3 ] && echo '(正常)' || echo '(异常 — 卷未挂载)')"
    printf "  /data 挂载                : %s\n" \
      "$(nsenter -t "$p" -m -p -U --root -- sh -c 'grep -q " /data " /proc/self/mountinfo && echo 是 || echo 否')"
    printf "  esdfs 挂载数              : %s\n" "$(mount | grep -c esdfs)"
    printf "  external_primary 错误     : %s 条\n" \
      "$(nsenter -t "$p" -m -p -U --root -- /system/bin/logcat -d -t 500 2>/dev/null | grep -c 'external_primary not found')"
  else
    echo "  Android 容器未运行"
  fi

  echo
  echo "--- wrapper 日志 ---"
  if [ -f "$LOG" ]; then tail -8 "$LOG"; else echo "  (无)"; fi
}

case "$MODE" in
  --status) status; exit 0 ;;
  --uninstall)
    mount -o remount,rw / 2>/dev/null
    if [ -f "$BACKUP/arc-boot-continue.conf.orig" ]; then
      cp -f "$BACKUP/arc-boot-continue.conf.orig" "$CONF"
      echo "已恢复原始 $CONF"
    else
      echo "!! 找不到原始备份，请手动把 exec 行改回：" >&2
      echo "   exec /sbin/minijail0 --config /usr/share/minijail/arc-boot-continue.conf \\" >&2
      echo "       -- /usr/sbin/arc-setup --mode=boot-continue \"--log_tag=\${UPSTART_JOB}\"" >&2
    fi
    rm -f "$WAIT_DST"
    echo "已移除 $WAIT_DST"
    echo "重启后生效。"
    exit 0 ;;
  install) ;;
  *) die "未知参数: $MODE（--status / --uninstall）" ;;
esac

echo "=== 安装 ARC 启动竞态修复 ==="

[ -f "$WAIT_SRC" ] || die "找不到 $WAIT_SRC（请在 fixes/ 目录下运行）"

echo
echo "--- 1. wrapper -> /usr/local/sbin （持久） ---"
# 确保目标目录存在；部分安装没有预建 /usr/local/sbin。
mkdir -p "$(dirname "$WAIT_DST")" || die "无法创建 $(dirname "$WAIT_DST")"
install -m 0755 "$WAIT_SRC" "$WAIT_DST"
sh -n "$WAIT_DST" && echo "  语法 OK" || die "语法错误"
ls -la "$WAIT_DST"

echo
echo "--- 2. 备份 + 挂钩 arc-boot-continue.conf ---"
mount -o remount,rw / 2>&1 || true
mkdir -p "$BACKUP"

if [ ! -f "$BACKUP/arc-boot-continue.conf.orig" ]; then
  cp -f "$CONF" "$BACKUP/arc-boot-continue.conf.orig"
  echo "  原始文件已备份 -> $BACKUP/arc-boot-continue.conf.orig"
fi

if grep -q 'arc-boot-continue-wait.sh' "$CONF"; then
  echo "  已经挂过钩，跳过"
else
  cp -f "$CONF" "$BACKUP/arc-boot-continue.conf.pre-patch"
  python3 - "$CONF" <<'PY' || die "改写 conf 失败"
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r'^exec\s+/sbin/minijail0.*$', s, re.M | re.S)
if not m:
    print("  找不到 exec 行"); sys.exit(1)
new = (
    'exec /usr/local/sbin/arc-boot-continue-wait.sh \\\n'
    '    /sbin/minijail0 --config /usr/share/minijail/arc-boot-continue.conf \\\n'
    '    -- /usr/sbin/arc-setup --mode=boot-continue "--log_tag=${UPSTART_JOB}"'
)
open(p, 'w').write(s[:m.start()] + new + "\n")
print("  已改写 exec 行")
PY
fi

echo "  --- 现在的 exec 块 ---"
tail -4 "$CONF" | sed 's/^/  /'

echo
echo "--- 3. 确认没有残留的旧版补丁 ---"
if [ -f /etc/init/arc-data-heal.conf ]; then
  echo "  ! 检测到 v1 补丁（arc-data-heal），正在移除 —— 它会导致安装 APK 失败"
  rm -f /etc/init/arc-data-heal.conf
fi
if [ -f /usr/local/sbin/arc-data-heal.sh ]; then
  mv -f /usr/local/sbin/arc-data-heal.sh "$BACKUP/arc-data-heal.sh.v1"
fi
echo "  v1 已清除"

echo
echo "================================================================"
echo "  安装完成。重启后生效。"
echo
echo "  重启后检查：  sudo bash install-arc-race-fix.sh --status"
echo "  卸载：        sudo bash install-arc-race-fix.sh --uninstall"
echo
echo "  判据（重启后）："
echo "    /storage/emulated/0 里有目录（不是空）"
echo "    mount | grep -c esdfs  应 >= 4"
echo "    装任意 APK 成功"
echo "================================================================"
