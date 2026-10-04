#!/bin/bash
# 当前交付内核已包含 alt-syscall 适配；使用 --uninstall 移除旧修复，避免重复触发。
# 内核适配说明见 BUILD.md 第 4.5 节。
#
# 用法：
#   sudo bash install-metadata-fix.sh --status
#   sudo bash install-metadata-fix.sh --uninstall       # 只撤 rc 触发（推荐）
#   sudo bash install-metadata-fix.sh --install --reboot
#   sudo bash install-metadata-fix.sh --uninstall-all   # 连 /metadata 一起撤
# 无参数时执行安装；变更在重启后生效。
# /metadata 使用 stateful 持久目录，属主按容器 UID/GID 映射设置。
set -u

CONFIG=/opt/google/containers/android/config.json
ROOTFS=/opt/google/containers/android/rootfs/root
INITRC="$ROOTFS/init.cheets.rc"
SRC=/mnt/stateful_partition/arc-metadata
BACKUP=/mnt/stateful_partition/arc-heal
DEST=/metadata
KSUSNIP="ksud post-fs-data"

# 默认宿主 UID/GID，由容器 init 的 uid_map 和 gid_map 更新。
CUID=655360
CGID=655360

MODE="${1:-install}"
REBOOT=0
for a in "$@"; do [ "$a" = "--reboot" ] && REBOOT=1; done

die() { echo "错误: $*" >&2; exit 1; }
[ "$(id -u)" = "0" ] || die "请用 sudo 运行"

get_ipid() { pgrep -f '^/system/bin/init' 2>/dev/null | head -1; }

detect_cuid() {
  local p m
  p=$(get_ipid); [ -n "$p" ] || return
  m=$(awk '$1==0 {print $2; exit}' "/proc/$p/uid_map" 2>/dev/null); [ -n "${m:-}" ] && CUID="$m"
  m=$(awk '$1==0 {print $2; exit}' "/proc/$p/gid_map" 2>/dev/null); [ -n "${m:-}" ] && CGID="$m"
}

# 检查 /metadata 挂载：0 已配置，1 未配置，2 配置不可读。
config_has_meta() {
  python3 - "$CONFIG" "$DEST" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(2)
sys.exit(0 if any(m.get("destination") == sys.argv[2] for m in d.get("mounts", [])) else 1)
PY
}

# 检查 init.cheets.rc 中的触发命令。
rc_has_hook() { [ -f "$INITRC" ] && grep -qF "$KSUSNIP" "$INITRC"; }

need_rw_root() {
  if ! touch "$(dirname "$CONFIG")/.wtest" 2>/dev/null; then
    echo "  $(dirname "$CONFIG") 只读，remount rw ..."
    mount -o remount,rw / 2>&1 || die "无法把 / 重新挂载为可写"
  fi
  touch "$(dirname "$CONFIG")/.wtest" 2>/dev/null || die "$(dirname "$CONFIG") 仍不可写"
  rm -f "$(dirname "$CONFIG")/.wtest"
}

status() {
  detect_cuid
  local p
  echo "=== ARC 旧变通改动 — 状态 ==="
  echo "  （本脚本已过时：新内核下真正起作用的是 KernelSU 自己的 read-proxy 注入）"
  echo "  容器 uid 0 对应宿主 uid : $CUID"
  echo
  echo "  --- ① /metadata 挂载（应当保留）---"
  printf "    config.json 里的挂载   : %s\n" \
    "$(config_has_meta && echo '已添加 ✓' || echo '未添加')"
  printf "    持久源目录 %s : %s\n" "$SRC" \
    "$([ -d "$SRC" ] && stat -c '%u:%g %A' "$SRC" || echo 不存在)"
  printf "    容器根挂载点 %s : %s\n" "$ROOTFS$DEST" \
    "$([ -d "$ROOTFS$DEST" ] && stat -c '%u:%g %A' "$ROOTFS$DEST" || echo 不存在)"
  echo "    说明: Android 的 init.rc 需要 /metadata（restorecon_recursive、"
  echo "          mkdir /metadata/vold …），KernelSU 也往 /metadata/watchdog/ksu 写。"
  echo "          **不要**为「清理」把它删掉，除非用 --uninstall-all 明确确认。"
  echo
  echo "  --- ② 多余的 rc 触发（应当**不在**）---"
  printf "    init.cheets.rc 里        : %s\n" \
    "$(rc_has_hook && echo '仍在 ✗（建议 --uninstall）' || echo '已撤 ✓')"
  printf "    %s : %s\n" "$ROOTFS/system/etc/init/00-ksud-post-fs-data.rc" \
    "$([ -f "$ROOTFS/system/etc/init/00-ksud-post-fs-data.rc" ] && echo '仍在 ✗' || echo '已撤 ✓')"
  echo "    说明: 这两条从未真正生效过；撤前撤后 PostFsData 都是 2 次。"

  p=$(get_ipid)
  [ -n "$p" ] || { echo; echo "  (容器未运行，跳过实况检查)"; return; }
  echo
  echo "  --- 容器内实况 ---"
  nsenter -t "$p" -m -p -U --root -- sh -c '
    printf "    /metadata 可写       : "; touch /metadata/.wtest 2>/dev/null && { echo 是; rm -f /metadata/.wtest; } || echo 否
    printf "    modules_update 空    : %s  （应为「是」）\n" "$([ -z "$(ls -A /data/adb/modules_update/ 2>/dev/null)" ] && echo 是 || echo 否)"
    printf "    boot 后 PostFsData   : %s 次  （2 次属正常，见 USER-MANUAL 10.2）\n" "$(grep -ac "command: PostFsData" /data/adb/ksu/log/logcat.log 2>/dev/null)"
    printf "    UAPI 错误            : %s 次  （应为 0）\n" "$(grep -ac "UAPI version mismatch" /data/adb/ksu/log/logcat.log 2>/dev/null)"
    echo "    --- 模块 ---"
    /data/adb/ksu/ksud module list 2>/dev/null | grep -E "\"id\"|\"mount\"|\"enabled\"" | sed "s/^/    /"
  ' 2>/dev/null
}

case "$MODE" in
  --status) status; exit 0 ;;

  --uninstall)
    # 只撤**重复的 rc 触发**，保留 /metadata 挂载。
    #
    # 为什么不连 /metadata 一起删：
    #   Android 自己的 init.rc 就要求 /metadata 存在
    #     restorecon_recursive /metadata
    #     mkdir /metadata/vold /metadata/password_slots /metadata/bootstat …
    #   KernelSU 也往 /metadata/watchdog/ksu 写模块 rc。
    #   实测容器里 /metadata 下有 Android 建的一整套目录，删掉是净损失。
    #
    # 为什么要撤 rc 触发：
    #   新内核上 KernelSU 自己的 read-proxy 注入已经能触发
    #   `ksud post-fs-data`，这两条触发是多余的死代码
    #   —— 实测撤前撤后 post-fs-data 都是跑 2 次，它们从未真正生效过。
    #
    # 确实想连 /metadata 一起撤，用 --uninstall-all。
    need_rw_root
    mkdir -p "$BACKUP"

    if rc_has_hook; then
      cp -f "$INITRC" "$BACKUP/init.cheets.rc.before-uninstall-$(date +%Y%m%d-%H%M%S)"
      python3 - "$INITRC" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8", errors="replace").read().splitlines(True)
out, i = [], 0
while i < len(lines):
    if lines[i].startswith("# --- KernelSU: 触发 post-fs-data ---"):
        break
    out.append(lines[i]); i += 1
open(p, "w", encoding="utf-8").writelines(out)
print("  已移除 init.cheets.rc 里的 KernelSU 触发（截掉 %d 行）" % (len(lines) - len(out)))
PY
    else
      echo "  init.cheets.rc 里没有本脚本加的触发，跳过"
    fi

    # 本脚本另一处遗留：/system/etc/init/00-ksud-post-fs-data.rc
    INITRC2="$ROOTFS/system/etc/init/00-ksud-post-fs-data.rc"
    if [ -f "$INITRC2" ]; then
      cp -f "$INITRC2" "$BACKUP/00-ksud-post-fs-data.rc.orig"
      rm -f "$INITRC2"
      echo "  已删除 $INITRC2（备份在 $BACKUP/）"
    else
      echo "  $INITRC2 不在，跳过"
    fi

    echo
    echo "  /metadata 挂载**保留**（Android 与 KernelSU 都要用）。"
    echo "  重启后生效；重启后 PostFsData 仍会是 2 次 —— 那是 KernelSU"
    echo "  自身的两条触发路径，与本脚本无关。"
    exit 0 ;;

  --uninstall-all)
    # 连 /metadata 挂载一起撤。只在确认环境不需要 /metadata 时才用。
    need_rw_root
    mkdir -p "$BACKUP"
    if config_has_meta; then
      cp -f "$CONFIG" "$BACKUP/config.json.before-uninstall-$(date +%Y%m%d-%H%M%S)"
      python3 - "$CONFIG" "$DEST" <<'PY' || die "改写失败"
import json, sys, os
p, dest = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["mounts"] = [m for m in d.get("mounts", []) if m.get("destination") != dest]
tmp = p + ".new"
open(tmp, "w").write(json.dumps(d, ensure_ascii=False, indent=2))
json.load(open(tmp))
os.replace(tmp, p)
PY
      echo "  已从 config.json 移除 $DEST 挂载"
    else
      echo "  config.json 里本来就没有 $DEST 挂载，跳过"
    fi
    echo
    echo "  ! 注意：Android 的 init.rc 期望 /metadata 存在，撤掉后"
    echo "    restorecon_recursive /metadata 等命令会失败（不影响启动）。"
    echo "  持久目录 $SRC 保留未删，需要清理请手动 rm -rf。"
    echo "  重启后生效。"
    exit 0 ;;

  install|--install) ;;
  *) die "未知参数: $MODE（--status / --uninstall / --uninstall-all / --install）" ;;
esac

echo "=== 安装 ARC KernelSU 模块激活修复 ==="
detect_cuid
echo "  容器 uid 0 对应宿主 uid: $CUID"
[ -f "$CONFIG" ] || die "找不到 $CONFIG —— 这台机器可能不是 ARC 布局"
[ -f "$INITRC" ] || die "找不到 $INITRC —— 这台机器可能不是 FydeOS 布局"

# 配置持久 /metadata 挂载。
echo
echo "############ ① /metadata 挂载 ############"

echo "--- 1.1 持久源目录 ---"
mkdir -p "$SRC" || die "无法创建 $SRC"
chown -R "$CUID:$CGID" "$SRC" || die "chown 失败（$CUID:$CGID）"
chmod 0700 "$SRC"
ls -ld "$SRC"

echo
echo "--- 1.2 容器根上的挂载点 ---"
if [ -d "$ROOTFS$DEST" ]; then
  echo "  已存在: $ROOTFS$DEST"
else
  mkdir -p "$ROOTFS$DEST" || die "无法创建挂载点 $ROOTFS$DEST"
  echo "  已创建: $ROOTFS$DEST"
fi
chown "$CUID:$CGID" "$ROOTFS$DEST" || die "chown 挂载点失败"
chmod 0700 "$ROOTFS$DEST"
ls -ld "$ROOTFS$DEST"

echo
echo "--- 1.3 写 config.json ---"
need_rw_root
echo "  可写 ✓"
mkdir -p "$BACKUP"
BK="$BACKUP/config.json.orig-$(date +%Y%m%d-%H%M%S)"
cp -f "$CONFIG" "$BK"; echo "  已备份 -> $BK"
[ -f "$BACKUP/config.json.bak" ] || { cp -f "$CONFIG" "$BACKUP/config.json.bak"; echo "  长期备份 -> $BACKUP/config.json.bak"; }

if config_has_meta; then
  echo "  已经挂过 $DEST，跳过"
else
  python3 - "$CONFIG" "$DEST" "$SRC" <<'PY' || die "改写 config.json 失败 —— 原文件已备份在 $BK"
import json, sys, os
p, dest, src = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
d.setdefault("mounts", []).append({
    "destination": dest, "type": "bind", "source": src, "options": ["bind"],
})
tmp = p + ".new"
open(tmp, "w").write(json.dumps(d, ensure_ascii=False, indent=2))
chk = json.load(open(tmp))
assert any(m.get("destination") == dest for m in chk.get("mounts", [])), "条目未写入"
os.replace(tmp, p)
print("  已追加: %s -> %s" % (dest, src))
PY
fi

echo
echo "--- 1.4 校验 JSON（非法会导致容器起不来）---"
python3 -c "import json;d=json.load(open('$CONFIG'));print('  JSON 合法，挂载点 %d 个' % len(d.get('mounts',[])))" \
  || { cp -f "$BK" "$CONFIG"; die "校验失败，已回滚"; }

# 添加 init.cheets.rc 触发命令。
echo
echo "############ ② init.cheets.rc 触发钩子 ############"
if rc_has_hook; then
  echo "  已有钩子，跳过"
else
  cp -f "$INITRC" "$BACKUP/init.cheets.rc.orig"
  echo "  已备份 -> $BACKUP/init.cheets.rc.orig"
  cat >> "$INITRC" <<EOF

# --- KernelSU: 触发 post-fs-data ---
# 本内核的 KernelSU 靠注入 rc 来触发 \`ksud post-fs-data\`，但 ARC 容器里
# 没有 /metadata、且容器 init 只 import 固定路径，注入的 rc 无人读取，
# 模块会永远停在 /data/adb/modules_update/。
# 这里直接在容器 init 里加一条显式触发。init.rc 第 9 行
# \`import /init.\${ro.hardware}.rc\`（ro.hardware=cheets）会自动加载本文件。
on post-fs-data
    exec - root root -- /data/adb/ksud post-fs-data
EOF
  echo "  已追加触发条目"
fi
echo
echo "  --- 钩子现状 ---"
grep -n -A1 'on post-fs-data' "$INITRC" | tail -4
ls -la "$INITRC"

# 清理 ZygiskNext 禁用标记。
echo
echo "############ ③ 清理 ZygiskNext 自禁用标记（如果还在） ############"
P=$(get_ipid)
if [ -n "$P" ]; then
  nsenter -t "$P" -m -p -U --root -- sh -c '
    f=/data/adb/modules/zygisksu/disable
    if [ -f "$f" ]; then rm -f "$f"; echo "  已移除 $f"; else echo "  无该标记"; fi
  ' 2>/dev/null
else
  echo "  容器未运行，跳过"
fi

cat <<EOF

================================================================
  安装完成（① /metadata 挂载 + ② init rc 触发钩子）。

  生效需要重启：
      sudo reboot

  重启后检查：
      sudo bash install-metadata-fix.sh --status

  期望：
      /metadata 可写                     = 是
      modules_update 空                  = 是
      boot 后 PostFsData 次数            >= 1

  若模块的 "mount" 仍为 false、或 Zygisk 类模块（LSPosed/ZygiskNext）
  的 daemon 起不来 —— 那是内核构建层面的遗留问题，见脚本头部说明，
  本脚本不解决。

  回滚：
      sudo bash install-metadata-fix.sh --uninstall       # 只撤 rc 触发（推荐） && sudo reboot
================================================================
EOF

if [ "$REBOOT" = 1 ]; then
  echo "  按 --reboot 要求，5 秒后重启..."
  sync; sleep 5; reboot
fi
