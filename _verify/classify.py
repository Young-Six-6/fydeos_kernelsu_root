"""Classify each module the official archive has and ours does not:
is it genuinely absent, or merely built in (=y) instead of =m?
"""
import gzip, io, os, tarfile

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = r"C:\Users\wang\Documents\DSH"
WORK = os.path.join(BASE, "ghostlock", "work")

CASES = {
    "iris": [
        ("drivers/devfreq/governor_performance.ko", ["CONFIG_DEVFREQ_GOV_PERFORMANCE"]),
        ("drivers/gpu/drm/drm_kms_helper.ko",       ["CONFIG_DRM_KMS_HELPER"]),
    ],
    "apu": [
        ("drivers/extcon/extcon-core.ko",           ["CONFIG_EXTCON"]),
        ("drivers/gpio/gpio-crystalcove.ko",        ["CONFIG_GPIO_CRYSTAL_COVE"]),
        ("drivers/platform/x86/intel/intel_bytcrc_pwrsrc.ko",
         ["CONFIG_INTEL_BYTCRC_PWRSRC", "CONFIG_INTEL_PMC_CORE"]),
        ("drivers/usb/serial/usbserial.ko",         ["CONFIG_USB_SERIAL"]),
    ],
}


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


def builtin(tag, which):
    if which == "ours":
        p = os.path.join(BASE, "fydeos-ksu", tag, "modules-%s.tar.gz" % tag)
        with tarfile.open(p, "r:gz") as tf:
            txt = tf.extractfile("lib/modules/%s/modules.builtin" % V).read().decode()
    else:
        # the official archive ships only the kernel/ subtree; its modules.builtin
        # was captured separately during reconnaissance
        p = os.path.join(WORK, "off-%s.builtin" % tag)
        txt = open(p, encoding="utf-8", errors="replace").read()
    return txt


for tag, items in CASES.items():
    our = parse(open(os.path.join(BASE, "fydeos-ksu", "config-%s.txt" % tag),
                     encoding="utf-8", errors="replace").read())
    off = off_cfg(tag)
    ob = builtin(tag, "ours")
    fb = builtin(tag, "official")
    print("=" * 78)
    print(tag)
    for ko, syms in items:
        base = os.path.basename(ko)
        print("  %s" % ko)
        print("    ours  builtin list contains it: %s" % (base in ob))
        print("    official builtin list contains it: %s" % (base in fb))
        for s in syms:
            print("    %-34s ours=%-6s official=%s" % (s, our.get(s, "(absent)"), off.get(s, "(absent)")))
