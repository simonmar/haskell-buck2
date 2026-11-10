"""The checks of what holds however a target is compiled. Each builds its
fixtures both per-module and with --make (see COMPILES), and says how the
two differ where they should."""

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
    replace,
    tail,
    what_ran,
)


def check_make_build(st):
    """The fixtures build with --make too. Each fixture that sets PER_MODULE
    is compiled by one --make action, and the others as they always are:
    make-between's p and t per-module, make-lib and m with --make."""
    build(*[configured(t, "make") for t in st.targets])
    expect_set("compiles of the fixtures with --make", compiled(what_ran()),
               {"lib", "lib-user", "th-gen", "th-prebuilt-splice", "th-make-dep", "ffi-import", "boot-cycle", "main",
                "reexport", "reexport-user", "flat-sources", "make-lib", "m", "p:Chain.P", "t:Chain.T"})


# How the checks of splices that run local code compile their fixtures. Those
# splices fail to compile per-module (see check_local_splices), so they are
# checked with --make alone.
LOCAL_SPLICE_COMPILES = ["make"]


def check_local_splices(st):
    """A splice that runs code of another local library (C.Splice's runs
    TH.Gen's, MK.Run's runs make-lib's Q.Lib) or of its own target (P.Use's
    runs P.Gen's). Compiled per-module, which doesn't support that, each
    module fails to compile, saying how to build the target instead. With
    --make, each compiles, and //th-internal-splice:use prints the value
    that P.Gen's splice made, in prof mode too."""
    for target, module in [("//th-local-splice:th-local-splice", "C.Splice"), ("//th-make-dep:mkrun", "MK.Run")]:
        p = build(target, keep_going=True)
        expect("{} fails to build".format(target), p.returncode != 0)
        expect("{}'s failure is {}'s, and names the fix (got:\n{})".format(target, module, tail(p.stderr, 15)),
               module in p.stderr and "per_module = False" in p.stderr)
    p = build("//th-internal-splice:th-internal-splice", keep_going=True)
    expect("//th-internal-splice:th-internal-splice fails to build", p.returncode != 0)
    expect("its failure is P.Use's, and names the fix (got:\n{})".format(tail(p.stderr, 15)),
           "P.Use" in p.stderr and "this target's own modules" in p.stderr and "per_module = False" in p.stderr)

    build(*[configured(t, "make") for t in ["//th-local-splice:th-local-splice", "//th-make-dep:mkrun"]])
    for mode in [None, "prof"]:
        expect_output(configured("//th-internal-splice:use", "make", mode), "with --make, in {} mode".format(mode or "dev"), "42")


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
    prints the new value."""
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//th-local-splice:show", c), "before the edit to TH.Gen, compiled {}".format(c), "43")
    replace("th-gen/TH/Gen.hs", "integerL 42", "integerL 43")
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//th-local-splice:show", c), "after the edit to TH.Gen, compiled {}".format(c), "44")


def check_native_soname_for_splices(st):
    """Splices find a native library whose soname isn't of the form
    libfoo.so: V.S's runs code that calls libver.so.1. (Not on macOS, whose
    libraries have no sonames.)"""
    if sys.platform == "darwin":
        raise Skipped("macOS's libraries have no sonames")
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//th-native-soname:show", c), "compiled {}".format(c), "5")


@known_failure("with --make, a splice can't call its own target's C libraries")
def check_own_native_libraries_for_splices(st):
    """Splices find the native libraries of their own targets: A.S's and
    B.S's splices run their targets' own modules, which call their targets'
    own C libraries."""
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//th-own-native:show", c), "compiled {}".format(c), "(9,11)")


@known_failure("with --make, a splice isn't run again when only the code it runs changes")
def check_native_library_change(st):
    """U.V's and U.W's splices run //c-lib:c-lib's code, through
    //ffi-import:ffi-import and //ffi-import:ffi-wrap, and c-lib calls
    //c-lib:c-base. After a change to c-lib, the splices run the new code."""
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//th-ffi-splice:show", c), "before the edit to //c-lib:c-lib, compiled {}".format(c), "(7,7)")
    replace("c-lib/cl.c", "return 7", "return 8")
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//th-ffi-splice:show", c), "after the edit to //c-lib:c-lib, compiled {}".format(c), "(8,8)")


def check_data_dirs(st):
    """A splice runs code of a local library that reads a data file through
    the variable data_dirs sets, as a package's Paths_<pkg> module does."""
    for c in LOCAL_SPLICE_COMPILES:
        expect_output(configured("//data-dirs:data-dirs", c), "from its data file, compiled {}".format(c), "hello")


def check_configurations(st):
    """l is built in two configurations in one build, with the same unit id
    and soname in both. Its v is 4 in the execution platform's configuration,
    and 3 in the target platform's. tool's splice (tool is gen's build tool)
    runs the execution platform's l, and user's runs the target platform's.
    Each gets its own configuration's l."""
    for c in LOCAL_SPLICE_COMPILES:
        gen, show = configured("//th-exec-config:gen", c), configured("//th-exec-config:show", c)
        out = buck2("build", "--show-full-output", gen, show).stdout
        path = [line.split()[1] for line in out.splitlines() if line.split() and line.split()[0].startswith("root//th-exec-config:gen")][0]
        with open(path) as f:
            value = f.read().strip()
        expect("compiled {}, tool's splice ran the execution platform's l (gen.txt: {!r})".format(c, value), value == "4")
        expect_output(show, "(the target platform's l), compiled {}".format(c), "3")


def check_th_boot_cycles(st):
    """Tie.I and Tie.K run Template Haskell, and each one's boot file is
    below the other: the target builds."""
    for c in LOCAL_SPLICE_COMPILES:
        build(configured("//th-boot-cycles:th-boot-cycles", c))
