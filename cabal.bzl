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
#     "data": {"dir": str, "files": [str]},   # the package's data-dir and data-files (patterns)
#     "extra_source_files": [str],            # the package's extra-source-files (patterns)
#     "components": [
#       {
#         "kind": "library" | "executable" | "test-suite" | "benchmark",
#         "name": str,                        # also the buck2 target name
#         "exe_name": str,                    # executables only: the file name, if not the target name
#         "srcs": {module: src},              # src: package-relative path | {"autogen": name} | {"provided": True}
#         "boot_srcs": {module: str},         # the .hs-boot file of each module that has one (package-relative)
#         "provided_sources": {str: kind},    # C/C++/Cmm/asm sources that the project provides; kind: "c_sources", say
#         "main_is": src,                     # not for libraries; module "Main", or C/C++ (see _foreign_main)
#         "ghc_options": [str], "cpp_options": [str],
#         "language": str, "extensions": [str],
#         "extra_libraries": [str],
#         "ld_options": [str],                # ld-options as configured, so with pkgconfig-depends' other linker flags (-Wl,-rpath, say)
#         "extra_lib_dirs": [str],            # where to find them: extra-lib-dirs as configured, so with pkgconfig-depends' directories
#         "deps": [dep],                      # see below
#         "reexports": [{"module": str, "original": str, "from": dep}],  # libraries only; no "from" for a module of the library itself
#         "build_tools": [{"exe": str, "package": str} | {"exe": str, "external": True}],  # package: built by this project
#         "c_sources": [str], "cc_options": [str],
#         "cxx_sources": [str], "cxx_options": [str],
#         "cmm_sources": [str],
#         "asm_sources": [str], "asm_options": [str],
#         "include_dirs": [str], "pkgconfig": [str],
#         "hsc_options": [str],               # defines for hsc2hs's C compiler (the platform)
#         "includes": [str],                  # headers that GHC includes in what is compiled against the library
#         "exposed": bool,                    # False: the library's package isn't exposed (a library's)
#         "generated_include_dir": str,       # the target of their directory
#         "generated_headers": str,           # the headers that `./configure` generated: a target in cabal-buck2/autogen
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
load("//cabal-buck2:packages.bzl", "OVERRIDES", "PACKAGES", "PACKAGE_SETS", "PACKAGE_SET_MODIFIERS", "PACKAGE_SET_TRANSITIONS", "PACKAGE_TARGETS", "PROJECT_PACKAGE_SET")
load("@prelude//haskell:util.bzl", "haskell_unit_id")
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
    dir = _packages(spec).get(name)
    if dir == None:
        fail("package {} isn't in cabal-buck2/packages.bzl (at the root of the project): re-run `cabal buck2`".format(name))
    here = native.package_name()
    if here != ("" if dir == "." else dir):
        fail("package {} is in {} according to cabal-buck2/packages.bzl, but its BUCK file is in {}: re-run `cabal buck2`".format(name, dir, here or "."))
    return dir

def _packages(spec):
    # The packages that this package's dependencies are among: those of its
    # later stage (see `cabal buck2 --later-stage`), or of the project.
    if "package_set" in spec:
        return PACKAGE_SETS[spec["package_set"]]
    return PACKAGES

def _third_party_label(name):
    return "third-party-haskell//:" + name

def _autogen_dir(spec, pkg_dir):
    # Where the package's autogen files of its package set are (see autogenDir
    # in cabal-buck2's Write.hs).
    dir = "cabal-buck2/autogen" + ("-" + spec["package_set"] if "package_set" in spec else "")
    return dir if pkg_dir == "." else pkg_dir + "/" + dir

def _src(c, src):
    if type(src) == type({}):
        return _label(c["_autogen"], src["autogen"])
    return src

def _provided(src):
    return type(src) == type({}) and src.get("provided", False)

def _srcs(c, pkg_dir):
    srcs = {}
    if "main_is" in c:
        srcs["Main"] = _src(c, c["main_is"])
    for module, src in c.get("srcs", {}).items():
        if not _provided(src):
            srcs[module] = _src(c, src)
    return srcs

def _check_provided(spec, c, srcs):
    # A "provided" module has no source in the package: one generated by its
    # Setup.hs, which `cabal buck2 --enable-custom-setup` doesn't run, or by
    # the build system of a later stage's package. The project gives its
    # source instead, in the component's overrides.
    missing = [m for m, src in c.get("srcs", {}).items() if _provided(src) and m not in srcs]
    if missing:
        fail("{}: package {} has no source for {}, which is generated: give their sources in the component's overrides, e.g. overrides = {{\"{}\": {{\"srcs\": {{\"{}\": ...}}}}}}".format(
            c["name"],
            spec["package"]["name"],
            ", ".join(missing),
            c["name"],
            missing[0],
        ))

_FOREIGN_SOURCES = ["c_sources", "cxx_sources", "asm_sources", "cmm_sources"]

def _with_foreign_sources(spec, c, provided, src_flags):
    # The component, with the sources that the project provides (in the
    # component's overrides, `provided_sources`) among those of their kind,
    # and each source with flags of its own (`src_flags`) paired with them,
    # as cxx_library() and cmm_library() take it.
    wanted = c.get("provided_sources", {})
    missing = [f for f in wanted if f not in provided]
    if missing:
        fail("{}: package {} has no {}, which is generated: give them in the component's overrides, e.g. overrides = {{\"{}\": {{\"provided_sources\": {{\"{}\": ...}}}}}}".format(
            c["name"],
            spec["package"]["name"],
            ", ".join(missing),
            c["name"],
            missing[0],
        ))
    unknown = [f for f in provided if f not in wanted]
    if unknown:
        fail("{}: provided_sources for sources the package has: {}".format(c["name"], ", ".join(unknown)))
    if not wanted and not src_flags:
        return c
    c = dict(c)
    for f, kind in wanted.items():
        c[kind] = list(c.get(kind, [])) + [f]
    sources = [f for kind in _FOREIGN_SOURCES for f in c.get(kind, [])]
    unknown = [f for f in src_flags if f not in sources]
    if unknown:
        fail("{}: src_flags for sources it doesn't have: {}".format(c["name"], ", ".join(unknown)))

    def source(f):
        src = provided.get(f, f)
        return (src, src_flags[f]) if f in src_flags else src

    for kind in _FOREIGN_SOURCES:
        if kind in c:
            c[kind] = [source(f) for f in c[kind]]
    return c

def _include_flags(c, pkg_dir):
    # The package's own include directories: GHC needs them for CPP and for
    # the C stubs of foreign imports. They are paths from the root of the
    # project, which is where the compiler runs.
    dirs = [d if pkg_dir == "." or d.startswith("/") else pkg_dir + "/" + d for d in c.get("include_dirs", [])]
    return _nub(["-I" + d for d in dirs])

def _generated_headers(c, pkg_dir):
    # The target with the headers that the package's configure script
    # generated, which are needed where its own include directories are.
    if "generated_headers" not in c:
        return []
    return [_label(c["_autogen"], c["generated_headers"])]

# What an include directory has that a C preprocessor may include.
_HEADER_PATTERNS = ["**/*.h", "**/*.hh", "**/*.hpp", "**/*.hxx", "**/*.inc"]

def _package_include_dirs(c, pkg_dir):
    # The include directories of the library's package, as Cabal registers
    # them in place: its own (each a filegroup of its headers), and those its
    # configure script generated headers in. One outside the project is the
    # system's, which is only for the package's own C (see _include_flags()).
    dirs = []
    for i, d in enumerate([d for d in c.get("include_dirs", []) if not d.startswith("/")]):
        prefix = "" if d == "." else d.rstrip("/") + "/"
        name = "{}-include-{}".format(c["name"], i)
        native.filegroup(
            name = name,
            srcs = {f[len(prefix):]: f for f in native.glob([prefix + p for p in _HEADER_PATTERNS])},
            **c["_common"]
        )
        dirs.append(":" + name)
    return dirs + ([_label(c["_autogen"], c["generated_include_dir"])] if "generated_include_dir" in c else [])

def _this_unit_id(flags):
    # The unit id that a package's options give its library, as those of a
    # package that GHC knows by its unit id do (rts, ghc-internal).
    unit_id = None
    for i, flag in enumerate(flags):
        if flag == "-this-unit-id" and i + 1 < len(flags):
            unit_id = flags[i + 1]
    return unit_id

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

def _dep_label(packages, d):
    # A dependency's target: a library of this project (or for its main
    # library, the target that the project's PACKAGE_TARGETS gives, which it
    # makes of the generated one, say), or an external package's main
    # library or sub-library.
    if d["package"] in packages and d["package"] in PACKAGE_TARGETS and "library" not in d:
        return PACKAGE_TARGETS[d["package"]]
    if d["package"] in packages:
        return _label(packages[d["package"]], d.get("library", d["package"]))
    if "library" in d:
        # Libraries of different packages have the same names.
        return _third_party_label(d["package"] + "--" + d["library"])
    return _third_party_label(d["package"])

def _classify_deps(known, deps):
    # `packages` only ever resolves an external package's main library;
    # everything else (local libraries, external sub-libraries) is a target
    # label in `deps`.
    packages = []
    local = []
    external_sublibs = []
    for d in deps:
        if d["package"] in known:
            local.append(_dep_label(known, d))
        elif "library" in d:
            external_sublibs.append(_dep_label(known, d))
        else:
            packages.append(d["package"])
    return _nub(packages), _nub(local + external_sublibs)

def _build_tool_depends(packages, build_tools):
    # Each tool becomes a real dependency that is put on PATH for just this
    # rule's compile actions.
    labels = []
    for t in build_tools:
        if "package" in t:
            labels.append(_label(packages[t["package"]], t["exe"]))
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

def _cxx_library(c, packages, pkg_dir, pkgconfig_seen, overrides):
    # Returns the labels the Haskell rule must additionally depend on.
    srcs = list(c.get("c_sources", [])) + list(c.get("cxx_sources", [])) + list(c.get("asm_sources", []))
    if not srcs:
        return []
    kwargs = _cxx_kwargs(c, pkgconfig_seen, srcs)
    name = c["name"] + "-cxx"

    # The C of a Haskell component is compiled as GHC would compile it,
    # which includes the rts's version header (defining __GLASGOW_HASKELL__)
    # and makes available its headers (HsFFI.h) and those of the packages
    # the component depends on (HsUnixConfig.h, say).
    deps, has_rts = _header_deps(c, packages)
    if has_rts:
        kwargs["compiler_flags"] = ["-include", "ghcversion.h"]
    headers = name + "-headers"
    headers_of(name = headers, deps = deps, **c["_common"])
    kwargs["deps"] = [":" + headers] + kwargs["deps"]

    # exported_preprocessor_flags is an opaque list of strings to buck2, so
    # (unlike srcs) its include paths have to be made relative to the cell
    # root by hand: cxx actions always run from there.
    include_flags = _include_flags(c, pkg_dir)
    if include_flags:
        kwargs["exported_preprocessor_flags"] = include_flags
    kwargs["exported_deps"] = _generated_headers(c, pkg_dir)
    # Like the C of a Cabal package, it is all part of the library of the
    # component's Haskell code (see `internal_deps` of haskell_library()):
    # the RTS's C, say, calls hidden functions of its Cmm, which only resolve
    # within one shared library.
    kwargs["preferred_linkage"] = "static"
    kwargs["link_whole"] = True
    kwargs["use_archive"] = False
    cxx_library(name = name, **_merge(_merge(kwargs, c["_common"]), overrides))
    return [":" + name]

# The extensions by which Cabal recognises a C or C++ main-is.
_FOREIGN_MAIN_EXTENSIONS = [".c", ".cpp", ".cxx", ".c++"]

def _foreign_main(c):
    main = c.get("main_is")
    return type(main) == type("") and paths.split_extension(main)[1] in _FOREIGN_MAIN_EXTENSIONS

def _cxx_binary(c, packages, pkg_dir, pkgconfig_seen, overrides):
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
    _, local_deps = _classify_deps(packages, c.get("deps", []))
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
    kwargs["deps"] = kwargs["deps"] + _generated_headers(c, pkg_dir)
    linker_flags = _lib_dir_flags(c, pkg_dir) + ["-l" + l for l in c.get("extra_libraries", [])] + c.get("ld_options", [])
    if linker_flags:
        kwargs["linker_flags"] = _nub(linker_flags)
    cxx_binary(**_merge(_merge(kwargs, c["_common"]), overrides))

def _header_deps(c, packages):
    # The libraries whose headers the C or Cmm of a component may include:
    # those of the packages it depends on, and the rts's. The compiler's own
    # rts is always available; one of this project's only to the components
    # that depend on it (as all do that depend on anything), as it is to GHC.
    # Returns them, and whether the rts is among them.
    external, labels = _classify_deps(packages, c.get("deps", []))
    implicit = [] if "rts" in packages else ["rts"]
    deps = _nub([_dep_label(packages, {"package": p}) for p in implicit + external] + labels)
    return deps, bool(implicit or c.get("deps"))

def _cmm_library(c, spec, overrides):
    # GHC compiles Cmm, given the component's options as for Haskell.
    if not c.get("cmm_sources"):
        return []
    pkg_dir = _this_dir(spec)
    name = c["name"] + "-cmm"
    kwargs = {
        "srcs": list(c["cmm_sources"]),
        "flags": _haskell_flags(c, pkg_dir, list(spec.get("ghc_options", []))),
        "deps": _generated_headers(c, pkg_dir) + _header_deps(c, _packages(spec))[0],
        "visibility": ["PUBLIC"],
    }
    cmm_library(name = name, **_merge(_merge(kwargs, c["_common"]), overrides))
    return [":" + name]

def _haskell_kwargs(c, spec, helpers):
    # `helpers` are the rules of the component's C/C++/Cmm code.
    pkg_dir = _this_dir(spec)
    project_ghc_options = list(spec.get("ghc_options", []))
    kind = c["kind"]
    project_packages = _packages(spec)
    packages, deps = _classify_deps(project_packages, c.get("deps", []))
    deps = _nub(deps + _generated_headers(c, pkg_dir))
    kwargs = {
        "name": c["name"],
        "srcs": _srcs(c, pkg_dir),
        "boot_srcs": dict(c.get("boot_srcs", {})),
        "cabal_component": (c["_autogen"], c.get("_name", c["name"])),
    }
    if "exe_name" in c:
        kwargs["exe_name"] = c["exe_name"]
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
        # The unit id of the package, whichever set's it is built as (the
        # one of the alias `<comp>`).
        kwargs["unit_id"] = _this_unit_id(compiler_flags) or haskell_unit_id(
            native.get_cell_name() + "//" + native.package_name(),
            c.get("_name", c["name"]),
        )
        # The code of the helpers is part of the library, as in Cabal.
        if helpers:
            kwargs["internal_deps"] = helpers
        include_dirs = _package_include_dirs(c, pkg_dir)
        if include_dirs:
            kwargs["include_dirs"] = include_dirs
        if c.get("includes"):
            kwargs["includes"] = list(c["includes"])
        kwargs["exposed"] = c.get("exposed", True)
        if c.get("reexports"):
            kwargs["reexported_modules"] = {r["module"]: (_dep_label(project_packages, r["from"]) if "from" in r else None, r["original"]) for r in c["reexports"]}
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
    if "package_set" in spec:
        # The rts of a later stage is one of its packages, which each package
        # that needs depends on explicitly.
        kwargs["auto_packages"] = []
    if packages:
        kwargs["packages"] = packages
    if deps:
        kwargs["deps"] = deps
    build_tool_depends = _build_tool_depends(project_packages, c.get("build_tools", []))
    if build_tool_depends:
        kwargs["build_tool_depends"] = build_tool_depends
    if kind != "test-suite":
        kwargs["visibility"] = ["PUBLIC"]
    return _merge(kwargs, c["_common"])

def _merge(base, extra):
    # Lists are appended to (by lists or selects of them), dicts are merged,
    # anything else is replaced.
    out = dict(base)
    for k, v in extra.items():
        cur = out.get(k)
        if type(v) in (type([]), type(select({"DEFAULT": []}))) and type(cur) == type([]):
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

    A component's overrides may also have, for its C/C++/asm and Cmm code:
      cxx: extra attributes of the cxx_library() of its C/C++/asm sources.
      cmm: extra attributes of the cmm_library() of its Cmm sources.
      src_flags: extra flags for compiling particular sources, keyed by path.
      provided_sources: the sources that the package lacks because the
          project generates them (see "provided_sources" in the spec), keyed
          by path: the labels of their sources.
      variants: targets <component>-<name> that are the component as the
          configuration that a transition (a transition target) makes
          builds it, keyed by name (the RTS's ways, say).
    An executable whose main-is is C/C++ is a cxx_binary() (see
    _cxx_binary()), to which only its overrides apply: defaults, transform
    and rules are for the Haskell rules.
    """
    if type(spec) == type([]):
        _cabal_targets_of_sets(spec, defaults, overrides, transform, rules)
        return
    _cabal_targets_of_set(spec, defaults, overrides, transform, rules, extras = True)
    set = spec.get("package_set")
    if _has_set_alias(set):
        for c in spec["components"]:
            _set_alias(c["name"], _set_name(set))

def _cabal_targets_of_sets(specs, defaults, overrides, transform, rules):
    # The targets of a package that is in more than one package set (the
    # project's and a later stage's, say): those of each set's spec, under
    # names with the set in them (<component>.<set>, the project's set being
    # PROJECT_PACKAGE_SET, else "project"), which a later set's are only
    # compatible with configurations
    # of (so that `buck2 build //...` doesn't build them for the project's).
    # Each component's own target is an alias of the one for the set of the
    # configuration: what a target is built by (the stage, its compiler) is
    # its configuration's.
    impls = {}
    for spec in specs:
        set = spec.get("package_set")
        components = []
        for c in spec["components"]:
            base = c["name"]
            c = dict(c, name = base + "." + _set_name(set), _name = base)
            if set != None:
                c["_common"] = {"target_compatible_with": [_set_constraint(set)]}
            if c["kind"] != "library":
                c["exe_name"] = c.get("exe_name", base)
            components.append(c)
            impls.setdefault(base, {})[set] = ":" + c["name"]
        _cabal_targets_of_set(dict(spec, components = components), defaults, overrides, transform, rules, extras = spec == specs[0])
    for base, sets in impls.items():
        arms = {_set_constraint(set): impl for set, impl in sets.items() if set != None}
        arms["DEFAULT"] = sets[None] if None in sets else sets.values()[0]
        native.alias(name = base, actual = select(arms), visibility = ["PUBLIC"])
        for set in sets:
            if _has_set_alias(set):
                _set_alias(base, _set_name(set))

def _set_constraint(set):
    # The constraint of a package set's configurations: the first of its
    # PACKAGE_SET_MODIFIERS (in the project's cabal-buck2.bzl), the others
    # being whatever else its configurations have (a build mode, say).
    modifiers = PACKAGE_SET_MODIFIERS.get(set)
    if not modifiers:
        fail("package set {} has no PACKAGE_SET_MODIFIERS in cabal-buck2.bzl".format(set))
    return modifiers[0]

def _set_name(set):
    # The name of a package set: a later stage's, or the project's own
    # (`None`), which the project may name in its cabal-buck2.bzl.
    return set or PROJECT_PACKAGE_SET or "project"

def _has_set_alias(set):
    # Whether a package set's components have <component>-<set> aliases: a
    # later stage's do, and the project's own, if it names it and has a
    # transition to it.
    return set != None or (PROJECT_PACKAGE_SET != None and PROJECT_PACKAGE_SET in PACKAGE_SET_TRANSITIONS)

def _set_alias(name, set):
    # <component>-<set>: the component built for the set (with the project's
    # PACKAGE_SET_TRANSITIONS), to build by hand.
    if set not in PACKAGE_SET_TRANSITIONS:
        fail("package set {} has no PACKAGE_SET_TRANSITIONS in cabal-buck2.bzl".format(set))
    variant(name = name + "-" + set, actual = ":" + name, transition = PACKAGE_SET_TRANSITIONS[set], visibility = ["PUBLIC"])

def _cabal_targets_of_set(spec, defaults, overrides, transform, rules, extras):
    # The targets of a package's spec for one of its package sets; `extras`
    # says whether to make those of the package as a whole (its data files,
    # say), which are the same for each set.
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
        base = c.get("_name", c["name"])
        c = dict(c, _autogen = _autogen_dir(spec, pkg_dir), _common = c.get("_common", {}))
        component_overrides = _merge(project_overrides.get(base, {}), overrides.get(base, {}))

        # These are for the rules of the component's C/C++/Cmm code.
        c = _with_foreign_sources(
            spec,
            c,
            component_overrides.pop("provided_sources", {}),
            component_overrides.pop("src_flags", {}),
        )
        cxx_overrides = component_overrides.pop("cxx", {})
        cmm_overrides = component_overrides.pop("cmm", {})
        variants = component_overrides.pop("variants", {})
        if _foreign_main(c):
            _cxx_binary(c, _packages(spec), pkg_dir, pkgconfig_seen, _merge(component_overrides, cxx_overrides))
            continue
        kind = c["kind"]
        helpers = _cxx_library(c, _packages(spec), pkg_dir, pkgconfig_seen, cxx_overrides) + _cmm_library(c, spec, cmm_overrides)
        kwargs = _haskell_kwargs(c, spec, helpers)

        # The helpers' own dependencies are linked with the component's.
        kwargs["deps"] = kwargs.get("deps", []) + _pkgconfig_deps(c, pkgconfig_seen)
        kwargs = _merge(kwargs, defaults.get("*", {}))
        kwargs = _merge(kwargs, defaults.get(kind, {}))
        kwargs = _merge(kwargs, component_overrides)
        if transform:
            kwargs = transform(kind, c, kwargs)
            if kwargs == None:
                continue
        _check_provided(spec, c, kwargs.get("srcs", {}))
        rules.get(kind, _DEFAULT_RULES[kind])(**kwargs)
        for way, transition in variants.items():
            variant(name = c["name"] + "-" + way, actual = ":" + c["name"], transition = transition, visibility = ["PUBLIC"], **c["_common"])
    if extras:
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
