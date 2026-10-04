"""Extract the OFFICIAL FydeOS kernels' configs from their configs.ko, then diff
them symbol-by-symbol against ours. This is the ground truth the whole port was
aimed at, so the diff is the single most important fidelity number.
"""
import gzip
import io
import os
import tarfile

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = r"C:\Users\wang\Documents\DSH"
WORK = os.path.join(BASE, "ghostlock", "work")


def cfg_from_tar(path, member):
    with tarfile.open(path, "r:gz") as tf:
        blob = tf.extractfile(member).read()
    s = blob.find(b"IKCFG_ST")
    e = blob.find(b"IKCFG_ED")
    return gzip.GzipFile(fileobj=io.BytesIO(blob[s + 8:e])).read().decode("utf-8", "replace")


def parse(text):
    d = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            if line.startswith("# CONFIG_") and line.endswith(" is not set"):
                d[line[2:-11]] = "n"
            continue
        if line.startswith("CONFIG_") and "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


for tag in ("iris", "apu"):
    off_tar = os.path.join(WORK, "offmods-%s.tar.gz" % tag)
    off = parse(cfg_from_tar(off_tar, "lib/modules/%s/kernel/kernel/configs.ko" % V))
    our_path = os.path.join(BASE, "fydeos-ksu", "config-%s.txt" % tag)
    our = parse(open(our_path, encoding="utf-8", errors="replace").read())

    out = os.path.join(BASE, "fydeos-ksu", "config-official-%s.txt" % tag)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(cfg_from_tar(off_tar, "lib/modules/%s/kernel/kernel/configs.ko" % V))

    print("=" * 74)
    print("%s   ours=%d symbols   official=%d symbols" % (tag, len(our), len(off)))

    keys = sorted(set(our) | set(off))
    diffs = []
    for k in keys:
        a, b = our.get(k), off.get(k)
        if a != b:
            diffs.append((k, a, b))
    print("  differing symbols: %d" % len(diffs))

    only_our = [d for d in diffs if d[2] is None]
    only_off = [d for d in diffs if d[1] is None]
    value = [d for d in diffs if d[1] is not None and d[2] is not None]
    print("    ours-only (not in official)  : %d" % len(only_our))
    print("    official-only (we lack)      : %d" % len(only_off))
    print("    value differs                : %d" % len(value))

    interesting = [d for d in diffs if any(s in d[0] for s in (
        "KSU", "KPROBE", "KRETPROBE", "OPTPROBE", "RETHOOK", "PROBE_EVENTS",
        "ASHMEM", "ESD_FS", "ALT_SYSCALL", "QUOTA2", "DRM_", "BACKLIGHT",
        "FW_LOADER", "EFI_", "NR_CPUS", "KVM", "BTF", "IKCONFIG", "MODULE_COMPRESS",
        "KERNEL_GZIP", "KERNEL_LZMA", "LOCALVERSION", "VMWARE", "VIRTIO", "HYPERVISOR"))]
    print("  --- differences in the load-bearing area (%d) ---" % len(interesting))
    for k, a, b in interesting[:60]:
        print("    %-52s ours=%-10s official=%s" % (k, a, b))
