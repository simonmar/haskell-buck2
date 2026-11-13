"""The checks of what the per-module rules decide: the package dbs and
interfaces of each module's compile, what its dep file lists, and which
modules compile again after an edit."""

import json
import re

from harness import (
    DEV_STYLE,
    OPT_STATIC_STYLE,
    append,
    buck2,
    build,
    compiled_modules,
    dep_file,
    expect,
    expect_output,
    expect_set,
    find_compile,
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
                "flat-sources:Lib", "flat-sources:User", "lib-user:B.Lit", "lib-user:B.UsesLit", "lib-user:B.Safe"}
               | ({"eli:E.Gen", "eli:E.Lib", "eli:E.Mk", "eli-reexport:ER.M", "eli-persist:P.Persist"} if st.eli else set()))


def check_workers(st):
    """In the clean build, every module compile ran in the shared persistent
    worker if the project has one (run.sh with BUCK2_GHC_WORKER), and as a process
    of its own if not. That includes the compiles of the Template Haskell
    modules, which need nothing from their target's environment, even when
    their splices load local libraries (see Note [Template Haskell modules]).

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


def check_native_libraries_in_conf(st):
    """ffi-import's final package db lists, in extra-ghci-libraries, the
    native libraries that ffi-import depends on, followed by its own library.
    Each native library comes after the libraries it depends on, so c-base
    comes before c-lib. The db's dynamic-library-dirs also include the
    directory that holds the native libraries. Together, these let a splice
    that runs ffi-import's code load c-lib and c-base, although a compile has
    nothing on LD_LIBRARY_PATH."""
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
    dependency only if its target's template_haskell_depends lists that
    dependency. For the other local dependencies, it gets a db that names no
    library, so it doesn't wait for their libraries to be linked.

    - th-local-splice lists //th-gen:th-gen in template_haskell_depends. So C.Splice,
      and C.Ann, whose ANN pragma also runs GHC's interpreter, compile
      against th-gen's final db and lib's early db.
    - th-prebuilt-splice has template_haskell_depends = [], so D.Splice compiles
      against early dbs only, and against a copy of the prebuilt db in which
      only template-haskell's closure names its libraries.
    - make-lib is built with --make. MK.Lit, whose target has
      template_haskell_depends = [], compiles against make-lib's library-less db.
      MK.Run, whose target lists make-lib in template_haskell_depends,
      compiles against make-lib's final db."""
    for module in ["C.Splice", "C.Ann"]:
        c = find_compile(st.actions, "th-local-splice", module)
        expect_set("{}'s package dbs".format(module), c["dbs"], {"lib:early", "th-gen:final", "ghc:global"})
        expect_set("{}'s interface dirs".format(module), c["hidirs"], {"lib:out", "th-gen:hi"})
    c = find_compile(st.actions, "th-prebuilt-splice", "D.Splice")
    expect_set("D.Splice's package dbs", c["dbs"], {"lib:early", "th-gen:early", "th-prebuilt-splice:th-db"})
    c = find_compile(st.actions, "th-make-dep", "MK.Lit")
    expect_set("MK.Lit's package dbs", c["dbs"], {"make-lib:nolib", "th-make-dep:th-db"})
    c = find_compile(st.actions, "mkrun", "MK.Run")
    expect_set("MK.Run's package dbs", c["dbs"], {"make-lib:final", "mkrun:th-db"})


def check_template_haskell_depends_not_a_dependency(st):
    """If a target's template_haskell_depends names a target that isn't one of its
    dependencies, the target's analysis fails. //th-make-dep:mkbad's
    template_haskell_depends names //lib:lib, which isn't one of its dependencies."""
    p = build("//th-make-dep:mkbad", keep_going=True)
    expect("//th-make-dep:mkbad fails to build", p.returncode != 0)
    expect("its failure says template_haskell_depends names a non-dependency (got:\n{})".format(tail(p.stderr, 15)),
           "template_haskell_depends names root//lib:lib, which is not a dependency" in p.stderr)


def check_unlisted_prebuilt_dependency_fails(st):
    """A splice may only run code of the prebuilt packages that its target's
    template_haskell_depends lists, of template-haskell's closure, and of the
    packages that GHC's external interpreter is itself linked with. D.Text's
    splice runs code of text, which is none of those. It fails to compile in
    //th-prebuilt-splice:th-prebuilt-unlisted, which doesn't list text, and
    the error suggests listing it. From GHC 9.14, a compile in the worker
    can't tell which package that is (see spliceHint in Request.hs). It
    compiles in //th-prebuilt-splice:th-prebuilt-listed, which does. text's
    entry in the prebuilt db has its id on the line after "id:" (see
    gen_prebuilt.py), as a long id does, so the rules must read that form
    to keep text's library."""
    p = build("//th-prebuilt-splice:th-prebuilt-unlisted", keep_going=True)
    expect("//th-prebuilt-splice:th-prebuilt-unlisted fails to build", p.returncode != 0)
    package = "a package" if st.eli and st.worker else "the package text"
    expect("its failure is D.Text's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "D/Text.hs: error: per_module: a splice couldn't load code from {}: list the package in the target's template_haskell_depends".format(package) in p.stderr)
    build("//th-prebuilt-splice:th-prebuilt-listed")


def check_unlisted_th_dependency_fails(st):
    """A splice that runs code of a local library which its target's
    template_haskell_depends leaves out fails to compile, and the error suggests
    listing the library in template_haskell_depends. MK.Miss's splice runs the code
    of Q.Lib, of //make-lib:make-lib, which is built with --make. MK.Miss's
    compile only gets make-lib's db that names no library, so the splice
    can't load make-lib's code.

    The compile must still fail when another target's splice has loaded
    make-lib's library earlier in the same build. Otherwise a dependency left
    out of template_haskell_depends could go unnoticed, and the module wouldn't
    compile again when the library changed."""
    p = build("//th-make-dep:mkmiss", keep_going=True)
    expect("//th-make-dep:mkmiss fails to build", p.returncode != 0)
    expect("its failure is MK.Miss's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "MK.Miss" in p.stderr and "template_haskell_depends" in p.stderr)
    # MK.MissAfter imports MK.Load, so it compiles after MK.Load's splice
    # has loaded make-lib's library. With the worker, both modules compile in
    # the same process.
    p = build("//th-make-dep:mkmiss-after", keep_going=True)
    expect("//th-make-dep:mkmiss-after fails to build", p.returncode != 0)
    expect("its failure is MK.MissAfter's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "MK.MissAfter" in p.stderr and "template_haskell_depends" in p.stderr)


def check_explicit_level_imports(st):
    """With GHC 9.14 or later, a module's explicit level imports narrow its
    target's template_haskell_depends. The module's compile gets the final db
    of each listed local dependency whose modules it imports with `import
    splice`, and a db that names no library for each of the others. In
    //eli:eli, which lists th-gen and make-lib:

    - E.Gen (`import splice TH.Gen`) compiles against th-gen's final db.
    - E.Mk (`import splice Q.Lib`) compiles against the final db of
      make-lib, which is built with --make.
    - E.Lib (`import splice Language.Haskell.TH`) gets the final db of no
      local dependency.

    ER.M imports A.Base with `import splice`, through reexport's re-export of
    it from lib. It compiles against the final dbs of both lib and reexport,
    and against a copy of the prebuilt db, since eli-reexport lists no
    prebuilt package.
    P.Persist turns implicit stage persistence back on, so it has no
    explicit level imports. It compiles against the final dbs of all the
    dependencies that eli-persist lists, like any Template Haskell module.

    //eli:eli-unlisted doesn't list th-gen, so E.Gen's splice import of
    TH.Gen fails its build, naming the import."""
    c = find_compile(st.actions, "eli", "E.Gen")
    expect_set("E.Gen's package dbs", c["dbs"], {"lib:early", "th-gen:final", "make-lib:nolib", "ghc:global"})
    c = find_compile(st.actions, "eli", "E.Lib")
    expect_set("E.Lib's package dbs", c["dbs"], {"lib:early", "th-gen:early", "make-lib:nolib", "ghc:global"})
    c = find_compile(st.actions, "eli", "E.Mk")
    expect_set("E.Mk's package dbs", c["dbs"], {"lib:early", "th-gen:early", "make-lib:final", "ghc:global"})
    c = find_compile(st.actions, "eli-reexport", "ER.M")
    expect_set("ER.M's package dbs", c["dbs"], {"lib:final", "reexport:final", "eli-reexport:th-db"})
    c = find_compile(st.actions, "eli-persist", "P.Persist")
    expect_set("P.Persist's package dbs", c["dbs"], {"th-gen:final", "ghc:global"})
    p = build("//eli:eli-unlisted", keep_going=True)
    expect("//eli:eli-unlisted fails to build", p.returncode != 0)
    expect("its failure names E.Gen's splice import of TH.Gen (got:\n{})".format(tail(p.stderr, 15)),
           "E.Gen's splice import of TH.Gen runs code from" in p.stderr and "but template_haskell_depends doesn't list it" in p.stderr)


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
               {"lib:A.Base", "lib:A.Mid", "th-local-splice:C.Splice", "th-local-splice:C.Ann", "th-prebuilt-splice:D.Splice", "reexport-user:U.M"}
               | ({"eli:E.Gen", "eli:E.Lib", "eli-reexport:ER.M"} if st.eli else set()))


def check_cutoff_abi_mid(st):
    """A new export of A.Mid recompiles A.Mid's importers in other packages:
    B.M, C.Plain, and B.Safe, whose import is a safe one. It doesn't
    recompile B.M's importers in main, because B.M's ABI is unchanged. With
    GHC 9.14 or later, it also recompiles ER.M. ER.M's splice runs lib's
    code, so lib's library is an input of its compile, and the edit makes
    the library change."""
    replace("lib/A/Mid.hs", "module A.Mid (mid) where", "module A.Mid (mid, mid2) where")
    append("lib/A/Mid.hs", "\nmid2 :: Int\nmid2 = 2\n")
    expect_set("modules compiled after a new export of A.Mid", rebuild(st),
               {"lib:A.Mid", "lib-user:B.M", "lib-user:B.Safe", "th-local-splice:C.Plain"} | ({"eli-reexport:ER.M"} if st.eli else set()))


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
    - U.V's, U.W's and V.S's splices, which call native libraries (one of
      them with the soname libver.so.1), compile.
    - After a change to the body of TH.Gen, C.Splice and C.Ann compile again
      in each mode, and //th-local-splice:show prints the new value."""
    def check():
        shown = buck2("run", "//th-local-splice:show").stdout.strip()
        for mode in ["opt", "prof"]:
            build("//th-local-splice:show", "//th-ffi-splice:th-ffi-splice", "//th-native-soname:th-native-soname", mode=mode)
            ran = compiled_modules(what_ran())
            expect("the splicing modules compiled per-module in {} mode (ran: {})".format(mode, sorted(ran)),
                   {"th-local-splice:C.Splice", "th-ffi-splice:U.V", "th-ffi-splice:U.W", "th-native-soname:V.S"} <= ran)
            expect_output("//th-local-splice:show", "in {} mode".format(mode), shown, mode)
        bump_literal("th-gen/TH/Gen.hs", 10)
        for mode in ["opt", "prof"]:
            build("//th-local-splice:show", mode=mode)
            expect_set("modules of th-local-splice compiled in {} mode after a body-only edit to TH.Gen".format(mode),
                       {m for m in compiled_modules(what_ran()) if m.startswith("th-local-splice:")}, {"th-local-splice:C.Splice", "th-local-splice:C.Ann"})
            expect_output("//th-local-splice:show", "in {} mode after the edit to TH.Gen".format(mode), str(int(shown) + 10), mode)
    restoring("th-gen/TH/Gen.hs", check)


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
