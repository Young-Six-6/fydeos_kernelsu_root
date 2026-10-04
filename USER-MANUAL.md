# FydeOS for PC + KernelSU 用户手册（iris / apu）

> 测试内核：**FydeOS for PC v23.0-SP1**（内核 `6.12.54-01180-gb4e10020ba49-dirty`）

---

## 1. 这是什么

一个**内置 KernelSU 的 FydeOS 内核**，用于替换官方 FydeOS for PC 的内核，
从而在设备上获得 root

| 项 | 说明 |
|---|---|
| 版本 | `6.12.54-01180-gb4e10020ba49-dirty` |
| vermagic | `6.12.54-01180-gb4e10020ba49-dirty SMP preempt mod_unload` |
| 内核格式 | 带 EFI stub 的 bzImage |
| 模块 | 有 |

> ### 须知
>
> 你必须了解每一条命令意图，逐条粘贴很可能失败
>
> 你自愿 放弃数据安全性 或 你有备份
>
> **iris 内核已在真机上启动并通过验证**
>
> **apu 尚未在真机上验证**但是和iris应该区别不大

---

## 2. 项目结构

### 2.1 文件清单

```
fydeos-ksu/
├── README.md                    交付总览
├── USER-MANUAL.md               本文档
├── BUILD.md                     构建流程
├── FIDELITY.md                  对比报告
├── deploy.sh                    部署脚本
├── verify.sh                    部署后验证脚本
├── MD5SUMS / SHA256SUMS         校验清单
├── config-iris.txt              从 iris 产物里提取出的构建配置
├── config-apu.txt               从 apu 产物里提取出的构建配置
├── config-official-iris.txt     官方 iris 的配置
├── config-official-apu.txt      官方 apu 的配置
├── tools/
│   ├── inspect-artifact.py      离线核验脚本
│   ├── config-diff.py           配置 vs 官方差异统计
│   └── check-links.py           文档链接自检
├── fixes/                       补丁
│   ├── install-arc-race-fix.sh  子系统启动竞态修复 / 安装 / 卸载
│   ├── install-metadata-fix.sh  【已过时】旧内核的 /metadata 变通
│   └── arc-boot-continue-wait.sh 包装脚本本体
├── iris/
│   ├── vmlinuz.A                    13,456,384 B
│   └── modules-iris.tar.gz          33,369,701 B
└── apu/
    ├── vmlinuz.A                    15,102,976 B
    └── modules-apu.tar.gz           41,597,536 B
```

### 2.2 校验值

**iris（现代 Intel）**

| 文件 | 大小 (B) | md5 | sha256 |
|---|---|---|---|
| `iris/vmlinuz.A` | 13,456,384 | `7349572f53dd3c9f7b852a29816fb1dc` | `8a012544dc788c88ad813f1c8d397de75ba4ec8558653a9674b15b65226db014` |
| `iris/modules-iris.tar.gz` | 33,369,701 | `f4a6760dc29f5aeb00eedeeb3c959e98` | `d5a1f912ea6760041c88db87da415a896a0510df692a2eb75e4aa5d0d7c4456f` |

**apu（AMD 显卡）**

| 文件 | 大小 (B) | md5 | sha256 |
|---|---|---|---|
| `apu/vmlinuz.A` | 15,102,976 | `9ea04b3dce1de20feb0754fd962dc629` | `35615c4a0b8ea4c087ef3f1333b00e7e3520a426bc25b0bb5be76c217a8dba71` |
| `apu/modules-apu.tar.gz` | 41,597,536 | `a24ab5afa75555adec4e73d03e10e91e` | `d687ee0325d84a2c5bc460765cc9215b2b3b3521a0a9e809d41621a2890b85f0` |

### 2.3 校验

**方式一：校验**

```bash
md5sum -c MD5SUMS        # Linux / FydeOS
sha256sum -c SHA256SUMS
```

```powershell
Get-FileHash -Algorithm MD5 .\iris\vmlinuz.A   # Windows
```

**方式二：核验脚本**

```bash
python tools/inspect-artifact.py iris
python tools/inspect-artifact.py apu
```
或

```bash
python tools/inspect-artifact.py iris --config-out my-config.txt
```

**方式三：检测 KernelSU**

```bash
python tools/inspect-artifact.py iris | grep -i kernelSU
```

---

## 3. 安装前

### 3.1 设备与系统

| 检查项 | 要求 | 查 |
|---|---|---|
| 系统推荐 | FydeOS for PC v23.0-SP1 | 设置 → 关于|
| 内核基线 | `6.12.54-01180-gb4e10020ba49-dirty` | `uname -r` |
| 开发者模式 | 已开启 | `sudo -i` 能用 |
| 根分区验证 | 已关闭 | 必须 |
| 磁盘空间 | ESP 至少 15 MiB 可用 | 见 3.3 |

### 3.2 确认内核一致

```bash
uname -r
```

### 3.3 ESP 空间与布局

需要能放下新的 `vmlinuz.A`。iris 约 12.3 MiB、apu 约 13.9 MiB。

大概率放不下，按需舍弃B槽位

`deploy.sh` 会自动识别ESP分区，失败请手动替换kernel和模块
`--dry-run` 会向用户打印其找到的ESP用于确认。

**槽位自动识别。** 空间不够不会删错，
也可以手动指定：（危险）

```bash
sudo bash deploy.sh iris ./vmlinuz.A ./modules-iris.tar.gz --slot=B
```

空间不够时的处理是**先备份、只删另一个槽**，
够用是原地覆盖

### 3.4 确认根文件系统可写，并留够模块空间

```bash
touch /lib/modules/.wtest && echo "可写" && rm -f /lib/modules/.wtest
df -h /
```

> ### 关于模块放不下
>
> FydeOS 的 `ROOT-A` 只有 **2.7 GiB**，日常已用掉约 2.6 GiB。
> 模块树展开约 **142 MiB**，而**旧 + 新 = 约 277 MiB** ——
> 根分区**放不下两份**。
> 脚本会**解到 stateful 暂存 → 校验 → 换入**。旧模块挪到
> `/mnt/stateful_partition/`（备份），换入失败能还原。
>
> 如果 `--dry-run` 报"根分区放不下一份模块树"，先清理残留：
>
> ```bash
> du -sh /lib/modules/*.orig-* 2>/dev/null
> sudo rm -rf /lib/modules/*.orig-*
> ```
>
> **注意**：更换模块需要 `可用 + 旧树占用 ≥ 142 MiB`，脚本会算这一项——

### 3.5 准备救援

使用前确保你能救援

---

## 4. 安装

### 4.1 传输

`deploy.sh`、对应的 `vmlinuz.A`、对应的 `modules-*.tar.gz`。

放进持久目录，**不要放 `/tmp`**（`/tmp` 是 tmpfs，重启即清空）：

```bash
mkdir -p ~/Downloads/ksu
cd ~/Downloads/ksu && ls -la
```

这里更推荐/home/user/HASHxxxxxxxxxxxx/MyFiles/Downloads/

不推荐放在root的home

### 4.2 预检

```bash
sudo bash deploy.sh iris ./vmlinuz.A ./modules-iris.tar.gz --dry-run
```

- ESP 探测
- 槽位判定
- ESP 空间核算
- **模块安装空间核算**

最后打印"dry-run 结束 … 均正常"才算全过。任何一项不够都会明确报出来并 `exit 1`。

### 4.3 正式安装

```bash
sudo bash deploy.sh iris ./vmlinuz.A ./modules-iris.tar.gz
```

把 `iris` 换成 `apu` 就是 AMD 版本。

**全程约 1–2 分钟**

### 4.4 重启

```bash
sudo reboot
```

---

## 5. 安装后验证

### 5.1 一条命令跑完全部检查

```bash
sudo bash verify.sh iris      # 或 apu
```

### 5.2 手动

```bash
uname -r                                  # 6.12.54-01180-gb4e10020ba49-dirty
dmesg | grep -c 'Invalid relocation'      # 应该是 0
dmesg | grep -c 'Unknown symbol'          # 0
```

### 5.2.1 确认 ARC 适配

`verify.sh` 的第 4b 节会检查这四项，手动核对如下：

```bash
sudo dmesg | grep -c 'blocked syscall 169'          # 0
sudo dmesg | grep -o "direct-hook table='[a-z_]*'"  # 'android'
sudo dmesg | grep 'read init.rc'                    # 有输出
grep -cw static_calls_table /proc/kallsyms          # 1
```

### 5.3 确认 KernelSU 

```bash
dmesg | grep -i kernelSU
```

期望：

```
KernelSU: alt_syscall: dispatcher -> 'complete_permissive'[134]
KernelSU: alt_syscall: dispatcher -> 'android'[134]
...
KernelSU: dispatcher installed at alt slot 134
KernelSU: on_post_fs_data!
KernelSU: Crowning manager: me.weishu.kernelsu(uid=10054)
```

### 5.4 确认显卡驱动

```bash
lsmod | grep -E 'i915|amdgpu|radeon'
```

如果显卡驱动没加载，确认固件：

```bash
ls /lib/firmware/i915 | head            # iris
ls /lib/firmware/amdgpu | head          # apu
```

**固件不需要替换**

---

## 6. 补齐 KernelSU 的用户态部分

> | 组件 | 位置 | 作用 |
> |---|---|---|
> | 内核hook | `vmlinuz.A`（`CONFIG_KSU=y`） | 内核部分 |
> | `ksud` | `/data/adb/ksu/ksud` | 用户态部分 |
> | Manager APK | `me.weishu.kernelsu` | 可选交互 |
>
> **FydeOS 上需要手动补ksud`** 

### 6.1 安装 Manager APK

从 <https://github.com/tiann/KernelSU/releases> 下载
`KernelSU_v3.3.0_32601-release.apk`，在 FydeOS 里安装

### 6.2 补 `ksud`

`ksud` 在 APK 里，x86_64 版本约 4.9 MB。

> ### 注意
> **1：容器里没有 `/tmp`。**
> **必须用 `/data/local/tmp`** —— 它在两边是同一个位置。
>
> **2：不要在宿主机侧 `cp`**
> **`cp` 这一步必须在 `nsenter` 里面做。**
>
> **子目录要先建好**（`bin`/`lib`/`modules`）。

```bash
# ⓪ 先定位 APK
HASH=$(ls -d /home/user/*/ | head -1 | xargs -n1 basename)
APK=/home/user/$HASH/MyFiles/Downloads/KernelSU_v3.3.0_32601-release.apk
ls -la "$APK" || echo "路径不对，先确认 APK 放哪了"

IPID=$(pgrep -f '^/system/bin/init' | head -1)
echo "IPID=[$IPID]"
[ -n "$IPID" ] || { echo "!! 找不到 android init —— 容器没起来，先处理这个"; }
AD=/opt/google/containers/android/rootfs/android-data/data

# ① 解包
rm -rf /tmp/ksua && mkdir -p /tmp/ksua && cd /tmp/ksua
unzip -o -q "$APK" 'lib/*'
chmod 644 lib/x86_64/libksud.so
ls -la lib/x86_64/libksud.so        # 应约 4941416 字节

# ② 投递到容器能看到的位置
cp lib/x86_64/libksud.so "$AD/local/tmp/ksud"
chmod 755 "$AD/local/tmp/ksud"
nsenter -t "$IPID" -m -p -U --root -- ls -la /data/local/tmp/ksud
```

# ③ 装进容器。

```bash
IPID=$(pgrep -f '^/system/bin/init' | head -1); echo "IPID=[$IPID]"; [ -n "$IPID" ] || exit 1
nsenter -t "$IPID" -m -p -U --root -- /system/bin/sh -c 'mkdir -p /data/adb/ksu/bin /data/adb/ksu/lib /data/adb/ksu/modules; cp /data/local/tmp/ksud /data/adb/ksu/ksud; cp /data/local/tmp/ksud /data/adb/ksud; chmod 755 /data/adb/ksu/ksud /data/adb/ksud; /data/adb/ksu/ksud --version; /data/adb/ksu/ksud install; /data/adb/ksu/ksud post-fs-data; ls -la /data/adb/ksu/bin/'
```

#### 常见错误

| 报错 | 含义 | 解决 |
|---|---|---|
| `nsenter: not integer:` | **`$IPID` 是空的** | 先执行 `IPID=$(pgrep -f '^/system/bin/init' \| head -1)`，并 `echo` 确认非空 |
| 提示符变成 `>` | 引号没闭合，shell 在等你补完 | 按 `Ctrl-C` 退出 |
| `unzip: cannot find ... /root/...` | `~` 在 root shell 里是 `/root` | 用绝对路径（见 ⓪） |
| `Permission denied` / 属主是 `overflowuid` | 在宿主机侧 `cp` 了 | 所有针对 `/data/adb` 的操作都必须在 `nsenter` 里做 |

成功后 `bin/` 里会有 `busybox`、`ksud`、`resetprop` 三项，
并且 `/data/adb/ksud` 与 `/data/adb/ksu/ksud` **两个文件都要在**
（`bin/ksud` 是指向 `/data/adb/ksud` 的软链接）。

### 6.3 重启一次

```bash
sudo reboot
```

> 重启后如果 `ls /data/adb/ksu/.allowlist` 报 `Invalid argument`，
> 这是**正常的** —— 表示文件还不存在，内核会在第一次真实授权请求时才创建它。
>
> Android 容器启动较慢。但是如果太长时间不成功请看故障排查（很有可能首次不成功）

---

## 7. 使用

### 7.1 授权

重启后打开 **KernelSU** App：

- 状态栏显示 **「工作中」** = 安装成功

### 7.2 常用命令

```bash
sudo dmesg | grep 'sys_execve su found'

# ksud 版本
IPID=$(pgrep -f '^/system/bin/init' | head -1)
sudo nsenter -t $IPID -m -p -U --root -- /system/bin/sh -c '/data/adb/ksu/ksud --version'

# Manager 是否被内核认出来
sudo dmesg | grep -E 'Crowning manager|open ksud'

# 一键检查
sudo bash verify.sh iris
```

### 7.3 推荐模块（未经推荐的版本可能有问题）

| 模块 | 版本 | 作用 |
|---|---|---|
| ZygiskNext | `1.5.0 (843-5217106-release)` | 提供 Zygisk 实现 |
| LSPosed | **`v1.9.2 (7024)`** | Xposed 框架 |

> **LSPosed 不要用 2.0.x**  会闪退

装完之后的状态：

```bash
IPID=$(pgrep -f '^/system/bin/init' | head -1)
sudo nsenter -t $IPID -m -p -U --root -- ps -A | grep -aiE 'lspd|zygiskd|lsposed'
```

应看到 `lspd`、`zygiskd64-zygisk_lsposed`、`zygiskd32-zygisk_lsposed`、
`org.lsposed.manager` 四类进程。

### 7.4 错误示范 

| 不要做 | 后果 |
|---|---|
| **只换内核不换模块** | 严重 |
| **在宿主机侧 `cp` 到 `/data/adb`** | ksud install` 会失败 |
| **在 root shell 里用 `~/MyFiles/...`** | `~` 是 `/root`，找不到文件 |

---

## 8. 补丁：子系统启动修复

**这一节是必读的。** 装完内核后，Android 子系统大概率卡在启动中。

### 8.1 症状

换完内核重启后，出现下面**任意一条**：

| 症状 | 表现 |
|---|---|
| **A. 子系统卡启动页** | 卡在启动页；`zygote` / `system_server` 不存在 |
| **B. 装任意 APK 都失败** | 「解析安装包失败」/ `InstallStaging: EACCES` |

排除内核问题：

```bash
uname -v                                                  # 应是我们构建的日期
sudo dmesg | grep -c 'Invalid relocation'                 # 应为 0
sudo dmesg | grep -c 'Unknown symbol'                     # 应为 0

IPID=$(pgrep -f '^/system/bin/init' | head -1)
# ① /data 挂在状态
sudo nsenter -t $IPID -m -p -U --root -- sh -c 'grep -q " /data " /proc/self/mountinfo && echo "data OK" || echo "data MISSING"'
# ② external_primary 卷
sudo nsenter -t $IPID -m -p -U --root -- ls /storage/emulated/0/ | head
# ③ 主机侧 esdfs 挂载数（正常 >= 4）
mount | grep -c esdfs
```

内核指标全 0 而这三条里任何一条异常就是本问题。

### 8.2 解释

host 的 upstart job `arc-boot-continue` 会在容器 init 的 property service
就绪之前调用 `/system/bin/arcbootcontinue`。它需要写 `ro.*` 属性，属性服务
没起来时它等 10 秒然后退出 1（有时几毫秒就退出）。后果有两个：

1. `/var/run/arc/shared_mounts/data` 从未 bind-mount 到 `/data`
   导致 Android 的 `post-fs-data` 全部因只读失败 进而 zygote 起不来
2. `arc_setup.cc:2556`（`initctl start arc-sdcard`）不会执行
   导致 `external_primary` 卷不存在 进而 MediaProvider 拒绝打开任何 APK

此问题理论上原版内核也存在，但是此内核增加更多内容，大幅提高触发概率

### 8.3 修法

```bash
cd fixes
sudo bash install-arc-race-fix.sh          # 安装
sudo reboot                                # 重启生效
```

其它子命令：

```bash
sudo bash install-arc-race-fix.sh --status     # 查看状态
sudo bash install-arc-race-fix.sh --uninstall  # 卸载（恢复原始 conf）
```

安装位置

| 路径 | 作用 |
|---|---|
| `/usr/local/sbin/arc-boot-continue-wait.sh` | 包装脚本 |
| `/etc/init/arc-boot-continue.conf` | 被改写为经由包装脚本 exec |

> 原始 conf 备份在 `/mnt/stateful_partition/arc-heal/arc-boot-continue.conf.orig`，
> `--uninstall` 会自动用它还原。

---

## 9. 收集诊断信息

把下面整段贴进终端，输出即可用于求助：

```bash
{
  echo "===== KernelSU 内核侧 ====="
  echo "Invalid relocation: $(sudo dmesg | grep -c 'Invalid relocation')"
  echo "Unknown symbol: $(sudo dmesg | grep -c 'Unknown symbol')"
  echo "KernelSU lines: $(sudo dmesg | grep -c KernelSU)"
  sudo dmesg | grep -E 'dispatcher installed|Crowning manager|open ksud' | tail -5

  echo "===== ARC 适配（决定模块能否激活）====="
  echo "blocked syscall 169: $(sudo dmesg | grep -c 'blocked syscall 169')   # 应为 0"
  sudo dmesg | grep -o "direct-hook table='[a-z_]*'" | head -1              # 应为 'android'
  sudo dmesg | grep 'read init.rc' | head -1                                # 有输出才对
  echo "static_calls_table: $(grep -cw static_calls_table /proc/kallsyms)"  # 应为 1

  echo "===== 模块 ====="
  find /lib/modules/6.12.54-01180-gb4e10020ba49-dirty -name '*.ko' | wc -l
  lsmod | grep -E 'i915|amdgpu|e1000e|iwlwifi'

  echo "===== ESP ====="
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT | head -25
  sudo losetup -nO NAME,BACK-FILE 2>/dev/null | head -5      # 双引导：引导槽在 loop 里

  echo "===== Android 容器 ====="
  IPID=$(pgrep -f '^/system/bin/init' | head -1)
  echo "IPID=$IPID"
  sudo nsenter -t $IPID -m -p -U --root -- getprop sys.boot_completed
  sudo nsenter -t $IPID -m -p -U --root -- sh -c \
      'grep -q " /data " /proc/self/mountinfo && echo "data OK" || echo "data MISSING"'
  echo "esdfs mounts: $(mount | grep -c esdfs)"
  sudo nsenter -t $IPID -m -p -U --root -- ls /storage/emulated/0/ | head

  echo "===== ksud 活动（模块是否在开机时激活）====="
  sudo nsenter -t $IPID -m -p -U --root -- sh -c '
    L=/data/adb/ksu/log/logcat.log
    echo "PostFsData: $(grep -ac "command: PostFsData" $L)"
    echo "UAPI 错误: $(grep -ac "UAPI version mismatch" $L)   # 应为 0"
    ls /data/adb/modules_update/ 2>/dev/null | wc -l
    ls /data/adb/modules/ 2>/dev/null'

  echo "===== 补丁状态 ====="
  sudo bash fixes/install-arc-race-fix.sh --status 2>/dev/null || echo "子系统竞态补丁未安装"
  sudo bash fixes/install-metadata-fix.sh --status 2>/dev/null || echo "metadata 变通未安装（新内核不需要）"
} 2>&1 | tee ~/ksu-diag.txt

echo
echo "结果已存到 ~/ksu-diag.txt"
```

> **两个 `fixes/` 脚本的区别**：`install-arc-race-fix.sh` 修的是**子系统启动竞态**，
> 现在仍然需要（见第 8 节）；`install-metadata-fix.sh` 是**旧内核时期的变通**，
> 换新内核后应当用 `--uninstall` 撤掉（见 [10.2](#102-模块一直等待重启重启也不生效)）。

---

## 10. 模块问题

### 10.1  `UAPI version mismatch: kernel=0, ksud=2`

同下

### 10.2 模块一直等待重启，即使已经重启

适用于：检查：`ksud module list`返回 `"update": "true"`，且 `/data/adb/modules_update/` 里还有内容。

**修复：新内核已修复**，无需额外操作。

### 10.3 ZygiskNext 报错

**修复：新内核已修复**，无需额外操作。

---

### 10.4 Zygisk 模块

请安装ZygiskNext

####  LSPosed 2.0.x 闪退

兼容问题，**无法修复**。

1.9.2 不受影响。

---
