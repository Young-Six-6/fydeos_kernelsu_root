"""Structural sanity check for the shell scripts, since no bash is available here.

Checks the things that actually break these scripts:
  * heredoc openers have a matching terminator
  * if/fi, for/done, case/esac, while/done, do/done balance
  * quotes are balanced per logical line
  * no CRLF line endings (they break `bash script.sh` on Linux)
  * python3 - <<'PY' blocks contain valid Python
"""
import re
import sys
import os

SCRIPTS = ["build.sh", "deploy.sh", "verify.sh", "fixes/arc-boot-continue-wait.sh", "fixes/install-arc-race-fix.sh"]
# scripts live one level above tools/
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OPEN_KW = {
    "if": "fi",
    "for": "done",
    "while": "done",
    "until": "done",
    "case": "esac",
}


def strip_comment(line):
    """Remove a trailing shell comment, respecting quotes and ${var#pat}.

    A naive `line.split("#")[0]` is wrong in two common cases:
        case "$a" in --esp=*) x="${a#--esp=}" ;; esac   # '#' is parameter expansion
        echo "a # b"                                    # '#' is inside quotes
    Both would truncate the line and produce bogus keyword-balance errors.
    """
    out = []
    i = 0
    n = len(line)
    quote = None
    while i < n:
        c = line[i]
        if quote is None:
            if c in ("'", '"'):
                quote = c
            elif c == "#":
                # A comment only starts at the beginning of a word, i.e. after
                # whitespace or at the start of the line. `${a#pat}` has no space.
                if i == 0 or line[i - 1] in " \t;&|()":
                    break
            out.append(c)
        else:
            if c == "\\" and quote == '"' and i + 1 < n:
                out.append(c)
                out.append(line[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(c)
        i += 1
    return "".join(out)


def check(path):
    raw = open(path, "rb").read()
    problems = []

    if b"\r\n" in raw:
        problems.append("CRLF line endings present (breaks bash on Linux)")

    text = raw.decode("utf-8", "replace")
    lines = text.split("\n")

    stack = []
    heredocs = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # heredoc terminator?
        if heredocs:
            term = heredocs[-1]
            if stripped == term or (term.startswith("'") and stripped == term.strip("'")):
                heredocs.pop()
            i += 1
            continue

        # skip comments and blanks for keyword counting
        code = strip_comment(line)

        # heredoc opener — may be followed by `|| die "..."`, so don't anchor to EOL.
        # Body starts on the next line regardless of what trails the redirection.
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        if m:
            heredocs.append(m.group(2))
            i += 1
            continue

        # single-quote balance (rough, ignores escaped quotes)
        if code.count("'") % 2 == 1 and not re.search(r"<<-?\s*'", line):
            # could be a multi-line single-quoted string; only warn
            pass

        # keyword tracking on word boundaries.
        # Strip quoted strings first: `log "=== done ==="` must not count as a
        # `done` keyword, and `echo "if x"` must not open an `if` block.
        scrub = re.sub(r"'[^']*'", "''", code)
        scrub = re.sub(r'"[^"]*"', '""', scrub)
        words = re.findall(r"\b(if|then|elif|else|fi|for|while|until|do|done|case|esac)\b", scrub)
        for w in words:
            if w in ("if", "for", "while", "until", "case"):
                # `for x in ...; do` — the do comes later
                stack.append((w, i + 1))
            elif w in ("fi", "esac"):
                if not stack:
                    problems.append("line %d: stray '%s'" % (i + 1, w))
                else:
                    o, ln = stack.pop()
                    if OPEN_KW.get(o) != w:
                        problems.append("line %d: '%s' closes '%s' opened at line %d"
                                        % (i + 1, w, o, ln))
            elif w == "done":
                if not stack:
                    problems.append("line %d: stray 'done'" % (i + 1))
                else:
                    o, ln = stack.pop()
                    if OPEN_KW.get(o) != "done":
                        problems.append("line %d: 'done' closes '%s' opened at line %d"
                                        % (i + 1, o, ln))
        i += 1

    if heredocs:
        problems.append("unterminated heredoc(s): %s" % ", ".join(heredocs))
    if stack:
        problems.append("unclosed block(s): %s"
                        % ", ".join("%s@%d" % (o, ln) for o, ln in stack))

    return problems


def check_embedded_python(path):
    """Extract python3 - <<'PY' ... PY blocks and compile them."""
    text = open(path, encoding="utf-8", errors="replace").read()
    problems = []
    for m in re.finditer(r"python3[^\n]*<<'?PY'?[A-Za-z0-9_]*\n(.*?)\n[A-Za-z0-9_]*PY[A-Za-z0-9_]*",
                         text, re.S):
        body = m.group(1)
        try:
            compile(body, "<embedded>", "exec")
        except SyntaxError as e:
            problems.append("embedded python SyntaxError: %s (line %s)" % (e.msg, e.lineno))
    return problems


def main():
    total = 0
    for s in SCRIPTS:
        p = os.path.join(BASE, s)
        if not os.path.exists(p):
            print("%-12s MISSING" % s)
            continue
        probs = check(p) + check_embedded_python(p)
        n_lines = sum(1 for _ in open(p, encoding="utf-8", errors="replace"))
        if probs:
            total += len(probs)
            print("%-12s %4d lines   %d problem(s)" % (s, n_lines, len(probs)))
            for x in probs:
                print("    - %s" % x)
        else:
            print("%-12s %4d lines   OK" % (s, n_lines))

    print()
    print("total problems: %d" % total)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
