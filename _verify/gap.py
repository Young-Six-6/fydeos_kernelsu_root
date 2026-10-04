import gzip, io, os, tarfile, collections

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


def our_mods(tag):
    p = os.path.join(BASE, "fydeos-ksu", tag, "modules-%s.tar.gz" % tag)
    with tarfile.open(p, "r:gz") as tf:
        return {n[len("lib/modules/%s/kernel/" % V):] for n in tf.getnames() if n.endswith(".ko")}


def off_mods(tag):
    p = os.path.join(WORK, "offmods-%s.tar.gz" % tag)
    with tarfile.open(p, "r:gz") as tf:
        return {n[len("lib/modules/%s/kernel/" % V):] for n in tf.getnames() if n.endswith(".ko")}


for tag in ("iris", "apu"):
    off = off_cfg(tag)
    our = parse(open(os.path.join(BASE, "fydeos-ksu", "config-%s.txt" % tag),
                     encoding="utf-8", errors="replace").read())
    only_off = sorted(k for k in off if k not in our)

    # How many of the official-only symbols are actually ENABLED in official?
    enabled = [k for k in only_off if off[k] not in ("n",)]
    print("=" * 74)
    print("%s: %d official-only symbols, of which %d are ENABLED (=y or =m)"
          % (tag, len(only_off), len(enabled)))
    print("  enabled ones:")
    for k in enabled:
        print("    %-52s official=%s" % (k, off[k]))

    # and how do the module sets differ, expressed in the official's own tree
    om, rm = off_mods(tag), our_mods(tag)
    missing = sorted(om - rm)
    extra = sorted(rm - om)
    print("  module sets: official=%d ours=%d  missing=%d extra=%d"
          % (len(om), len(rm), len(missing), len(extra)))
    fams = collections.Counter()
    for m in missing:
        top = m.split("/")
        fams["/".join(top[:3])] += 1
    print("  missing module families:")
    for f, n in fams.most_common(12):
        print("    %-46s %3d" % (f, n))
    for m in missing:
        print("      %s" % m)
