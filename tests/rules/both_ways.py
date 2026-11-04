"""The checks of what holds however a target is compiled. Each builds its
fixtures both per-module and with --make (see COMPILES), and says how the
two differ where they should."""

import json
import re
import sys

from harness import (
    COMPILES,
    CheckFailed,
    DEV_STYLE,
    Skipped,
    buck2,
    build,
    compiled,
    configured,
    expect,
    expect_output,
    expect_set,
    failed_compiles,
    index_files,
    known_failure,
    module_of,
    replace,
    short,
    tail,
    what_ran,
    what_ran_entries,
)


def check_make_build(st):
    """The fixtures build with --make too. Each fixture that sets PER_MODULE
    is compiled by one --make action, and the others as they always are:
    make-between's p and t per-module, make-lib and m with --make."""
    build(*[configured(t, "make") for t in st.targets])
    expect_set("compiles of the fixtures with --make", compiled(what_ran()),
               {"lib", "lib-user", "th-gen", "th-local-splice", "show", "th-prebuilt-splice", "th-make-dep", "mkrun",
                "ffi-import", "boot-cycle", "main", "reexport", "reexport-user", "flat-sources", "make-lib", "m", "p:Chain.P", "t:Chain.T"})


def check_local_splices(st):
    """A splice that runs code of another local library (C.Splice's runs
    TH.Gen's, MK.Run's runs make-lib's Q.Lib) or of its own target (P.Use's
    runs P.Gen's) compiles either way, and //th-internal-splice:use prints
    the value that P.Gen's splice made. With --make, it does so in prof mode
    too. check_local_splices_in_modes checks the other modes per-module."""
    build(*[configured(t, c) for t in ["//th-local-splice:th-local-splice", "//th-make-dep:mkrun", "//th-internal-splice:th-internal-splice"] for c in COMPILES])
    for c, mode in [("per-module", None), ("make", None), ("make", "prof")]:
        expect_output(configured("//th-internal-splice:use", c, mode), "compiled {}, in {} mode".format(c, mode or "dev"), "42")


def check_own_boot_splices(st):
    """Splices that run code of a module of their own target behind an
    hs-boot file. OB.A imports OB.B {-# SOURCE #-}, and the splices run
    OB.A's code, which runs OB.B's. Compiled per-module, OB.T, which reaches
    OB.B only through the boot file, fails to compile. Outside the worker,
    the dep file check fails it (see DepFile in tools/ghc-api). In the
    worker, GHC's linker refuses OB.B, or with GHC 9.14 panics. With --make,
    OB.T compiles. OB.U, which also imports OB.B whole through OB.C,
    compiles either way, except in the persistent worker, whose session has
    OB.B only as its boot interface, so that it may fail too."""
    p = build(configured("//th-own-boot:boot-only", "per-module"), keep_going=True)
    expect_set("the modules whose compiles failed", failed_compiles(p.stderr), {"boot-only:OB.T"})
    build(configured("//th-own-boot:boot-only", "make"))
    build(configured("//th-own-boot:both", "make"))
    p = build(configured("//th-own-boot:both", "per-module"), keep_going=True)
    if not st.worker:
        expect("//th-own-boot:both builds per-module (got:\n{})".format(tail(p.stderr, 15)), p.returncode == 0)


def check_rts_flags(st):
    """Options for GHC's runtime (+RTS ... -RTS) among a target's compiler
    flags don't stop its modules compiling."""
    build(*[configured("//rtsflags:rtsflags", c) for c in COMPILES])


def check_index(st):
    """A library built with -fwrite-ide-info has an index (HaskellIndexInfo)
    with each module's .hie file."""
    for c in COMPILES:
        expect_set("the .hie files of //index:index's index, compiled {}".format(c), index_files("//index:index", compile=c), {"A.hie", "B.hie"})


def check_module_moved(st):
    """A module moved from a target to its dependency (MV.X, from
    //module-move:hi to //module-move:lo): its importer compiles against the
    dependency's, not the interface its old target left behind."""
    for c in COMPILES:
        expect_output(configured("//module-move:main", c), "before MV.X moves, compiled {}".format(c), "12")
    replace("module-move/BUCK.fixture", '''srcs = {"MV.Lo": "MV/Lo.hs"}''', '''srcs = {"MV.Lo": "MV/Lo.hs", "MV.X": "MV/X.hs"}''')
    replace("module-move/BUCK.fixture", '''"MV.X": "MV/X.hs", "MV.Y": "MV/Y.hs"''', '''"MV.Y": "MV/Y.hs"''')
    replace("module-move/MV/X.hs", "x = 2", "x = 3")
    for c in COMPILES:
        expect_output(configured("//module-move:main", c), "after MV.X moves, compiled {}".format(c), "13")


def check_discovered_module(st):
    """A new module that a preprocessor finds by listing a directory, as
    hspec-discover finds specs, compiles the preprocessed module again.
    //build-tools:discover's BT.Disc is written by bt-discover, which imports
    each module in BT/Disc. Adding BT/Disc/B.hs to the target's sources
    changes no file that BT.Disc's compile names, but it changes what the
    preprocessor writes.

    Compiled per-module, the target's other modules may compile again too,
    since a new module changes the target's output directory (see
    per_module_out_dir), so only BT.Disc and BT.Disc.B are required."""
    targets = {c: configured("//build-tools:discover", c) for c in COMPILES}
    build(*targets.values())
    with open("build-tools/BT/Disc/B.hs", "w") as f:
        f.write("module BT.Disc.B where\n")
    replace("build-tools/BUCK.fixture", '"BT.Disc.A": "BT/Disc/A.hs"}', '"BT.Disc.A": "BT/Disc/A.hs", "BT.Disc.B": "BT/Disc/B.hs"}')
    for c, t in targets.items():
        build(t)
        ran = compiled(what_ran())
        if c == "make":
            expect_set("compiles after adding BT/Disc/B.hs, compiled with --make", ran, {"discover"})
        else:
            required = {"discover:BT.Disc", "discover:BT.Disc.B"}
            expect("BT.Disc and BT.Disc.B compile after adding BT/Disc/B.hs, compiled {} (compiled: {})".format(c, sorted(ran)), required <= ran)


def check_header_change(st):
    """An edit to a header in a target's srcs, which a module #includes,
    compiles the module again."""
    targets = {c: configured("//header:header", c) for c in COMPILES}
    build(*targets.values())
    replace("header/Hdr/value.h", "VALUE 1", "VALUE 2")
    expected = {"per-module": {"header:Hdr.M"}, "make": {"header"}}
    for c, t in targets.items():
        build(t)
        expect_set("compiles after an edit to Hdr/value.h, compiled {}".format(c), compiled(what_ran()), expected[c])


def make_compile_dbs(target):
    """The package dbs of `target`'s --make compile in dev mode, by short
    name. aquery doesn't take a target's modifiers, so --make's is passed
    with -m, and it prints the command as one string."""
    out = buck2("aquery", "-m", "//compile:make", "all_actions({})".format(target), "--output-attribute", "category", "--output-attribute", "cmd", "--json").stdout
    for action in json.loads(out).values():
        if action.get("category") == "haskell_compile_" + DEV_STYLE:
            cmd = action["cmd"].strip("[]").split(", ")
            return {short(cmd[n + 1]) for n, a in enumerate(cmd) if a == "-package-db"}
    raise CheckFailed("no --make compile of {}".format(target))


def check_make_th_dbs(st):
    """With --make, a target's compile gets the final package db of a local
    dependency only if its splice_depends lists it, as a
    per-module Template Haskell module does. For the other local
    dependencies, it gets a db that names no library, so it doesn't wait
    for their libraries to be linked. th-local-splice lists //th-gen:th-gen
    but not //lib:lib, and th-prebuilt-splice lists neither."""
    expect_set("th-local-splice's package dbs with --make", make_compile_dbs("root//th-local-splice:th-local-splice"), {"lib:nolib", "th-gen:final", "ghc:global"})
    expect_set("th-prebuilt-splice's package dbs with --make", make_compile_dbs("root//th-prebuilt-splice:th-prebuilt-splice"), {"lib:nolib", "th-gen:nolib", "ghc:global"})


def check_th_modes(st):
    """Splices run in the other build modes: opt (static, -dynamic-too) and
    prof, whose profiled compiles load unprofiled libraries into GHC's
    interpreter. //th-make-dep:lit prints MK.Lit's splice, which runs
    template-haskell's code, as in dev mode."""
    compile_of_lit = {"per-module": "th-make-dep:MK.Lit", "make": "th-make-dep"}
    for c in COMPILES:
        for mode in ["opt", "prof"]:
            target = configured("//th-make-dep:lit", c, mode)
            build(target)
            ran = compiled(what_ran())
            expect("{} compiled in {} mode (ran: {})".format(compile_of_lit[c], mode, sorted(ran)), compile_of_lit[c] in ran)
            expect_output(target, "compiled {}, in {} mode".format(c, mode), "2")


def check_toolchain_th(st):
    """With Template Haskell enabled by the toolchain's flags, a module
    without a LANGUAGE pragma, which runs a splice, compiles: the build is
    the check. (At the end: it changes the configuration.)"""
    buck2("build", "-c", "haskell.compiler_flags=-XTemplateHaskell", *[configured("//toolchain-th:toolchain-th", c) for c in COMPILES])


def check_toolchain_index(st):
    """With -fwrite-ide-info in the toolchain's flags, a library has an
    index with each module's .hie file. (At the end: it changes the
    configuration.)"""
    for c in COMPILES:
        expect_set("the .hie files of //lib:lib's index, compiled {}, with the toolchain's -fwrite-ide-info".format(c),
                   index_files("//lib:lib", "-c", "haskell.compiler_flags=-fwrite-ide-info", compile=c),
                   {"Base.hie", "Mid.hie", "Unused.hie"})


@known_failure("with --make, a splice isn't run again when only the code it runs changes")
def check_th_body_change(st):
    """A change to the body of TH.Gen's gen, which leaves its type and so its
    ABI the same, runs C.Splice's splice of gen again: //th-local-splice:show
    prints the new value. This check runs with --make alone, and
    check_th_body_change_recompiles checks the same per-module."""
    for c in ["make"]:
        expect_output(configured("//th-local-splice:show", c), "before the edit to TH.Gen, compiled {}".format(c), "43")
    replace("th-gen/TH/Gen.hs", "integerL 42", "integerL 43")
    for c in ["make"]:
        expect_output(configured("//th-local-splice:show", c), "after the edit to TH.Gen, compiled {}".format(c), "44")


def check_native_soname_for_splices(st):
    """Splices find a native library whose soname isn't of the form
    libfoo.so: V.S's runs code that calls libver.so.1. (Not on macOS, whose
    libraries have no sonames.)"""
    if sys.platform == "darwin":
        raise Skipped("macOS's libraries have no sonames")
    for c in COMPILES:
        expect_output(configured("//th-native-soname:show", c), "compiled {}".format(c), "5")


@known_failure("with --make, a splice can't call its own target's C libraries")
def check_own_native_libraries_for_splices(st):
    """Splices find the native libraries of their own targets: A.S's and
    B.S's splices run their targets' own modules, which call their targets'
    own C libraries. This check runs with --make alone, and
    check_own_native_libraries_per_module checks it per-module."""
    for c in ["make"]:
        expect_output(configured("//th-own-native:show", c), "compiled {}".format(c), "(9,11)")


@known_failure("with -fexternal-interpreter, the static and profiled interpreters don't load a local library's native dependencies")
def check_external_interpreter_native_splices(st):
    """With -fexternal-interpreter in the toolchain's compiler flags, splices
    that call native libraries run in the opt and prof modes too: U.V's and
    U.W's splices, which run //c-lib:c-lib's code through
    //ffi-import:ffi-import, compile with --make.

    In those modes the external interpreter is static or profiled, and it
    loads ffi-import's archive with GHC's own linker. Only the libraries that
    ffi-import's package db names are loaded, and the db doesn't name
    c-lib, so the splices can't find its symbols."""
    for mode in ["opt", "prof"]:
        buck2("build", "-c", "haskell.compiler_flags=-fexternal-interpreter", configured("//th-ffi-splice:th-ffi-splice", "make", mode))


def check_external_interpreter_prof_library(st):
    """With -fexternal-interpreter in the toolchain's compiler flags, a
    profiled splice runs a local library's code: C.Splice's splice, which
    runs TH.Gen of //th-gen:th-gen, compiles with --make in prof mode. The
    profiled interpreter loads th-gen's profiled archive. Its non-profiled
    shared library would crash the interpreter."""
    buck2("build", "-c", "haskell.compiler_flags=-fexternal-interpreter", configured("//th-local-splice:th-local-splice", "make", "prof"))


@known_failure("with --make, a splice isn't run again when only the code it runs changes")
def check_native_library_change(st):
    """U.V's and U.W's splices run //c-lib:c-lib's code, through
    //ffi-import:ffi-import and //ffi-import:ffi-wrap, and c-lib calls
    //c-lib:c-base. After a change to c-lib, the splices run the new code.
    This check runs with --make alone, and
    check_native_library_change_recompiles checks the same per-module."""
    for c in ["make"]:
        expect_output(configured("//th-ffi-splice:show", c), "before the edit to //c-lib:c-lib, compiled {}".format(c), "(7,7)")
    replace("c-lib/cl.c", "return 7", "return 8")
    for c in ["make"]:
        expect_output(configured("//th-ffi-splice:show", c), "after the edit to //c-lib:c-lib, compiled {}".format(c), "(8,8)")


def check_data_dirs(st):
    """A splice runs code of a local library that reads a data file through
    the variable data_dirs sets, as a package's Paths_<pkg> module does.
    Per-module, the module with the splice compiles outside the worker even
    when the project has one, since the worker can't give a compile the
    variable (see Note [Data files of splices])."""
    for c in COMPILES:
        target = configured("//data-dirs:data-dirs", c)
        build(target)
        if c == "per-module":
            ran = {module_of(e): e["reproducer"].get("executor", "") for e in what_ran_entries() if "haskell_compile_module_" in e["identity"]}
            # The first compile that buck2 sends to a worker has the executor
            # WorkerInit rather than Worker, because it also starts the worker.
            executor = {"WorkerInit": "Worker"}.get(ran.get("data-dirs:Main"), ran.get("data-dirs:Main"))
            expect_set("how //data-dirs:data-dirs's Main compiled", {executor}, {"Local"})
        expect_output(target, "from its data file, compiled {}".format(c), "hello")


def check_configurations(st):
    """l is built in two configurations in one build, with the same unit id
    and soname in both. Its v is 4 in the execution platform's configuration,
    and 3 in the target platform's. tool's splice (tool is gen's build tool)
    runs the execution platform's l, and user's runs the target platform's.
    Each gets its own configuration's l.

    Per-module, buck2 starts a worker of the toolchain's for each
    configuration."""
    for c in COMPILES:
        gen, show = configured("//th-exec-config:gen", c), configured("//th-exec-config:show", c)
        out = buck2("build", "--show-full-output", gen, show).stdout
        entries = what_ran_entries()
        path = [line.split()[1] for line in out.splitlines() if line.split() and line.split()[0].startswith("root//th-exec-config:gen")][0]
        with open(path) as f:
            value = f.read().strip()
        expect("compiled {}, tool's splice ran the execution platform's l (gen.txt: {!r})".format(c, value), value == "4")
        expect_output(show, "(the target platform's l), compiled {}".format(c), "3")
        if c == "per-module" and st.worker:
            inits = {}
            for e in entries:
                m = re.match(r"^(\S+) \(cfg:([^)]*)\) \((\S+)", e["identity"])
                if m and m.group(3).startswith("haskell_compile_module_") and e["reproducer"].get("executor") == "WorkerInit":
                    inits[m.group(2)] = inits.get(m.group(2), 0) + 1
            expect("a worker for each configuration (started: {})".format(inits), sorted(inits.values()) == [1, 1])


def check_th_boot_cycles(st):
    """Tie.I and Tie.K run Template Haskell, and each one's boot file is
    below the other: the target builds."""
    for c in COMPILES:
        build(configured("//th-boot-cycles:th-boot-cycles", c))
