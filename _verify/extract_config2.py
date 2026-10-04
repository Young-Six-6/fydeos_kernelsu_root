"""The kernel is built with CONFIG_IKCONFIG=m, so the config ships as a module
(kernel/kernel/configs.ko) rather than inside vmlinuz. Pull it out of the
delivered tarball and decode it -- that is the authoritative config of the
artifact.
"""
import gzip
import io
import tarfile
import os

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = r"C:\Users\wang\Documents\DSH"

for tag in ("iris", "apu"):
    path = os.path.join(BASE, "fydeos-ksu", tag, "modules-%s.tar.gz" % tag)
    with tarfile.open(path, "r:gz") as tf:
        blob = tf.extractfile("lib/modules/%s/kernel/kernel/configs.ko" % V).read()
    print("=" * 74)
    print("%s  configs.ko = %d bytes" % (tag, len(blob)))
    s = blob.find(b"IKCFG_ST")
    e = blob.find(b"IKCFG_ED")
    print("  IKCFG_ST @ %s   IKCFG_ED @ %s" % (s, e))
    if s < 0 or e < 0:
        print("  markers not found")
        continue
    payload = blob[s + len(b"IKCFG_ST"):e]
    cfg = gzip.GzipFile(fileobj=io.BytesIO(payload)).read().decode("utf-8", "replace")
    lines = cfg.splitlines()
    out = os.path.join(BASE, "fydeos-ksu", "config-%s.txt" % tag)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(cfg if cfg.endswith("\n") else cfg + "\n")
    print("  decoded: %d lines, %d bytes -> %s" % (len(lines), len(cfg), out))
    for key in ("CONFIG_KSU=", "CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=",
                "CONFIG_EFI_STUB=", "CONFIG_EFI_MIXED=", "CONFIG_EFI_HANDOVER_PROTOCOL=",
                "CONFIG_LOCALVERSION=", "CONFIG_KERNEL_GZIP=", "CONFIG_KERNEL_LZMA=",
                "CONFIG_DRM_I915=", "CONFIG_DRM_AMDGPU=", "CONFIG_DRM_RADEON=",
                "CONFIG_DRM_VMWGFX=", "CONFIG_NR_CPUS=", "CONFIG_DEBUG_INFO_BTF=",
                "CONFIG_ASHMEM=", "CONFIG_ESD_FS=", "CONFIG_ALT_SYSCALL=",
                "CONFIG_NETFILTER_XT_MATCH_QUOTA2=", "CONFIG_MODULE_COMPRESS"):
        hit = [l for l in lines if l.startswith(key)]
        print("    %-46s %s" % (key, hit[0] if hit else "(absent)"))
