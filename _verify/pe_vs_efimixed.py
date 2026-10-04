"""The apu PE section lists differ (4 vs 3) while iris matches (4 vs 4).
Check whether that is explained by CONFIG_EFI_MIXED, which also differs for apu.
"""
import gzip, io, os, struct, tarfile

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = r"C:\Users\wang\Documents\DSH"
WORK = os.path.join(BASE, "ghostlock", "work")


def pe_sections(path):
    d = open(path, "rb").read()
    e = struct.unpack_from("<I", d, 0x3C)[0]
    nsec = struct.unpack_from("<H", d, e + 6)[0]
    opt = struct.unpack_from("<H", d, e + 20)[0]
    out = []
    for i in range(nsec):
        o = e + 24 + opt + 40 * i
        nm = d[o:o + 8].rstrip(b"\0").decode("latin1")
        vsize = struct.unpack_from("<I", d, o + 8)[0]
        vaddr = struct.unpack_from("<I", d, o + 12)[0]
        out.append((nm, vaddr, vsize))
    return out


def cfg(path):
    with tarfile.open(path, "r:gz") as tf:
        ko = tf.extractfile("lib/modules/%s/kernel/kernel/configs.ko" % V).read()
    s = ko.find(b"IKCFG_ST"); e = ko.find(b"IKCFG_ED")
    txt = gzip.GzipFile(fileobj=io.BytesIO(ko[s + 8:e])).read().decode()
    d = {}
    for line in txt.splitlines():
        line = line.strip()
        if line.startswith("# CONFIG_") and line.endswith(" is not set"):
            d[line[2:-11]] = "n"
        elif line.startswith("CONFIG_") and "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


for tag in ("iris", "apu"):
    print("=" * 72)
    print(tag)
    for label, kp, mp in (
            ("ours", os.path.join(BASE, "fydeos-ksu", tag, "vmlinuz.A"),
             os.path.join(BASE, "fydeos-ksu", tag, "modules-%s.tar.gz" % tag)),
            ("official", os.path.join(WORK, "off-%s-vmlinuz.A" % tag),
             os.path.join(WORK, "offmods-%s.tar.gz" % tag))):
        secs = pe_sections(kp)
        c = cfg(mp)
        print("  %-9s sections=%d  %s" % (
            label, len(secs), ", ".join(s[0] for s in secs)))
        print("            EFI_MIXED=%s  EFI_STUB=%s  EFI_HANDOVER=%s" % (
            c.get("CONFIG_EFI_MIXED", "(absent)"),
            c.get("CONFIG_EFI_STUB", "(absent)"),
            c.get("CONFIG_EFI_HANDOVER_PROTOCOL", "(absent)")))
