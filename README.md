# FydeOS for PC + KernelSU（iris / apu）—— 交付说明

> **FydeOS for PC v23.0-SP1** 内核 `6.12.54-01180-gb4e10020ba49-dirty`
> 内置 KernelSU

---

## 从这里开始

| 你想做什么 | 应该看什么 |
|---|---|
| **安装到设备上** | [USER-MANUAL.md](USER-MANUAL.md) |
| **从源码构建** | [BUILD.md](BUILD.md) |
| **看它和官方差在哪** | [FIDELITY.md](FIDELITY.md) |
| **核验下载到的文件对不对** | 下面的 [快速核验](#快速核验) |

---

## 须知

**iris 内核已在真机上启动并通过验证**

**apu 尚未在真机上验证**

**你必须知道各个命令的意图，否则不仅 安装大概率失败 而且可能损失数据 **

---

## 产物

```
fydeos-ksu/
├── README.md                    本文件
├── USER-MANUAL.md               用户手册
├── BUILD.md                     构建流程
├── FIDELITY.md                  逐项对比报告
│
├── deploy.sh                    部署脚本
├── verify.sh                    部署后验证脚本
├── build.sh                     构建脚本
│
├── MD5SUMS / SHA256SUMS         校验清单
│
├── config-iris.txt              从 iris 产物提取的构建配置
├── config-apu.txt               从 apu 产物提取的构建配置
├── config-official-iris.txt     官方 iris 配置
├── config-official-apu.txt      官方 apu 配置
│
├── tools/
│   ├── inspect-artifact.py      离线核验
│   └── lint-shell.py            脚本静态检查
├── fixes/                       问题修复补丁
│   ├── install-arc-race-fix.sh  安装 / 卸载
│   └── arc-boot-continue-wait.sh 等待 property service 的 exec 包装层
├── _verify/                     复现 FIDELITY.md 数字的脚本
│
├── iris/
│   ├── vmlinuz.A                    12,878,848 B
│   └── modules-iris.tar.gz          33,369,354 B
└── apu/
    ├── vmlinuz.A                    14,529,536 B
    └── modules-apu.tar.gz           41,601,209 B
```

---

## 快速核验

### 推荐

```bash
python tools/inspect-artifact.py iris
python tools/inspect-artifact.py apu
```

### 校验

```bash
md5sum -c MD5SUMS && sha256sum -c SHA256SUMS
```

### 校验值

| 文件 | md5 |
|---|---|
| `iris/vmlinuz.A` | `c8c6b467819fc2272667f3a77ac62b67` |
| `iris/modules-iris.tar.gz` | `c2af400294fdd51122a7e1ffd83d0797` |
| `apu/vmlinuz.A` | `4bcab93f3f763dabedd4eb662fe6fccf` |
| `apu/modules-apu.tar.gz` | `f24faeab0fe86cab5aedcd5086b27e63` |

---

## 已知限制

`CONFIG_PM_GENERIC_DOMAINS` 与官方有差异（iris），可能影响挂起

apu 缺 2 个模块，均为 Intel Bay Trail 平台驱动

编译器不同

---

