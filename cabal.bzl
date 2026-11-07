# Creates the buck2 rules for one Cabal package from a "build spec": a plain
# dict describing the package's components as Cabal sees them, rather than as
# buck2 rules. `cabal buck2` writes the spec (into the package's
# BUCK.cabal.bzl); this file turns it into haskell_library()/haskell_binary()/
# haskell_test() (and, for components with C/C++ sources, cxx_library() and
# external_pkgconfig_library()) targets, so all of the buck2-specific
# decisions - target labels, flag assembly, which wrapper to use - live here
# and can be customised from a BUCK file (see cabal_targets()).
#
# Spec schema. Optional keys are omitted when empty.
#
#   {
#     "cabal_buck2": str,                    # the release of cabal-buck2 that wrote this; see version.bzl
#     "package": {"name": str, "version": str},   # where it lives: see PACKAGES, below
#     "ghc_options": [str],                   # supplied by the project, not the .cabal file
#     "per_module": bool,                     # compile each module in its own action (`cabal buck2 --per-module`)
#     "data": {"dir": str, "files": [str]},   # the package's data-dir and data-files (patterns)
#     "extra_source_files": [str],            # the package's extra-source-files (patterns)
#     "components": [
#       {
#         "kind": "library" | "executable" | "test-suite" | "benchmark",
#         "name": str,                        # also the buck2 target name
#         "exe_name": str,                    # executables only: the file name, if not the target name
#         "srcs": {module: src},              # src: package-relative path | {"autogen": name} | {"provided": True}
#         "boot_srcs": {module: str},         # the .hs-boot file of each module that has one (package-relative)
#         "main_is": src,                     # not for libraries; module "Main", or C/C++ (see _foreign_main)
#         "ghc_options": [str], "cpp_options": [str],
#         "language": str, "extensions": [str],
#         "extra_libraries": [str],
#         "ld_options": [str],                # ld-options as configured, so with pkgconfig-depends' other linker flags (-Wl,-rpath, say)
#         "extra_lib_dirs": [str],            # where to find them: extra-lib-dirs as configured, so with pkgconfig-depends' directories
#         "deps": [dep],                      # see below
#         "reexports": [{"module": str, "original": str, "from": dep}],  # libraries only; no "from" for a module of the library itself
#         "hidden_modules": [str],            # libraries only: the modules the package doesn't expose (other-modules)
#         "build_tools": [{"exe": str, "package": str} | {"exe": str, "external": True}],  # package: built by this project
#         "c_sources": [str], "cc_options": [str],
#         "cxx_sources": [str], "cxx_options": [str],
#         "cmm_sources": [str],
#         "asm_sources": [str], "asm_options": [str],
#         "include_dirs": [str], "pkgconfig": [str],
#         "hsc_options": [str],               # defines for hsc2hs's C compiler (the platform)
#         "exposed": bool,                    # False: the library's package isn't exposed (a library's)
#         "generated_include_dirs": [str],    # headers that `./configure` generated (relative to the project root)
#         "test_args": [str],                 # test-suites only
#       },
#     ],
#   }
#
# An "autogen" src names a file generated next to the sources, in the
# package's cabal-buck2/autogen directory. A dep is {"package": str} for a
# package's main library, {"package": str, "library": str} for a named
# sub-library.
#
# The spec says nothing about where packages are: that is in PACKAGES, which
# `cabal buck2` writes for the whole project into cabal-buck2/packages.bzl at
# the project root, and which maps the name of each package that the project
# builds to its directory (relative to the root, "." for the root itself). A
# dependency on one of those is a dependency on a target of this project,
# anything else is a prebuilt package from @third-party-haskell. So a
# package's spec is the same wherever in the project the package is, and in
# whichever project: moving a package only changes packages.bzl. (All of the
# packages are in the root cell.)
#
# A project customises the generated targets of its packages in a
# cabal-buck2.bzl at its root, rather than in each package's BUCK file (which
# may not be the project's to change, in a git submodule say): its OVERRIDES
# maps the name of a package to the overrides of its components, as
# cabal_targets() takes them. packages.bzl passes it on.

# This load has to come before the others: they load more from tools.bzl (the
# fingerprints, the alex and happy targets...), which a tools.bzl written by
# another release of cabal-buck2 doesn't have, and then all that buck2 says is
# that a symbol is missing. This one is in every tools.bzl since 0.3.0.0, so
# a tools.bzl from an earlier release fails here, on a symbol that says what
# it is about, and an incompatible one is reported just below.
load("@third-party-haskell//:tools.bzl", TOOLS_CABAL_BUCK2_VERSION = "CABAL_BUCK2_VERSION")
load("//buck2:version.bzl", "CABAL_BUCK2_VERSION")
load("//buck2:cmm.bzl", "cmm_library")
load("//buck2:cxx.bzl", "cxx_binary", "cxx_library")
load("//buck2:headers.bzl", "headers_of")
load("//buck2:haskell.bzl", "haskell_binary", "haskell_library", "haskell_test")
load("//buck2:variant.bzl", "variant")
load("//cabal-buck2:packages.bzl", "OVERRIDES", "PACKAGES")
load("@prelude//paths.bzl", "paths")
load("@prelude//third-party:pkgconfig.bzl", "external_pkgconfig_library")

if TOOLS_CABAL_BUCK2_VERSION != CABAL_BUCK2_VERSION:
    fail("\n".join([
        "third-party/haskell was generated by cabal-buck2 {}, but buck2/ is for cabal-buck2 {}.".format(TOOLS_CABAL_BUCK2_VERSION, CABAL_BUCK2_VERSION),
        "Re-run `cabal buck2` with cabal-buck2 {}, or switch buck2/ to the {} branch of".format(CABAL_BUCK2_VERSION, TOOLS_CABAL_BUCK2_VERSION),
        "https://github.com/simonmar/haskell-buck2.",
    ]))

_DEFAULT_RULES = {
    "library": haskell_library,
    "executable": haskell_binary,
    "benchmark": haskell_binary,
    "test-suite": haskell_test,
}

def _nub(xs):
    seen = {}
    out = []
    for x in xs:
        if x not in seen:
            seen[x] = True
            out.append(x)
    return out

def _label(dir, name):
    return "//" + ("" if dir == "." else dir) + ":" + name

def _this_dir(spec):
    # The directory of the package being generated. The BUCK file calling
    # cabal_targets() has to be in it: if it isn't, packages.bzl is out of
    # date (or this BUCK file was copied from elsewhere).
    name = spec["package"]["name"]
    dir = PACKAGES.get(name)
    if dir == None:
        fail("package {} isn't in cabal-buck2/packages.bzl (at the root of the project): re-run `cabal buck2`".format(name))
    here = native.package_name()
    if here != ("" if dir == "." else dir):
        fail("package {} is in {} according to cabal-buck2/packages.bzl, but its BUCK file is in {}: re-run `cabal buck2`".format(name, dir, here or "."))
    return dir

def _third_party_label(name):
    return "third-party-haskell//:" + name

def _src(pkg_dir, src):
    if type(src) == type({}):
        autogen_dir = "cabal-buck2/autogen" if pkg_dir == "." else pkg_dir + "/cabal-buck2/autogen"
        return _label(autogen_dir, src["autogen"])
    return src

def _provided(src):
    return type(src) == type({}) and src.get("provided", False)

# If the Cabal file has `main-is: foo.hs` and `ghc-options: -main-is
# Foo`, then the only way we can know the module of `foo.hs` is by
# groveling around in `ghc-options` looking for `-main-is`.
# This is fragile, but I don't see a better way to do it.
def _main_module(c):
    # Note that we have to support `-main-is Mod`, `-main-is Mod.fn` and
    # `-main-is fn` (the latter is ignored)
    opts = c.get("ghc_options", [])
    for i in range(len(opts) - 1):
        if opts[i] == "-main-is" and opts[i + 1][0].isupper():
            mod, _, last = opts[i + 1].rpartition(".")
            return mod if mod and last[0].islower() else opts[i + 1]
    return "Main"

def _srcs(c, pkg_dir):
    srcs = {}
    if "main_is" in c:
        srcs[_main_module(c)] = _src(pkg_dir, c["main_is"])
    for module, src in c.get("srcs", {}).items():
        if not _provided(src):
            srcs[module] = _src(pkg_dir, src)
    return srcs

def _check_provided(spec, c, srcs):
    # A "provided" module is one that the package's Setup.hs would have
    # generated (`cabal buck2 --enable-custom-setup` doesn't run it), whose
    # source the project gives instead, in the component's overrides.
    missing = [m for m, src in c.get("srcs", {}).items() if _provided(src) and m not in srcs]
    if missing:
        fail("{}: the Setup.hs of package {} would generate {}, but it isn't run (--enable-custom-setup): give their sources in the component's overrides, e.g. overrides = {{\"{}\": {{\"srcs\": {{\"{}\": ...}}}}}}".format(
            c["name"],
            spec["package"]["name"],
            ", ".join(missing),
            c["name"],
            missing[0],
        ))

def _include_flags(c, pkg_dir):
    # The package's own include directories, and where a configure script put
    # the headers it generated: GHC needs both for CPP and for the C stubs of
    # foreign imports. They are paths from the root of the project, which is
    # where the compiler runs.
    dirs = [d if pkg_dir == "." or d.startswith("/") else pkg_dir + "/" + d for d in c.get("include_dirs", [])]
    return _nub(["-I" + d for d in dirs + c.get("generated_include_dirs", [])])

def _this_unit_id(flags):
    # The unit id that a package's options give its library, as those of a
    # package that GHC knows by its unit id do (rts, ghc-internal).
    unit_id = None
    for i, flag in enumerate(flags):
        if flag == "-this-unit-id" and i + 1 < len(flags):
            unit_id = flags[i + 1]
    return unit_id

def _unit_id(spec, c, name):
    """
    The unit id of the library component `c` (named `name`) in the given
    package spec.

    The unit id is given by a `-this-unit-id` flag if there is one, or
    otherwise the default Cabal unit id:
        <package>-<version>-inplace[-<component>]
    """
    unit_id = _this_unit_id(list(c.get("ghc_options", [])) + list(spec.get("ghc_options", [])))
    if unit_id:
        return unit_id
    package = spec["package"]
    unit_id = package["name"] + ("-" + package["version"] if "version" in package else "") + "-inplace"
    return unit_id if name == package["name"] else unit_id + "-" + name

def cabal_unit_id(spec, name):
    """
    The unit id of the component `name` in the given package `spec`
    """
    c = [c for c in spec["components"] if c["kind"] == "library" and c["name"] == name][0]
    return _unit_id(spec, c, name)

def _lib_dir_flags(c, pkg_dir):
    # Where the linker looks for the component's extra_libraries: its
    # extra-lib-dirs, which Cabal has already extended with the directories
    # of its pkgconfig-depends at configure time. Package-relative, like
    # include_dirs, so made relative to the root of the project the same way.
    dirs = [d if pkg_dir == "." or d.startswith("/") else pkg_dir + "/" + d for d in c.get("extra_lib_dirs", [])]
    return _nub(["-L" + d for d in dirs])

def _ld_flags(c):
    # ld-options are for the linker itself: they reach it from GHC's command
    # line with -optl.
    return _nub(["-optl" + f for f in c.get("ld_options", [])])

def _haskell_flags(c, pkg_dir, project_ghc_options):
    # default-language isn't just documentation: GHC2021/GHC2024 each imply a
    # bundle of extensions, so leaving it out would silently fall back to
    # GHC's own default (Haskell2010). Project-supplied options come last, as
    # in Cabal, so that they can override the component's own.
    own = list(c.get("ghc_options", [])) + list(c.get("cpp_options", []))
    if "language" in c:
        own.append("-X" + c["language"])
    own += ["-X" + e for e in c.get("extensions", [])]
    own += _include_flags(c, pkg_dir)
    return _nub(own) + project_ghc_options

def _linker_flags(c, pkg_dir, project_ghc_options):
    # haskell_binary and haskell_test pass compiler_flags to each module's
    # compile step only, not to the final link, whereas Cabal gives a
    # component's whole ghc-options to every ghc invocation. So anything
    # link-relevant there (-threaded, -rtsopts) has to reach linker_flags
    # too; compile-only flags like -Wall are ignored by ghc when linking.
    own = _lib_dir_flags(c, pkg_dir) + ["-l" + l for l in c.get("extra_libraries", [])] + _ld_flags(c) + list(c.get("ghc_options", []))
    return _nub(own) + project_ghc_options

def _dep_label(d):
    # A dependency's target: a library of this project, or an external
    # package's main library or sub-library.
    if d["package"] in PACKAGES:
        return _label(PACKAGES[d["package"]], d.get("library", d["package"]))
    if "library" in d:
        # Libraries of different packages have the same names.
        return _third_party_label(d["package"] + "--" + d["library"])
    return _third_party_label(d["package"])

def _classify_deps(deps):
    # `packages` only ever resolves an external package's main library;
    # everything else (local libraries, external sub-libraries) is a target
    # label in `deps`.
    packages = []
    local = []
    external_sublibs = []
    for d in deps:
        if d["package"] in PACKAGES:
            local.append(_dep_label(d))
        elif "library" in d:
            external_sublibs.append(_dep_label(d))
        else:
            packages.append(d["package"])
    return _nub(packages), _nub(local + external_sublibs)

def _build_tool_depends(build_tools):
    # Each tool becomes a real dependency that is put on PATH for just this
    # rule's compile actions.
    labels = []
    for t in build_tools:
        if "package" in t:
            labels.append(_label(PACKAGES[t["package"]], t["exe"]))
        else:
            labels.append(_third_party_label(t["exe"] + "-exe"))
    return _nub(labels)

def _pkgconfig_deps(c, pkgconfig_seen):
    # The targets of the component's pkgconfig-depends, created by the first
    # component of the package that has them.
    pkgconfig = _nub(c.get("pkgconfig", []))
    for p in pkgconfig:
        if p not in pkgconfig_seen:
            pkgconfig_seen[p] = True
            external_pkgconfig_library(name = "pkgconfig-" + p, package = p, visibility = ["PUBLIC"])
    return [":pkgconfig-" + p for p in pkgconfig]

def _cxx_kwargs(c, pkgconfig_seen, srcs):
    # The attributes of a C/C++ rule that compiles `srcs` with the
    # component's options.
    pkgconfig = _pkgconfig_deps(c, pkgconfig_seen)

    kwargs = {"srcs": srcs, "visibility": ["PUBLIC"]}

    # cc-options are for C and assembler (which GHC also gets the C compiler
    # to preprocess), cxx-options for C++.
    cc_options = _nub(c.get("cc_options", []))
    lang_flags = {
        "assembler_with_cpp": cc_options + _nub(c.get("asm_options", [])),
        "c": cc_options,
        "cxx": _nub(c.get("cxx_options", [])),
    }
    kwargs["lang_compiler_flags"] = {lang: flags for lang, flags in lang_flags.items() if flags}

    kwargs["deps"] = pkgconfig

    return kwargs

_PROFILING_DEFINES = select({
    "root//buck2/constraints:prof": ["-DPROFILING"],
    "DEFAULT": [],
})

# To match GHC, we explicitly disable PIC for C compiles (except on
# MacOS and Windows), in case gcc has it enabled by default. See GHC's
# picCCOpts. When linking dynamically, the later -fPIC will override
# this.
_NO_PIC = select({
    "config//os:macos": [],
    "config//os:windows": [],
    "DEFAULT": ["-fno-PIC"],
})

def _cxx_library(c, pkg_dir, pkgconfig_seen):
    # Returns the labels the Haskell rule must additionally depend on.
    srcs = list(c.get("c_sources", [])) + list(c.get("cxx_sources", [])) + list(c.get("asm_sources", []))
    if not srcs:
        return []
    kwargs = _cxx_kwargs(c, pkgconfig_seen, srcs)
    name = c["name"] + "-cxx"

    # The C of a Haskell component is compiled as GHC would compile it,
    # which includes its version header (defining __GLASGOW_HASKELL__) and
    # makes available its own headers (HsFFI.h) and those of the packages
    # the component depends on (HsUnixConfig.h, say), and defines PROFILING
    # when it is profiled.
    kwargs["compiler_flags"] = ["-include", "ghcversion.h"] + _PROFILING_DEFINES + _NO_PIC
    packages, labels = _classify_deps(c.get("deps", []))
    headers = name + "-headers"
    headers_of(name = headers, deps = _nub([_third_party_label(p) for p in ["rts"] + packages] + labels))
    kwargs["deps"] = [":" + headers] + kwargs["deps"]

    # exported_preprocessor_flags is an opaque list of strings to buck2, so
    # (unlike srcs) its include paths have to be made relative to the cell
    # root by hand: cxx actions always run from there.
    include_flags = _include_flags(c, pkg_dir)
    if include_flags:
        kwargs["exported_preprocessor_flags"] = include_flags
    # Like the C of a Cabal package, it is all part of the library of the
    # component's Haskell code (see `internal_deps` of haskell_library()):
    # the RTS's C, say, calls hidden functions of its Cmm, which only resolve
    # within one shared library.
    kwargs["preferred_linkage"] = "static"
    kwargs["link_whole"] = True
    kwargs["use_archive"] = False
    cxx_library(name = name, **kwargs)
    return [":" + name]

# The extensions by which Cabal recognises a C or C++ main-is.
_FOREIGN_MAIN_EXTENSIONS = [".c", ".cpp", ".cxx", ".c++"]

def _foreign_main(c):
    main = c.get("main_is")
    return type(main) == type("") and paths.split_extension(main)[1] in _FOREIGN_MAIN_EXTENSIONS

def _cxx_binary(c, pkg_dir, pkgconfig_seen, overrides):
    # A component whose main-is is C/C++ (as some of GHC's own tools are) is
    # built as a plain C/C++ program. Cabal would compile it with GHC, which
    # makes GHC's headers and those of the component's Haskell dependencies
    # available, and link it with GHC, which links in the RTS. Neither is of
    # any use to a program without Haskell code in it (which isn't supported
    # here), so its dependencies on external Haskell packages (base, say)
    # are ignored.
    unsupported = []
    if c["kind"] not in ("executable", "benchmark"):
        unsupported.append("a " + c["kind"])
    if c.get("srcs"):
        unsupported.append("Haskell modules")
    if c.get("cmm_sources"):
        unsupported.append("Cmm sources")
    _, local_deps = _classify_deps(c.get("deps", []))
    if local_deps:
        unsupported.append("dependencies on Haskell libraries")
    if unsupported:
        fail("{}: a C/C++ main-is ({}) is only supported in an executable without {}".format(
            c["name"],
            c["main_is"],
            " or ".join(unsupported),
        ))
    srcs = [c["main_is"]] + list(c.get("c_sources", [])) + list(c.get("cxx_sources", [])) + list(c.get("asm_sources", []))
    kwargs = _cxx_kwargs(c, pkgconfig_seen, srcs)
    kwargs["name"] = c["name"]
    if "exe_name" in c:
        kwargs["executable_name"] = c["exe_name"]
    include_flags = _include_flags(c, pkg_dir)
    if include_flags:
        kwargs["preprocessor_flags"] = include_flags
    linker_flags = _lib_dir_flags(c, pkg_dir) + ["-l" + l for l in c.get("extra_libraries", [])] + c.get("ld_options", [])
    if linker_flags:
        kwargs["linker_flags"] = _nub(linker_flags)
    cxx_binary(**_merge(kwargs, overrides))

def _cmm_library(c, spec):
    # GHC compiles Cmm, given the component's options as for Haskell.
    if not c.get("cmm_sources"):
        return []
    pkg_dir = _this_dir(spec)
    name = c["name"] + "-cmm"
    cmm_library(
        name = name,
        srcs = list(c["cmm_sources"]),
        flags = _haskell_flags(c, pkg_dir, list(spec.get("ghc_options", []))),
        visibility = ["PUBLIC"],
    )
    return [":" + name]

def _profiled(label):
    # `label` (a target of this package) built for profiling.
    name = label.removeprefix(":") + "-prof"
    variant(name = name, actual = label, transition = "root//buck2/constraints:to-prof", visibility = ["PUBLIC"])
    return ":" + name

def _haskell_kwargs(c, spec, helpers):
    # `helpers` are the rules of the component's C/C++/Cmm code.
    pkg_dir = _this_dir(spec)
    project_ghc_options = list(spec.get("ghc_options", []))
    kind = c["kind"]
    packages, deps = _classify_deps(c.get("deps", []))
    kwargs = {
        "name": c["name"],
        "srcs": _srcs(c, pkg_dir),
        "boot_srcs": dict(c.get("boot_srcs", {})),
        "cabal_component": (pkg_dir, c["name"]),
    }
    if "exe_name" in c:
        kwargs["exe_name"] = c["exe_name"]
    if spec.get("per_module", False):
        kwargs["per_module"] = True
    if kind == "test-suite":
        kwargs["cwd"] = pkg_dir
        if c.get("test_args"):
            kwargs["test_args"] = list(c["test_args"])
    compiler_flags = _haskell_flags(c, pkg_dir, project_ghc_options)
    hsc_flags = ["--cflag=" + f for f in c.get("hsc_options", []) + c.get("cc_options", []) + _include_flags(c, pkg_dir)]
    if hsc_flags:
        kwargs["hsc_flags"] = hsc_flags

    # hsc2hs compiles C, as in Cabal, unless there is C++ in the component.
    kwargs["hsc_cxx"] = bool(c.get("cxx_sources") or c.get("cxx_options"))
    if compiler_flags:
        kwargs["compiler_flags"] = compiler_flags
    if kind == "library":
        kwargs["package_name"] = spec["package"]["name"]
        if "version" in spec["package"]:
            kwargs["package_version"] = spec["package"]["version"]
        kwargs["unit_id"] = _unit_id(spec, c, c["name"])
        # The code of the helpers is part of the library, as in Cabal, which
        # compiles it for each way: for the profiled library, as built for
        # profiling.
        if helpers:
            kwargs["internal_deps"] = helpers
            kwargs["prof_internal_deps"] = [_profiled(h) for h in helpers]
        kwargs["exposed"] = c.get("exposed", True)
        if c.get("hidden_modules"):
            kwargs["hidden_modules"] = list(c["hidden_modules"])
        if c.get("reexports"):
            kwargs["reexported_modules"] = {r["module"]: (_dep_label(r["from"]) if "from" in r else None, r["original"]) for r in c["reexports"]}
        lib_dirs = _lib_dir_flags(c, pkg_dir)
        # Raw flags: the link of whatever depends on the library hands these
        # to the linker itself (as -optl) already.
        exported = _nub(lib_dirs + ["-l" + l for l in c.get("extra_libraries", [])] + c.get("ld_options", []))
        if exported:
            kwargs["exported_linker_flags"] = exported
        # The library's own shared object must link against them too, not
        # only whatever finally links the library in: GHC loads the .so to
        # run Template Haskell splices in dependents, and that fails on any
        # symbol it leaves unresolved. (ld_options reach GHC's command line
        # with -optl here, unlike the raw flags that dependents are given.)
        own_link = lib_dirs + ["-l" + l for l in c.get("extra_libraries", [])] + _ld_flags(c)
        if own_link:
            kwargs["linker_flags"] = _nub(own_link)
    else:
        deps = deps + helpers
        linker_flags = _linker_flags(c, pkg_dir, project_ghc_options)
        if linker_flags:
            kwargs["linker_flags"] = linker_flags
    if packages:
        kwargs["packages"] = packages
    if deps:
        kwargs["deps"] = deps
    build_tool_depends = _build_tool_depends(c.get("build_tools", []))
    if build_tool_depends:
        kwargs["build_tool_depends"] = build_tool_depends
    if kind != "test-suite":
        kwargs["visibility"] = ["PUBLIC"]
    return kwargs

_LIST_TYPES = (type([]), type(select({"DEFAULT": []})))

def _merge(base, extra):
    # Lists (or selects of them) are appended to, dicts are merged, anything
    # else is replaced.
    out = dict(base)
    for k, v in extra.items():
        cur = out.get(k)
        if type(v) in _LIST_TYPES and type(cur) in _LIST_TYPES:
            out[k] = cur + v
        elif type(v) == type({}) and type(cur) == type({}):
            merged = dict(cur)
            merged.update(v)
            out[k] = merged
        else:
            out[k] = v
    return out

def cabal_targets(spec, defaults = {}, overrides = {}, transform = None, rules = {}):
    """Create the targets described by a build spec.

    Args:
      spec: the package's build spec (see the top of this file).
      defaults: extra attributes for every target of a kind, keyed by kind
          ("library", "executable", "test-suite", "benchmark"), or "*" for all
          of them.
      overrides: extra attributes for individual components, keyed by
          component name. The project's own overrides of the package's
          components (OVERRIDES[package] in its cabal-buck2.bzl, if it has
          one) come before these.
      transform: if given, called as transform(kind, component, attrs) with
          each target's final attributes (the Haskell rule's, not the C/C++
          helper's), and returns the attributes to use instead - or None to
          not create the target at all.
      rules: replacement rule functions to call instead of the defaults,
          keyed by kind.

    Extra attributes are merged into the generated ones: lists are appended
    to, dicts merged, anything else replaced. Later sources win: defaults for
    "*", then for the kind, then the component's override, then transform.
    An executable whose main-is is C/C++ is a cxx_binary() (see
    _cxx_binary()), to which only its overrides apply: defaults, transform
    and rules are for the Haskell rules.
    """
    generated_by = spec.get("cabal_buck2")
    if generated_by != CABAL_BUCK2_VERSION:
        generator = "cabal-buck2 " + generated_by if generated_by else "an earlier release of cabal-buck2 (0.1.0.0)"
        fail("\n".join([
            "This was generated by {}, but buck2/ is for cabal-buck2 {}.".format(generator, CABAL_BUCK2_VERSION),
            "Re-run `cabal buck2` with cabal-buck2 {}, or switch buck2/ to the {} branch of".format(CABAL_BUCK2_VERSION, generated_by or "0.1.0.0"),
            "https://github.com/simonmar/haskell-buck2.",
        ]))
    pkg_dir = _this_dir(spec)
    project_overrides = OVERRIDES.get(spec["package"]["name"], {})
    pkgconfig_seen = {}
    for c in spec["components"]:
        if _foreign_main(c):
            _cxx_binary(c, pkg_dir, pkgconfig_seen, _merge(project_overrides.get(c["name"], {}), overrides.get(c["name"], {})))
            continue
        kind = c["kind"]
        helpers = _cxx_library(c, pkg_dir, pkgconfig_seen) + _cmm_library(c, spec)
        kwargs = _haskell_kwargs(c, spec, helpers)

        # The helpers' own dependencies are linked with the component's.
        kwargs["deps"] = kwargs.get("deps", []) + _pkgconfig_deps(c, pkgconfig_seen)
        kwargs = _merge(kwargs, defaults.get("*", {}))
        kwargs = _merge(kwargs, defaults.get(kind, {}))
        kwargs = _merge(kwargs, project_overrides.get(c["name"], {}))
        kwargs = _merge(kwargs, overrides.get(c["name"], {}))
        if transform:
            kwargs = transform(kind, c, kwargs)
            if kwargs == None:
                continue
        _check_provided(spec, c, kwargs.get("srcs", {}))
        rules.get(kind, _DEFAULT_RULES[kind])(**kwargs)
    _data_files(spec, pkg_dir)
    _extra_source_files(spec)

def _data_files(spec, pkg_dir):
    # The package's data-files, as a directory laid out like its data-dir:
    # what a tool of the package (alex, happy) reads when it runs, to be
    # found through its <package>_datadir environment variable.
    data = spec.get("data")
    if not data:
        return
    prefix = "" if data["dir"] in ("", ".") else data["dir"].rstrip("/") + "/"
    files = native.glob([prefix + pattern for pattern in data["files"]])
    native.filegroup(
        name = spec["package"]["name"] + "-data",
        srcs = {f[len(prefix):]: f for f in files},
        visibility = ["PUBLIC"],
    )

def _extra_source_files(spec):
    # The package's extra-source-files, as a directory laid out like the
    # package, for whatever else in the project needs them: a generator of
    # its sources, say.
    patterns = spec.get("extra_source_files")
    if not patterns:
        return
    native.filegroup(
        name = spec["package"]["name"] + "-extra-source-files",
        srcs = native.glob(patterns),
        visibility = ["PUBLIC"],
    )
