import gzip, io, os, tarfile, re

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = r"C:\Users\wang\Documents\DSH"
WORK = os.path.join(BASE, "ghostlock", "work")


def parse(text):
    d = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("# CONFIG_") and line.endswith(" is not set"):
            d[line[2:-11]] = "n"
        elif line.startswith("CONFIG_") and "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def off_cfg(tag):
    p = os.path.join(WORK, "offmods-%s.tar.gz" % tag)
    with tarfile.open(p, "r:gz") as tf:
        blob = tf.extractfile("lib/modules/%s/kernel/kernel/configs.ko" % V).read()
    s = blob.find(b"IKCFG_ST"); e = blob.find(b"IKCFG_ED")
    return parse(gzip.GzipFile(fileobj=io.BytesIO(blob[s + 8:e])).read().decode("utf-8", "replace"))


INTEREST = [
    "CONFIG_EFI_STUB", "CONFIG_EFI_MIXED", "CONFIG_EFI_HANDOVER_PROTOCOL",
    "CONFIG_RELOCATABLE", "CONFIG_RANDOMIZE_BASE", "CONFIG_CMDLINE",
    "CONFIG_KERNEL_GZIP", "CONFIG_MODULE_COMPRESS", "CONFIG_MODULE_SIG",
    "CONFIG_MODVERSIONS", "CONFIG_MODULES", "CONFIG_KALLSYMS", "CONFIG_KALLSYMS_ALL",
    "CONFIG_IKCONFIG", "CONFIG_IKCONFIG_PROC",
    "CONFIG_DRM_KMS_HELPER", "CONFIG_DRM_GEM_SHMEM_HELPER", "CONFIG_DRM_TTM",
    "CONFIG_DRM_FBDEV_EMULATION", "CONFIG_DRM_I915", "CONFIG_DRM_AMDGPU",
    "CONFIG_DRM_RADEON", "CONFIG_BACKLIGHT_CLASS_DEVICE",
    "CONFIG_FW_LOADER_COMPRESS", "CONFIG_FW_LOADER_COMPRESS_XZ",
    "CONFIG_FW_LOADER_COMPRESS_ZSTD", "CONFIG_EXTRA_FIRMWARE",
    "CONFIG_NR_CPUS", "CONFIG_KVM", "CONFIG_KVM_INTEL", "CONFIG_KVM_AMD",
    "CONFIG_HYPERVISOR_GUEST", "CONFIG_DEBUG_INFO_BTF",
    "CONFIG_ASHMEM", "CONFIG_ESD_FS", "CONFIG_ALT_SYSCALL",
    "CONFIG_NETFILTER_XT_MATCH_QUOTA2", "CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG",
    "CONFIG_KSU", "CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER",
    "CONFIG_LOCALVERSION", "CONFIG_LOCALVERSION_AUTO",
    "CONFIG_CC_HAS_COUNTED_BY", "CONFIG_CC_VERSION_TEXT", "CONFIG_CLANG_VERSION",
    "CONFIG_LD_VERSION", "CONFIG_AS_VERSION", "CONFIG_PAHOLE_VERSION",
    "CONFIG_RUSTC_VERSION", "CONFIG_RUSTC_HAS_UNNECESSARY_TRANSMUTES",
    "CONFIG_HAVE_CFI_ICALL_NORMALIZE_INTEGERS_RUSTC",
    "CONFIG_SECURITY_CHROMIUMOS", "CONFIG_SECURITY_SELINUX", "CONFIG_LSM",
    "CONFIG_DEVFREQ_GOV_PERFORMANCE", "CONFIG_EXTCON", "CONFIG_USB_SERIAL",
    "CONFIG_GPIO_CRYSTAL_COVE", "CONFIG_INTEL_BYTCRC_PWRSRC",
    "CONFIG_X86_AMD_PLATFORM_DEVICE", "CONFIG_SPI_INTEL",
    "CONFIG_PM_GENERIC_DOMAINS", "CONFIG_HPET_MMAP_DEFAULT",
]

for tag in ("iris", "apu"):
    our = parse(open(os.path.join(BASE, "fydeos-ksu", "config-%s.txt" % tag),
                     encoding="utf-8", errors="replace").read())
    off = off_cfg(tag)
    print("=" * 84)
    print("%s   (%d vs %d symbols)" % (tag, len(our), len(off)))
    print("  %-46s %-16s %-16s %s" % ("symbol", "ours", "official", ""))
    for k in INTEREST:
        a, b = our.get(k, "(absent)"), off.get(k, "(absent)")
        mark = "" if a == b else ("  <-- differs")
        print("  %-46s %-16s %-16s%s" % (k, a, b, mark))
