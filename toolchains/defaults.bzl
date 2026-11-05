load("@third-party-haskell//:tools.bzl", "CC", "CC_FINGERPRINT", "CC_TYPE", "CXX", "GHC", "GHC_DYNAMIC", "GHC_FINGERPRINT", "GHC_PKG", "HADDOCK", "HSC2HS", "LINKER")
load("@prelude//tests:test_toolchain.bzl", "noop_test_toolchain")
load("@prelude//toolchains:cxx.bzl", "system_cxx_toolchain")
load("@prelude//toolchains:genrule.bzl", "system_genrule_toolchain")
load("@prelude//toolchains:python.bzl", "system_python_bootstrap_toolchain")
load("@prelude//toolchains:remote_test_execution.bzl", "remote_test_execution_toolchain")
load(":haskell.bzl", "haskell_toolchain")

# The Haskell toolchain for a project set up by `cabal buck2`. A project can
# define its own toolchains cell and call this, overriding any attribute of
# haskell_toolchain(), e.g. to use a compiler that it builds itself.
#
# The tools are those of the GHC that `cabal buck2` configured the project
# with, by the symlinks to them that it renews each time it runs
# (third-party/haskell/toolchain/, relative to the project root, where build
# actions run). Not by their names on the PATH: that would be the PATH of the
# buck2 daemon, which is that of the shell it started in, and goes on being
# that after the shell's tools change (a different Nix shell, say), until the
# daemon restarts.
def default_haskell_toolchain(name, **kwargs):
    kwargs.setdefault("compiler", GHC)
    kwargs.setdefault("packager", GHC_PKG)
    kwargs.setdefault("haddock", HADDOCK)
    kwargs.setdefault("hsc2hs", HSC2HS)
    # Flags for every compile and link, from the project's buckconfig (a
    # machine-local .buckconfig.local, usually: see the README). buck2 runs
    # actions with a clean environment, so the -L and -I directories that a
    # shell sets up (LIBRARY_PATH, CPATH, a Nix or Homebrew shell's flags)
    # don't reach GHC any other way. The root cell's config, not this
    # cell's: the project's .buckconfig is at the root, and read_config()
    # here would read the toolchains cell's own (nonexistent) one.
    kwargs.setdefault("compiler_flags", read_root_config("haskell", "compiler_flags", "").split())
    kwargs.setdefault("linker_flags", read_root_config("haskell", "linker_flags", "").split())
    # GHC_DYNAMIC is what `ghc --info` says of the configured GHC
    # (`("GHC Dynamic", ...)`), so it follows a change of GHC too.
    kwargs.setdefault("dynamic_ghc", GHC_DYNAMIC)
    # Under asan, GHC's own process needs the ASAN runtime already loaded
    # before Template Haskell dlopen's an asan-instrumented dependency
    # mid-compile (confirmed empirically - see buck2/prelude/haskell/
    # toolchain.bzl's own comment on `compile_env`, and buck2.md). The
    # runtime here must match whichever compiler actually produces this
    # project's cxx_library .so's - the C++ compiler of the C/C++ toolchain
    # (CXX: see default_toolchains() below), not the linker; mixing
    # compile/link drivers is fine, but the ASAN runtime ABI must match the
    # *compiler*. `compile_env`'s values are shell-evaluated at build-action
    # time (see haskell/compile.bzl), so this asks the compiler where its
    # runtime is on the machine doing the build. Only correct while CXX is
    # clang: for gcc the runtime is `libasan.so`
    # (`g++ -print-file-name=libasan.so`).
    # CABAL_BUCK2_GHC and CABAL_BUCK2_CC are not read by anything: they are
    # there so that fingerprints of the GHC installation and of the C toolchain
    # (GHC_FINGERPRINT and CC_FINGERPRINT, see third-party/haskell/tools.bzl)
    # are part of every compile and link action, and so of its cache key.
    # `compiler` above is only the path of a symlink, the same wherever GHC is
    # installed, and the files of the installations aren't tracked by buck2.
    # GHC runs the C compiler to preprocess a module that uses CPP, and to
    # link.
    kwargs.setdefault("compile_env", select({
        "root//buck2/constraints:asan": {
            "CABAL_BUCK2_GHC": GHC_FINGERPRINT,
            "CABAL_BUCK2_CC": CC_FINGERPRINT,
            "LD_PRELOAD": "$(" + CXX + " -print-file-name=libclang_rt.asan-x86_64.so)",
            # This preload leaks into every subprocess GHC spawns while
            # compiling (not just the dlopen'd .so's it's actually for) -
            # including plain system tools like `ld`/`bash`/`gcc` that
            # aren't written to be leak-clean under a leak-checking
            # allocator and were never meant to be instrumented at all.
            # Disable leak detection for this incidental, build-tooling-
            # wide preload; the C++ code we actually care about checking
            # still gets real leak detection when the *final executable*
            # itself is linked with -fsanitize=address (see haskell.bzl's
            # _ASAN_LINKER_FLAGS), which is a separate, unaffected setting.
            "ASAN_OPTIONS": "detect_leaks=0",
        },
        "DEFAULT": {"CABAL_BUCK2_GHC": GHC_FINGERPRINT, "CABAL_BUCK2_CC": CC_FINGERPRINT},
    }))
    kwargs.setdefault("link_env", {"CABAL_BUCK2_GHC": GHC_FINGERPRINT, "CABAL_BUCK2_CC": CC_FINGERPRINT})
    kwargs.setdefault("visibility", ["PUBLIC"])
    haskell_toolchain(name = name, **kwargs)

# The toolchains besides Haskell's that the rules of a project set up by
# `cabal buck2` use. The project's C and C++ compiler flags (`c_flags`,
# `cxx_flags`: e.g. its language standard and target CPU) are the C/C++
# toolchain's.
#
# The C and C++ compilers are those `cabal buck2` chose (see
# Distribution.Client.Buck2.Toolchain in cabal-buck2): the C compiler the user
# gave Cabal for `gcc` (`--with-gcc`, or `gcc-location:` in the
# `program-locations` of the project file) and the C++ compiler of the same
# name next to it, else GHC's if it has absolute paths for them (a GHC built
# by Nix), else clang and clang++, linking with g++. Like GHC (see default_haskell_toolchain()), by their symlinks under
# third-party/haskell/toolchain/.
def default_toolchains(c_flags = [], cxx_flags = []):
    system_cxx_toolchain(
        name = "cxx",
        c_flags = c_flags,
        cxx_flags = cxx_flags,
        compiler = CC,
        cxx_compiler = CXX,
        compiler_type = CC_TYPE,
        linker = LINKER,
        visibility = ["PUBLIC"],
    )

    # The C++ toolchain's default names this in an arm of a select() that is
    # never chosen (see _cxx_toolchain() in decls/toolchains_common.bzl), so
    # it only has to exist: for queries of the unconfigured graph (uquery),
    # which follow every arm.
    native.alias(
        name = "cxx_no_default_deps",
        actual = ":cxx",
        visibility = ["PUBLIC"],
    )

    system_genrule_toolchain(
        name = "genrule",
        visibility = ["PUBLIC"],
    )

    system_python_bootstrap_toolchain(
        name = "python_bootstrap",
        visibility = ["PUBLIC"],
    )

    remote_test_execution_toolchain(
        name = "remote_test_execution",
        visibility = ["PUBLIC"],
    )

    noop_test_toolchain(
        name = "test",
        visibility = ["PUBLIC"],
    )
