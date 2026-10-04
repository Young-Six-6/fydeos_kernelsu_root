#!/usr/bin/env python3
"""inspect-artifact.py —— 离线核验 FydeOS KernelSU 交付产物

不需要 Linux、不需要设备：直接读 vmlinuz.A 与 modules-*.tar.gz，把"这个内核
到底是什么"打印出来。文档里的每个数字都能用这个脚本复现。

    python inspect-artifact.py iris
    python inspect-artifact.py apu
    python inspect-artifact.py iris --config-out my-config.txt

检查项：
  1. x86 引导协议头 + PE/EFI stub（GRUB 走 EFI 路径加载，这一项缺了开不了机）
  2. 解压内核载荷，确认它真的是一个 ELF vmlinux
  3. 在 vmlinux 里找功能指纹（KernelSU、alt-syscall、esdfs、ashmem、xt_quota2）
  4. 从模块包里的 kernel/kernel/configs.ko 取出构建时用的完整 .config
  5. 模块清单统计与关键模块在位检查
"""
import argparse
import gzip
import io
import os
import re
import struct
import sys
import tarfile
import zlib

VER = "6.12.54-01180-gb4e10020ba49-dirty"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

VARIANTS = {
    "iris": {
        "dir": "iris",
        "kernel": "iris/vmlinuz.A",
        "modules": "iris/modules-iris.tar.gz",
        "md5": "c8c6b467819fc2272667f3a77ac62b67",
        # NOTE: amdgpu lives under drm/amd/amdgpu/, not drm/amdgpu/
        "gpu": ["i915/i915", "amd/amdgpu/amdgpu"],
    },
    "apu": {
        "dir": "apu",
        "kernel": "apu/vmlinuz.A",
        "modules": "apu/modules-apu.tar.gz",
        "md5": "4bcab93f3f763dabedd4eb662fe6fccf",
        "gpu": ["amd/amdgpu/amdgpu", "radeon/radeon"],
    },
}

FEATURES = [
    (rb"KernelSU", "KernelSU 内核支持"),
    (rb"alt_syscall: dispatcher ->", "alt-syscall 分发器安装代码"),
    (rb"dispatcher installed at alt slot", "alt 表槽位选择"),
    (rb"ksu_get_pristine_sys_call_table", "pristine 系统调用表访问器"),
    (rb"ksu_get_alt_sys_call_tables", "alt 系统调用表访问器"),
    (rb"Crowning manager", "管理器加冕逻辑"),
    (rb"save allow list", "授权名单写入"),
    (rb"packages.list detected", "管理器搜索"),
    (rb"/data/adb/ksud", "ksud 路径"),
    (rb"Registering esdfs", "ESD_FS"),
    (rb"ashmem: initialized", "ASHMEM"),
    (rb"xt_quota2: cannot alloc skb", "xt_quota2（netns 版）"),
    (rb"overlayfs: suspected uncovered", "overlayfs LSM 放行"),
    (rb"acpi_get_lps0_constraint|acpi_pci_device_constraint_d3", "030 AMD 挂起补丁"),
    (rb"i915", "i915 标识"),
    (rb"amdgpu", "amdgpu 标识"),
    (rb"radeon", "radeon 标识"),
]

CONFIG_KEYS = [
    "CONFIG_KSU=", "CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=",
    "CONFIG_KPROBES=", "CONFIG_KRETPROBES=", "CONFIG_OPTPROBES=", "CONFIG_RETHOOK=",
    "CONFIG_EFI_STUB=", "CONFIG_EFI_MIXED=", "CONFIG_EFI_HANDOVER_PROTOCOL=",
    "CONFIG_RELOCATABLE=", "CONFIG_RANDOMIZE_BASE=",
    "CONFIG_LOCALVERSION=", "CONFIG_LOCALVERSION_AUTO=",
    "CONFIG_KERNEL_GZIP=", "CONFIG_MODULE_COMPRESS",
    "CONFIG_MODULES=", "CONFIG_MODVERSIONS=", "CONFIG_MODULE_SIG=",
    "CONFIG_DRM_I915=", "CONFIG_DRM_AMDGPU=", "CONFIG_DRM_RADEON=",
    "CONFIG_DRM_VMWGFX=", "CONFIG_BACKLIGHT_CLASS_DEVICE=",
    "CONFIG_FW_LOADER_COMPRESS=", "CONFIG_NR_CPUS=", "CONFIG_DEBUG_INFO_BTF=",
    "CONFIG_ASHMEM=", "CONFIG_ESD_FS=", "CONFIG_ALT_SYSCALL=",
    "CONFIG_NETFILTER_XT_MATCH_QUOTA2=", "CONFIG_CLANG_VERSION=",
]


def hdr(t):
    print()
    print("\033[1;36m== %s ==\033[0m" % t)


def ok(s):
    print("  \033[1;32m[ OK ]\033[0m %s" % s)


def bad(s):
    print("  \033[1;31m[FAIL]\033[0m %s" % s)


def info(s):
    print("  %s" % s)


def load_kernel(path):
    buf = open(path, "rb").read()
    return buf


def check_boot_header(buf):
    hdr("1. 引导头与 EFI stub")
    good = True
    info("文件大小     : %d B" % len(buf))

    mz = buf[:2] == b"MZ"
    (ok if mz else bad)("MZ 头（%r）—— 有 EFI stub 的内核才是这个开头" % buf[:2])
    good &= mz

    e = struct.unpack_from("<I", buf, 0x3C)[0]
    pe = buf[e:e + 4] == b"PE\x00\x00"
    (ok if pe else bad)("PE/COFF 头 @0x%x —— GRUB 通过 EFI 路径加载内核，必须有" % e)
    good &= pe
    if pe:
        machine = struct.unpack_from("<H", buf, e + 4)[0]
        nsec = struct.unpack_from("<H", buf, e + 6)[0]
        info("  machine=0x%04x (0x8664 = x86_64)   sections=%d" % (machine, nsec))
        good &= machine == 0x8664

    hdrs = buf[0x202:0x206] == b"HdrS"
    (ok if hdrs else bad)("HdrS @0x202 —— bzImage 魔数")
    good &= hdrs

    bf = struct.unpack_from("<H", buf, 0x1FE)[0]
    (ok if bf == 0xAA55 else bad)("boot_flag @0x1FE = 0x%04x（须为 0xAA55）" % bf)
    good &= bf == 0xAA55

    ss = buf[0x1F1]
    proto = struct.unpack_from("<H", buf, 0x206)[0]
    lf = buf[0x211]
    info("setup_sects  : %d（须 <= 64）" % ss)
    info("boot protocol: 0x%04x" % proto)
    info("loadflags    : 0x%02x" % lf)
    good &= ss <= 64 and proto >= 0x0203 and (lf & 1)

    po = struct.unpack_from("<I", buf, 0x248)[0]
    pl = struct.unpack_from("<I", buf, 0x24C)[0]
    base = (ss + 1) * 512
    info("载荷偏移     : %d -> 文件内 0x%x" % (po, base + po))
    info("载荷长度     : %d B" % pl)
    info("init_size    : %d B" % struct.unpack_from("<I", buf, 0x260)[0])
    return good, base + po, pl


def decompress_payload(buf, off, ln):
    hdr("2. 解压内核载荷")
    magic = buf[off:off + 4]
    if magic[:2] == b"\x1f\x8b":
        algo = "gzip"
    elif magic == b"\xfd7zXZ\x00":
        algo = "xz"
    elif magic == b"\x28\xb5\x2f\xfd":
        algo = "zstd"
    else:
        bad("未知压缩魔数 %s" % magic.hex())
        return None
    info("压缩算法     : %s" % algo)
    if algo != "gzip":
        info("（本脚本只解 gzip；这两个内核都是 gzip）")
        return None

    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = bytearray()
    for i in range(off, min(off + ln + 64, len(buf)), 1 << 20):
        try:
            out += d.decompress(buf[i:i + (1 << 20)])
        except zlib.error as exc:
            bad("解压失败: %s" % exc)
            return None
        if d.eof:
            break
    blob = bytes(out)
    info("解压后       : %d B (%.1f MiB)" % (len(blob), len(blob) / 1048576))
    if blob[:4] == b"\x7fELF":
        ok("是一个 ELF 镜像（vmlinux）")
    else:
        bad("不是 ELF 镜像（头部 %r）" % blob[:4])
        return None

    # ELF 节区名，用来和官方镜像比结构
    e_shoff = struct.unpack_from("<Q", blob, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", blob, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", blob, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", blob, 0x3E)[0]
    sh = e_shoff + e_shstrndx * e_shentsize
    stroff = struct.unpack_from("<Q", blob, sh + 0x18)[0]
    strsize = struct.unpack_from("<Q", blob, sh + 0x20)[0]
    stab = blob[stroff:stroff + strsize]
    names = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        no = struct.unpack_from("<I", blob, o)[0]
        nm = stab[no:stab.find(b"\0", no)].decode("latin1")
        if nm:
            names.append(nm)
    info("ELF 节区数   : %d" % len(names))
    info("含 .BTF      : %s" % (".BTF" in names))
    m = re.search(rb"Linux version ([0-9][^\x00\x20]{0,72})", blob)
    if m:
        v = m.group(1).decode("latin1")
        if v == VER:
            ok("版本串       : %s" % v)
        else:
            bad("版本串       : %s（期望 %s）" % (v, VER))
    else:
        bad("没找到 'Linux version' 字符串")
    return blob


def probe_features(blob):
    hdr("3. 功能指纹")
    for pat, label in FEATURES:
        n = len(re.findall(pat, blob))
        (ok if n else bad)("%-34s 命中 %d" % (label, n))


def extract_config(tar_path):
    hdr("4. 构建时使用的 .config")
    member = "lib/modules/%s/kernel/kernel/configs.ko" % VER
    try:
        with tarfile.open(tar_path, "r:gz") as tf:
            ko = tf.extractfile(member).read()
    except KeyError:
        bad("模块包里没有 %s" % member)
        return None
    s = ko.find(b"IKCFG_ST")
    e = ko.find(b"IKCFG_ED")
    if s < 0 or e < 0:
        bad("configs.ko 里没有 IKCFG 标记")
        return None
    text = gzip.GzipFile(fileobj=io.BytesIO(ko[s + 8:e])).read().decode("utf-8", "replace")
    lines = text.splitlines()
    info("从 configs.ko 解出 %d 行 / %d B" % (len(lines), len(text)))
    for k in CONFIG_KEYS:
        hit = [l for l in lines if l.startswith(k)]
        if hit:
            info("  %-46s %s" % (k, hit[0]))
    return text


def scan_modules(tar_path, gpu):
    hdr("5. 模块包")
    with tarfile.open(tar_path, "r:gz") as tf:
        names = tf.getnames()
        kos = [n for n in names if n.endswith(".ko")]
        info("包内条目     : %d" % len(names))
        info(".ko 数量     : %d" % len(kos))
        prefix = "lib/modules/%s/" % VER
        # tarfile strips the trailing slash from directory entries, so compare
        # against the prefix with and without it.
        stray = [n for n in names if not (n.startswith(prefix) or n + "/" == prefix)]
        if stray:
            bad("有 %d 个条目不在 %s 下 —— 解包路径会错" % (len(stray), prefix))
            for n in stray[:5]:
                info("    %s" % n)
        else:
            ok("所有条目都在 %s 下（可直接解到 /）" % prefix)
        for m in ["kernel/drivers/net/ethernet/intel/e1000/e1000.ko"] + \
                 ["kernel/drivers/gpu/drm/%s.ko" % g for g in gpu]:
            if prefix + m in names:
                ok("在位: %s" % m)
            else:
                bad("缺失: %s" % m)
        for m in ("build", "source"):
            if prefix + m in names:
                info("  （含 %s 符号链接，指向构建机路径；deploy.sh 会删掉它）" % m)
        # modules.builtin 行数 = 内建项
        try:
            bi = tf.extractfile(prefix + "modules.builtin").read().decode()
            info("modules.builtin: %d 行（内建项）" % len([l for l in bi.splitlines() if l.strip()]))
        except KeyError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("variant", choices=sorted(VARIANTS))
    ap.add_argument("--config-out", help="把提取出的 .config 写到这个文件")
    args = ap.parse_args()

    v = VARIANTS[args.variant]
    kpath = os.path.join(ROOT, v["kernel"])
    mpath = os.path.join(ROOT, v["modules"])
    for p in (kpath, mpath):
        if not os.path.exists(p):
            print("找不到 %s" % p)
            return 1

    print("=" * 78)
    print("交付产物核验: %s" % args.variant)
    print("  内核  : %s" % v["kernel"])
    print("  模块包: %s" % v["modules"])
    print("=" * 78)

    buf = load_kernel(kpath)
    good, off, ln = check_boot_header(buf)
    blob = decompress_payload(buf, off, ln)
    if blob is None:
        print("\n载荷无法解压，后续检查跳过。")
        return 1
    probe_features(blob)
    cfg = extract_config(mpath)
    if cfg and args.config_out:
        with open(args.config_out, "w", encoding="utf-8", newline="\n") as f:
            f.write(cfg if cfg.endswith("\n") else cfg + "\n")
        info("已写出: %s" % args.config_out)
    scan_modules(mpath, v["gpu"])

    print()
    print("=" * 78)
    print("结论: %s" % ("引导头全部通过" if good else "引导头有失败项 —— 不要刷这个文件"))
    print("=" * 78)
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
