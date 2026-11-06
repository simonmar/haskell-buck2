#!/usr/bin/env python3
"""The checks of the per-module rules, run in the test project by run.sh.

Each check builds what it needs, reads what the rules decided from buck2
(the command lines of `buck2 log what-ran`, `buck2 audit dep-files`, the
static actions of `buck2 aquery`) and compares sets of short names (see
short()) with what it expects, saying what is missing and what is not
expected. The checks run in order, on one project: some edit its sources.
"""

import argparse
import glob
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.request

MAIN_TARGETS = ["//lib:lib", "//lib-user:lib-user", "//th-gen:th-gen", "//th-prebuilt-splice:th-prebuilt-splice", "//th-make-dep:th-make-dep", "//ffi-import:ffi-import", "//make-between:t", "//boot-cycle:boot-cycle", "//main:main", "//reexport:reexport", "//reexport-user:reexport-user", "//flat-sources:flat-sources"]

LOG_DIR = "buck-logs"


class CheckFailed(Exception):
    pass


# --- Running buck2 ---------------------------------------------------------

_run_count = 0


def buck2(*args, ok=True):
    """Runs buck2 with the args, saving its output under LOG_DIR. Fails the
    check if `ok` and buck2 fails."""
    global _run_count
    _run_count += 1
    os.makedirs(LOG_DIR, exist_ok=True)
    log = os.path.join(LOG_DIR, "{:02d}-{}.log".format(_run_count, args[0]))
    p = subprocess.run(["buck2", *args], capture_output=True, text=True)
    with open(log, "w") as f:
        f.write("$ buck2 " + " ".join(args) + "\n" + p.stdout + p.stderr)
    if ok and p.returncode != 0:
        raise CheckFailed("`buck2 {}` failed (see {}):\n{}".format(" ".join(args), log, tail(p.stderr)))
    return p


def tail(text, n=30):
    return "\n".join(text.splitlines()[-n:])


def build(*targets, mode=None, keep_going=False):
    args = ["build"] + (["-m", mode] if mode else []) + (["--keep-going"] if keep_going else []) + list(targets)
    return buck2(*args, ok=not keep_going)


IDENTITY = re.compile(r"^(\S+) \(cfg:[^)]*\) \((\S+)(?: (.+))?\)$")


def what_ran():
    """The actions the last build ran, as (target, category, identifier,
    command) tuples: target as "th-local-splice:th-local-splice", without the
    cell. Not those that buck2 found up to date by their dep files (or in a
    cache), which what-ran lists too."""
    out = buck2("log", "what-ran", "--format", "json").stdout
    actions = []
    for line in out.splitlines():
        if not line.startswith("{"):
            continue
        entry = json.loads(line)
        m = IDENTITY.match(entry["identity"])
        if not m or entry["reproducer"].get("executor", "").endswith("Cache"):
            continue
        target = m.group(1).split("//", 1)[1].lstrip(":")
        cmd = entry.get("reproducer", {}).get("details", {}).get("command", [])
        actions.append((target, m.group(2), m.group(3), cmd))
    return actions


def compiled_modules(actions):
    """The per-module compiles that ran, as "target-name:Module"."""
    return {target_name(t) + ":" + i for t, c, i, _ in actions if c.startswith("haskell_compile_module_")}


def target_name(target):
    return target.split(":")[-1]


def dep_file(target, category, identifier, mode=None):
    """The entries of an action's dep file (its tagged inputs that it read),
    by short name, and its untagged inputs, by short name."""
    args = ["audit", "dep-files"] + (["-m", mode] if mode else []) + ["root" + target, category, identifier]
    out = buck2(*args).stdout
    tagged, untagged = set(), set()
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        (untagged if parts[0] == "untagged" else tagged).add(short(parts[1]))
    return tagged, untagged


def raw_dep_file(package, name, node):
    """The entries of a per-module compile's dep file as its action wrote
    them, by short name."""
    paths = glob.glob("buck-out/v2/art/root/*/{}/__{}__/__action___*/per-module-shared/dep/{}.dep".format(package, name, node))
    if len(paths) != 1:
        raise CheckFailed("no single dep file of {}:{} {} (found {})".format(package, name, node, paths))
    with open(paths[0]) as f:
        return {short(line.strip()) for line in f if line.strip()}


# --- Naming buck-out paths ---------------------------------------------------

OWN = r"buck-out/v2/art/root/[0-9a-f]+/(?:[^ ]*/)?__([^/]+)__/"
SHORT_NAMES = [
    # A module's outputs: lib:A.Mid.abi, boot-cycle:Cyc.B.abi-boot.
    (OWN + r"per-module-[^/]+/out-[0-9]+/(.+)\.([a-z_]+(?:-boot)?)$", lambda m: "{}:{}.{}".format(m[1], m[2].replace("/", "."), m[3])),
    (OWN + r"per-module-[^/]+/out-[0-9]+$", lambda m: m[1] + ":out"),
    (OWN + r"db-early-[^/]+(/.*)?$", lambda m: m[1] + ":early"),
    (OWN + r"db-nolib-[^/]+(/.*)?$", lambda m: m[1] + ":nolib"),
    (OWN + r"db-[^/]+(/.*)?$", lambda m: m[1] + ":final"),
    (OWN + r"hi-[^/]+$", lambda m: m[1] + ":hi"),
    (OWN + r"lib-[^/]+/.*$", lambda m: m[1] + ":lib"),
    (r"third-party/haskell/ghc-[^/]+(/package\.conf\.d)?$", lambda m: "ghc:global"),
]


def short(path):
    for pattern, name in SHORT_NAMES:
        m = re.match(pattern, path)
        if m:
            return name(m)
    return path


# --- Reading a per-module compile's command line -----------------------------

def parse_compile(cmd):
    """The parts of a per-module compile's command line (the compile tool's
    request) that the rules decide: package dbs, interface dirs."""
    args = cmd[cmd.index("--depfile"):]
    sep = args.index("--")
    script, rest = args[:sep], args[sep + 1:]
    session = rest[:rest.index("--")]
    hidirs = {short(a[len("--hidir="):].split("=", 1)[1]) for a in script if a.startswith("--hidir=")}
    dbs = {short(session[n + 1]) for n, a in enumerate(session) if a == "-package-db"}
    units = [session[n + 1] for n, a in enumerate(session) if a == "-this-unit-id"]
    return {"dbs": dbs, "hidirs": hidirs, "unit": units[-1] if units else None}

def find_compile(actions, target, module):
    for t, c, i, cmd in actions:
        if target_name(t) == target and c.startswith("haskell_compile_module_") and i == module:
            return parse_compile(cmd)
    raise CheckFailed("no compile of {}:{} in the build".format(target, module))


# --- Assertions ----------------------------------------------------------------

def expect_set(what, actual, expected):
    actual, expected = set(actual), set(expected)
    if actual != expected:
        raise CheckFailed("{}:\n  missing:    {}\n  unexpected: {}\n  (actual:    {})".format(
            what, sorted(expected - actual) or "-", sorted(actual - expected) or "-", sorted(actual)))


def expect(what, cond):
    if not cond:
        raise CheckFailed(what)


# --- Editing sources ------------------------------------------------------------

def append(path, text):
    with open(path, "a") as f:
        f.write(text)


def replace(path, old, new):
    with open(path) as f:
        s = f.read()
    expect("{} contains {!r}".format(path, old), old in s)
    with open(path, "w") as f:
        f.write(s.replace(old, new))


# --- The checks -------------------------------------------------------------------

class State:
    def __init__(self, bazel_remote):
        self.bazel_remote = bazel_remote
        self.targets = MAIN_TARGETS
        self.actions = None


def check_clean_build(st):
    """The fixtures build from clean, compiling every module. The build itself
    guards against some regressions: flat-sources's flat Lib taken for
    make-lib's Q.Lib (whose interface path ends the same way); the hs-boot pair
    of boot-cycle; B.Lit, a literate source."""
    buck2("clean")
    build(*st.targets)
    st.actions = what_ran()
    expect_set("modules compiled from clean", compiled_modules(st.actions),
               {"lib:A.Base", "lib:A.Mid", "lib:A.Unused", "lib-user:B.M", "th-gen:TH.Gen", "th-make-dep:MK.Lit", "ffi-import:FFI.C", "p:Chain.P", "t:Chain.T",
                "th-prebuilt-splice:D.Splice", "boot-cycle:Cyc.A", "boot-cycle:Cyc.B", "boot-cycle:Cyc.B-boot", "reexport:R.R", "reexport-user:U.M", "main:Main", "main:Main.Util",
                "flat-sources:Lib", "flat-sources:User", "lib-user:B.Lit", "lib-user:B.UsesLit", "lib-user:B.Safe"})


def check_early_db_conf(st):
    """lib's early package db names no library, and its import dir is the
    per-module output dir; its final db names the library."""
    out = buck2("aquery", "all_actions(root//lib:lib)", "--output-all-attributes").stdout
    confs = {v.get("identifier"): v.get("contents", "") for v in json.loads(out).values() if v.get("kind") == "write"}
    expect("aquery shows the write of pkg-early-shared.conf (got {})".format(sorted(confs)), "pkg-early-shared.conf" in confs)
    early = parse_conf(confs["pkg-early-shared.conf"])
    final = parse_conf(confs["pkg-shared.conf"])
    library_fields = {"hs-libraries", "extra-libraries", "library-dirs", "dynamic-library-dirs"}
    expect_set("library fields of lib's early db conf", set(early) & library_fields, set())
    dirs = early.get("import-dirs", [])
    expect("lib's early db conf has one import-dir, the modules' output directory (got {})".format(dirs),
           len(dirs) == 1 and re.fullmatch(r'"\$\{pkgroot\}/per-module-shared/out-[0-9]+"', dirs[0]) is not None)
    expect("lib's final db conf names its library (fields: {})".format(sorted(final)), "extra-libraries" in final)


def parse_conf(text):
    fields, key = {}, None
    for line in text.splitlines():
        m = re.match(r"^([\w-]+):\s*(.*)$", line)
        if m:
            key = m.group(1)
            fields[key] = [v.strip() for v in m.group(2).split(",") if v.strip()]
    return fields


def check_cross_package_dep_file(st):
    """B.M's dep file lists only the lib interfaces GHC recorded a usage of:
    A.Mid, which it imports (A.Base reaches it through A.Mid's ABI hash),
    nothing of A.Unused. (Its closure, which it may read, is A.Mid and
    A.Base, but nothing buck2 shows lists a dynamic action's inputs, so
    that isn't checked here; unrelated_modules checks that a closure
    leaves out what a module doesn't import.)"""
    tagged, untagged = dep_file("//lib-user:lib-user", "haskell_compile_module_shared", "B.M")
    expect_set("B.M's dep file", tagged, {"lib:A.Mid.abi"})
    expect_set("lib's package dbs among B.M's untagged inputs", {u for u in untagged if u.startswith("lib:")}, {"lib:early"})


def check_module_name_clash(st):
    """X uses bar through second's Re, which re-exports it from second's
    Utils; first and X's own target have a module Utils too. X's dep file
    lists second's Utils, which GHC recorded the usage of, not another unit's
    module of the same name."""
    build("//module-name-clash:user")
    tagged, _ = dep_file("//module-name-clash:user", "haskell_compile_module_shared", "X")
    expect_set("X's dep file", tagged, {"second:Re.abi", "second:Utils.abi"})


def check_plain_module_uses_early_dbs(st):
    """A module without Template Haskell compiles against its dependencies'
    early dbs:

    - B.M against lib's early db;
    - flat-sources's User against make-lib's library-less db (make-lib is
      built with --make), with make-lib's interface dir;
    - Chain.T, which imports Chain.M of m (built with --make), against m's
      library-less db and p's early db (p is compiled per-module, below
      m)."""
    c = find_compile(st.actions, "lib-user", "B.M")
    expect_set("B.M's package dbs", c["dbs"], {"lib:early", "ghc:global"})
    expect_set("B.M's interface dirs", c["hidirs"], {"lib:out"})
    c = find_compile(st.actions, "flat-sources", "User")
    expect_set("User's package dbs", c["dbs"], {"make-lib:nolib", "ghc:global"})
    expect_set("User's interface dirs", c["hidirs"], {"make-lib:hi"})
    c = find_compile(st.actions, "t", "Chain.T")
    expect_set("Chain.T's package dbs", c["dbs"], {"m:nolib", "p:early", "ghc:global"})

def check_binary_unit(st):
    """A per-module binary's modules are in a unit named after the target,
    as a library's are, not GHC's default `main`, which every binary would
    share."""
    c = find_compile(st.actions, "main", "Main")
    expect("main's Main is in unit root-main-main (got {})".format(c["unit"]), c["unit"] == "root-main-main")


def check_th_modules_dbs(st):
    """A Template Haskell module compiles against the same dbs as one that runs
    none, since its splices can run only prebuilt code: D.Splice against lib's
    and th-gen's early dbs, MK.Lit against make-lib's library-less db (make-lib
    is built with --make)."""
    c = find_compile(st.actions, "th-prebuilt-splice", "D.Splice")
    expect_set("D.Splice's package dbs", c["dbs"], {"lib:early", "th-gen:early", "ghc:global"})
    c = find_compile(st.actions, "th-make-dep", "MK.Lit")
    expect_set("MK.Lit's package dbs", c["dbs"], {"make-lib:nolib", "ghc:global"})


def check_local_splice_fails(st):
    """Not supported: a splice that runs code of another local package.
    C.Splice's runs TH.Gen's (//th-gen:th-gen, compiled per-module), MK.Run's
    runs Q.Lib's (//make-lib:make-lib, built with --make). Their dbs name no
    library, so each fails to compile, saying how to build the target
    instead."""
    for target, module in [("//th-local-splice:th-local-splice", "C.Splice"), ("//th-make-dep:mkrun", "MK.Run")]:
        p = build(target, keep_going=True)
        expect("{} fails to build".format(target), p.returncode != 0)
        expect("{}'s failure is {}'s, and names the fix (got:\n{})".format(target, module, tail(p.stderr, 15)),
               module in p.stderr and "per_module = False" in p.stderr)


def check_internal_splice_fails(st):
    """Not supported: a splice that runs code of its own target. P.Use's
    runs P.Gen's, so it fails to compile, saying how to build the target
    instead."""
    p = build("//th-internal-splice:th-internal-splice", keep_going=True)
    expect("//th-internal-splice:th-internal-splice fails to build", p.returncode != 0)
    expect("its failure is P.Use's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "P.Use" in p.stderr and "this target's own modules" in p.stderr and "per_module = False" in p.stderr)


def check_own_boot(st):
    """A module with a boot file that no import cycle needs (OB.U, which OB.B
    imports {-# SOURCE #-}) depends on the boot file, so GHC checks the module
    against it: a boot file that declares what the module doesn't define fails
    the module's compile."""
    build("//ownboot:ownboot")
    append("ownboot/OB/U.hs-boot", "y :: Int\n")
    p = build("//ownboot:ownboot", keep_going=True)
    replace("ownboot/OB/U.hs-boot", "y :: Int\n", "")
    expect("the build of ownboot fails in OB.U's compile after y is added to its boot file",
           p.returncode != 0 and "haskell_compile_module_shared OB.U" in p.stderr)


def check_main_file(st):
    """A Main module in a file not named Main, without a module header, which
    srcs names Server, builds."""
    build("//mainname:server")


def check_rts_flags(st):
    """Options for GHC's runtime (+RTS ... -RTS) among a target's compiler
    flags don't stop its module graph being made."""
    build("//rtsflags:rtsflags")


def check_boot(st):
    """The hs-boot pair: the boot file has its own action, which Cyc.A (its
    {-# SOURCE #-} importer) and Cyc.B (checked against it) depend on; its
    own dep file doesn't list its own output, and Cyc.A's lists the boot
    file's, even once Cyc.B's own is there too."""
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_shared", "Cyc.B-boot")
    expect_set("Cyc.B-boot's dep file", tagged, set())
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_shared", "Cyc.A")
    expect_set("Cyc.A's dep file", tagged, {"boot-cycle:Cyc.B.abi-boot"})
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_shared", "Cyc.B")
    expect_set("Cyc.B's dep file", tagged, {"boot-cycle:Cyc.A.abi", "boot-cycle:Cyc.B.abi-boot"})
    # Compiled again, with Cyc.B's whole interface there now too, Cyc.A's
    # dep file still lists the boot file's .abi, which is what Cyc.A
    # imports. We read the file the action wrote, since buck2's record of it
    # leaves out entries that aren't inputs of the action, as Cyc.B.abi
    # isn't.
    append("boot-cycle/Cyc/A.hs", "\n-- an edit\n")
    build("//boot-cycle:boot-cycle")
    expect_set("Cyc.A's dep file, compiled again", raw_dep_file("boot-cycle", "boot-cycle", "Cyc.A"), {"boot-cycle:Cyc.B.abi-boot"})


def index_files(target, *config):
    """The names of the .hie files in the target's index (HaskellIndexInfo)."""
    path = buck2("bxl", *config, "//index.bxl:index", "--", "--target", target).stdout.strip().splitlines()[-1]
    hie = set()
    for root, _, files in os.walk(path, followlinks=True):
        hie |= {f for f in files if f.endswith(".hie")}
    return hie


def check_index(st):
    """A library built with -fwrite-ide-info has an index (HaskellIndexInfo)
    with each module's .hie file."""
    expect_set("the .hie files of //index:index's index", index_files("//index:index"), {"A.hie", "B.hie"})


def check_module_moved(st):
    """A module moved from a target to its dependency (MV.X, from
    //module-move:hi to //module-move:lo): its importer compiles against the
    dependency's, not the interface its old target left behind."""
    expect_output("//module-move:main", "before MV.X moves", "12")
    replace("module-move/BUCK.fixture", '''srcs = {"MV.Lo": "MV/Lo.hs"}''', '''srcs = {"MV.Lo": "MV/Lo.hs", "MV.X": "MV/X.hs"}''')
    replace("module-move/BUCK.fixture", '''"MV.X": "MV/X.hs", "MV.Y": "MV/Y.hs"''', '''"MV.Y": "MV/Y.hs"''')
    replace("module-move/MV/X.hs", "x = 2", "x = 3")
    expect_output("//module-move:main", "after MV.X moves", "13")


def check_header_change(st):
    """An edit to a header in a target's srcs, which a module #includes,
    recompiles the module."""
    build("//header:header")
    replace("header/Hdr/value.h", "VALUE 1", "VALUE 2")
    build("//header:header")
    expect_set("modules compiled after an edit to Hdr/value.h", compiled_modules(what_ran()), {"header:Hdr.M"})


def check_toolchain_th(st):
    """With Template Haskell enabled by the toolchain's flags, a module
    without a LANGUAGE pragma, which runs a splice, compiles: the build is
    the check. (At the end: it changes the configuration.)"""
    buck2("build", "-c", "haskell.compiler_flags=-XTemplateHaskell", "//toolchain-th:toolchain-th")


def check_toolchain_index(st):
    """With -fwrite-ide-info in the toolchain's flags, a library has an
    index with each module's .hie file. (At the end: it changes the
    configuration.)"""
    expect_set("the .hie files of //lib:lib's index, with the toolchain's -fwrite-ide-info",
               index_files("//lib:lib", "-c", "haskell.compiler_flags=-fwrite-ide-info"),
               {"Base.hie", "Mid.hie", "Unused.hie"})


def rebuild(st):
    """Builds the fixtures again: the modules compiled."""
    build(*st.targets)
    return compiled_modules(what_ran())


def check_cutoff_comment(st):
    """A comment-only edit to A.Base recompiles A.Base alone."""
    append("lib/A/Base.hs", "\n-- a comment\n")
    ran = rebuild(st)
    expect_set("modules compiled after a comment-only edit to A.Base", ran, {"lib:A.Base"})


# The categories of library and executable links.
LINK = re.compile(r"link|archive")


def check_interfaces_subtarget(st):
    """After an edit to A.Base's code that leaves its ABI alone,
    main[interfaces] compiles A.Base but links nothing; a build of main then
    links lib and main."""
    replace("lib/A/Base.hs", "base = 1", "base = 0 + 1")
    build("//main:main[interfaces]")
    actions = what_ran()
    expect_set("modules compiled for main[interfaces]", compiled_modules(actions), {"lib:A.Base"})
    links = {(target_name(t), c) for t, c, _, _ in actions if LINK.search(c)}
    expect_set("links run for main[interfaces]", links, set())
    build("//main:main")
    links = {target_name(t) for t, c, _, _ in what_ran() if LINK.search(c)}
    expect("main and lib linked after main[interfaces] (linked: {})".format(sorted(links)), {"lib", "main"} <= links)


def check_cutoff_abi_base(st):
    """A new export of A.Base recompiles the modules whose dep files list
    A.Base's ABI, within and across packages, reexport-user's U.M among them,
    which imports A.Base through reexport's re-export of it; A.Mid's ABI is
    unchanged, so nothing that imports A.Mid alone, and nothing of A.Unused."""
    replace("lib/A/Base.hs", "module A.Base (base) where", "module A.Base (base, base2) where")
    append("lib/A/Base.hs", "\nbase2 :: Int\nbase2 = 2\n")
    ran = rebuild(st)
    expect_set("modules compiled after a new export of A.Base", ran,
               {"lib:A.Base", "lib:A.Mid", "th-prebuilt-splice:D.Splice", "reexport-user:U.M"})


def check_cutoff_abi_mid(st):
    """A new export of A.Mid recompiles its importers in other packages
    (B.M, and B.Safe, whose import is a safe one), not B.M's importers in
    main, whose ABI is unchanged."""
    replace("lib/A/Mid.hs", "module A.Mid (mid) where", "module A.Mid (mid, mid2) where")
    append("lib/A/Mid.hs", "\nmid2 :: Int\nmid2 = 2\n")
    expect_set("modules compiled after a new export of A.Mid", rebuild(st),
               {"lib:A.Mid", "lib-user:B.M", "lib-user:B.Safe"})


def expect_output(target, when, value, mode=None):
    out = buck2("run", *(["-m", mode] if mode else []), target).stdout.strip()
    expect("{} should print {} {}; it printed {}".format(target, value, when, out), out == value)


def check_th_modes(st):
    """Splices run in the other build modes: opt (static, -dynamic-too) and
    prof, whose profiled compiles load unprofiled libraries into GHC's
    interpreter. //th-make-dep:lit prints MK.Lit's splice, which runs
    template-haskell's code, as in dev mode."""
    for mode in ["opt", "prof"]:
        build("//th-make-dep:lit", mode=mode)
        ran = compiled_modules(what_ran())
        expect("MK.Lit compiled per-module in {} mode (ran: {})".format(mode, sorted(ran)), "th-make-dep:MK.Lit" in ran)
        expect_output("//th-make-dep:lit", "in {} mode".format(mode), "2", mode)


def check_unrelated_modules(st):
    """W.M imports S.Ok only, so its compile doesn't wait for S.Broken,
    which fails: with --keep-going, W.M is compiled."""
    build("//unrelated-failure:w", keep_going=True)
    ran = compiled_modules(what_ran())
    expect("S.Broken was attempted (ran: {})".format(sorted(ran)), "s:S.Broken" in ran)
    expect("W.M compiled although S.Broken, which it doesn't import, failed (ran: {})".format(sorted(ran)),
           "w:W.M" in ran)


def check_opt_static(st):
    """opt mode (static, -dynamic-too): B.M's dep file lists A.Mid, as in
    dev mode."""
    build("//main:main", mode="opt")
    tagged, _ = dep_file("//lib-user:lib-user", "haskell_compile_module_static", "B.M", mode="opt")
    expect_set("B.M's dep file in opt mode", tagged, {"lib:A.Mid.abi"})


def check_opt_shared_consumer(st):
    """opt mode: a binary linked shared compiles against lib-user's "shared"
    package, which comes from lib-user's -dynamic-too compile; Main's dep file
    lists B.M, which it imports."""
    build("//main:main-shared", mode="opt")
    tagged, _ = dep_file("//main:main-shared", "haskell_compile_module_shared", "Main", mode="opt")
    expect_set("lib-user's files in Main's dep file (main-shared, opt mode)",
               {t for t in tagged if t.startswith("lib-user:")}, {"lib-user:B.M.abi"})


# The targets of check_cache: per-module compiles, package dbs and a binary's
# link (main), and a library built with --make (make-lib, below th-make-dep).
CACHE_TARGETS = ["//main:main", "//th-make-dep:th-make-dep"]


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def check_cache(st):
    """With a remote cache (bazel-remote), configured as `cabal buck2
    --cache` configures it, the rules' actions upload their results, and a
    clean build finds them all there. Without `[buck2]
    default_allow_cache_upload`, nothing is uploaded. Cleans the project, so it
    runs last."""
    grpc = "127.0.0.1:{}".format(free_port())
    http = "127.0.0.1:{}".format(free_port())
    cache_dir = tempfile.mkdtemp(prefix="bazel-remote-")
    log = open(os.path.join(LOG_DIR, "bazel-remote.log"), "w")
    server = subprocess.Popen([st.bazel_remote, "--dir", cache_dir, "--max_size", "1",
                               "--grpc_address", grpc, "--http_address", http],
                              stdout=log, stderr=subprocess.STDOUT)

    def stored():
        with urllib.request.urlopen("http://{}/status".format(http)) as r:
            return json.load(r)["NumFiles"]

    def configure(uploads):
        with open(".buckconfig.local", "w") as f:
            f.write("[buck2_re_client]\n")
            for key in ["engine_address", "action_cache_address", "cas_address"]:
                f.write("  {} = grpc://{}\n".format(key, grpc))
            f.write("  tls = false\n\n[cabal_buck2]\n  cache = true\n")
            if uploads:
                f.write("\n[buck2]\n  default_allow_cache_upload = true\n")
        # The daemon reads [buck2_re_client] as it starts.
        buck2("kill")

    try:
        for _ in range(100):
            try:
                stored()
                break
            except OSError:
                expect("bazel-remote is running (see {}/bazel-remote.log)".format(LOG_DIR), server.poll() is None)
                time.sleep(0.1)

        configure(uploads=False)
        buck2("clean")
        build(*CACHE_TARGETS)
        expect("nothing in the cache after a build without default_allow_cache_upload", stored() == 0)

        configure(uploads=True)
        buck2("clean")
        build(*CACHE_TARGETS)
        expect("results in the cache after a build", stored() > 0)

        buck2("clean")
        build(*CACHE_TARGETS)
        expect_set("actions that ran, though the cache has their results",
                   {"{} {} {}".format(t, c, i or "") for t, c, i, _ in what_ran()}, set())
        out = buck2("log", "what-ran", "--format", "json").stdout
        entries = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
        cached = {IDENTITY.match(e["identity"]).group(2) for e in entries
                  if IDENTITY.match(e["identity"]) and e["reproducer"].get("executor", "").endswith("Cache")}
        kinds = {
            "per-module compile": lambda c: c.startswith("haskell_compile_module_"),
            "--make compile": lambda c: c.startswith("haskell_compile_") and not c.startswith("haskell_compile_module_"),
            "module graph": lambda c: c.startswith("haskell_deps_"),
            "GHC API tool": lambda c: c.startswith("haskell_ghc_api_tool"),
            "package db": lambda c: c.startswith("haskell_package_"),
            "link": lambda c: c.startswith("haskell_link"),
        }
        expect_set("kinds of action found in the cache",
                   {k for k, is_kind in kinds.items() if any(is_kind(c) for c in cached)}, set(kinds))
    finally:
        if os.path.exists(".buckconfig.local"):
            os.remove(".buckconfig.local")
        buck2("kill", ok=False)
        server.terminate()
        server.wait()
        log.close()


CHECKS = [
    check_clean_build,
    check_early_db_conf,
    check_cross_package_dep_file,
    check_module_name_clash,
    check_plain_module_uses_early_dbs,
    check_binary_unit,
    check_th_modules_dbs,
    check_local_splice_fails,
    check_internal_splice_fails,
    check_own_boot,
    check_main_file,
    check_rts_flags,
    check_boot,
    check_index,
    check_cutoff_comment,
    check_interfaces_subtarget,
    check_cutoff_abi_base,
    check_cutoff_abi_mid,
    check_unrelated_modules,
    check_opt_static,
    check_th_modes,
    check_opt_shared_consumer,
    check_module_moved,
    check_header_change,
    check_toolchain_th,
    check_toolchain_index,
    check_cache,
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append", help="run only this check (by name, without check_); repeatable")
    ap.add_argument("--bazel-remote", help="a bazel-remote binary, for check_cache")
    args = ap.parse_args()
    unknown = set(args.only or []) - {check.__name__[len("check_"):] for check in CHECKS}
    if unknown:
        ap.error("no such check: " + " ".join(sorted(unknown)))
    st = State(bazel_remote=args.bazel_remote)
    failed = []
    for check in CHECKS:
        name = check.__name__[len("check_"):]
        if args.only and name not in args.only and check is not check_clean_build:
            continue
        if check is check_cache and not st.bazel_remote:
            print("SKIP   {} (no BAZEL_REMOTE)".format(name))
            continue
        start = time.time()
        try:
            check(st)
            error = None
        except CheckFailed as e:
            error = str(e)
        except Exception:
            # Most likely a change to buck2's logs or the rules' command
            # lines that the harness can't read.
            error = traceback.format_exc()
        took = "{:.0f}s".format(time.time() - start)
        if error is None:
            print("PASS   {} ({})".format(name, took))
        else:
            failed.append(name)
            print("FAIL   {} ({}): {}\n       {}".format(name, took,
                                                   check.__doc__.split("\n")[0], error.replace("\n", "\n       ")))
        sys.stdout.flush()
        if check is check_clean_build and error is not None:
            print("(the other checks need the clean build)")
            break
    print("{} failed: {}".format(len(failed), " ".join(failed)) if failed else "all passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
