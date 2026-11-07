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
import subprocess
import sys
import time
import traceback

MAIN_TARGETS = ["//lib:lib", "//lib-user:lib-user", "//th-gen:th-gen", "//th-local-splice:th-local-splice", "//th-local-splice:show", "//th-prebuilt-splice:th-prebuilt-splice", "//th-make-dep:th-make-dep", "//th-make-dep:mkrun", "//th-make-dep:mkall", "//ffi-import:ffi-import", "//make-between:t", "//boot-cycle:boot-cycle", "//main:main", "//reexport:reexport", "//reexport-user:reexport-user", "//th-boot-cycles:th-boot-cycles", "//flat-sources:flat-sources"]
ELI_TARGETS = ["//eli:eli", "//eli-reexport:eli-reexport", "//eli-persist:eli-persist"]

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


def what_ran_entries():
    """The entries of `buck2 log what-ran` for the last build, as JSON."""
    out = buck2("log", "what-ran", "--format", "json").stdout
    return [json.loads(line) for line in out.splitlines() if line.startswith("{")]


def what_ran(entries=None):
    """The actions the last build ran (or those of the given what-ran entries),
    as (target, category, identifier, command) tuples: target as
    "th-local-splice:th-local-splice", without the cell.

    Leaves out the actions that buck2 found up to date by their dep files (or
    in a cache), which what-ran lists too. Also leaves out the start of a
    persistent worker, which what-ran lists under the first action sent to the
    worker."""
    actions = []
    for entry in (what_ran_entries() if entries is None else entries):
        m = IDENTITY.match(entry["identity"])
        executor = entry["reproducer"].get("executor", "")
        if not m or executor.endswith("Cache") or executor == "WorkerInit":
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
    """The parts of a per-module compile's request (to the worker or the
    compile tool) that the rules decide: package dbs, interface dirs, and
    the modules a splice may link past boot files."""
    args = cmd[cmd.index("--request"):]
    sep = args.index("--")
    script, rest = args[:sep], args[sep + 1:]
    session = rest[:rest.index("--")]
    hidirs, links = set(), set()
    for a in script:
        if a.startswith("--hidir="):
            hidirs.add(short(a[len("--hidir="):].split("=", 1)[1]))
        elif a.startswith("--link="):
            links.add(a[len("--link="):])
    dbs = {short(session[n + 1]) for n, a in enumerate(session) if a == "-package-db"}
    units = [session[n + 1] for n, a in enumerate(session) if a == "-this-unit-id"]
    return {"dbs": dbs, "hidirs": hidirs, "links": links, "unit": units[-1] if units else None}


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
    def __init__(self, eli, worker):
        self.eli = eli
        self.worker = worker
        self.targets = MAIN_TARGETS + (ELI_TARGETS if eli else [])
        self.entries = None
        self.actions = None


def check_clean_build(st):
    """The fixtures build from clean, compiling every module. The build itself
    guards against some regressions: flat-sources's flat Lib taken for
    make-lib's Q.Lib (whose interface path ends the same way); th-boot-cycles's
    Template Haskell modules, which would each wait for the other; the hs-boot
    pair of boot-cycle; B.Lit, a literate source."""
    buck2("clean")
    build(*st.targets)
    st.entries = what_ran_entries()
    st.actions = what_ran(st.entries)
    expect_set("modules compiled from clean", compiled_modules(st.actions),
               {"lib:A.Base", "lib:A.Mid", "lib:A.Unused", "lib-user:B.M", "th-gen:TH.Gen", "th-local-splice:C.Splice", "th-local-splice:C.Plain", "th-local-splice:C.Ann", "th-make-dep:MK.Lit", "mkrun:MK.Run", "mkall:MK.All", "ffi-import:FFI.C", "p:Chain.P", "t:Chain.T",
                "th-prebuilt-splice:D.Splice", "boot-cycle:Cyc.A", "boot-cycle:Cyc.B", "boot-cycle:Cyc.B-boot", "boot-cycle:Cyc.AS", "reexport:R.R", "reexport-user:U.M", "main:Main", "main:Main.Util", "show:Main",
                "th-boot-cycles:Tie.A", "th-boot-cycles:Tie.B", "th-boot-cycles:Tie.I", "th-boot-cycles:Tie.K", "th-boot-cycles:Tie.I-boot", "th-boot-cycles:Tie.K-boot",
                "th-boot-cycles:Tie.AZ", "th-boot-cycles:Tie.V", "th-boot-cycles:Tie.W", "th-boot-cycles:Tie.W-boot", "flat-sources:Lib", "flat-sources:User", "lib-user:B.Lit", "lib-user:B.UsesLit", "lib-user:B.Safe"}
               | ({"eli:E.Gen", "eli:E.Lib", "eli:E.Mk", "eli:E.Own", "eli:E.UseOwn", "eli-reexport:ER.M", "eli-persist:P.Persist"} if st.eli else set()))


def check_workers(st):
    """All the module compiles of the clean build ran in the shared persistent
    worker when the project has one (run.sh with GHC_WORKER), and as their
    own processes otherwise. That includes the Template Haskell modules.

    A target with build tools compiles in the worker too, if its build tools
    are all on the worker's PATH (per_module_worker_build_tools, which the
    project's buckconfig sets to //build-tools:bt-shared). So
    //build-tools:shared's module compiles in the worker, and
    //build-tools:own's without it.

    That build is a separate buck2 command, so it starts a new worker. The
    worker keeps what it reads for its whole life, which is only safe if it
    lives for one command (see Note [Hashing the libraries] in the worker's
    Session.hs)."""
    def executors(entries):
        compiles = [e for e in entries if "haskell_compile_module_" in e["identity"]]
        return [(module_of(e), e["reproducer"].get("executor", "")) for e in compiles], [e for e in compiles if e["reproducer"].get("executor") == "WorkerInit"]

    ran, inits = executors(st.entries)
    build("//build-tools:shared", "//build-tools:own")
    bt, bt_inits = executors(what_ran_entries())
    bt = set(bt) - {(m, "WorkerInit") for m, _ in bt}
    if not st.worker:
        expect_set("how the module compiles ran", {x for _, x in ran} - {"WorkerInit"}, {"Local"})
        expect_set("how //build-tools's module compiles ran", bt, {("shared:BT.Shared", "Local"), ("own:BT.Own", "Local")})
        return
    expect_set("the modules compiled without the worker", {m for m, x in ran if x == "Local"}, set())
    expect_set("how the other module compiles ran", {x for _, x in ran} - {"Local", "WorkerInit"}, {"Worker"})
    expect("one worker (started: {})".format(len(inits)), len(inits) == 1)
    expect_set("how //build-tools's module compiles ran", bt, {("shared:BT.Shared", "Worker"), ("own:BT.Own", "Local")})
    expect("a new worker for a new buck2 command (started: {})".format(len(bt_inits)), len(bt_inits) == 1)
    # A target naming its worker (//worker-attr:w, which runs
    # //worker-attr:ghc-worker).
    build("//worker-attr:worker-attr")
    entries = what_ran_entries()
    ran, _ = executors(entries)
    expect_set("how //worker-attr:worker-attr's module compiles ran", {x for _, x in ran} - {"WorkerInit"}, {"Worker"})
    named = [e for e in entries if e["reproducer"].get("executor") == "WorkerInit" and any(a == "worker-attr/ghc-worker" or a.endswith("/worker-attr/ghc-worker") for a in e["reproducer"]["details"].get("command", []))]
    expect("//worker-attr:worker-attr's compiles started the worker it names (//worker-attr:w)", len(named) == 1)


def module_of(entry):
    """A what-ran entry's module, as "target-name:Module"."""
    m = IDENTITY.match(entry["identity"])
    return target_name(m.group(1)) + ":" + m.group(3)


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


def check_native_libraries_in_conf(st):
    """For GHC's interpreter, ffi-import's final db names the native libraries
    it depends on, each after those it depends on (c-base before c-lib), then
    its own library, and the directory they are in. So a splice that loads
    ffi-import finds them without LD_LIBRARY_PATH."""
    out = buck2("aquery", "all_actions(root//ffi-import:ffi-import)", "--output-all-attributes").stdout
    confs = {v.get("identifier"): v.get("contents", "") for v in json.loads(out).values() if v.get("kind") == "write"}
    final = parse_conf(confs["pkg-shared.conf"])
    expect_set("ffi-import's libraries for GHC's interpreter, in order",
               [tuple(final.get("extra-ghci-libraries", []))], [("c-lib_c-base", "c-lib_c-lib", "root_ffi-import_ffi-import")])
    expect("ffi-import's dynamic-library-dirs have its native libraries' tree (got {})".format(final.get("dynamic-library-dirs")),
           any("ghci_native_libs" in d for d in final.get("dynamic-library-dirs", [])))


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
    """The package dbs of Template Haskell modules:

    - With th_build_depends = ["//th-gen:th-gen"], C.Splice and C.Ann (an ANN
      pragma) compile against th-gen's final db and lib's early one.
    - With th_build_depends = [], D.Splice compiles only against early dbs.
    - Of make-lib, built with --make, MK.Lit (th_build_depends = []) gets the
      library-less db, and MK.Run (th_build_depends =
      ["//make-lib:make-lib"]) and MK.All (no th_build_depends) the final
      db."""
    for module in ["C.Splice", "C.Ann"]:
        c = find_compile(st.actions, "th-local-splice", module)
        expect_set("{}'s package dbs".format(module), c["dbs"], {"lib:early", "th-gen:final", "ghc:global"})
        expect_set("{}'s interface dirs".format(module), c["hidirs"], {"lib:out", "th-gen:hi"})
    c = find_compile(st.actions, "th-prebuilt-splice", "D.Splice")
    expect_set("D.Splice's package dbs", c["dbs"], {"lib:early", "th-gen:early", "ghc:global"})
    c = find_compile(st.actions, "th-make-dep", "MK.Lit")
    expect_set("MK.Lit's package dbs", c["dbs"], {"make-lib:nolib", "ghc:global"})
    c = find_compile(st.actions, "mkrun", "MK.Run")
    expect_set("MK.Run's package dbs", c["dbs"], {"make-lib:final", "ghc:global"})
    c = find_compile(st.actions, "mkall", "MK.All")
    expect_set("MK.All's package dbs", c["dbs"], {"make-lib:final", "ghc:global"})


def check_th_build_depends_not_a_dependency(st):
    """th_build_depends naming a target that isn't a dependency
    (//th-make-dep:mkbad's names //lib:lib) is an error of the target's
    analysis."""
    p = build("//th-make-dep:mkbad", keep_going=True)
    expect("//th-make-dep:mkbad fails to build", p.returncode != 0)
    expect("its failure says th_build_depends names a non-dependency (got:\n{})".format(tail(p.stderr, 15)),
           "th_build_depends names root//lib:lib, which is not a dependency" in p.stderr)


def check_unlisted_th_dependency_fails(st):
    """A splice that runs code of a local library that its target's
    th_build_depends leaves out: MK.Miss's runs Q.Lib's (//make-lib:make-lib,
    built with --make). make-lib's db names no library, so the compile fails,
    saying to list make-lib in th_build_depends. It still fails after another
    target's splice has loaded make-lib's library in the same build."""
    p = build("//th-make-dep:mkmiss", keep_going=True)
    expect("//th-make-dep:mkmiss fails to build", p.returncode != 0)
    expect("its failure is MK.Miss's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "MK.Miss" in p.stderr and "th_build_depends" in p.stderr)
    # The same after a splice that loaded make-lib's library in the same
    # build (MK.Load's, which MK.MissAfter imports). With the worker, both
    # compile in the same process, but a target's splices mustn't see what
    # another target's loaded.
    p = build("//th-make-dep:mkmiss-after", keep_going=True)
    expect("//th-make-dep:mkmiss-after fails to build", p.returncode != 0)
    expect("its failure is MK.MissAfter's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "MK.MissAfter" in p.stderr and "th_build_depends" in p.stderr)


def check_explicit_level_imports(st):
    """GHC 9.14: explicit level imports choose each module's package dbs. In
    //eli:eli, whose th_build_depends = []:

    - E.Gen (`import splice TH.Gen`) compiles against th-gen's final db.
    - E.Mk (`import splice Q.Lib`) compiles against make-lib's final db
      (make-lib is built with --make).
    - E.Lib (`import splice Language.Haskell.TH`) compiles only against dbs
      that name no library.
    - E.UseOwn (`import splice E.Own`, of its own target) compiles against
      th-gen's final db, since E.Own imports TH.Gen.

    ER.M (`import splice A.Base`, which reexport re-exports) compiles against
    lib's and reexport's final dbs. P.Persist, which turns implicit stage
    persistence back on, has no explicit level imports: it compiles against
    the final dbs of all of eli-persist's dependencies."""
    c = find_compile(st.actions, "eli", "E.Gen")
    expect_set("E.Gen's package dbs", c["dbs"], {"lib:early", "th-gen:final", "make-lib:nolib", "ghc:global"})
    c = find_compile(st.actions, "eli", "E.Lib")
    expect_set("E.Lib's package dbs", c["dbs"], {"lib:early", "th-gen:early", "make-lib:nolib", "ghc:global"})
    c = find_compile(st.actions, "eli", "E.Mk")
    expect_set("E.Mk's package dbs", c["dbs"], {"lib:early", "th-gen:early", "make-lib:final", "ghc:global"})
    c = find_compile(st.actions, "eli-reexport", "ER.M")
    expect_set("ER.M's package dbs", c["dbs"], {"lib:final", "reexport:final", "ghc:global"})
    c = find_compile(st.actions, "eli", "E.UseOwn")
    expect_set("E.UseOwn's package dbs", c["dbs"], {"lib:early", "th-gen:final", "make-lib:nolib", "ghc:global"})
    c = find_compile(st.actions, "eli-persist", "P.Persist")
    expect_set("P.Persist's package dbs", c["dbs"], {"th-gen:final", "ghc:global"})


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
    file's, even once Cyc.B's own is there too. Cyc.AS, whose splice may link
    Cyc.B past its boot file, names Cyc.B with --link. Cyc.B, which runs no
    splice, names nothing."""
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_shared", "Cyc.B-boot")
    expect_set("Cyc.B-boot's dep file", tagged, set())
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_shared", "Cyc.A")
    expect_set("Cyc.A's dep file", tagged, {"boot-cycle:Cyc.B.abi-boot"})
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_shared", "Cyc.B")
    expect_set("Cyc.B's dep file", tagged, {"boot-cycle:Cyc.A.abi", "boot-cycle:Cyc.B.abi-boot"})
    # The clean build's compiles (st.actions):
    expect_set("the modules Cyc.AS links past boot files", find_compile(st.actions, "boot-cycle", "Cyc.AS")["links"], {"Cyc.B"})
    expect_set("the modules Cyc.B links past boot files", find_compile(st.actions, "boot-cycle", "Cyc.B")["links"], set())
    # Compiled again, with Cyc.B's whole interface there now too, Cyc.A's
    # dep file still lists the boot file's .abi, which is what Cyc.A
    # imports. We read the file the action wrote, since buck2's record of it
    # leaves out entries that aren't inputs of the action, as Cyc.B.abi
    # isn't.
    append("boot-cycle/Cyc/A.hs", "\n-- an edit\n")
    build("//boot-cycle:boot-cycle")
    expect_set("Cyc.A's dep file, compiled again", raw_dep_file("boot-cycle", "boot-cycle", "Cyc.A"), {"boot-cycle:Cyc.B.abi-boot"})


def check_boot_cycle_inline(st):
    """With -O, Loop.User needs the interface of Loop.B, a module in an
    import cycle that it reaches only through Loop.Via's unfoldings. Loop.User
    compiles before Loop.B, which is slow to compile (see the fixture). It
    sees Loop.B's boot interface, as `ghc -c` does, with the worker too."""
    p = build("//boot-cycle-inline:boot-cycle-inline", keep_going=True)
    expect("//boot-cycle-inline:boot-cycle-inline builds (got:\n{})".format(tail(p.stderr, 15)), p.returncode == 0)


def check_th_boot_cycles(st):
    """Tie.I and Tie.K run Template Haskell, and each one's boot file is
    below the other, so each would wait for the other. Tie.I, the first by
    name, doesn't wait for Tie.K. Tie.K waits for Tie.I, and names it to
    link past its boot file. Tie.AZ, which is only behind that cycle, keeps
    its waits."""
    expect_set("the modules Tie.I links past boot files", find_compile(st.actions, "th-boot-cycles", "Tie.I")["links"], set())
    expect_set("the modules Tie.K links past boot files", find_compile(st.actions, "th-boot-cycles", "Tie.K")["links"], {"Tie.I"})
    expect_set("the modules Tie.AZ, only behind the cycle, links past boot files",
               find_compile(st.actions, "th-boot-cycles", "Tie.AZ")["links"], {"Tie.I", "Tie.K", "Tie.W"})


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


def check_native_library_change(st):
    """U.V's and U.W's splices run //c-lib:c-lib's code, through
    //ffi-import:ffi-import and //ffi-import:ffi-wrap, and c-lib calls
    //c-lib:c-base. A change to c-lib compiles both modules again, and the
    splices run the new code."""
    expect_output("//th-ffi-splice:show", "before the edit to //c-lib:c-lib", "(7,7)")
    replace("c-lib/cl.c", "return 7", "return 8")
    build("//th-ffi-splice:th-ffi-splice")
    ran = compiled_modules(what_ran())
    expect("U.V and U.W compiled after the edit to //c-lib:c-lib (ran: {})".format(sorted(ran)),
           {"th-ffi-splice:U.V", "th-ffi-splice:U.W"} <= ran)
    expect_output("//th-ffi-splice:show", "after the edit to //c-lib:c-lib", "(8,8)")


def check_native_libraries_for_splices(st):
    """Splices find a native library whose soname isn't of the form
    libfoo.so: V.S's runs code that calls libver.so.1. They also find the
    native libraries of their own targets: A.S's and B.S's splices run their
    targets' own modules, which call their targets' own C libraries. Built
    at once with the worker, they compile in one process."""
    expect_output("//th-native-soname:show", "", "5")
    build("//th-own-native:a", "//th-own-native:b")
    expect_output("//th-own-native:show", "", "(9,11)")


def check_configurations(st):
    """l is built in two configurations in one build, with the same unit id
    and soname in both. Its v is 4 in the execution platform's configuration,
    and 3 in the target platform's. tool's splice (tool is gen's build tool)
    runs the execution platform's l, and user's runs the target platform's.
    Each gets its own configuration's l. We check that with the toolchain's
    worker, which has a worker for each configuration, and, with GHC_WORKER,
    with a worker that the targets name themselves, which compiles both
    configurations' modules in one process."""
    for suffix in [""] + (["-local"] if st.worker else []):
        gen, show = "//th-exec-config:gen" + suffix, "//th-exec-config:show" + suffix
        out = buck2("build", "--show-full-output", gen, show).stdout
        entries = what_ran_entries()
        path = [l.split()[1] for l in out.splitlines() if l.split() and l.split()[0].endswith(gen[1:])][0]
        with open(path) as f:
            value = f.read().strip()
        expect("tool{}'s splice ran the execution platform's l (gen.txt: {!r})".format(suffix, value), value == "4")
        expect_output(show, "(the target platform's l)", "3")
        if suffix == "" and st.worker:
            inits = {}
            for e in entries:
                m = re.match(r"^(\S+) \(cfg:([^)]*)\) \((\S+)", e["identity"])
                if m and m.group(3).startswith("haskell_compile_module_") and e["reproducer"].get("executor") == "WorkerInit":
                    inits[m.group(2)] = inits.get(m.group(2), 0) + 1
            expect("a worker for each configuration (started: {})".format(inits), sorted(inits.values()) == [1, 1])


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
    without a LANGUAGE pragma compiles as one that runs Template Haskell.
    The build is the check: TF.M's splice runs A.Base's code, which it
    can't unless it has lib's final db and library. (At the end: it changes
    the configuration.)"""
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


def check_cutoff_abi_base(st):
    """A new export of A.Base recompiles the modules whose dep files list
    A.Base's ABI, within and across packages, reexport-user's U.M among them,
    which imports A.Base through reexport's re-export of it; A.Mid's ABI is
    unchanged, so nothing that imports A.Mid alone, and nothing of A.Unused."""
    replace("lib/A/Base.hs", "module A.Base (base) where", "module A.Base (base, base2) where")
    append("lib/A/Base.hs", "\nbase2 :: Int\nbase2 = 2\n")
    ran = rebuild(st)
    expect_set("modules compiled after a new export of A.Base", ran,
               {"lib:A.Base", "lib:A.Mid", "th-local-splice:C.Splice", "th-local-splice:C.Ann", "th-prebuilt-splice:D.Splice", "reexport-user:U.M"}
               | ({"eli:E.Gen", "eli:E.Lib", "eli-reexport:ER.M"} if st.eli else set()))


def check_cutoff_abi_mid(st):
    """A new export of A.Mid recompiles its importers in other packages
    (B.M, C.Plain, and B.Safe, whose import is a safe one), not B.M's
    importers in main, whose ABI is unchanged. With GHC 9.14 it also
    recompiles ER.M: its splice runs lib's code, so its compile has lib's
    library, which is linked again, as an input."""
    replace("lib/A/Mid.hs", "module A.Mid (mid) where", "module A.Mid (mid, mid2) where")
    append("lib/A/Mid.hs", "\nmid2 :: Int\nmid2 = 2\n")
    expect_set("modules compiled after a new export of A.Mid", rebuild(st),
               {"lib:A.Mid", "lib-user:B.M", "lib-user:B.Safe", "th-local-splice:C.Plain"} | ({"eli-reexport:ER.M"} if st.eli else set()))


def check_th_body_change(st):
    """A change to the body of TH.Gen's gen, which leaves its type and so its
    ABI the same, recompiles the modules of th-local-splice that load
    th-gen's library. The library is a plain input of their compiles, since
    GHC records no use of it. Those modules are C.Splice, whose splice runs
    gen, and C.Ann, whose ANN pragma runs the interpreter too, but not
    C.Plain. //th-local-splice:show then prints the new value."""
    expect_output("//th-local-splice:show", "before the edit to TH.Gen", "43")
    replace("th-gen/TH/Gen.hs", "integerL 42", "integerL 43")
    ran = rebuild(st)
    expect("TH.Gen recompiled after its edit (ran: {})".format(sorted(ran)), "th-gen:TH.Gen" in ran)
    expect_output("//th-local-splice:show", "after the edit to TH.Gen", "44")
    expect_set("modules of th-local-splice compiled after a body-only edit to TH.Gen",
               {m for m in ran if m.startswith("th-local-splice:")}, {"th-local-splice:C.Splice", "th-local-splice:C.Ann"})


def expect_output(target, when, value, mode=None):
    out = buck2("run", *(["-m", mode] if mode else []), target).stdout.strip()
    expect("{} should print {} {}; it printed {}".format(target, value, when, out), out == value)


def bump_literal(path, by):
    """Adds `by` to the integerL literal in the given Template Haskell
    generator."""
    with open(path) as f:
        n = int(re.search(r"integerL (\d+)", f.read()).group(1))
    replace(path, "integerL {}".format(n), "integerL {}".format(n + by))


def check_th_modes(st):
    """Splices run in the other build modes: opt (static, -dynamic-too) and
    prof. Their compiles run splices in GHC's static and profiled
    interpreters. These find libraries in other places than the dynamic
    one, and load the compile's own objects (.o or .p_o).

    In each mode, these binaries print the same as in dev mode:

    - //th-make-dep:lit prints MK.Lit's splice, which runs
      template-haskell's code.
    - //th-local-splice:show prints C.Splice's, which runs th-gen's TH.Gen.
    - //th-internal-splice:main prints P.Use's, which runs P.Gen of the
      same library, from P.Gen's object of the same way.
    - //th-internal-splice:static-main does the same for a library that is
      linked statically only.
    - //th-internal-splice:own prints its own Main's splice, which runs
      P.Gen of the same binary.

    The splices of U.V, U.W and V.S, which call native libraries (one with
    the soname libver.so.1), compile.

    After we change the bodies of TH.Gen and P.Gen, the modules whose
    splices run them compile again in every mode, dev mode too, and the
    binaries print the new values."""
    internal = ["//th-internal-splice:main", "//th-internal-splice:static-main", "//th-internal-splice:own"]
    shown = buck2("run", "//th-local-splice:show").stdout.strip()
    used = {t: buck2("run", t).stdout.strip() for t in internal}
    for mode in ["opt", "prof"]:
        build("//th-make-dep:lit", "//th-local-splice:show", "//th-ffi-splice:th-ffi-splice", "//th-native-soname:th-native-soname", *internal, mode=mode)
        ran = compiled_modules(what_ran())
        expect("the splicing modules compiled per-module in {} mode (ran: {})".format(mode, sorted(ran)),
               {"th-make-dep:MK.Lit", "th-local-splice:C.Splice", "th-ffi-splice:U.V", "th-ffi-splice:U.W", "th-native-soname:V.S",
                "th-internal-splice:P.Use", "static:P.Use", "own:Main"} <= ran)
        category, obj = ("haskell_compile_module_static", "P.Gen.o") if mode == "opt" else ("haskell_compile_module_static_prof", "P.Gen.p_o")
        for t in ["//th-internal-splice:th-internal-splice", "//th-internal-splice:static"]:
            tagged, _ = dep_file(t, category, "P.Use", mode=mode)
            expect_set("the objects {}'s P.Use's splice loaded in {} mode".format(t, mode),
                       {e.split(":", 1)[1] for e in tagged if not e.endswith(".abi")}, {obj})
        expect_output("//th-make-dep:lit", "in {} mode".format(mode), "2", mode)
        expect_output("//th-local-splice:show", "in {} mode".format(mode), shown, mode)
        for t in internal:
            expect_output(t, "in {} mode".format(mode), used[t], mode)
    bump_literal("th-gen/TH/Gen.hs", 10)
    bump_literal("th-internal-splice/P/Gen.hs", 10)
    for mode in [None, "opt", "prof"]:
        when = "in {} mode after the edits".format(mode or "dev")
        build("//th-local-splice:show", *internal, mode=mode)
        ran = compiled_modules(what_ran())
        expect_set("modules of th-local-splice compiled " + when,
                   {m for m in ran if m.startswith("th-local-splice:")}, {"th-local-splice:C.Splice", "th-local-splice:C.Ann"})
        expect("P.Use and own's Main compiled {} (ran: {})".format(when, sorted(ran)),
               {"th-internal-splice:P.Use", "static:P.Use", "own:Main"} <= ran)
        expect_output("//th-local-splice:show", when, str(int(shown) + 10), mode)
        for t in internal:
            expect_output(t, when, str(int(used[t]) + 10), mode)


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


CHECKS = [
    check_clean_build,
    check_workers,
    check_early_db_conf,
    check_native_libraries_in_conf,
    check_cross_package_dep_file,
    check_module_name_clash,
    check_plain_module_uses_early_dbs,
    check_binary_unit,
    check_th_modules_dbs,
    check_unlisted_th_dependency_fails,
    check_th_build_depends_not_a_dependency,
    check_explicit_level_imports,
    check_own_boot,
    check_main_file,
    check_rts_flags,
    check_boot,
    check_boot_cycle_inline,
    check_th_boot_cycles,
    check_index,
    check_native_library_change,
    check_native_libraries_for_splices,
    check_configurations,
    check_cutoff_comment,
    check_cutoff_abi_base,
    check_cutoff_abi_mid,
    check_th_body_change,
    check_unrelated_modules,
    check_opt_static,
    check_th_modes,
    check_opt_shared_consumer,
    check_module_moved,
    check_header_change,
    check_toolchain_th,
    check_toolchain_index,
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", action="append", help="run only this check (by name, without check_); repeatable")
    ap.add_argument("--ghc-version", required=True)
    ap.add_argument("--worker", action="store_true", help="the project compiles in a persistent worker")
    args = ap.parse_args()
    unknown = set(args.only or []) - {check.__name__[len("check_"):] for check in CHECKS}
    if unknown:
        ap.error("no such check: " + " ".join(sorted(unknown)))
    major, minor = (int(x) for x in args.ghc_version.split(".")[:2])
    st = State(eli=(major, minor) >= (9, 14), worker=args.worker)
    failed = []
    for check in CHECKS:
        name = check.__name__[len("check_"):]
        if args.only and name not in args.only and check is not check_clean_build:
            continue
        if check is check_explicit_level_imports and not st.eli:
            print("SKIP   {} (GHC {})".format(name, args.ghc_version))
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
