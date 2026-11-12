#!/usr/bin/env python3
# port.py SRC OUT: ports our benchmark sources to STINT's compiler (LLVM 9 Tapir, -fcilkplus), for stint.sh ours.
# Mechanical, three edits, nothing else:
#   1. cilk_scope { BODY }  ->  { BODY cilk_sync; }   (that compiler has no cilk_scope; the sync at the end of the block
#      waits for the block's spawns as cilk_scope does, and also for any earlier spawns of the function, of which these
#      programs have none outstanding at a scope's end; at one worker the two are the same execution).
#   2. drop "#ifdef SERIAL / #include <cilk/cilk_stub.h> / #endif" (SERIAL is never defined; the header is OpenCilk's).
#   3. END_OF_COMPUTATION hook, as STINT's benchmarks have it: before main's last return, under #ifdef END_OF_COMPUTATION,
#      a call to stint_end_of_computation() (stint-eoc.cpp: global_trace.end_of_computation(), which prints "###stats:###").
# Every other byte is unchanged. Prints one line per file; a scope body containing return/break/continue/goto (which
# would jump past the inserted sync) is reported as a WARN.
import os, re, sys

FILES = ["cholesky.c", "cilksort.c", "fib.c", "lu.c", "matmul.c", "nqueens.c", "qsort.cpp", "rectmul.c",
         "rectmulred.c", "spp_karatsuba.cpp", "spp_sort.cpp", "strassen.c"]
COPY = ["getoptions.c", "getoptions.h", "timing.h"]


def code_mask(s):
    """mask[i] is True where s[i] is code (not inside a comment, string or char literal)."""
    m = [True] * len(s)
    i, n = 0, len(s)
    while i < n:
        if s.startswith("//", i):
            j = s.find("\n", i)
            j = n if j < 0 else j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2)
            j = n if j < 0 else j + 2
        elif s[i] in "\"'":
            q, j = s[i], i + 1
            while j < n and s[j] != q:
                j += 2 if s[j] == "\\" else 1
            j += 1
        else:
            i += 1
            continue
        for k in range(i, min(j, n)):
            m[k] = False
        i = j
    return m


def match_brace(s, m, i):
    """Index of the '}' matching the '{' at i."""
    d = 0
    for k in range(i, len(s)):
        if not m[k]:
            continue
        if s[k] == "{":
            d += 1
        elif s[k] == "}":
            d -= 1
            if d == 0:
                return k
    raise ValueError("unbalanced braces")


def port_scopes(s, warn):
    n = 0
    while True:
        m = code_mask(s)
        hit = next((x for x in re.finditer(r"\bcilk_scope\b", s) if m[x.start()]), None)
        if not hit:
            return s, n
        o = hit.end()
        while s[o].isspace():
            o += 1
        if s[o] != "{":
            raise ValueError(f"cilk_scope at {hit.start()} is not followed by a block")
        c = match_brace(s, m, o)
        body = "".join(ch if m[o + k] else " " for k, ch in enumerate(s[o:c]))
        if re.search(r"\b(return|break|continue|goto)\b", body):
            warn.append(f"scope at line {s.count(chr(10), 0, hit.start()) + 1} has return/break/continue/goto")
        ls = s.rfind("\n", 0, c) + 1
        if s[ls:c].strip() == "":  # '}' on its own line: the sync on its own line, indented one level deeper
            ins = s[ls:c] + "  cilk_sync;\n"
            s = s[:ls] + ins + s[ls:]
        else:
            s = s[:c] + "cilk_sync; " + s[c:]
        s = s[:hit.start()] + s[o:]  # "cilk_scope {" -> "{"
        n += 1


STUB = re.compile(r"#ifdef SERIAL\n#include <cilk/cilk_stub.h>\n#endif\n")


def add_hook(s, cxx):
    m = code_mask(s)
    mm = next((x for x in re.finditer(r"\bint\s+main\s*\(", s) if m[x.start()]), None)
    if not mm:
        raise ValueError("no main")
    o = s.index("{", mm.end())
    c = match_brace(s, m, o)
    rets = [x.start() for x in re.finditer(r"\breturn\b", s[o:c]) if m[o + x.start()]]
    at = o + rets[-1] if rets else c
    ls = s.rfind("\n", 0, at) + 1
    ind = re.match(r"[ \t]*", s[ls:]).group(0)
    hook = f"#ifdef END_OF_COMPUTATION\n{ind}stint_end_of_computation();\n#endif\n"
    s = s[:ls] + hook + s[ls:]
    decl = ('#ifdef END_OF_COMPUTATION\n' + ('extern "C" ' if cxx else '') +
            'void stint_end_of_computation(void);  // stint-eoc.cpp\n#endif\n')
    at = re.search(r"^#include <cilk/cilk.h>\n", s, re.M)  # every program has it, outside any #if
    if not at:
        raise ValueError("no #include <cilk/cilk.h>")
    return s[:at.end()] + decl + s[at.end():]


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out)
    for f in COPY:
        with open(os.path.join(src, f)) as a, open(os.path.join(out, f), "w") as b:
            b.write(a.read())
    for f in FILES:
        with open(os.path.join(src, f)) as a:
            s = a.read()
        warn = []
        s, n = port_scopes(s, warn)
        s, k = STUB.subn("", s)
        if "cilk_stub" in s:
            raise SystemExit(f"{f}: a cilk_stub.h include outside the SERIAL block")
        s = add_hook(s, f.endswith(".cpp"))
        with open(os.path.join(out, f), "w") as b:
            b.write(s)
        print(f"PORT {f}: {n} cilk_scope -> cilk_sync, {k} cilk_stub block dropped, hook added"
              + "".join(f"; WARN {w}" for w in warn))


main()
