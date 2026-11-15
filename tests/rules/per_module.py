"""The checks of what the per-module rules decide: the package dbs and
interfaces of each module's compile, what its dep file lists, and which
modules compile again after an edit."""

import json
import re

from harness import (
    DEV_STYLE,
    IDENTITY,
    OPT_STATIC_STYLE,
    append,
    buck2,
    build,
    compiled_modules,
    dep_file,
    expect,
    expect_set,
    find_compile,
    raw_dep_file,
    replace,
    tail,
    target_name,
    what_ran,
    what_ran_entries,
)


def check_clean_build(st):
    """The fixtures build from clean, compiling every module. The build itself
    guards against some regressions: flat-sources's flat Lib taken for
    make-lib's Q.Lib (whose interface path ends the same way); the hs-boot pair
    of boot-cycle; B.Lit, a literate source."""
    buck2("clean")
    build(*st.targets)
    st.entries = what_ran_entries()
    st.actions = what_ran(st.entries)
    expect_set("modules compiled from clean", compiled_modules(st.actions),
               {"lib:A.Base", "lib:A.Mid", "lib:A.Unused", "lib-user:B.M", "th-gen:TH.Gen", "th-make-dep:MK.Lit", "ffi-import:FFI.C", "p:Chain.P", "t:Chain.T",
                "th-prebuilt-splice:D.Splice", "boot-cycle:Cyc.A", "boot-cycle:Cyc.B", "boot-cycle:Cyc.B-boot", "reexport:R.R", "reexport-user:U.M", "main:Main", "main:Main.Util",
                "flat-sources:Lib", "flat-sources:User", "lib-user:B.Lit", "lib-user:B.UsesLit", "lib-user:B.Safe"})


def check_workers(st):
    """In the clean build, every module compile ran in the shared persistent
    worker if the project has one (run.sh with PER_MODULE_WORKER=builtin),
    and as a process of its own if not. That includes the compiles of the
    Template Haskell modules, because their splices load only prebuilt
    libraries (see Note [The persistent worker]).

    A target with build tools compiles in the worker too, if all its build
    tools are on the worker's PATH. The project's buckconfig puts
    //build-tools:bt-shared there (per_module_worker_build_tools), so
    //build-tools:shared's module compiles in the worker, and
    //build-tools:own's module compiles without it.

    The build of //build-tools is a separate buck2 command, so it starts a
    new worker. That matters because the worker keeps what it reads for its
    whole life, which is only safe if it lives for a single command (see
    Note [Hashing the libraries] in the worker's Session.hs)."""
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


def module_of(entry):
    """The module of a what-ran entry, as "target-name:Module"."""
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
           len(dirs) == 1 and re.fullmatch(r'"\$\{pkgroot\}/per-module-' + DEV_STYLE + r'/out-[0-9]+"', dirs[0]) is not None)
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
    tagged, untagged = dep_file("//lib-user:lib-user", "haskell_compile_module_" + DEV_STYLE, "B.M")
    expect_set("B.M's dep file", tagged, {"lib:A.Mid.abi"})
    expect_set("lib's package dbs among B.M's untagged inputs", {u for u in untagged if u.startswith("lib:")}, {"lib:early"})


def check_module_name_clash(st):
    """X uses bar through second's Re, which re-exports it from second's
    Utils; first and X's own target have a module Utils too. X's dep file
    lists second's Utils, which GHC recorded the usage of, not another unit's
    module of the same name."""
    build("//module-name-clash:user")
    tagged, _ = dep_file("//module-name-clash:user", "haskell_compile_module_" + DEV_STYLE, "X")
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
           p.returncode != 0 and "haskell_compile_module_{} OB.U".format(DEV_STYLE) in p.stderr)


def check_main_file(st):
    """A Main module in a file not named Main, without a module header, which
    srcs names Server, builds."""
    build("//mainname:server")


def check_boot(st):
    """The hs-boot pair: the boot file has its own action, which Cyc.A (its
    {-# SOURCE #-} importer) and Cyc.B (checked against it) depend on; its
    own dep file doesn't list its own output, and Cyc.A's lists the boot
    file's, even once Cyc.B's own is there too."""
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_" + DEV_STYLE, "Cyc.B-boot")
    expect_set("Cyc.B-boot's dep file", tagged, set())
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_" + DEV_STYLE, "Cyc.A")
    expect_set("Cyc.A's dep file", tagged, {"boot-cycle:Cyc.B.abi-boot"})
    tagged, _ = dep_file("//boot-cycle:boot-cycle", "haskell_compile_module_" + DEV_STYLE, "Cyc.B")
    expect_set("Cyc.B's dep file", tagged, {"boot-cycle:Cyc.A.abi", "boot-cycle:Cyc.B.abi-boot"})
    # Compiled again, with Cyc.B's whole interface there now too, Cyc.A's
    # dep file still lists the boot file's .abi, which is what Cyc.A
    # imports. We read the file the action wrote, since buck2's record of it
    # leaves out entries that aren't inputs of the action, as Cyc.B.abi
    # isn't.
    append("boot-cycle/Cyc/A.hs", "\n-- an edit\n")
    build("//boot-cycle:boot-cycle")
    expect_set("Cyc.A's dep file, compiled again", raw_dep_file("boot-cycle", "boot-cycle", "Cyc.A"), {"boot-cycle:Cyc.B.abi-boot"})


def check_boot_cycle_inline(st):
    """//boot-cycle-inline builds, with the worker as well as without it.
    With -O, Loop.User needs the interface of Loop.B, which is in an import
    cycle, although Loop.User reaches Loop.B only through the unfoldings in
    Loop.Via's interface. Loop.B is slow to compile (see the fixture), so
    Loop.User compiles first, while only Loop.B's boot interface exists.
    `ghc -c` uses the boot interface then, and the worker has to do the
    same."""
    p = build("//boot-cycle-inline:boot-cycle-inline", keep_going=True)
    expect("//boot-cycle-inline:boot-cycle-inline builds (got:\n{})".format(tail(p.stderr, 15)), p.returncode == 0)


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


def check_cutoff_instances(st):
    """An edit to an instance that a module sees only through its imports'
    imports, two packages down, compiles the module again: I.High fails to
    compile once I.Orphan has a Show T instance too, and once I.Fam makes F
    Int Char rather than Bool, though I.High imports neither."""
    build("//instances:high")
    for path, old, new, error in [
        ("instances/I/Orphan.hs", "import I.T (T (..))\n", 'import I.T (T (..))\n\ninstance Show T where\n  show T = "orphan"\n', "Duplicate instance"),
        ("instances/I/Fam.hs", "type instance F Int = Bool", "type instance F Int = Char", "Couldn't match"),
    ]:
        replace(path, old, new)
        p = build("//instances:high", keep_going=True)
        replace(path, new, old)
        expect("I.High fails to compile after an edit to {} (got:\n{})".format(path, tail(p.stderr, 15)),
               p.returncode != 0 and "haskell_compile_module_{} I.High".format(DEV_STYLE) in p.stderr and error in p.stderr)
        build("//instances:high")


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
    tagged, _ = dep_file("//lib-user:lib-user", "haskell_compile_module_" + OPT_STATIC_STYLE, "B.M", mode="opt")
    expect_set("B.M's dep file in opt mode", tagged, {"lib:A.Mid.abi"})


def check_opt_shared_consumer(st):
    """opt mode: a binary linked shared compiles against lib-user's "shared"
    package, which comes from lib-user's -dynamic-too compile; Main's dep file
    lists B.M, which it imports."""
    build("//main:main-shared", mode="opt")
    tagged, _ = dep_file("//main:main-shared", "haskell_compile_module_shared", "Main", mode="opt")
    expect_set("lib-user's files in Main's dep file (main-shared, opt mode)",
               {t for t in tagged if t.startswith("lib-user:")}, {"lib-user:B.M.abi"})
