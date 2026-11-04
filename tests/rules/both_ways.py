"""The checks of what holds however a target is compiled. Each builds its
fixtures both per-module and with --make (see COMPILES), and says how the
two differ where they should."""

import re
import sys

from harness import (
    COMPILES,
    Skipped,
    buck2,
    build,
    compiled,
    configured,
    expect,
    expect_output,
    expect_set,
    index_files,
    known_failure,
    module_of,
    replace,
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
                "ffi-import", "boot-cycle", "main", "reexport", "reexport-user", "th-boot-cycles", "flat-sources", "make-lib", "m", "p:Chain.P", "t:Chain.T"})


def check_local_splices(st):
    """A splice that runs code of another local library (C.Splice's runs
    TH.Gen's, MK.Run's runs make-lib's Q.Lib) or of its own target (P.Use's
    runs P.Gen's) compiles either way, and //th-internal-splice:use prints
    the value that P.Gen's splice made. With --make, it does so in prof mode
    too; check_local_splices_in_modes checks the other modes per-module."""
    build(*[configured(t, c) for t in ["//th-local-splice:th-local-splice", "//th-make-dep:mkrun", "//th-internal-splice:th-internal-splice"] for c in COMPILES])
    for c, mode in [("per-module", None), ("make", None), ("make", "prof")]:
        expect_output(configured("//th-internal-splice:use", c, mode), "compiled {}, in {} mode".format(c, mode or "dev"), "42")


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
    prints the new value. With --make alone: check_th_body_change_recompiles
    checks it per-module."""
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
    own C libraries. With --make alone: check_own_native_libraries_per_module
    checks it per-module."""
    for c in ["make"]:
        expect_output(configured("//th-own-native:show", c), "compiled {}".format(c), "(9,11)")


@known_failure("with --make, a splice isn't run again when only the code it runs changes")
def check_native_library_change(st):
    """U.V's and U.W's splices run //c-lib:c-lib's code, through
    //ffi-import:ffi-import and //ffi-import:ffi-wrap, and c-lib calls
    //c-lib:c-base. After a change to c-lib, the splices run the new code.
    With --make alone: check_native_library_change_recompiles checks it
    per-module."""
    for c in ["make"]:
        expect_output(configured("//th-ffi-splice:show", c), "before the edit to //c-lib:c-lib, compiled {}".format(c), "(7,7)")
    replace("c-lib/cl.c", "return 7", "return 8")
    for c in ["make"]:
        expect_output(configured("//th-ffi-splice:show", c), "after the edit to //c-lib:c-lib, compiled {}".format(c), "(8,8)")


def check_data_dirs(st):
    """A splice runs code of a local library that reads a data file through
    the variable data_dirs sets, as a package's Paths_<pkg> module does.
    When the project has a worker, the module with the splice compiles in the
    worker per-module, which starts the session's interpreter with the
    variable."""
    for c in COMPILES:
        target = configured("//data-dirs:data-dirs", c)
        build(target)
        if c == "per-module":
            ran = {module_of(e): e["reproducer"].get("executor", "") for e in what_ran_entries() if "haskell_compile_module_" in e["identity"]}
            # The first compile that buck2 sends to a worker has the executor
            # WorkerInit rather than Worker, because it also starts the worker.
            executor = {"WorkerInit": "Worker"}.get(ran.get("data-dirs:Main"), ran.get("data-dirs:Main"))
            expect_set("how //data-dirs:data-dirs's Main compiled", {executor}, {"Worker" if st.worker else "Local"})
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
