# Creates the buck2 rules for one Cabal package from a "build spec": a plain
# dict describing the package's components as Cabal sees them, rather than as
# buck2 rules. `cabal buck2` writes the spec (into the package's
# BUCK.cabal.bzl); this file turns it into haskell_library()/haskell_binary()/
# haskell_test() (and, for components with C/C++ sources, cxx_library() and
# external_pkgconfig_library()) targets, so all of the buck2-specific
# decisions - target labels, flag assembly, which wrapper to use - live here
# and can be customised from a BUCK file (see cabal_targets()).
#
# Spec schema (version 1). Optional keys are omitted when empty.
#
#   {
#     "schema": 1,
#     "package": {"name": str, "version": str, "dir": str},   # dir: relative to the cell root, "." at the root
#     "ghc_options": [str],                   # supplied by the project, not the .cabal file
#     "data": {"dir": str, "files": [str]},   # the package's data-dir and data-files (patterns)
#     "components": [
#       {
#         "kind": "library" | "executable" | "test-suite" | "benchmark",
#         "name": str,                        # also the buck2 target name
#         "srcs": {module: src},              # src: package-relative path | {"autogen": name}
#         "main_is": src,                     # not for libraries; becomes module "Main"
#         "ghc_options": [str], "cpp_options": [str],
#         "language": str, "extensions": [str],
#         "extra_libraries": [str],
#         "deps": [dep],                      # see below
#         "build_tools": [{"exe": str, "dir": str} | {"exe": str, "external": True}],
#         "c_sources": [str], "cxx_sources": [str], "cxx_options": [str],
#         "include_dirs": [str], "pkgconfig": [str],
#         "generated_include_dirs": [str],    # headers that `./configure` generated (project-relative)
#         "test_args": [str],                 # test-suites only
#       },
#     ],
#   }
#
# An "autogen" src names a file generated next to the sources, in the
# package's cabal-buck2/autogen directory. A dep is {"package": str} for an
# external package's main library, {"package": str, "library": str} for a
# named sub-library, and additionally has "dir" (the package's directory) if
# the package is built by this project.

load("//buck2:cxx.bzl", "cxx_library")
load("//buck2:haskell.bzl", "haskell_binary", "haskell_library", "haskell_test")
load("@prelude//third-party:pkgconfig.bzl", "external_pkgconfig_library")

SCHEMA_VERSION = 1

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

def _third_party_label(name):
    return "third-party-haskell//:" + name

def _src(pkg_dir, src):
    if type(src) == type({}):
        autogen_dir = "cabal-buck2/autogen" if pkg_dir == "." else pkg_dir + "/cabal-buck2/autogen"
        return _label(autogen_dir, src["autogen"])
    return src

def _srcs(c, pkg_dir):
    srcs = {}
    if "main_is" in c:
        srcs["Main"] = _src(pkg_dir, c["main_is"])
    for module, src in c.get("srcs", {}).items():
        srcs[module] = _src(pkg_dir, src)
    return srcs

def _include_flags(c, pkg_dir):
    # The package's own include directories, and where a configure script put
    # the headers it generated: GHC needs both for CPP and for the C stubs of
    # foreign imports. They are paths from the root of the project, which is
    # where the compiler runs.
    dirs = [d if pkg_dir == "." or d.startswith("/") else pkg_dir + "/" + d for d in c.get("include_dirs", [])]
    return _nub(["-I" + d for d in dirs + c.get("generated_include_dirs", [])])

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

def _linker_flags(c, project_ghc_options):
    # haskell_binary and haskell_test pass compiler_flags to each module's
    # compile step only, not to the final link, whereas Cabal gives a
    # component's whole ghc-options to every ghc invocation. So anything
    # link-relevant there (-threaded, -rtsopts) has to reach linker_flags
    # too; compile-only flags like -Wall are ignored by ghc when linking.
    own = ["-l" + l for l in c.get("extra_libraries", [])] + list(c.get("ghc_options", []))
    return _nub(own) + project_ghc_options

def _classify_deps(deps):
    # `packages` only ever resolves an external package's main library;
    # everything else (local libraries, external sub-libraries) is a target
    # label in `deps`.
    packages = []
    local = []
    external_sublibs = []
    for d in deps:
        if "dir" in d:
            local.append(_label(d["dir"], d.get("library", d["package"])))
        elif "library" in d:
            external_sublibs.append(_third_party_label(d["library"]))
        else:
            packages.append(d["package"])
    return _nub(packages), _nub(local + external_sublibs)

def _build_tool_depends(build_tools):
    # Each tool becomes a real dependency that is put on PATH for just this
    # rule's compile actions.
    labels = []
    for t in build_tools:
        if "dir" in t:
            labels.append(_label(t["dir"], t["exe"]))
        else:
            labels.append(_third_party_label(t["exe"] + "-exe"))
    return _nub(labels)

def _cxx_library(c, pkg_dir, pkgconfig_seen):
    # Returns the labels the Haskell rule must additionally depend on.
    srcs = list(c.get("c_sources", [])) + list(c.get("cxx_sources", []))
    if not srcs:
        return []
    pkgconfig = _nub(c.get("pkgconfig", []))
    for p in pkgconfig:
        if p not in pkgconfig_seen:
            pkgconfig_seen[p] = True
            external_pkgconfig_library(name = "pkgconfig-" + p, package = p, visibility = ["PUBLIC"])

    # exported_preprocessor_flags is an opaque list of strings to buck2, so
    # (unlike srcs) its include paths have to be made relative to the cell
    # root by hand: cxx actions always run from there.
    include_flags = _include_flags(c, pkg_dir)
    name = c["name"] + "-cxx"
    kwargs = {"name": name, "srcs": srcs, "visibility": ["PUBLIC"]}
    if include_flags:
        kwargs["exported_preprocessor_flags"] = include_flags
    if c.get("cxx_options"):
        kwargs["compiler_flags"] = _nub(c["cxx_options"])

    # GHC's own headers (HsFFI.h): GHC adds them when it compiles C itself,
    # but buck2 doesn't.
    kwargs["deps"] = [_third_party_label("rts")] + [":pkgconfig-" + p for p in pkgconfig]

    # cxx_library() adds -std=c++20 to everything, which a C-only target
    # can't have.
    if not c.get("cxx_sources"):
        kwargs["cxx_std"] = False
    cxx_library(**kwargs)
    return [":" + name]

def _haskell_kwargs(c, spec, cxx_deps):
    pkg_dir = spec["package"]["dir"]
    project_ghc_options = list(spec.get("ghc_options", []))
    kind = c["kind"]
    packages, deps = _classify_deps(c.get("deps", []))
    deps = _nub(deps + cxx_deps)
    kwargs = {
        "name": c["name"],
        "srcs": _srcs(c, pkg_dir),
        "cabal_component": (pkg_dir, c["name"]),
    }
    if kind == "test-suite":
        kwargs["cwd"] = pkg_dir
        if c.get("test_args"):
            kwargs["test_args"] = list(c["test_args"])
    compiler_flags = _haskell_flags(c, pkg_dir, project_ghc_options)
    hsc_flags = ["--cflag=" + f for f in _include_flags(c, pkg_dir)]
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
        exported = _nub(["-l" + l for l in c.get("extra_libraries", [])])
        if exported:
            kwargs["exported_linker_flags"] = exported
    else:
        linker_flags = _linker_flags(c, project_ghc_options)
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

def _merge(base, extra):
    # Lists are appended to, dicts are merged, anything else is replaced.
    out = dict(base)
    for k, v in extra.items():
        cur = out.get(k)
        if type(v) == type([]) and type(cur) == type([]):
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
          component name.
      transform: if given, called as transform(kind, component, attrs) with
          each target's final attributes (the Haskell rule's, not the C/C++
          helper's), and returns the attributes to use instead - or None to
          not create the target at all.
      rules: replacement rule functions to call instead of the defaults,
          keyed by kind.

    Extra attributes are merged into the generated ones: lists are appended
    to, dicts merged, anything else replaced. Later sources win: defaults for
    "*", then for the kind, then the component's override, then transform.
    """
    if spec.get("schema") != SCHEMA_VERSION:
        fail("build spec has schema {}, but buck2/cabal.bzl understands {}: re-run `cabal buck2`, or update buck2/".format(spec.get("schema"), SCHEMA_VERSION))
    pkg_dir = spec["package"]["dir"]
    pkgconfig_seen = {}
    for c in spec["components"]:
        kind = c["kind"]
        cxx_deps = _cxx_library(c, pkg_dir, pkgconfig_seen)
        kwargs = _haskell_kwargs(c, spec, cxx_deps)
        kwargs = _merge(kwargs, defaults.get("*", {}))
        kwargs = _merge(kwargs, defaults.get(kind, {}))
        kwargs = _merge(kwargs, overrides.get(c["name"], {}))
        if transform:
            kwargs = transform(kind, c, kwargs)
            if kwargs == None:
                continue
        rules.get(kind, _DEFAULT_RULES[kind])(**kwargs)
    _data_files(spec, pkg_dir)

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
