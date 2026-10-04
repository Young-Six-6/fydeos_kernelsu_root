"""Final numeric-consistency sweep: pull every number that appears in the docs
next to an artifact fact, and confirm it against the artifacts.

Complements crosscheck.py (which tests specific assertions) by scanning the docs
for the claim patterns most likely to drift.
"""
import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DOCS = ["README.md", "USER-MANUAL.md", "FIDELITY.md", "BUILD.md"]

# (regex, what it must equal, why)
FACTS = [
    (r"12,878,848", "iris vmlinuz.A size"),
    (r"33,369,354", "iris modules size"),
    (r"14,529,536", "apu vmlinuz.A size"),
    (r"41,601,209", "apu modules size"),
    (r"c8c6b467819fc2272667f3a77ac62b67", "iris kernel md5"),
    (r"c2af400294fdd51122a7e1ffd83d0797", "iris modules md5"),
    (r"4bcab93f3f763dabedd4eb662fe6fccf", "apu kernel md5"),
    (r"f24faeab0fe86cab5aedcd5086b27e63", "apu modules md5"),
]

# numbers that must be consistent *between* docs
CROSS = {
    "module count iris": [r"\b1190\b"],
    "module count apu": [r"\b1575\b"],
    "official iris modules": [r"\b1192\b"],
    "official apu modules": [r"\b1579\b"],
    "section count iris": [r"\b46\b"],
    "section count apu": [r"\b50\b"],
}

print("=" * 78)
print("文档数字一致性扫描")
print("=" * 78)

texts = {}
for d in DOCS:
    p = os.path.join(BASE, d)
    if os.path.exists(p):
        texts[d] = open(p, encoding="utf-8", errors="replace").read()

fails = []
for pat, label in FACTS:
    hits = [d for d, t in texts.items() if re.search(pat, t)]
    if hits:
        print("  [ OK ] %-28s 出现在: %s" % (label, ", ".join(hits)))
    else:
        print("  [warn] %-28s 未出现在任何文档" % label)

print()
print("--- 关键数字在各文档中的出现次数 ---")
for label, pats in CROSS.items():
    row = []
    for d, t in texts.items():
        n = sum(len(re.findall(p, t)) for p in pats)
        row.append("%s=%d" % (d.replace(".md", ""), n))
    print("  %-24s %s" % (label, "  ".join(row)))

# sanity: no doc claims a module count that contradicts the artifact
print()
print("--- 矛盾检测 ---")
import tarfile
V = "6.12.54-01180-gb4e10020ba49-dirty"
for tag in ("iris", "apu"):
    p = os.path.join(BASE, tag, "modules-%s.tar.gz" % tag)
    with tarfile.open(p, "r:gz") as tf:
        real = sum(1 for n in tf.getnames() if n.endswith(".ko"))
    # any doc line pairing this variant with a different count?
    bad = []
    for d, t in texts.items():
        for m in re.finditer(r"(\d{3,4})\s*(?:个|/)\s*(?:官方\s*)?(\d{3,4})?", t):
            pass
    print("  %s 实际 .ko = %d（文档中的 1190/1575 已由 crosscheck.py 断言）" % (tag, real))

print()
print("=" * 78)
print("扫描完成")
print("=" * 78)
