# Wrappers around the native haskell_library()/haskell_binary() rules, and
# a haskell_test() rule.
#
# These handle:
#   - build modes: e.g. `-m opt` selects optimisation + static linking
#   - package deps: `packages = ["text", ...]` instead of explicit
#     `"@third-party-haskell//:text"` entries in `deps`.
#   - a standard set of packages (rts) added to every target (`auto_packages`).
#   - hsc2hs: any `.hsc` file in `srcs` is automatically preprocessed, with
#     include paths derived from `deps` (see buck2/hsc2hs.bzl) - so a `.hsc`
#     file that needs a C++ dependency's headers just needs that dependency
#     listed in `deps`, same as any other buck2 target.
#   - alex/happy: any `.x`/`.y`/`.ly` file in `srcs` is automatically run through
#     the corresponding tool (see buck2/alex_happy.bzl).
#   - boot files: `boot_srcs = {module: file}` gives the .hs-boot file of each
#     module (of `srcs`, by module name) that has one. That of a generated
#     module (from a .hsc/.x/.y file) is put next to the generated source,
#     which is where GHC looks for it.
#   - support for build rules generated from Cabal packages:
#     - `cabal_component = (autogen, component)` causes this component's
#       `cabal_macros.h` file (in `autogen`, the directory of the package's
#       autogen files, from the project root) to be included when
#       `{-# LANGUAGE CPP #-}` is on.

load("//buck2:alex_happy.bzl", "alex", "happy")
load("//buck2:hsc2hs.bzl", "hsc2hs")
load("@prelude//paths.bzl", "paths")

# Packages implicitly needed by every Haskell target.
AUTO_PACKAGES = ["rts"]

def _package_deps(packages, auto_packages):
    all_pkgs = {p: None for p in (auto_packages + packages)}
    return [("@third-party-haskell//:" + p) for p in sorted(all_pkgs.keys())]

def _cabal_macros_include_flags(cabal_component):
    if cabal_component == None:
        return []
    autogen_dir, component = cabal_component
    label = "//" + autogen_dir + ":" + component + "-cabal-macros"
    return ["-optP-include", "-optP$(location " + label + ")"]

def _cabal_macros_hsc_flags(cabal_component):
    # hsc2hs wants the package's macros too (MIN_VERSION_base, say).
    flags = _cabal_macros_include_flags(cabal_component)
    return ["--cflag=-include", "--cflag=" + flags[1][len("-optP"):]] if flags else []

# Link style for executables: the linking constraint's (static or shared), or
# else dynamic, but static for opt, and for prof, which must be static: GHC
# doesn't support prof/dynamic.
_BUILD_MODE_LINK_STYLE = select({
    "root//buck2/constraints:static": "static",
    "root//buck2/constraints:shared": "shared",
    "DEFAULT": select({
        "root//buck2/constraints:prof": "static",
        "DEFAULT": select({
            "root//buck2/constraints:opt": "static",
            "DEFAULT": "shared",
        }),
    }),
})

_BUILD_MODE_HASKELL_FLAGS = select({
    "root//buck2/constraints:opt": ["-O"],
    "DEFAULT": [],
})

# Libraries are built shared when executables are linked shared, and static
# and shared otherwise (Template Haskell needs a library shared, for a GHC
# that is itself linked shared).
_BUILD_MODE_PREFERRED_LINKAGE = select({
    "root//buck2/constraints:static": "any",
    "root//buck2/constraints:shared": "shared",
    "DEFAULT": select({
        "root//buck2/constraints:prof": "any",
        "DEFAULT": select({
            "root//buck2/constraints:opt": "any",
            "DEFAULT": "shared",
        }),
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
    for ext in (".hsc", ".x", ".y", ".ly"):
        if path.endswith(ext):
            return path[:-len(ext)] + ".hs"
    return path

def _resolve_src(name, src, deps, hsc_flags, hsc_cxx, common):
    out = paths.replace_extension(src, ".hs")
    if src.endswith(".hsc"):
        rule_name = name + "-hsc-" + out.replace("/", "_")
        hsc2hs(name = rule_name, hsc_file = src, out = out, deps = deps, extra_flags = hsc_flags, cxx = hsc_cxx, **common)
        return ":" + rule_name
    elif src.endswith(".x"):
        rule_name = name + "-alex-" + out.replace("/", "_")
        alex(name = rule_name, src = src, out = out, **common)
        return ":" + rule_name
    elif src.endswith(".y") or src.endswith(".ly"):
        rule_name = name + "-happy-" + out.replace("/", "_")
        happy(name = rule_name, src = src, out = out, **common)
        return ":" + rule_name
    else:
        return src

def _with_boot_impl(ctx: AnalysisContext) -> list[Provider]:
    boot_path = paths.split_extension(ctx.attrs.path)[0] + paths.split_extension(ctx.attrs.boot.short_path)[1]
    srcs = ctx.actions.symlinked_dir("srcs", {ctx.attrs.path: ctx.attrs.src, boot_path: ctx.attrs.boot}, has_content_based_path = False)
    return [DefaultInfo(sub_targets = {
        "boot": [DefaultInfo(default_output = srcs.project(boot_path))],
        "src": [DefaultInfo(default_output = srcs.project(ctx.attrs.path))],
    })]

# A generated source of a module (`path` is where it would be in the package),
# with the module's boot file next to it, which is where GHC looks for it.
_with_boot = rule(
    impl = _with_boot_impl,
    attrs = {
        "boot": attrs.source(),
        "path": attrs.string(),
        "src": attrs.source(),
    },
)

def _resolve_srcs(name, srcs, boot_srcs, deps, hsc_flags, hsc_cxx, kwargs):
    # The rules that preprocess sources are compatible with the same
    # configurations as the rule whose sources they are.
    common = {"target_compatible_with": kwargs["target_compatible_with"]} if "target_compatible_with" in kwargs else {}
    if type(srcs) != type({}):
        if boot_srcs:
            fail("{}: boot_srcs needs srcs to be a dict, by module name".format(name))
        return [ _resolve_src(name, src, deps, hsc_flags, hsc_cxx, common) for src in srcs ]
    unknown = [modl for modl in boot_srcs if modl not in srcs]
    if unknown:
        fail("{}: boot_srcs for modules not in srcs: {}".format(name, ", ".join(unknown)))
    resolved = {}
    for modl, src in srcs.items():
        resolved_src = _resolve_src(name, src, deps, hsc_flags, hsc_cxx, common)
        boot = boot_srcs.get(modl)
        if boot == None:
            resolved[modl] = resolved_src
        elif resolved_src == src:
            resolved[modl] = src
            resolved[modl + "-boot"] = boot
        else:
            rule_name = name + "-boot-" + modl
            _with_boot(name = rule_name, src = resolved_src, boot = boot, path = paths.replace_extension(src, ".hs"), **common)
            resolved[modl] = ":" + rule_name + "[src]"
            resolved[modl + "-boot"] = ":" + rule_name + "[boot]"
    return resolved

def haskell_library(
        name,
        srcs = [],
        packages = [],
        deps = [],
        compiler_flags = [],
        hsc_flags = [],
        hsc_cxx = True,
        cabal_component = None,
        boot_srcs = {},
        auto_packages = AUTO_PACKAGES,
        internal_deps = [],
        **kwargs):
    all_deps = deps + _package_deps(packages, auto_packages)
    kwargs.setdefault("preferred_linkage", _BUILD_MODE_PREFERRED_LINKAGE)
    native.haskell_library(
        name = name,
        srcs = _resolve_srcs(name, srcs, boot_srcs, all_deps + internal_deps, hsc_flags + _cabal_macros_hsc_flags(cabal_component), hsc_cxx, kwargs),
        compiler_flags = compiler_flags + _BUILD_MODE_HASKELL_FLAGS + _cabal_macros_include_flags(cabal_component),
        deps = all_deps,
        internal_deps = internal_deps,
        **kwargs
    )

def haskell_binary(
        name,
        srcs = [],
        packages = [],
        deps = [],
        compiler_flags = [],
        hsc_flags = [],
        hsc_cxx = True,
        linker_flags = [],
        cabal_component = None,  # see haskell_library()
        boot_srcs = {},  # see haskell_library()
        auto_packages = AUTO_PACKAGES,  # see haskell_library()
        **kwargs):
    all_deps = deps + _package_deps(packages, auto_packages)
    kwargs.setdefault("link_style", _BUILD_MODE_LINK_STYLE)
    kwargs.setdefault("enable_profiling", _PROF_ENABLED)
    native.haskell_binary(
        name = name,
        srcs = _resolve_srcs(name, srcs, boot_srcs, all_deps, hsc_flags + _cabal_macros_hsc_flags(cabal_component), hsc_cxx, kwargs),
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



