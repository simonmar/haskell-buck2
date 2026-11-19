"""The checks of what the per-module rules decide: the package dbs and
interfaces of each module's compile, what its dep file lists, and which
modules compile again after an edit."""

import json
import re
import sys

from harness import (
    DEV_STYLE,
    OPT_STATIC_STYLE,
    append,
    buck2,
    build,
    compiled_modules,
    configured,
    dep_file,
    expect,
    expect_output,
    expect_set,
    failed_compiles,
    find_compile,
    known_failure,
    module_of,
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
               {"lib:A.Base", "lib:A.Mid", "lib:A.Unused", "lib-user:B.M", "th-gen:TH.Gen", "th-local-splice:C.Splice", "th-local-splice:C.Plain", "th-local-splice:C.Ann", "th-make-dep:MK.Lit", "mkrun:MK.Run", "ffi-import:FFI.C", "p:Chain.P", "t:Chain.T",
                "th-prebuilt-splice:D.Splice", "boot-cycle:Cyc.A", "boot-cycle:Cyc.B", "boot-cycle:Cyc.B-boot", "reexport:R.R", "reexport-user:U.M", "main:Main", "main:Main.Util", "show:Main",
                "flat-sources:Lib", "flat-sources:User", "lib-user:B.Lit", "lib-user:B.UsesLit", "lib-user:B.Safe"})


def check_workers(st):
    """In the clean build, every module compile ran in the shared persistent
    worker if the project has one (run.sh with PER_MODULE_WORKER=builtin),
    and as a process of its own if not. That includes the compiles of the
    Template Haskell modules whose splices need nothing from their target's
    environment, which is all of those in the clean build's targets. (A
    module whose splices need data files or native libraries compiles
    outside the worker. check_data_dirs and
    check_native_libraries_outside_worker check those.)

    A module compiles without the worker if it may run one of its target's
    build tools. It may run one if GHC runs a program for it that it finds
    on PATH (with -F -pgmF, for example), or if the module runs Template
    Haskell. So:

    - In //build-tools:own, BT.Own runs bt-own from its OPTIONS_GHC pragma,
      and BT.OwnSplice runs Template Haskell, so both compile without the
      worker. BT.OwnPlain runs no program, so it compiles in the worker.
    - //build-tools:flags's module runs bt-copy because the target's flags
      say so, and compiles without the worker.

    The build of //build-tools is a separate buck2 command, so it starts a
    new worker. That matters because the worker keeps what it reads for its
    whole life, which is only safe if it lives for a single command (see
    Note [Hashing the libraries] in the worker's Session.hs)."""
    def executors(entries):
        compiles = [e for e in entries if "haskell_compile_module_" in e["identity"]]
        return [(module_of(e), e["reproducer"].get("executor", "")) for e in compiles], [e for e in compiles if e["reproducer"].get("executor") == "WorkerInit"]

    ran, inits = executors(st.entries)
    build("//build-tools:own", "//build-tools:flags")
    bt, bt_inits = executors(what_ran_entries())
    bt = set(bt) - {(m, "WorkerInit") for m, _ in bt}
    bt_modules = ["own:BT.Own", "own:BT.OwnPlain", "own:BT.OwnSplice", "flags:BT.Flags"]
    if not st.worker:
        expect_set("how the module compiles ran", {x for _, x in ran} - {"WorkerInit"}, {"Local"})
        expect_set("how //build-tools's module compiles ran", bt, {(m, "Local") for m in bt_modules})
        return
    expect_set("the modules compiled without the worker", {m for m, x in ran if x == "Local"}, set())
    expect_set("how the other module compiles ran", {x for _, x in ran} - {"Local", "WorkerInit"}, {"Worker"})
    expect("one worker (started: {})".format(len(inits)), len(inits) == 1)
    in_worker = {"own:BT.OwnPlain"}
    expect_set("how //build-tools's module compiles ran", bt, {(m, "Worker" if m in in_worker else "Local") for m in bt_modules})
    expect("a new worker for a new buck2 command (started: {})".format(len(bt_inits)), len(bt_inits) == 1)


def check_build_tool_change(st):
    """A change to a build tool recompiles only the modules that may run it.
    In //build-tools:own, BT.Own runs bt-own, and BT.OwnSplice runs Template
    Haskell, whose splices may run any of the target's build tools. BT.OwnPlain
    runs no program, so it doesn't compile again. (Its import, BT.Own, does,
    but bt-own still writes the same module.)"""
    append("build-tools/bt-own", "# a comment\n")
    build("//build-tools:own")
    expect_set("modules compiled after a change to bt-own", compiled_modules(what_ran()), {"own:BT.Own", "own:BT.OwnSplice"})


def advice(check, *targets):
    """The findings of an advice check for each target (see Note [Advice] in
    compile_per_module.bzl), after an ordinary build. They are read through
    the prelude's validation/audit_results.bxl, as a tool that reports them
    would."""
    build(*targets)
    findings = {}
    for t in targets:
        out = buck2("bxl", "prelude//validation/audit_results.bxl:main", "--", "--take", check, "--trim", "true", "--targets", t).stdout
        for target, results in json.loads(out).items():
            with open(results[check]) as f:
                result = json.load(f)
            expect("{}'s {} succeeds, whatever it finds".format(target, check), result["data"]["status"] == "success")
            findings[target_name(target.split(" ")[0])] = result["data"]["findings"]
    return findings


def check_advice_unused_build_tools(st):
    """haskell_unused_build_tools reports the build tools that no module's
    compile runs: certainly in //build-tools:unused, which runs no Template
    Haskell, and unless a splice runs it in //build-tools:unused-splice.
    //build-tools:own's bt-own is run by BT.Own, so there is nothing to
    report there."""
    found = advice("haskell_unused_build_tools", "//build-tools:unused", "//build-tools:unused-splice", "//build-tools:own")
    expect_set("the targets checked", set(found), {"unused", "unused-splice", "own"})
    expect_set("unused's findings", {(f["tool"], f["certainty"]) for f in found["unused"]}, {("bt-copy", "definite")})
    expect_set("unused-splice's findings", {(f["tool"], f["certainty"]) for f in found["unused-splice"]}, {("bt-copy", "unless_a_splice_runs_it")})
    expect_set("own's findings", {(f["tool"], f["certainty"]) for f in found["own"]}, set())


def check_advice_template_haskell(st):
    """haskell_template_haskell_from_flags reports a target whose flags turn
    on Template Haskell for all its modules (//advice:th-flags's two), and
    haskell_ann_pragmas the modules that compile as Template Haskell modules
    only because of ANN pragmas (//advice:ann's AD.Ann). //build-tools:own's
    BT.OwnSplice turns on Template Haskell in its own pragma, which neither
    check reports."""
    targets = ["//advice:th-flags", "//advice:ann", "//build-tools:own"]
    flags = advice("haskell_template_haskell_from_flags", *targets)
    expect_set("the targets whose flags turn on Template Haskell", {t for t, fs in flags.items() if fs}, {"th-flags"})
    expect("th-flags's finding counts its two modules (got {})".format(flags["th-flags"]), flags["th-flags"] == [{"modules": 2}])
    anns = advice("haskell_ann_pragmas", *targets)
    expect_set("the modules that run Template Haskell only for ANN pragmas", {(t, f["module"]) for t, fs in anns.items() for f in fs}, {("ann", "AD.Ann")})


def check_advice_modules_outside_worker(st):
    """haskell_modules_outside_worker reports the modules compiled without
    the persistent worker, with the build tools they may run and why: in
    //build-tools:own, BT.Own, which runs bt-own as its preprocessor, and
    BT.OwnSplice, which runs Template Haskell, but not BT.OwnPlain. Without
    a worker, it reports nothing."""
    found = advice("haskell_modules_outside_worker", "//build-tools:own")
    expected = {("BT.Own", ("bt-own",), "programs"), ("BT.OwnSplice", ("bt-own",), "template_haskell")} if st.worker else set()
    expect_set("the modules of own compiled without the worker", {(f["module"], tuple(f["tools"]), f["reason"]) for f in found["own"]}, expected)


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


@known_failure("on macOS, a splice can't load a local library's native dependencies, with --make as well", when=lambda st: sys.platform == "darwin")
def check_native_libraries_outside_worker(st):
    """U.V's and U.W's splices run code of //ffi-import:ffi-import (U.W's
    through //ffi-import:ffi-wrap), which depends on //c-lib:c-lib's shared
    library. A splice finds that through LD_LIBRARY_PATH, which the worker
    can't set for one compile, so both modules compile outside the worker
    even when the project has one, and haskell_modules_outside_worker says
    why."""
    found = advice("haskell_modules_outside_worker", "//th-ffi-splice:th-ffi-splice")
    expected = {("U.V", "native_libraries"), ("U.W", "native_libraries")} if st.worker else set()
    expect_set("the modules of th-ffi-splice compiled outside the worker", {(f["module"], f["reason"]) for f in found["th-ffi-splice"]}, expected)


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
    """A Template Haskell module gets the final package db of a local
    dependency only if its target's splice_depends lists that
    dependency. For the other local dependencies, it gets a db that names no
    library, so it doesn't wait for their libraries to be linked.

    - th-local-splice lists //th-gen:th-gen in splice_depends. So
      C.Splice, and C.Ann, whose ANN pragma also runs GHC's interpreter,
      compile against th-gen's final db and lib's early db.
    - th-prebuilt-splice has splice_depends = [], so D.Splice
      compiles against the early dbs of its local dependencies and the
      prebuilt db.
    - make-lib is built with --make. MK.Lit, whose target has
      splice_depends = [], compiles against make-lib's
      library-less db. MK.Run, whose target lists make-lib in
      splice_depends, compiles against make-lib's final db."""
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


def check_splice_depends_not_a_dependency(st):
    """If a target's splice_depends names a target that isn't one
    of its dependencies, the target's analysis fails. //th-make-dep:mkbad's
    splice_depends names //lib:lib, which isn't one of its
    dependencies."""
    p = build("//th-make-dep:mkbad", keep_going=True)
    expect("//th-make-dep:mkbad fails to build", p.returncode != 0)
    expect("its failure says splice_depends names a non-dependency (got:\n{})".format(tail(p.stderr, 15)),
           "splice_depends names root//lib:lib, which is not a dependency" in p.stderr)


def check_unlisted_th_dependency_fails(st):
    """A splice that runs code of a local library which its target's
    splice_depends leaves out fails to compile. MK.Miss's
    splice runs the code of Q.Lib, of //make-lib:make-lib, which is built
    with --make. MK.Miss's compile only gets the db of make-lib that names
    no library, so the splice can't load make-lib's code."""
    p = build("//th-make-dep:mkmiss", keep_going=True)
    expect("//th-make-dep:mkmiss fails to build", p.returncode != 0)
    expect_set("the modules whose compiles failed", failed_compiles(p.stderr), {"mkmiss:MK.Miss"})


@known_failure("in the worker, a splice can run code of a library that another target's splice loaded", when=lambda st: st.worker and not st.external_interpreter)
def check_unlisted_th_dependency_fails_after_load(st):
    """A compile like check_unlisted_th_dependency_fails's must still fail
    when another target's splice has loaded the library earlier in the same
    build. Otherwise a dependency left out of splice_depends
    could go unnoticed, and the module wouldn't compile again when the
    library changed. MK.MissAfter, of //th-make-dep:mkmiss-after, imports
    MK.Load, of //th-make-dep:mkload, so it compiles after MK.Load's splice
    has loaded make-lib's library. With the worker, both modules compile in
    the same process."""
    p = build("//th-make-dep:mkmiss-after", keep_going=True)
    expect("//th-make-dep:mkmiss-after fails to build", p.returncode != 0)
    expect_set("the modules whose compiles failed", failed_compiles(p.stderr), {"mkmiss-after:MK.MissAfter"})


@known_failure("in the worker, the splices of different targets share a library's global state", when=lambda st: st.worker and not st.external_interpreter)
def check_splice_global_state(st):
    """The splices of different targets don't share the global state of a
    library they both run. TI.A's and TI.B's splices each lift their first
    call of G.State's counter, so //th-isolation:show prints (1,1)."""
    expect_output("//th-isolation:show", "with each splice's own counter", "(1,1)")


@known_failure("in the worker, a splice that crashes the process fails the other compiles it is running", when=lambda st: st.worker and not st.external_interpreter)
def check_splice_crash(st):
    """A splice that aborts its process fails its own module's compile and
    no other: TI.Crash's splice aborts while TI.Slow's, of another target, is
    still running, and only TI.Crash's compile fails."""
    p = build("//th-isolation:crash", "//th-isolation:slow", keep_going=True)
    expect_set("the modules whose compiles failed", failed_compiles(p.stderr), {"crash:TI.Crash"})


def external_interpreter_run(target):
    """What `target` prints, built with -fexternal-interpreter in the
    toolchain's compiler flags and then without, as a pair. The build without
    the flag comes second, so that later checks find the compiles as they
    were."""
    with_flag = buck2("run", "-c", "haskell.compiler_flags=-fexternal-interpreter", target).stdout.strip()
    return with_flag, buck2("run", target).stdout.strip()


def check_external_interpreter_splices(st):
    """With -fexternal-interpreter in the toolchain's compiler flags, splices
    that run code of local libraries compiled per-module still run:
    //th-local-splice:show prints what it prints without the flag."""
    with_flag, without = external_interpreter_run("//th-local-splice:show")
    expect("//th-local-splice:show should print {} with -fexternal-interpreter, as without it; it printed {}".format(without, with_flag), with_flag == without)


@known_failure("with -fexternal-interpreter, a profiled splice that runs a per-module library's code crashes the interpreter")
def check_external_interpreter_prof_splices(st):
    """As check_external_interpreter_splices, in prof mode, where the
    interpreter is a profiled one."""
    target = configured("//th-local-splice:show", "per-module", "prof")
    with_flag, without = external_interpreter_run(target)
    expect("{} should print {} with -fexternal-interpreter, as without it; it printed {}".format(target, without, with_flag), with_flag == without)


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
               {"lib:A.Base", "lib:A.Mid", "th-local-splice:C.Splice", "th-local-splice:C.Ann", "th-prebuilt-splice:D.Splice", "reexport-user:U.M"})


def check_cutoff_abi_mid(st):
    """A new export of A.Mid recompiles A.Mid's importers in other packages:
    B.M, C.Plain, and B.Safe, whose import is a safe one. It doesn't
    recompile B.M's importers in main, because B.M's ABI is unchanged."""
    replace("lib/A/Mid.hs", "module A.Mid (mid) where", "module A.Mid (mid, mid2) where")
    append("lib/A/Mid.hs", "\nmid2 :: Int\nmid2 = 2\n")
    expect_set("modules compiled after a new export of A.Mid", rebuild(st),
               {"lib:A.Mid", "lib-user:B.M", "lib-user:B.Safe", "th-local-splice:C.Plain"})


def restoring(path, check):
    """Runs check, then puts back the file at path as it was, so that later
    checks find the source they expect."""
    with open(path) as f:
        original = f.read()
    try:
        check()
    finally:
        with open(path, "w") as f:
            f.write(original)


def bump_literal(path, by):
    """Adds `by` to the integerL literal in the given Template Haskell
    generator."""
    with open(path) as f:
        n = int(re.search(r"integerL (\d+)", f.read()).group(1))
    replace(path, "integerL {}".format(n), "integerL {}".format(n + by))


def check_th_body_change_recompiles(st):
    """A change to the body of TH.Gen's gen, which leaves gen's type and so
    TH.Gen's ABI the same, recompiles the modules of th-local-splice whose
    compiles load th-gen's library. Those are C.Splice, whose splice runs
    gen, and C.Ann, whose ANN pragma also runs GHC's interpreter, but not
    C.Plain. GHC records no use of the library in their interfaces, so their
    dep files can't pick up the change. The library is a plain input of
    their compiles instead. After the change, //th-local-splice:show prints
    the new value."""
    def check():
        shown = int(buck2("run", "//th-local-splice:show").stdout.strip())
        bump_literal("th-gen/TH/Gen.hs", 1)
        ran = rebuild(st)
        expect("TH.Gen recompiled after its edit (ran: {})".format(sorted(ran)), "th-gen:TH.Gen" in ran)
        expect_output("//th-local-splice:show", "after the edit to TH.Gen", str(shown + 1))
        expect_set("modules of th-local-splice compiled after a body-only edit to TH.Gen",
                   {m for m in ran if m.startswith("th-local-splice:")}, {"th-local-splice:C.Splice", "th-local-splice:C.Ann"})
    restoring("th-gen/TH/Gen.hs", check)


@known_failure("on macOS, a splice can't load a local library's native dependencies, with --make as well", when=lambda st: sys.platform == "darwin")
def check_native_library_change_recompiles(st):
    """A change to a native library that splices call compiles the splicing
    modules again, and the splices then run the new code. Nothing in those
    modules' sources or interfaces changes, so this only works because the
    native libraries are inputs of their compiles. U.V's and U.W's splices
    call //c-lib:c-lib's cl_value, through //ffi-import:ffi-import and
    //ffi-import:ffi-wrap, and cl_value calls //c-lib:c-base."""
    def check():
        expect_output("//th-ffi-splice:show", "before the edit to //c-lib:c-lib", "(7,7)")
        replace("c-lib/cl.c", "return 7", "return 8")
        build("//th-ffi-splice:th-ffi-splice")
        ran = compiled_modules(what_ran())
        expect("U.V and U.W compiled after the edit to //c-lib:c-lib (ran: {})".format(sorted(ran)),
               {"th-ffi-splice:U.V", "th-ffi-splice:U.W"} <= ran)
        expect_output("//th-ffi-splice:show", "after the edit to //c-lib:c-lib", "(8,8)")
    restoring("c-lib/cl.c", check)


def check_local_splices_in_modes(st):
    """Splices that run local code run in the other build modes too: opt
    (static, with -dynamic-too) and prof. Their compiles run splices in GHC's
    static and profiled interpreters, which find libraries in different
    places from the dynamic interpreter.

    - //th-local-splice:show prints the value of C.Splice's splice, which
      runs th-gen's TH.Gen, as in dev mode.
    - After a change to the body of TH.Gen, C.Splice and C.Ann compile again
      in each mode, and //th-local-splice:show prints the new value.

    check_native_splices_in_modes checks the splices that call native
    libraries. With -fexternal-interpreter, prof mode is left to
    check_external_interpreter_prof_splices."""
    modes = ["opt"] if st.external_interpreter else ["opt", "prof"]
    def check():
        shown = buck2("run", "//th-local-splice:show").stdout.strip()
        for mode in modes:
            build("//th-local-splice:show", mode=mode)
            ran = compiled_modules(what_ran())
            expect("C.Splice compiled per-module in {} mode (ran: {})".format(mode, sorted(ran)), "th-local-splice:C.Splice" in ran)
            expect_output("//th-local-splice:show", "in {} mode".format(mode), shown, mode)
        bump_literal("th-gen/TH/Gen.hs", 10)
        for mode in modes:
            build("//th-local-splice:show", mode=mode)
            expect_set("modules of th-local-splice compiled in {} mode after a body-only edit to TH.Gen".format(mode),
                       {m for m in compiled_modules(what_ran()) if m.startswith("th-local-splice:")}, {"th-local-splice:C.Splice", "th-local-splice:C.Ann"})
            expect_output("//th-local-splice:show", "in {} mode after the edit to TH.Gen".format(mode), str(int(shown) + 10), mode)
    restoring("th-gen/TH/Gen.hs", check)


@known_failure("on macOS, a splice can't load a local library's native dependencies, with --make as well; and with -fexternal-interpreter, the static and profiled interpreters don't load them", when=lambda st: sys.platform == "darwin" or st.external_interpreter)
def check_native_splices_in_modes(st):
    """Splices that call native libraries run in the opt and prof modes too:
    U.V's, U.W's and V.S's splices (one of them calls a library with the
    soname libver.so.1) compile. A static or profiled external interpreter
    loads a local library's archive with GHC's own linker, which doesn't
    know about the library's native dependencies, so with
    -fexternal-interpreter these fail, with --make too."""
    for mode in ["opt", "prof"]:
        build("//th-ffi-splice:th-ffi-splice", "//th-native-soname:th-native-soname", mode=mode)
        ran = compiled_modules(what_ran())
        expect("the splicing modules compiled per-module in {} mode (ran: {})".format(mode, sorted(ran)),
               {"th-ffi-splice:U.V", "th-ffi-splice:U.W", "th-native-soname:V.S"} <= ran)


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
