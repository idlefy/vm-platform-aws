#!/usr/bin/env python3
"""Print each line of an HCL file with its comments removed, prefixed by "<n>:".

Used by scripts/boundary-check.sh. It exists because the obvious form —
`sed -e 's,//.*,,' -e 's,#.*,,'` — treats the `//` in a URL as a comment, so

    source = "git::https://host/repo.git//vms/modules/../shared?ref=<sha>"

is truncated at `https:` and the `../` after the module delimiter is never
seen. That is precisely the escape the guard exists to catch.

Quotes are tracked so a `#` or `//` inside a string survives; everything from
an unquoted `#` or `//` to end of line is dropped, and `/* ... */` state is
carried across lines — a `../` inside a block comment would otherwise be
reported as a boundary violation, and a guard that fires on a clean tree is one
nobody leaves switched on.

Heredocs are not handled: no .tf under vms/modules/ uses one, and a heredoc
body cannot introduce a module source.
"""
import sys


def strip(line: str, in_block: bool) -> "tuple[str, bool]":
    """Return the line with comments removed, and whether a block comment is open."""
    out, i, quote = [], 0, None
    while i < len(line):
        c = line[i]
        if in_block:
            if line[i:i + 2] == "*/":
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c == '"' or c == "'":
            quote = c
            out.append(c)
        elif c == "#":
            break
        elif line[i:i + 2] == "//":
            break
        elif line[i:i + 2] == "/*":
            in_block = True
            i += 2
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out), in_block


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: strip-hcl-comments.py <file>\n")
        return 2
    in_block = False
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            text, in_block = strip(line.rstrip("\n"), in_block)
            sys.stdout.write("%d:%s\n" % (n, text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
