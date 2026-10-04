#!/bin/sh
# 等容器 property service 就绪后执行原始 arc-setup 命令。
# 必须执行完整命令，以继续启动后续的 arc-sdcard 步骤。
# 等待均有上限；超时后仍会执行原始命令。
set -u

LOG=/var/log/arc-boot-continue-wait.log
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# 限制日志文件大小。
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 400 ]; then
  tail -150 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log "=== wait start (pid $$) ==="

# 等待容器 init，最多 3 分钟。
IPID=""
i=0
while [ "$i" -lt 90 ]; do
  IPID=$(pgrep -f '^/system/bin/init' 2>/dev/null | head -1)
  [ -n "$IPID" ] && break
  i=$((i + 1))
  sleep 2
done

if [ -z "$IPID" ]; then
  log "WARN: android init not seen after $((i * 2))s; running command anyway"
else
  log "android init pid=$IPID (after $((i * 2))s)"

  # 等待容器内 getprop 可用，确认属性服务已就绪。
  ready=0
  j=0
  while [ "$j" -lt 120 ]; do
    if nsenter -t "$IPID" -m -p -U --root -- \
         /system/bin/getprop ro.build.version.sdk 2>/dev/null \
         | grep -qE '^[0-9]+$'; then
      ready=1
      break
    fi
    j=$((j + 1))
    sleep 1
  done

  if [ "$ready" = 1 ]; then
    log "property service ready (after $((j + i * 2))s total)"
  else
    log "WARN: property service not confirmed after $((j + i * 2))s; continuing"
  fi
fi

# 执行完整的原始命令。
log "exec: $*"
exec "$@"
