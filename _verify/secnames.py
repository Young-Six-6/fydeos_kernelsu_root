import struct, zlib

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

def secnames(b):
    e_shoff = struct.unpack_from('<Q', b, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', b, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', b, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', b, 0x3E)[0]
    sh = e_shoff + e_shstrndx * e_shentsize
    stroff = struct.unpack_from('<Q', b, sh + 0x18)[0]
    strsize = struct.unpack_from('<Q', b, sh + 0x20)[0]
    stab = b[stroff:stroff + strsize]
    names = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        nameoff = struct.unpack_from('<I', b, o)[0]
        nm = stab[nameoff:stab.find(b'\0', nameoff)].decode('latin1')
        if nm:
            names.append(nm)
    return names

PAIRS = [("iris", r'..\iris\vmlinuz.A', r'..\..\ghostlock\work\off-iris-vmlinuz.A'),
         ("apu", r'..\apu\vmlinuz.A', r'..\..\ghostlock\work\off-apu-vmlinuz.A')]

for tag, ours, off in PAIRS:
    a = secnames(load(ours))
    c = secnames(load(off))
    print("=" * 74)
    print("%s  ours=%d sections   official=%d sections" % (tag, len(a), len(c)))
    print("  identical list      : %s" % (a == c))
    print("  only in ours        : %s" % (sorted(set(a) - set(c)) or "none"))
    print("  only in official    : %s" % (sorted(set(c) - set(a)) or "none"))
    if a != c:
        print("  ours order     : %s" % ", ".join(a))
        print("  official order : %s" % ", ".join(c))
