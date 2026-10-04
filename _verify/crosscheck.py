"""Cross-check every factual claim made in the documentation against the
artifacts. Any mismatch is printed as a FAIL.

This is the guard against documentation drift: the numbers in README.md,
USER-MANUAL.md and FIDELITY.md must all be reproducible from the files.
"""
import gzip
import io
import os
import re
import struct
import sys
import tarfile
import zlib

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(BASE)

fails = []
checks = 0


def chk(label, got, want):
    global checks
    checks += 1
    if got == want:
        print("  [ OK ] %-56s %s" % (label, got))
    else:
        print("  [FAIL] %-56s got=%r want=%r" % (label, got, want))
        fails.append(label)


def chk_in(label, needle, haystack):
    global checks
    checks += 1
    if needle in haystack:
        print("  [ OK ] %-56s present" % label)
    else:
        print("  [FAIL] %-56s MISSING" % label)
        fails.append(label)


def gunzip(data):
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = bytearray()
    for i in range(0, len(data), 1 << 20):
        try:
            out += d.decompress(data[i:i + (1 << 20)])
        except zlib.error:
            break
        if d.eof:
            break
    return bytes(out)


def load_kernel(path):
    buf = open(path, "rb").read()
    base = (buf[0x1F1] + 1) * 512
    off = base + struct.unpack_from("<I", buf, 0x248)[0]
    ln = struct.unpack_from("<I", buf, 0x24C)[0]
    return buf, gunzip(buf[off:off + ln + 64])


def sections(b):
    e_shoff = struct.unpack_from("<Q", b, 0x28)[0]
    es = struct.unpack_from("<H", b, 0x3A)[0]
    n = struct.unpack_from("<H", b, 0x3C)[0]
    si = struct.unpack_from("<H", b, 0x3E)[0]
    sh = e_shoff + si * es
    stroff = struct.unpack_from("<Q", b, sh + 0x18)[0]
    strsize = struct.unpack_from("<Q", b, sh + 0x20)[0]
    stab = b[stroff:stroff + strsize]
    names = []
    for i in range(n):
        o = e_shoff + i * es
        no = struct.unpack_from("<I", b, o)[0]
        nm = stab[no:stab.find(b"\0", no)].decode("latin1")
        if nm:
            names.append(nm)
    return names


def cfg_from_tar(path):
    with tarfile.open(path, "r:gz") as tf:
        ko = tf.extractfile("lib/modules/%s/kernel/kernel/configs.ko" % V).read()
    s = ko.find(b"IKCFG_ST"); e = ko.find(b"IKCFG_ED")
    return gzip.GzipFile(fileobj=io.BytesIO(ko[s + 8:e])).read().decode("utf-8", "replace")


def parse_cfg(text):
    d = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("# CONFIG_") and line.endswith(" is not set"):
            d[line[2:-11]] = "n"
        elif line.startswith("CONFIG_") and "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def ko_set(path):
    with tarfile.open(path, "r:gz") as tf:
        return {n[len("lib/modules/%s/kernel/" % V):] for n in tf.getnames() if n.endswith(".ko")}


print("=" * 78)
print("文档与产物一致性交叉核对")
print("=" * 78)

for tag, ksize, msize, kmd5, nmd5 in (
        ("iris", 12878848, 33369354, "c8c6b467819fc2272667f3a77ac62b67",
         "c2af400294fdd51122a7e1ffd83d0797"),
        ("apu", 14529536, 41601209, "4bcab93f3f763dabedd4eb662fe6fccf",
         "f24faeab0fe86cab5aedcd5086b27e63")):
    print()
    print("--- %s ---" % tag)
    kp = os.path.join(BASE, tag, "vmlinuz.A")
    mp = os.path.join(BASE, tag, "modules-%s.tar.gz" % tag)

    chk("vmlinuz.A size", os.path.getsize(kp), ksize)
    chk("modules size", os.path.getsize(mp), msize)

    import hashlib
    chk("vmlinuz.A md5", hashlib.md5(open(kp, "rb").read()).hexdigest(), kmd5)
    chk("modules md5", hashlib.md5(open(mp, "rb").read()).hexdigest(), nmd5)

    raw, blob = load_kernel(kp)
    chk("boot: MZ", raw[:2], b"MZ")
    chk("boot: HdrS@0x202", raw[0x202:0x206], b"HdrS")
    chk("boot: setup_sects", raw[0x1F1], 39)
    chk("boot: bootproto", struct.unpack_from("<H", raw, 0x206)[0], 0x020F)
    chk("boot: boot_flag", struct.unpack_from("<H", raw, 0x1FE)[0], 0xAA55)
    chk("boot: loadflags", raw[0x211], 0x01)
    chk("boot: payload_offset", struct.unpack_from("<I", raw, 0x248)[0], 708)
    chk("boot: PE sig", raw[struct.unpack_from("<I", raw, 0x3C)[0]:
                              struct.unpack_from("<I", raw, 0x3C)[0] + 4], b"PE\x00\x00")
    chk("boot: PE machine", struct.unpack_from("<H", raw, struct.unpack_from("<I", raw, 0x3C)[0] + 4)[0], 0x8664)

    m = re.search(rb"Linux version ([0-9][^\x00\x20]{0,72})", blob)
    chk("version banner", m.group(1).decode() if m else None, V)

    secs = sections(blob)
    chk("ELF section count", len(secs), 46 if tag == "iris" else 50)
    chk("has .BTF", ".BTF" in secs, tag == "apu")
    chk("has .BTF_ids", ".BTF_ids" in secs, tag == "apu")

    cfg = parse_cfg(cfg_from_tar(mp))
    chk("CONFIG_KSU", cfg.get("CONFIG_KSU"), "y")
    chk("CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER",
        cfg.get("CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER"), "y")
    chk("CONFIG_EFI_STUB", cfg.get("CONFIG_EFI_STUB"), "y")
    chk("CONFIG_EFI_MIXED", cfg.get("CONFIG_EFI_MIXED"), "y")
    chk("CONFIG_EFI_HANDOVER_PROTOCOL", cfg.get("CONFIG_EFI_HANDOVER_PROTOCOL"), "y")
    chk("CONFIG_LOCALVERSION", cfg.get("CONFIG_LOCALVERSION"), '""')
    chk("CONFIG_ASHMEM", cfg.get("CONFIG_ASHMEM"), "y")
    chk("CONFIG_ESD_FS", cfg.get("CONFIG_ESD_FS"), "y")
    chk("CONFIG_ALT_SYSCALL", cfg.get("CONFIG_ALT_SYSCALL"), "y")
    chk("CONFIG_NETFILTER_XT_MATCH_QUOTA2",
        cfg.get("CONFIG_NETFILTER_XT_MATCH_QUOTA2"), "y")
    chk("CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG",
        cfg.get("CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG"), "y")
    chk("CONFIG_KERNEL_GZIP", cfg.get("CONFIG_KERNEL_GZIP"), "y")
    # iris ships i915 AND amdgpu (amdgpu is =m in the official iris config too);
    # radeon is only in apu.  A symbol written as "# CONFIG_X is not set" parses
    # as "n"; a symbol absent from the config entirely parses as None.
    chk("CONFIG_DRM_I915", cfg.get("CONFIG_DRM_I915"), "m" if tag == "iris" else "n")
    chk("CONFIG_DRM_AMDGPU", cfg.get("CONFIG_DRM_AMDGPU"), "m")
    chk("CONFIG_DRM_RADEON", cfg.get("CONFIG_DRM_RADEON"), "n" if tag == "iris" else "m")
    chk("CONFIG_NR_CPUS", cfg.get("CONFIG_NR_CPUS"), "24" if tag == "iris" else "64")

    kos = ko_set(mp)
    chk("module count", len(kos), 1190 if tag == "iris" else 1575)
    chk_in("e1000.ko present", "drivers/net/ethernet/intel/e1000/e1000.ko", kos)
    if tag == "iris":
        chk_in("i915.ko present", "drivers/gpu/drm/i915/i915.ko", kos)
        chk_in("amdgpu.ko present", "drivers/gpu/drm/amd/amdgpu/amdgpu.ko", kos)
        chk("radeon.ko absent", "drivers/gpu/drm/radeon/radeon.ko" in kos, False)
    else:
        chk_in("amdgpu.ko present", "drivers/gpu/drm/amd/amdgpu/amdgpu.ko", kos)
        chk_in("radeon.ko present", "drivers/gpu/drm/radeon/radeon.ko", kos)
        chk("i915.ko absent", "drivers/gpu/drm/i915/i915.ko" in kos, False)

# --- module set vs official -------------------------------------------------
SAMPLES = os.path.join(ROOT, "ghostlock", "work")
if os.path.exists(os.path.join(SAMPLES, "offmods-iris.tar.gz")):
    print()
    print("--- 模块集 vs 官方 ---")
    for tag, miss_n in (("iris", 2), ("apu", 4)):
        ours = ko_set(os.path.join(BASE, tag, "modules-%s.tar.gz" % tag))
        off = ko_set(os.path.join(SAMPLES, "offmods-%s.tar.gz" % tag))
        chk("%s official count" % tag, len(off), 1192 if tag == "iris" else 1579)
        chk("%s missing count" % tag, len(off - ours), miss_n)
        chk("%s extra count" % tag, len(ours - off), 0)
else:
    print()
    print("--- 模块集 vs 官方: 跳过（无官方样本）---")

# --- docs consistency -------------------------------------------------------
print()
print("--- 文档内部一致性 ---")
readme = open(os.path.join(BASE, "README.md"), encoding="utf-8").read()
manual = open(os.path.join(BASE, "USER-MANUAL.md"), encoding="utf-8").read()
fid = open(os.path.join(BASE, "FIDELITY.md"), encoding="utf-8").read()
build = open(os.path.join(BASE, "BUILD.md"), encoding="utf-8").read()

for doc, name in ((readme, "README"), (manual, "USER-MANUAL"), (fid, "FIDELITY")):
    chk_in("%s: 含 iris md5" % name, "c8c6b467819fc2272667f3a77ac62b67", doc)
    chk_in("%s: 含 apu md5" % name, "4bcab93f3f763dabedd4eb662fe6fccf", doc)
    chk_in("%s: 含版本串" % name, V, doc)

chk_in("BUILD: 提到 EFI_STUB", "EFI_STUB", build)
chk_in("BUILD: 提到 make modules 陷阱", "make bzImage", build)
chk_in("BUILD: 提到 --depth 1", "--depth 1", build)
chk_in("MANUAL: 提到 Invalid relocation", "Invalid relocation", manual)
chk_in("MANUAL: 提到 xt_quota2", "xt_quota2", manual)
chk_in("MANUAL: 提到 -n 陷阱", "`-n`", manual)
chk_in("FIDELITY: 提到 46/50 节区", "46", fid)

# every file referenced by README exists
print()
print("--- README 引用的文件是否存在 ---")
for m in re.finditer(r"\]\(([A-Za-z0-9_./-]+\.(?:md|sh|py))\)", readme):
    rel = m.group(1)
    exists = os.path.exists(os.path.join(BASE, rel))
    chk("README -> %s" % rel, exists, True)

print()
print("=" * 78)
print("检查项 %d，失败 %d" % (checks, len(fails)))
if fails:
    for f in fails:
        print("  FAILED: %s" % f)
print("=" * 78)
sys.exit(1 if fails else 0)
