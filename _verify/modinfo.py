"""Pull one .ko out of each delivered tarball and read its .modinfo vermagic,
without needing a Linux host: the .modinfo section is a plain NUL-separated
"key=value" blob, so it can be found by scanning for the literal tag.
"""
import re
import subprocess
import sys
import tarfile
import io

V = "6.12.54-01180-gb4e10020ba49-dirty"
WANT = V + " SMP preempt mod_unload"

TARGETS = {
    "iris": (r"..\iris\modules-iris.tar.gz", [
        "kernel/drivers/gpu/drm/i915/i915.ko",
        "kernel/drivers/net/ethernet/intel/e1000/e1000.ko",
        "kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko",
        "kernel/kernel/configs.ko",
    ]),
    "apu": (r"..\apu\modules-apu.tar.gz", [
        "kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko",
        "kernel/drivers/gpu/drm/radeon/radeon.ko",
        "kernel/drivers/net/ethernet/intel/e1000/e1000.ko",
        "kernel/kernel/configs.ko",
    ]),
}


def modinfo(blob):
    """Extract the .modinfo key=value pairs from a .ko image."""
    out = {}
    for m in re.finditer(rb"([a-z_]+)=([^\x00]{0,200})\x00", blob):
        k = m.group(1).decode()
        v = m.group(2).decode("latin1")
        if k in ("vermagic", "name", "license", "depends", "retpoline",
                 "intree", "srcversion", "alias", "parm", "description", "author"):
            out.setdefault(k, v)
    return out


for tag, (path, members) in TARGETS.items():
    print("=" * 78)
    print("%s  %s" % (tag, path))
    with tarfile.open(path, "r:gz") as tf:
        names = tf.getnames()
        for m in members:
            full = "lib/modules/%s/%s" % (V, m)
            if full not in names:
                print("  %-52s MISSING from archive" % m)
                continue
            data = tf.extractfile(full).read()
            info = modinfo(data)
            vm = info.get("vermagic", "(none)")
            # The stock kernel's vermagic carries a trailing space (measured on
            # crc7.ko); compare on the stripped value but report the raw one.
            ok = "OK " if vm.strip() == WANT else "BAD"
            print("  [%s] %-52s %8d B" % (ok, m, len(data)))
            print("        vermagic : %s" % vm)
            print("        name/retpoline/intree : %s / %s / %s" % (
                info.get("name", "-"), info.get("retpoline", "-"), info.get("intree", "-")))
            if vm != WANT:
                print("        EXPECTED : %s" % WANT)
