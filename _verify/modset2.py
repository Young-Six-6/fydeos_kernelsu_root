import tarfile, os

V = "6.12.54-01180-gb4e10020ba49-dirty"
BASE = r"C:\Users\wang\Documents\DSH"
WORK = os.path.join(BASE, "ghostlock", "work")


def ko_set(path):
    with tarfile.open(path, "r:gz") as tf:
        return {n[len("lib/modules/%s/kernel/" % V):] for n in tf.getnames() if n.endswith(".ko")}


for tag in ("iris", "apu"):
    ours = ko_set(os.path.join(BASE, "fydeos-ksu", tag, "modules-%s.tar.gz" % tag))
    off = ko_set(os.path.join(WORK, "offmods-%s.tar.gz" % tag))
    print("=" * 74)
    print("%s  delivered=%d  official=%d" % (tag, len(ours), len(off)))
    miss = sorted(off - ours)
    extra = sorted(ours - off)
    print("  missing from ours (%d): %s" % (len(miss), miss or "none"))
    print("  extra in ours (%d)    : %s" % (len(extra), extra or "none"))
    for probe in ("drm_shmem_helper", "drm_kms_helper", "governor_performance",
                  "usbserial", "extcon-core", "crystalcove", "bytcrc"):
        a = [x for x in ours if probe in x]
        b = [x for x in off if probe in x]
        if a or b:
            print("  %-20s ours=%-46s official=%s" % (probe, a or "-", b or "-"))
