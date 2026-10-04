import struct, zlib, re

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

def load(path):
    buf = open(path, 'rb').read()
    base = (buf[0x1F1] + 1) * 512
    off = base + struct.unpack_from('<I', buf, 0x248)[0]
    ln = struct.unpack_from('<I', buf, 0x24C)[0]
    return gunzip(buf[off:off + ln + 64])

def secmap(b):
    e_shoff = struct.unpack_from('<Q', b, 0x28)[0]
    es = struct.unpack_from('<H', b, 0x3A)[0]
    n = struct.unpack_from('<H', b, 0x3C)[0]
    si = struct.unpack_from('<H', b, 0x3E)[0]
    sh = e_shoff + si * es
    stroff = struct.unpack_from('<Q', b, sh + 0x18)[0]
    strsize = struct.unpack_from('<Q', b, sh + 0x20)[0]
    stab = b[stroff:stroff + strsize]
    out = []
    for i in range(n):
        o = e_shoff + i * es
        no = struct.unpack_from('<I', b, o)[0]
        nm = stab[no:stab.find(b'\0', no)].decode('latin1')
        off = struct.unpack_from('<Q', b, o + 0x18)[0]
        size = struct.unpack_from('<Q', b, o + 0x20)[0]
        if size:
            out.append((off, off + size, nm))
    out.sort()
    return out

for tag, path in (("iris", r'..\iris\vmlinuz.A'), ("apu", r'..\apu\vmlinuz.A')):
    b = load(path)
    secs = secmap(b)
    print("=" * 70)
    print(tag)
    total = 0
    buckets = {}
    for m in re.finditer(rb'ksu_', b):
        pos = m.start()
        total += 1
        owner = "?"
        for a, e, nm in secs:
            if a <= pos < e:
                owner = nm
                break
        buckets[owner] = buckets.get(owner, 0) + 1
    print("  total ksu_ = %d" % total)
    for k, v in sorted(buckets.items(), key=lambda kv: -kv[1]):
        print("    %-28s %5d" % (k, v))

    # functional markers -- the things that actually matter
    print("  --- functional markers (must match) ---")
    for pat in (b"KernelSU", b"Crowning manager", b"save allow list",
                b"alt_syscall: dispatcher ->", b"dispatcher installed at alt slot",
                b"ksu_get_pristine_sys_call_table", b"ksu_get_alt_sys_call_tables",
                b"packages.list detected", b"/data/adb/ksud"):
        print("    %-42s %d" % (pat.decode(), b.count(pat)))
