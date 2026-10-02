# Wrappers around the native haskell_library()/haskell_binary() rules, and
# a haskell_test() rule.
#
# These handle:
#   - build modes: e.g. `-m opt` selects optimisation + static linking
#   - package deps: `packages = ["text", ...]` instead of explicit
#     `"@third-party-haskell//:text"` entries in `deps`.
#   - a standard set of packages (base, rts) added to every target.
#   - hsc2hs: any `.hsc` file in `srcs` is automatically preprocessed, with
#     include paths derived from `deps` (see buck2/hsc2hs.bzl) - so a `.hsc`
#     file that needs a C++ dependency's headers just needs that dependency
#     listed in `deps`, same as any other buck2 target.
#   - alex/happy: any `.x`/`.y` file in `srcs` is automatically run through
#     the corresponding tool (see buck2/alex_happy.bzl).
#   - support for build rules generated from Cabal packages:
#     - `cabal_component = (pkg, component)` causes this component's
#       `cabal_macros.h` file to be included when `{-# LANGUAGE CPP #-}`
#       is on.

load("//buck2:alex_happy.bzl", "alex", "happy")
load("//buck2:hsc2hs.bzl", "hsc2hs")
load("@prelude//haskell/util.bzl", "src_to_module_name")
load("@prelude//paths.bzl", "paths")

# Packages implicitly needed by every Haskell target.
AUTO_PACKAGES = ["base", "rts"]

def _package_deps(packages):
    all_pkgs = {p: None for p in (AUTO_PACKAGES + packages)}
    return [("@third-party-haskell//:" + p) for p in sorted(all_pkgs.keys())]

def _cabal_macros_include_flags(cabal_component):
    if cabal_component == None:
        return []
    pkg, component = cabal_component
    autogen_dir = "cabal-buck2/autogen" if pkg == "." else pkg + "/cabal-buck2/autogen"
    label = "//" + autogen_dir + ":" + component + "-cabal-macros"
    return ["-optP-include", "-optP$(location " + label + ")"]

# Link style for executables: the default is dynamic, opt is static, and prof
# must also be static - GHC doesn't support prof/dynamic.
_BUILD_MODE_LINK_STYLE = select({
    "root//buck2/constraints:prof": "static",
    "DEFAULT": select({
        "root//buck2/constraints:opt": "static",
        "DEFAULT": "shared",
    }),
})

_BUILD_MODE_HASKELL_FLAGS = select({
    "root//buck2/constraints:opt": ["-O"],
    "DEFAULT": [],
})

_BUILD_MODE_PREFERRED_LINKAGE = select({
    "root//buck2/constraints:prof": "any",
    "DEFAULT": select({
        "root//buck2/constraints:opt": "any",
        "DEFAULT": "shared",
    }),
})

_PROF_ENABLED = select({
    "root//buck2/constraints:prof": True,
    "DEFAULT": False,
})

# Linker flags enabled when building with ASAN
_ASAN_LINKER_FLAGS = select({
    "root//buck2/constraints:asan": ["-optc-fsanitize=address", "-optl-fsanitize=address"],
    "DEFAULT": [],
})

def hs_module_path(path):
    for ext in (".hsc", ".x", ".y"):
        if path.endswith(ext):
            return path[:-len(ext)] + ".hs"
    return path

def _resolve_src(name, src, deps, hsc_flags):
    out = paths.replace_extension(src, ".hs")
    if src.endswith(".hsc"):
        rule_name = name + "-hsc-" + out.replace("/", "_")
        hsc2hs(name = rule_name, hsc_file = src, out = out, deps = deps, extra_flags = hsc_flags)
        return ":" + rule_name
    elif src.endswith(".x"):
        rule_name = name + "-alex-" + out.replace("/", "_")
        alex(name = rule_name, src = src, out = out)
        return ":" + rule_name
    elif src.endswith(".y"):
        rule_name = name + "-happy-" + out.replace("/", "_")
        happy(name = rule_name, src = src, out = out)
        return ":" + rule_name
    else:
        return src

def _resolve_srcs(name, srcs, deps, hsc_flags):
    items = srcs.items() if type(srcs) == type({}) else [(src_to_module_name(src), src) for src in srcs]
    return { modl: _resolve_src(name, src, deps, hsc_flags) for modl, src in items }

def haskell_library(
        name,
        srcs = [],
        packages = [],
        deps = [],
        compiler_flags = [],
        hsc_flags = [],
        cabal_component = None,
        **kwargs):
    all_deps = deps + _package_deps(packages)
    kwargs.setdefault("preferred_linkage", _BUILD_MODE_PREFERRED_LINKAGE)
    native.haskell_library(
        name = name,
        srcs = _resolve_srcs(name, srcs, all_deps, hsc_flags),
        compiler_flags = compiler_flags + _BUILD_MODE_HASKELL_FLAGS + _cabal_macros_include_flags(cabal_component),
        deps = all_deps,
        **kwargs
    )

def haskell_binary(
        name,
        srcs = [],
        packages = [],
        deps = [],
        compiler_flags = [],
        hsc_flags = [],
        linker_flags = [],
        cabal_component = None,  # see haskell_library()
        **kwargs):
    all_deps = deps + _package_deps(packages)
    kwargs.setdefault("link_style", _BUILD_MODE_LINK_STYLE)
    kwargs.setdefault("enable_profiling", _PROF_ENABLED)
    native.haskell_binary(
        name = name,
        srcs = _resolve_srcs(name, srcs, all_deps, hsc_flags),
        compiler_flags = compiler_flags + _BUILD_MODE_HASKELL_FLAGS + _ASAN_LINKER_FLAGS + _cabal_macros_include_flags(cabal_component),
        deps = all_deps,
        linker_flags = _ASAN_LINKER_FLAGS + linker_flags,
        **kwargs
    )

def haskell_test(name, test_args = [], test_env = {}, cwd = None, **kwargs):
    bin = name + "-bin"
    haskell_binary(name = bin, **kwargs)
    test_target = ":" + bin
    args = test_args

    if cwd != None:
        test_target = "//buck2:run_in_cwd"
        args = [cwd, "$(exe_target :" + bin + ")"] + test_args

    native.sh_test(
        name = name,
        test = test_target,
        args = args,
        env = {"LANG": "C.UTF-8"} | test_env,
        # `LANG` defaults to a UTF-8 locale: unlike `buck2 run` (which
        # inherits the caller's shell environment, `LANG` included),
        # `buck2 test` runs actions in a sanitized environment with no
        # `LANG` at all - so GHC's `hGetContents`/`readFile` fall back
        # to the POSIX/ASCII encoding and choke on any non-ASCII byte
        # in a test fixture.
    )



