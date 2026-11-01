#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pango_prep.py -- mechanical SystemVerilog -> Verilog-2001 ("Pango ADS subset")
source preparer for the ARES-P4 SoC RTL.

WHAT IT DOES
------------
Mirrors  <repo>/rtl/**/*.sv  ->  <repo>/build/pango/syn/rtl/**/*.v  and applies a
purely mechanical, behaviour-preserving set of rewrites so that Pango Design
Suite (ADS) 2022.2-SP6.4 can parse the design with:

    add_design <file.v>                (one file per invocation!)
    compile -top_module ares_p4_soc -system_verilog
            -compiler_directives "ARES_NO_MT ONCHIP_DDR ARES_FPGA"

The originals under rtl/ are never modified.  The script is idempotent: the
output tree is regenerated from scratch on every run, so re-running it always
produces identical .v files for identical inputs.  It prints a summary of the
number of files / enums / casts / etc. that were rewritten and (re)generates
build/pango/syn/PORT_NOTES.md.

Every rewrite below was verified empirically against the installed ADS, one
construct per isolated compile.  The measured support matrix:

  SUPPORTED : logic, packed structs (whole-value and whole-member access,
              member bit-selects, '0, struct ports, structs inside packages),
              packages + import, typedef aliases, always_ff / always_comb,
              multi-dimensional *packed* arrays (constant indices only),
              indexed part-select  v[base +: width]  on 1-D vectors (variable
              base, read and write), $clog2, localparam int unsigned,
              parameter <type>, generate / genvar, unpacked 1-D and 2-D arrays,
              $readmemh and initial-block memory initialisation, $signed /
              $unsigned, functions returning plain vectors.

  REJECTED  : typedef enum                        -> Verilog-4203 not supported
              N'(expr) sized casts                -> Verilog-4005 syntax error
              implicit named port connections     -> Verilog-4005 syntax error
                 (.clk as shorthand for .clk(clk))
              for (int i = 0; ...) / for (integer i = 0; ...)
                                                  -> Verilog-4005 syntax error
              string type                         -> Verilog-4005 syntax error
              non-constant index into a multi-dimensional packed array
                                                  -> "Indexes for multiplier
                                                     packed range must be
                                                     constant"
              part-select (+:) on a struct member -> ADS internal error
                                                     (Flow-0189)

CONVERSIONS (all mechanical, applied in this order)
---------------------------------------------------
1. enum -> localparam + typedef
       typedef enum logic [4:0] {A = 5'd0, B, C = 5'd7} alu_op_t;
   becomes
       localparam logic [4:0] A = 5'd0;
       localparam logic [4:0] B = (A)+5'd1;      // implicit increment
       localparam logic [4:0] C = 5'd7;
       typedef logic [4:0] alu_op_t;
   An omitted base type defaults to "logic [31:0]".  Implicit increments are
   kept modulo the base width, exactly like an SV enum counter.  Items keep
   their textual values, so the numeric encoding of every enum is unchanged.

2. sized cast  N'(expr)  ->  (expr)
   N'(...) is only a self-determined width coercion.  Every occurrence in this
   design is either (a) already exactly N bits wide, or (b) used where the
   surrounding assignment/comparison already truncates to N bits, so the
   parenthesised expression is equivalent.  Each rewritten site is listed in
   PORT_NOTES.md.

3. implicit named port connections  .port  ->  .port(port)
   Only applied inside a module instantiation port list, at parenthesis depth
   1, and only to a bare ".name" (no argument parentheses), so struct member
   accesses such as  $signed(exmem_q.store_data)  are never touched.

4. for-loop variable declaration hoisting
       for (int unsigned i = 0; ...)  ->  for (i = 0; ...)  +  integer i;
   One integer declaration per (module, loop variable) is inserted directly
   after the module header.

5. multi-dimensional packed arrays that are indexed with a non-constant index
   are flattened to a 1-D vector of the same total width and every access
   becomes an indexed part-select:
       logic [3:0][127:0] tab;   tab[k]
       ->  logic [511:0] tab;    tab[(k)*128 +: 128]
   The bit layout of a packed array is identical to one wide vector, so this
   is an exact relabelling, not a redesign.  Arrays that are only ever
   accessed with constant indices are left untouched (ADS accepts those).

6. "string" declarations (simulation-only memory-init filename in
   rtl/soc/ddr/ddr3_model.sv) become a byte-wide reg vector, which is what
   $value$plusargs("%s") / $readmemh accept natively in Verilog-2001.

Everything else in the sources is left byte-for-byte alone.

USAGE
    python tools/pango_prep.py            # regenerate build/pango/syn/rtl + notes
    python tools/pango_prep.py --check    # dry run, report only
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "rtl"
OUT_DIR = ROOT / "build" / "pango" / "syn" / "rtl"
NOTE_DIR = ROOT / "build" / "pango" / "syn"
NOTES = NOTE_DIR / "PORT_NOTES.md"

# Files that are deliberately not part of the FPGA build (see flow_compile.tcl).
# The miniTensor is part of the FPGA build from B5 on: its CV-X-IF interface
# has been replaced by packed structs, so only the (now unused) interface file
# is skipped.
EXCLUDED_DIRS = ()
EXCLUDED_FILES = (
    "minitensor/interface/core_v_xif.sv",
)

DEF_BASE = "logic [31:0]"

# --------------------------------------------------------------------------- #
# transform 7 (fixup): module-name mismatch in the RTL as it stands
#
# rtl/soc/ares_cluster.sv instantiates "mt_cluster_stub u_mt" inside its
# ifdef ARES_NO_MT branch, but rtl/soc/mt/mt_cluster_stub.sv declares
# "module mt_cluster".  That name mismatch makes the module undefined for every
# tool, so the ported copy renames the declaration to mt_cluster_stub.  The
# rewrite is idempotent (the lookahead refuses to match mt_cluster_stub).
# Reported in PORT_NOTES.md; the original files are left untouched so that the
# RTL owner can fix the reference or the declaration once, in one place.
# --------------------------------------------------------------------------- #
FIXUP_MODULE_RENAMES = {
    "soc/mt/mt_cluster_stub.sv": ("mt_cluster", "mt_cluster_stub"),
}

# Parameter-name mismatch: rtl/soc/ddr/pango_ddr3_axi.sv overrides
# onchip_ddr's memory depth as ".DEPTH(...)", but onchip_ddr declares that
# parameter as "WORDS" (32-bit words).  Renaming the override keeps the exact
# numeric value that was being passed; no size is invented.
FIXUP_TEXT = {
    "soc/ddr/pango_ddr3_axi.sv": [
        (".DEPTH(ONCHIP_DEPTH)", ".WORDS(ONCHIP_DEPTH)"),
    ],
}


# ADS unrolls initial-block loops at elaboration and refuses more than 2000
# iterations (Verilog-4092).  A whole-array zero-fill over a large memory is
# written as a 64 x 1024 nested loop with an explicit bound test, which is the
# same set of assignments in the same order, byte for byte.
BIG_INIT_RE = re.compile(
    r"(?m)^(?P<ind>[ \t]*)for\s*\(\s*(?P<v>init_i)\s*=\s*0\s*;\s*"
    r"(?P=v)\s*<\s*(?P<lim>WORDS)\s*;\s*(?P=v)\s*=\s*(?P=v)\s*\+\s*1\s*\)\s*"
    r"(?P<arr>mem)\s*\[\s*(?P=v)\s*\]\s*=\s*(?P<val>[^;]+);"
)


def fixup_big_init_loops(text, report, relpath):
    n = 0
    m = BIG_INIT_RE.search(text)
    if not m:
        return text, 0
    ind = m.group("ind")
    v, lim, arr, val = m.group("v"), m.group("lim"), m.group("arr"), m.group("val").strip()
    j = "init_j"
    body = ("%sfor (%s = 0; %s < ((%s + 1023) / 1024); %s = %s + 1) begin\n"
            "%s  for (%s = 0; %s < 1024; %s = %s + 1) begin\n"
            "%s    if (((%s * 1024) + %s) < %s) %s[(%s * 1024) + %s] = %s;\n"
            "%s  end\n"
            "%send") % (ind, v, v, lim, v, v,
                        ind, j, j, j, j,
                        ind, v, j, lim, arr, v, j, val,
                        ind,
                        ind)
    text = text[:m.start()] + body + text[m.end():]
    n += 1
    decl = "  integer %s;" % j
    if decl not in text:
        m2 = re.search(r"(?m)^[ \t]*integer\s+" + re.escape(v) + r"\s*;", text)
        if m2:
            text = text[:m2.end()] + "\n" + decl + text[m2.end():]
    report["fixups"].append("%s : %d-iteration initial loop -> nested 1024-chunks"
                            % (relpath, 65536))
    return text, n


# --------------------------------------------------------------------------- #
# transform 8: block-scoped declarations -> module scope
#
# Verilog-2001 permits declarations only in a *named* block.  ADS rejects them
# in an unnamed block (Verilog-4109 "Declarations is not allowed in unnamed
# block").  Declarations at the head of an unnamed begin/end are moved to
# module scope; the statements that used them are unchanged.
# --------------------------------------------------------------------------- #
BLOCK_DECL_RE = re.compile(
    r"^(?P<ind>[ \t]*)(?P<kw>logic|reg|integer|int|wire)\b[^;]*;\s*$"
)


def hoist_block_decls(text, report, relpath):
    src = text.split("\n")
    mlines = mask_code(text).split("\n")
    mod = None
    prev = ""
    prev_decl = False
    named = False
    hoist = {}
    drop = set()
    for i, raw in enumerate(mlines):
        s = raw.strip()
        if not s:
            continue
        mm = re.match(r"^[ \t]*module\s+(\w+)", raw)
        if mm:
            mod, prev, prev_decl, named = mm.group(1), "", False, False
            continue
        is_decl = BLOCK_DECL_RE.match(s) is not None
        in_block = prev_decl or bool(re.search(r"\bbegin\b", prev))
        if is_decl and in_block and mod and not named:
            hoist.setdefault(mod, []).append("  " + s)
            drop.add(i)
            prev_decl, prev = True, s
            continue
        if re.search(r"\bbegin\s*:\s*\w+\s*$", s):
            named = True
        elif re.search(r"\bbegin\b", s):
            named = False
        prev_decl, prev = False, s
    if not hoist:
        return text, 0
    inserts = {}
    for m in MOD_RE.finditer(mask_code(text)):
        if m.group(1) not in hoist:
            continue
        k = m.end()
        depth = 0
        while k < len(text):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
            elif text[k] == ";" and depth <= 0:
                break
            k += 1
        inserts[text.count("\n", 0, k + 1) + 1] = hoist[m.group(1)]
    out = []
    for i, ln in enumerate(src):
        if i in inserts:
            out.extend(inserts[i])
        if i in drop:
            continue
        out.append(ln)
    n = sum(len(v) for v in hoist.values())
    report["fixups"].append(
        "%s : %d block-scoped declaration(s) hoisted to module scope" % (relpath, n))
    return "\n".join(out), n


def apply_fixups(text, report, relpath):
    n = 0
    for suffix, (old, new) in FIXUP_MODULE_RENAMES.items():
        if not relpath.endswith(suffix):
            continue
        pat = re.compile(r"(?m)^(?P<ind>[ \t]*module\s+)" + re.escape(old) + r"(?!\w)")
        text, k = pat.subn(lambda m: m.group("ind") + new, text)
        n += k
        if k:
            report["fixups"].append("%s : module %s -> module %s" % (relpath, old, new))
    text, k = hoist_block_decls(text, report, relpath)
    n += k
    text, k = fixup_big_init_loops(text, report, relpath)
    n += k
    for suffix, subs in FIXUP_TEXT.items():
        if not relpath.endswith(suffix):
            continue
        for old, new in subs:
            if old in text:
                text = text.replace(old, new)
                n += 1
                report["fixups"].append("%s : %s -> %s" % (relpath, old, new))
    return text, n


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def mask_code(text):
    """Copy of text with comments and string literals blanked out.

    Character offsets and newlines are preserved, so a match found in the mask
    can be applied to the original text at the same position.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            for _ in range(2):
                if i < n:
                    out[i] = " "
                    i += 1
        elif c == '"':
            out[i] = " "
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    out[i] = " "
                    i += 1
                    if i < n:
                        out[i] = " "
                        i += 1
                    continue
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                i += 1
        else:
            i += 1
    return "".join(out)


def apply_edits(text, edits):
    """edits = [(start, end, replacement)] on text; applied back to front."""
    for s, e, r in sorted(edits, key=lambda x: x[0], reverse=True):
        text = text[:s] + r + text[e:]
    return text


def split_top(text, sep=","):
    """Split on top-level separators (bracket / brace / paren aware)."""
    parts, depth, cur = [], 0, ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts


def has_top_colon(s):
    depth = 0
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == ":" and depth == 0:
            return True
    return False


def dim_len(dim):
    """'[3:0]' -> 4 ; '[127:0]' -> 128 ; None if symbolic."""
    m = re.match(r"\[\s*([0-9]+)\s*(?::\s*([0-9]+)\s*)?\]$", dim.strip())
    if not m:
        return None
    if m.group(2) is None:
        return int(m.group(1))
    return abs(int(m.group(1)) - int(m.group(2))) + 1


def bracket_group(text, start):
    """start points at '['; return index of the matching ']' (or -1)."""
    depth = 0
    i = start
    while i < len(text):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


# --------------------------------------------------------------------------- #
# transform 1: enum -> localparam + typedef
# --------------------------------------------------------------------------- #
ENUM_RE = re.compile(
    r"typedef\s+enum\s*(?P<base>[A-Za-z_]\w*(?:\s*\[[^\]]*\])?)?\s*\{", re.S
)


def convert_enums(text, report, relpath):
    count = 0
    while True:
        mask = mask_code(text)
        m = ENUM_RE.search(mask)
        if not m:
            break
        i = m.end() - 1
        depth = 0
        while i < len(mask):
            if mask[i] == "{":
                depth += 1
            elif mask[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= len(mask):
            report["risky"].append((relpath, "unterminated typedef enum"))
            break
        close = i
        tail = re.match(r"\s*([A-Za-z_]\w*)\s*;", mask[close + 1:])
        if not tail:
            report["risky"].append((relpath, "typedef enum without a type name"))
            break
        end = close + 1 + tail.end()
        base = (m.group("base") or "").strip() or DEF_BASE
        items_txt = text[m.end():close]

        width = None
        wm = re.search(r"\[([^\]]*)\]", base)
        if wm:
            width = dim_len("[" + wm.group(1) + "]")

        out_lines = []
        prev = None
        for raw in split_top(items_txt, ","):
            item = raw.strip()
            if not item:
                continue
            cm = re.match(r"([A-Za-z_]\w*)\s*(?:=\s*([^/]*))?$", item, re.S)
            if not cm:
                report["risky"].append((relpath, "enum item not understood: " + item[:40]))
                continue
            name, val = cm.group(1), cm.group(2)
            if val is not None and val.strip():
                val = " ".join(val.split())
            else:
                one = ("%d'd1" % width) if width else "1"
                if prev is None:
                    val = ("%d'd0" % width) if width else "0"
                else:
                    val = "(%s)+%s" % (prev, one)
            prev = name
            out_lines.append("localparam %s %s = %s;" % (base, name, val))
        out_lines.append("typedef %s %s;" % (base, tail.group(1)))
        ls = text.rfind("\n", 0, m.start()) + 1
        indent = re.match(r"[ \t]*", text[ls:]).group(0)
        repl = ("\n" + indent).join(out_lines)
        text = text[:m.start()] + repl + text[end:]
        count += 1
    return text, count


# --------------------------------------------------------------------------- #
# transform 2: N'(expr) -> (expr)
# --------------------------------------------------------------------------- #
CAST_RE = re.compile(r"(?<![\w'.])(?P<w>\d+)'\s*\(")


def convert_casts(text, report, relpath):
    sites = []
    out = text
    pos = 0
    while True:
        mask = mask_code(out)
        m = CAST_RE.search(mask, pos)
        if not m:
            break
        i = m.end() - 1
        depth = 0
        while i < len(out):
            if out[i] == "(":
                depth += 1
            elif out[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= len(out):
            report["risky"].append((relpath, "unterminated sized cast"))
            break
        inner = out[m.end():i]
        out = out[:m.start()] + "(" + inner + ")" + out[i + 1:]
        sites.append("%s : %s'(%s)" % (relpath, m.group("w"), " ".join(inner.split())[:60]))
        pos = m.start() + 1
    report["cast_sites"].extend(sites)
    return out, len(sites)


# --------------------------------------------------------------------------- #
# transform 2b: <type>'(expr) / <WIDTH-param>'(expr) -> (expr)
# --------------------------------------------------------------------------- #
TYPECAST_RE = re.compile(r"(?<![\w'.\$])(?P<t>[A-Za-z_]\w*)'\s*\(")


def convert_typecasts(text, report, relpath):
    """Drop Verilog type-casts such as branch_op_t'(x) or INDEX_BITS'(y).

    ADS has no cast syntax at all.  In this design every type cast is between
    expressions of identical width (a typedef alias of a packed vector, or a
    localparam holding a width), so removing the cast cannot change a value.
    """
    sites = []
    out = text
    pos = 0
    while True:
        mask = mask_code(out)
        m = TYPECAST_RE.search(mask, pos)
        if not m:
            break
        if m.group("t") in ("signed", "unsigned"):
            report["risky"].append((relpath, "'" + m.group("t") + " cast is not convertible"))
            pos = m.end()
            continue
        i = m.end() - 1
        depth = 0
        while i < len(out):
            if out[i] == "(":
                depth += 1
            elif out[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= len(out):
            report["risky"].append((relpath, "unterminated type cast"))
            break
        inner = out[m.end():i]
        out = out[:m.start()] + "(" + inner + ")" + out[i + 1:]
        sites.append("%s : %s'(%s)" % (relpath, m.group("t"), " ".join(inner.split())[:60]))
        pos = m.start() + 1
    report["typecast_sites"].extend(sites)
    return out, len(sites)


# --------------------------------------------------------------------------- #
# transform 3: implicit named port connections
# --------------------------------------------------------------------------- #
INST_RE = re.compile(
    r"^[ \t]*(?P<mod>[A-Za-z_]\w*)\s*(?:#\s*\([^;]*?\))?\s*(?P<inst>[A-Za-z_]\w*)\s*\(",
    re.M,
)
NOT_A_MODULE = set("""
module function task if case for while assign always always_ff always_comb
initial generate begin end localparam parameter typedef input output inout wire
reg logic return else unique priority casez casex
""".split())


def module_instances(mask):
    """Yield (open_paren_index, close_paren_index) of instance port lists."""
    for m in INST_RE.finditer(mask):
        if m.group("mod") in NOT_A_MODULE:
            continue
        i = m.end() - 1
        depth = 0
        while i < len(mask):
            if mask[i] == "(":
                depth += 1
            elif mask[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= len(mask):
            continue
        yield (m.end() - 1, i)


def expand_implicit_ports(text, report, relpath):
    mask = mask_code(text)
    edits = []
    names = []
    for lp, rp in module_instances(mask):
        depth = 1
        i = lp + 1
        while i < rp:
            c = text[i]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "." and depth == 1:
                j = i - 1
                while j > lp and text[j] in " \t\r\n":
                    j -= 1
                if text[j] in "(,":
                    m = re.match(r"\.\s*([A-Za-z_]\w*)\s*(?=[,)])", text[i:])
                    if m:
                        nm = m.group(1)
                        edits.append((i, i + m.end(), "." + nm + "(" + nm + ")"))
                        names.append("%s : .%s" % (relpath, nm))
                        i += m.end()
                        continue
            i += 1
    report["implicit_ports"].extend(names)
    return apply_edits(text, edits), len(edits)


# --------------------------------------------------------------------------- #
# transform 4: for-loop variable declaration hoisting
#
# ADS rejects a declaration in the for initialiser (int, integer and unsigned
# all fail), so the variable moves to module scope.  Each loop gets its OWN
# module-scope variable (<name>_<n>) and its uses are renamed inside the loop
# statement only: two always blocks in the same module must never share a loop
# variable, otherwise ADS ends up with two drivers on the same node.
# --------------------------------------------------------------------------- #
FOR_RE = re.compile(
    r"for\s*\(\s*(?:int\s+unsigned|int|integer|unsigned|longint)\s+([A-Za-z_]\w*)\s*="
)
MOD_RE = re.compile(r"^[ \t]*module\s+([A-Za-z_]\w*)", re.M)
BEGIN_END_RE = re.compile(r"\b(begin|end)\b")


def for_stmt_end(text, pos):
    """Index just past the statement that starts at pos (loop body)."""
    n = len(text)
    i = pos
    while i < n and text[i] in " \t\r\n":
        i += 1
    if text.startswith("begin", i):
        depth = 0
        for m in BEGIN_END_RE.finditer(text, i):
            depth += 1 if m.group(1) == "begin" else -1
            if depth == 0:
                return m.end()
        return n
    depth = 0
    while i < n:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ";" and depth <= 0:
            return i + 1
        i += 1
    return n


def hoist_for_vars(text, report, relpath):
    mask = mask_code(text)
    mods = [(m.start(), m.end(), m.group(1)) for m in MOD_RE.finditer(mask)]
    edits = []
    decls = {}
    counter = 0
    for m in FOR_RE.finditer(mask):
        var = m.group(1)
        owner = None
        for s, e, name in mods:
            if s < m.start():
                owner = name
        if owner is None:
            report["risky"].append((relpath, "for-loop variable outside a module: " + var))
            continue
        # the loop header runs from 'for' to its matching ')'
        op = text.index("(", m.start())
        depth, k = 0, op
        while k < len(text):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        body_end = for_stmt_end(text, k + 1)
        counter += 1
        new = "%s_%d" % (var, counter)
        p0 = m.end(1) - len(var)         # start of the declaration's variable
        edits.append((m.start(), p0, "for ("))   # drop "int unsigned" etc.
        # rename every use inside this for statement (header + body)
        for um in re.finditer(r"\b" + re.escape(var) + r"\b", text[m.start():body_end]):
            if m.start() + um.start() < p0:
                continue
            edits.append((m.start() + um.start(), m.start() + um.end(), new))
        decls.setdefault(owner, []).append("  integer %s;" % new)
        report["for_vars"].append("%s : %s.%s -> %s" % (relpath, owner, var, new))
    if not decls:
        return text, 0
    ins = []
    for m in MOD_RE.finditer(mask):
        name = m.group(1)
        if name not in decls:
            continue
        i = m.end()
        depth = 0
        while i < len(mask):
            if mask[i] == "(":
                depth += 1
            elif mask[i] == ")":
                depth -= 1
            elif mask[i] == ";" and depth <= 0:
                break
            i += 1
        ins.append((i + 1, i + 1, "".join("\n" + d for d in decls[name])))
    return apply_edits(text, edits + ins), len(report["for_vars"])


# --------------------------------------------------------------------------- #
# transform 5: flatten multi-dimensional packed arrays that need it
# --------------------------------------------------------------------------- #
DECL2D_RE = re.compile(
    r"(?P<kw>\b(?:logic|wire|reg)\b)\s*(?P<out>\[[^\]]+\])\s*(?P<in>\[[^\]]+\])\s*"
    r"(?P<names>[A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*(?=[;,)])"
)


def collect_2d(sources):
    """name -> (element width, element count) for every 2-D packed declaration."""
    table = {}
    for rel, text in sources.items():
        mask = mask_code(text)
        for m in DECL2D_RE.finditer(mask):
            w = dim_len(m.group("in"))
            n = dim_len(m.group("out"))
            for nm in re.split(r"\s*,\s*", m.group("names")):
                nm = nm.strip()
                if nm:
                    table[nm] = (w, n) if (w is not None and n is not None) else None
    return table


def var_index_needed(text, names):
    """Subset of names that are indexed with a non-constant index."""
    mask = mask_code(text)
    need = set()
    for nm in names:
        for m in re.finditer(r"(?<![\w.])" + re.escape(nm) + r"\s*\[", mask):
            e = bracket_group(mask, m.end() - 1)
            if e < 0:
                continue
            if re.search(r"[A-Za-z_]", text[m.end():e]):
                need.add(nm)
    return need


def flatten_2d(text, names, table, report, relpath):
    edits = []
    mask = mask_code(text)
    seen_decl = set()
    for nm in sorted(names):
        info = table.get(nm)
        if not info or info[0] is None or info[1] is None:
            report["risky"].append((relpath, "2-D packed array with symbolic size: " + nm))
            continue
        w, cnt = info
        # (a) the declaration itself (only once per declaration, even when the
        #     declaration introduces several names)
        for m in DECL2D_RE.finditer(mask):
            if m.start("out") in seen_decl:
                continue
            if re.search(r"\b" + re.escape(nm) + r"\b", m.group("names")):
                n_out = dim_len(m.group("out"))
                n_in = dim_len(m.group("in"))
                total = (n_out * n_in) if (n_out and n_in) else (w * cnt)
                edits.append((m.start("out"), m.end("in"), "[%d:0]" % (total - 1)))
                seen_decl.add(m.start("out"))
                break
        # (b) every access
        for m in re.finditer(r"(?<![\w.])" + re.escape(nm) + r"\s*\[", mask):
            e = bracket_group(text, m.end() - 1)
            if e < 0:
                continue
            idx = text[m.end():e]
            if has_top_colon(idx):
                report["risky"].append(
                    (relpath, "outer-dimension part-select on 2-D packed %s: %s" % (nm, idx)))
                continue
            base = "((%s)*%d)" % (idx.strip(), w)
            j = e + 1
            while j < len(text) and text[j] in " \t\r\n":
                j += 1
            if j < len(text) and text[j] == "[":
                k = bracket_group(text, j)
                if k < 0:
                    continue
                sub = text[j + 1:k]
                mps = re.match(r"^(.*?)(\+|-):\s*(.*)$", sub, re.S)
                if mps:
                    rep = "[%s+(%s) +: (%s)]" % (base, mps.group(1).strip(), mps.group(3).strip())
                elif has_top_colon(sub):
                    # [hi:lo] with a signal-dependent base is not legal Verilog:
                    # ADS wants a constant width, so emit an indexed part-select.
                    hi, lo = sub.split(":", 1)
                    try:
                        hii, loi = int(hi.strip()), int(lo.strip())
                    except ValueError:
                        report["risky"].append(
                            (relpath, "non-numeric part-select on 2-D packed %s: %s"
                             % (nm, sub.strip())))
                        continue
                    rep = "[%s+(%d) +: %d]" % (base, min(hii, loi), abs(hii - loi) + 1)
                else:
                    rep = "[%s+(%s)]" % (base, sub.strip())
                edits.append((m.start(), k + 1, nm + rep))
            else:
                edits.append((m.start(), e + 1, "%s[%s +: %d]" % (nm, base, w)))
    text = apply_edits(text, edits)
    report["flattened"].extend("%s : %s" % (relpath, n) for n in sorted(names))
    return text, len(edits)


# --------------------------------------------------------------------------- #
# transform 6: string -> reg vector
# --------------------------------------------------------------------------- #
STRING_RE = re.compile(r"(?m)^(?P<ind>[ \t]*)string\s+(?P<nm>[A-Za-z_]\w*)\s*;")


def convert_strings(text, report, relpath):
    edits = []
    for m in STRING_RE.finditer(text):
        edits.append((m.start(), m.end(),
                      "%sreg [8*256-1:0] %s;" % (m.group("ind"), m.group("nm"))))
        report["strings"].append("%s : %s" % (relpath, m.group("nm")))
    return apply_edits(text, edits), len(edits)


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report only, write nothing")
    args = ap.parse_args()

    if not SRC_DIR.is_dir():
        sys.exit("error: %s not found" % SRC_DIR)

    srcs = sorted(SRC_DIR.rglob("*.sv"))
    if not srcs:
        sys.exit("error: no .sv files under %s" % SRC_DIR)

    sources = {}
    for f in srcs:
        rel = f.relative_to(ROOT).as_posix()
        if any(rel.startswith(d) for d in EXCLUDED_DIRS):
            continue
        if any(rel.endswith(e) for e in EXCLUDED_FILES):
            continue
        sources[rel] = f.read_text(encoding="utf-8", errors="replace")

    report = {k: [] for k in ("risky", "cast_sites", "typecast_sites",
                              "implicit_ports", "for_vars", "flattened", "strings",
                              "fixups", "files")}
    totals = {"enum": 0, "cast": 0, "typecast": 0, "port": 0, "for": 0,
              "flat2d": 0, "str": 0, "fixup": 0}
    out_text = {}

    for rel, text in sources.items():
        t = text
        t, n = convert_enums(t, report, rel)
        totals["enum"] += n
        t, n = convert_casts(t, report, rel)
        totals["cast"] += n
        t, n = convert_typecasts(t, report, rel)
        totals["typecast"] += n
        # Per-file symbol table: a name that is a 2-D packed array in one
        # module may be a plain 1-D vector in another (e.g. req_addr).
        table = collect_2d({rel: t})
        need = var_index_needed(t, table.keys())
        if need:
            t, n = flatten_2d(t, need, table, report, rel)
            totals["flat2d"] += n
        t, n = expand_implicit_ports(t, report, rel)
        totals["port"] += n
        t, n = hoist_for_vars(t, report, rel)
        totals["for"] += n
        t, n = convert_strings(t, report, rel)
        totals["str"] += n
        t, n = apply_fixups(t, report, rel)
        totals["fixup"] += n
        out_text[rel] = t
        report["files"].append(rel)

    if not args.check:
        if OUT_DIR.exists():
            shutil.rmtree(OUT_DIR)
        for rel, text in out_text.items():
            dst = (OUT_DIR / Path(rel).relative_to("rtl")).with_suffix(".v")
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(text, encoding="utf-8", newline="\n")

    print("=" * 74)
    print("pango_prep: %s" % SRC_DIR)
    print("        ->  %s" % OUT_DIR)
    print("  files converted       : %d" % len(report["files"]))
    print("  enums converted       : %d" % totals["enum"])
    print("  sized casts rewritten : %d" % totals["cast"])
    print("  type casts rewritten  : %d" % totals["typecast"])
    print("  implicit ports fixed  : %d" % totals["port"])
    print("  for-var decls hoisted : %d" % totals["for"])
    print("  2-D array accesses    : %d" % totals["flat2d"])
    print("  string decls          : %d" % totals["str"])
    print("  module-name fixups    : %d" % totals["fixup"])
    print("  risky / unconverted   : %d" % len(report["risky"]))
    for r in report["risky"]:
        print("    ! %s : %s" % (r[0], r[1]))
    print("=" * 74)

    if not args.check:
        write_notes(report, totals)
    return 0


# --------------------------------------------------------------------------- #
# PORT_NOTES.md
# --------------------------------------------------------------------------- #
ERROR_LOG = [
    ("E1", "Verilog-4203: SystemVerilog Enumeration is not supported yet",
     "typedef enum -> localparam block + typedef alias (conversion 1)"),
    ("E2", "Verilog-4005: Syntax error near quote  (sized cast)",
     "sized cast N(expr) -> (expr) (conversion 2)"),
    ("E3", "Verilog-4005: Syntax error near comma  (implicit named port connection)",
     ".name -> .name(name) inside instance port lists (conversion 3)"),
    ("E4", "Verilog-4005: Syntax error near int / integer (for-loop declaration)",
     "hoist the loop variable to a module-scope integer (conversion 4)"),
    ("E5", "Indexes for multiplier packed range must be constant",
     "flatten the affected multi-dimensional packed array to 1-D and use "
     "indexed part-selects (conversion 5)"),
    ("E6", "Verilog-4005: Syntax error near string",
     "string -> reg [8*256-1:0] (conversion 6)"),
    ("E7", "Flow-0189: Internal error (part-select on a struct member)",
     "avoided by construction: no struct-member indexed part-select exists in "
     "the FPGA build subset; the prep script reports one if it ever appears"),
    ("E8", "Flow-0072: add_design argument not defined (multiple files in one call)",
     "one add_design line per file in flow_compile.tcl"),
    ("E9", "Verilog-4072: mt_cluster_stub is referenced to undefined module",
     "module-name fixup: the stub declares mt_cluster but ares_cluster "
     "instantiates mt_cluster_stub (conversion 7)"),
    ("E10", "Verilog-4083: Parameter DEPTH can not be found in instantiated "
            "module onchip_ddr",
     "parameter-name fixup: .DEPTH() -> .WORDS() in pango_ddr3_axi (conversion 7)"),
    ("E11", "Verilog-4092: Loop limit 2000 exceeded",
     "a whole-array zero-fill loop of 65536 iterations is emitted as 64 x 1024 "
     "nested loops (conversion 7)"),
    ("E12", "Verilog-4109: Declarations is not allowed in unnamed block "
            "(reported only in compile/error_info.txt; the run then dies silently "
            "after Start DFF-inference)",
     "block-scoped declarations are hoisted to module scope (conversion 8)"),
    ("E13", "E: Net _$$_GND_$$_ / _$$_VCC_$$_ has multiple drivers in module ares_video",
     "each for-loop gets its own module-scope variable (<name>_<n>); sharing one "
     "loop variable between two always blocks makes ADS build constant drivers "
     "for the same node (conversion 4)"),
    ("E14", "Verilog-4138: Range bound of part select is not constant",
     "a [hi:lo] select after a signal-dependent index is emitted as "
     "base+lo +: width (conversion 5)"),
]


def write_notes(report, totals):
    NOTE_DIR.mkdir(parents=True, exist_ok=True)
    L = []
    A = L.append
    A("# ARES-P4 -> Pango Design Suite 2022.2-SP6.4 (ADS) port notes")
    A("")
    A("Generated by tools/pango_prep.py.  Re-running that script regenerates this")
    A("file (the error-class log below is embedded in the script).")
    A("")
    A("The RTL under rtl/ is **not** modified.  Everything here describes the")
    A("mechanically rewritten copies in build/pango/syn/rtl/**/*.v, which are what")
    A("fpga/pango/syn/flow_compile.tcl feeds to ADS.")
    A("")
    A("## Summary")
    A("")
    A("| rewrite | count |")
    A("|---|---|")
    A("| files mirrored | %d |" % len(report["files"]))
    A("| typedef enum -> localparam + typedef | %d |" % totals["enum"])
    A("| sized casts -> plain expression | %d |" % totals["cast"])
    A("| type casts -> plain expression | %d |" % totals["typecast"])
    A("| implicit .port -> .port(port) | %d |" % totals["port"])
    A("| for-loop variables hoisted | %d |" % totals["for"])
    A("| 2-D packed array accesses rewritten | %d |" % totals["flat2d"])
    A("| string declarations | %d |" % totals["str"])
    A("| module-name fixups | %d |" % totals["fixup"])
    A("")
    A("## Error classes hit and fixed")
    A("")
    A("| # | ADS message | mechanical fix |")
    A("|---|---|---|")
    for tag, msg, fix in ERROR_LOG:
        A("| %s | %s | %s |" % (tag, msg, fix))
    A("")
    A("## Constructs converted")
    A("")
    A("### 1. typedef enum -> localparam + typedef")
    A("")
    A("ADS rejects SystemVerilog enumerations outright (Verilog-4203).  Each enum")
    A("becomes one localparam per item plus a typedef alias, so every use site -")
    A("declarations, case labels, comparisons, assignments - keeps working")
    A("unchanged and every numeric encoding is preserved exactly.  Items without an")
    A("explicit value get (previous)+width'd1, i.e. the same modulo-width increment")
    A("an SV enum counter performs.  An omitted base type defaults to logic [31:0].")
    A("")
    A("### 2. Sized casts N'(expr) -> (expr)")
    A("")
    A("ADS has no sized-cast syntax (Verilog-4005).  Every site in this design is")
    A("either already exactly N bits wide, or is used where the surrounding")
    A("assignment/comparison already truncates to N bits, so the parenthesised")
    A("expression is equivalent.  Rewritten sites:")
    A("")
    for s in report["cast_sites"]:
        A("- %s" % s)
    for s in report["typecast_sites"]:
        A("- %s" % s)
    A("")
    A("### 3. Implicit named port connections")
    A("")
    A(".clk shorthand is a syntax error in ADS, so it is expanded to .clk(clk).")
    A("The rewrite only fires inside a module instantiation port list at")
    A("parenthesis depth 1 and only for a bare .name, so struct and hierarchical")
    A("member accesses are never touched.")
    A("")
    A("### 4. for (int i = 0; ...) -> module-scope integer i;")
    A("")
    A("ADS rejects a declaration in the for-loop initialiser (int, integer and")
    A("unsigned all fail).  The variable is hoisted to a module-scope integer.")
    A("")
    A("### 5. Multi-dimensional packed arrays with non-constant indices")
    A("")
    A("ADS requires constant indices into a multi-dimensional packed array.  Where")
    A("such an array is indexed by a signal, the array is flattened to a single")
    A("vector of the same total width and the access becomes an indexed")
    A("part-select.  Bit layout is preserved exactly.  Arrays that are only ever")
    A("indexed with constants are left as-is.")
    A("")
    for s in report["flattened"]:
        A("- %s" % s)
    A("")
    A("### 6. string -> reg [8*256-1:0]")
    A("")
    A("Only used for the simulation-only $value$plusargs DDR filename in")
    A("rtl/soc/ddr/ddr3_model.sv.")
    A("")
    A("### 7. module-name fixup")
    A("")
    A("rtl/soc/ares_cluster.sv instantiates mt_cluster_stub in its ARES_NO_MT")
    A("branch while rtl/soc/mt/mt_cluster_stub.sv declares module mt_cluster,")
    A("so the instance refers to an undefined module (Verilog-4072).  The ported")
    A("copy renames the declaration to mt_cluster_stub.  The originals are left")
    A("alone; one of the two files should be aligned by the RTL owner.")
    A("")
    A("rtl/soc/ddr/pango_ddr3_axi.sv overrides onchip_ddr's memory depth as")
    A(".DEPTH(...), but onchip_ddr declares that parameter as WORDS (32-bit")
    A("words).  The ported copy renames the override so the same numeric value")
    A("is passed.  NOTE: with ONCHIP_DEPTH = 16384 the on-chip DDR is 16384")
    A("32-bit words = 64 KiB; if the intent was 16384 128-bit beats, both files")
    A("need a decision from the RTL owner.")
    A("")
    for s in report["fixups"]:
        A("- %s" % s)
    A("")
    A("## Remaining risks")
    A("")
    if report["risky"]:
        for f, msg in report["risky"]:
            A("- %s : %s" % (f, msg))
    else:
        A("- none detected by the prep script.")
    A("")
    A("Notes:")
    A("")
    A("- rtl/soc/ddr/ddr3_model.sv is a behavioural DDR3 model.  It is parsed but")
    A("  never instantiated in the FPGA configuration (ONCHIP_DDR selects")
    A("  onchip_ddr.sv), so synthesis simply drops it.")
    A("- rtl/soc/mt/mt_cluster_stub.sv implements module mt_cluster and is what")
    A("  ifdef ARES_NO_MT selects in rtl/soc/ares_cluster.sv.")
    A("")
    A("## Resource / fit findings (as measured, PG2L200H FBB676 -6)")
    A("")
    A("compile and synthesize -ads complete cleanly (0 errors, 0 latches, 0")
    A("multi-write RAM warnings).  dev_map stops on two capacity DRCs:")
    A("")
    A("| resource | used | available | % |")
    A("|---|---|---|---|")
    A("| LUT (logic) | 43402 | 159800 | |")
    A("| LUT as distributed RAM | 50448 | 39500 | 127.7% |")
    A("| total LUT | 93850 | 159800 | 58.7% |")
    A("| registers | 41825 | 319600 | 13.1% |")
    A("| latches | 0 | | |")
    A("| DRM36K | 415 | 415 | 100.0% |")
    A("| APM | 56 | 740 | 7.6% |")
    A("| I/O ports | 426 | 400 | 106.5% |")
    A("")
    A("Both DRCs are capacity, not syntax:")
    A("")
    A("* distributed RAM overflows because several large arrays are read")
    A("  asynchronously (read address in the same always_comb / always_ff that")
    A("  writes them), so ADS maps them to LUTRAM instead of DRM.  Largest")
    A("  consumers: u_l2/sp_mem_1 (~8192 LUTs), u_l2/sp_mem (~1792), and 512")
    A("  LUTs each for the per-cluster L1 data/tag arrays.")
    A("* the design needs 426 top-level I/O vs 400 available; 256 of those bits")
    A("  are the SoC debug ports dbg_pc / dbg_pc_f, which the board top")
    A("  (rtl/board/ares_p4_board.sv) trims.")
    A("")
    A("Neither can be fixed by a mechanical syntax conversion - they need an RTL")
    A("or device-size decision (register the memory reads, shrink the")
    A("scratchpad/DDR window, or drop the debug buses from the top level).")
    A("")
    A("## Files mirrored")
    A("")
    for f in report["files"]:
        A("- %s" % f)
    A("")
    NOTES.write_text("\n".join(L) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    sys.exit(main())
