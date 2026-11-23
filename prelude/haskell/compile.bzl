# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load(
    "@prelude//cxx:preprocessor.bzl",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
    "HaskellModuleFiles",
)
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo")
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
    "compile_env_script",
    "in_compile_env",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_lib_infos",
    "attr_deps_haskell_link_infos",
    "variant_name",
    "is_haskell_src",
    "output_extensions",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_info.bzl",
    "LinkStyle",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "EMPTY_SHARED_LIBRARY_INFO",
    "SharedLibraryInfo",
    "create_shlib_symlink_tree",
    "merge_shared_libraries",
    "traverse_shared_library_info",
)
load("@prelude//utils:argfile.bzl", "at_argfile")

# The type of the return value of the `_compile()` function.
CompileResultInfo = record(
    objects = field(Artifact),
    hi = field(Artifact),
    stubs = field(Artifact),
    producing_indices = field(bool),
    # These are only set when the target is compiled per-module:
    modules = field(dict[str, HaskellModuleFiles] | None, None),
    closures = field(typing.Any, None),
    # For each module and node name, the dynamic object that GHC's internal
    # interpreter loads when a splice runs that module's code. This is the
    # module's object in a shared compile, or its .dyn_o with -dynamic-too.
    # These objects are also in `objects`, but separating them out lets a
    # compile action that only needs some of them depend on just those.
    #
    # Only per_module produces this field. A --make compile is one action that
    # may need any of the objects, so it depends on the whole `objects`
    # directory instead.
    dynamic_objects = field(dict[str, Artifact] | None, None),
    # The results of the advice checks, by the names of their validations
    # (see Note [Advice] in compile_per_module.bzl).
    advice = field(dict[str, Artifact] | None, None),
)

CompileArgsInfo = record(
    srcs = field(cmd_args),
    args_for_cmd = field(cmd_args),
    args_for_file = field(cmd_args),
    # The compile's variant (see variant_name).
    variant = field(str),
)

PackagesInfo = record(
    exposed_package_args = cmd_args,
    packagedb_args = cmd_args,
    transitive_deps = field(HaskellLibraryInfoTSet),
)

def _package_flag(toolchain: HaskellToolchainInfo) -> str:
    if toolchain.support_expose_package:
        return "-expose-package"
    else:
        return "-package"

# For a given target, this gives the names of the libraries which may be used 
# by the target's Template Haskell splices. 
#
# That is: the dependencies that splice_depends lists; the
# dependencies that are neither local nor prebuilt Haskell libraries; and
# the closures of both. 
#
# A compile action gets the final dbs and the libraries of
# these, as opposed to other dependencies where it only gets interfaces. That means
# that we must wait for these dependencies to be linked.
#
# The closures are included because a
# library's code needs the libraries it was linked against.
def target_splice_libraries(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool) -> dict[str, bool]:
    return splice_libraries(ctx.actions, splice_dep_infos(ctx, link_style, enable_profiling))

# The names of the libraries that a splice may load. `infos` are the
# target's splice dependencies (see splice_dep_infos). A splice may load the
# base dependencies, and the listed ones, or only those of them named in
# `names` if it isn't None. It may also load any library that these depend
# on, directly or indirectly.
def splice_libraries(actions: AnalysisActions, infos, names: [list[str], None] = None) -> dict[str, bool]:
    listed = infos.listed.values() if names == None else [infos.listed[n] for n in names]
    return {l.name: True for l in actions.tset(HaskellLibraryInfoTSet, children = infos.base + listed).traverse()}

# The libraries which may be used by the target's Template Haskell splices
# (see target_splice_libraries), in two groups:
#
# - base: the dependencies that are neither local nor prebuilt Haskell
#   libraries, which splices can always run.
# - listed: the dependencies that splice_depends lists, by name.
def splice_dep_infos(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool):
    deps = attr_deps(ctx) + ctx.attrs.template_deps
    known = {d.label.raw_target(): True for d in deps}
    listed = {}
    for d in ctx.attrs.splice_depends:
        t = d.label.raw_target()
        if t not in known:
            fail("{}: splice_depends names {}, which is not a dependency".format(ctx.label.raw_target(), t))
        listed[t] = True

    base = []
    named = {}
    for d in deps:
        link = d.get(HaskellLinkInfo)
        if link == None:
            continue
        info = link.prof_info[link_style] if enable_profiling else link.info[link_style]
        provider = d.get(HaskellLibraryProvider)
        lib = (provider.prof_lib if enable_profiling else provider.lib)[link_style] if provider != None else None
        if lib == None or (lib.early_db == None and not lib.is_prebuilt):
            base.append(info)
        elif d.label.raw_target() in listed:
            named[lib.name] = info
    return struct(base = base, listed = named)

# Given a compilation action whose splices may load the libraries in `finalDbs` (see
# target_splice_libraries), should it compile against `lib`'s library-less db, or 
# does it need the full db?
#
# If `finalDbs` is None that means that the splices may load every library.
def uses_library_less_db(lib, finalDbs: [dict[str, bool], None]) -> bool:
    return finalDbs != None and lib.early_db != None and lib.name not in finalDbs

# The `final` argument, names the libraries whose final dbs and libraries
# the compile uses (see target_splice_libraries()). 
def get_packages_info(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool, final: [dict[str, bool], None] = None) -> PackagesInfo:
    # Collect library dependencies. Note that these don't need to be in a
    # particular order.
    libs = dependency_libs(ctx, link_style, enable_profiling)

    exposed_package_args = cmd_args()

    packagedb_args = cmd_args()
    packagedb_set = {}

    for lib in libs.traverse():
        if uses_library_less_db(lib, final):
            # A library compiled per-module has no library-less db of its
            # own. Its early db names the directory of its modules'
            # interfaces, which are inputs one by one.
            packagedb_set[lib.early_db] = None
            if lib.modules != None:
                interfaces = [f for m in lib.modules.values() for f in [m.hi, m.dyn_hi] if f != None]
            else:
                interfaces = lib.import_dirs.values()
            hidden_args = cmd_args(hidden = [interfaces, lib.stub_dirs])
        else:
            packagedb_set[lib.db] = None
            hidden_args = cmd_args(
                hidden = [
                    lib.import_dirs.values(),
                    lib.stub_dirs,
                    # libs of dependencies might be needed at compile time if
                    # we're using Template Haskell:
                    lib.libs,
                ]
            )

        exposed_package_args.add(hidden_args)

        packagedb_args.add(hidden_args)

    # These we need to add for all the packages/dependencies, i.e.
    # direct and transitive (e.g. `fbcode-common-hs-util-hs-array`)
    packagedb_args.add([cmd_args("-package-db", x) for x in packagedb_set])

    exposed_package_args.add(get_exposed_package_args(ctx, link_style, specify_pkg_version, enable_profiling))

    return PackagesInfo(
        exposed_package_args = exposed_package_args,
        packagedb_args = packagedb_args,
        transitive_deps = libs,
    )

def dependency_libs(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool) -> HaskellLibraryInfoTSet:
    direct_deps_link_info = attr_deps_haskell_link_infos(ctx)
    return ctx.actions.tset(
        HaskellLibraryInfoTSet,
        children = [lib.prof_info[link_style] if enable_profiling else lib.info[link_style] for lib in direct_deps_link_info],
    )

def get_exposed_package_args(ctx: AnalysisContext, link_style: LinkStyle, specify_pkg_version: bool, enable_profiling: bool) -> cmd_args:
    package_flag = _package_flag(ctx.attrs._haskell_toolchain[HaskellToolchainInfo])
    exposed_package_args = cmd_args()
    haskell_direct_deps_lib_infos = attr_deps_haskell_lib_infos(
        ctx,
        link_style,
        enable_profiling,
    )

    # Expose only the packages we depend on directly
    for lib in haskell_direct_deps_lib_infos:
        # The rts has no modules to import, and is a dependency to be linked
        # with. GHC warns about exposing a package that is not used
        # (-Wunused-packages), which is an error in some projects.
        if lib.name == "rts":
            continue
        if lib.id:
            # Resolve by unit id rather than by name: unambiguous even when
            # another version of the same package is visible in another
            # package db (e.g. GHC's global db vs. a cabal-store rebuild of a
            # boot package such as time or directory, or a global Cabal
            # vs. one built from source here).
            exposed_package_args.add("-package-id", lib.id)
            continue

        pkg_name = lib.name
        if specify_pkg_version:
            pkg_name += "-{}".format(lib.version)

        exposed_package_args.add(package_flag, pkg_name)

    return exposed_package_args

# Whether the toolchain's GHC is at least the given version.
def _ghc_at_least(haskell_toolchain: HaskellToolchainInfo, version: (int, int)) -> bool:
    major_minor = [int(x) for x in haskell_toolchain.ghc_version.split(".")[:2]]
    return (major_minor[0], major_minor[1]) >= version

def ghc_flags(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname = None, dynamic_too: bool = False) -> (cmd_args, cmd_args):
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    compile_cmd = cmd_args()
    compile_cmd.add(haskell_toolchain.compiler_flags)

    # Some rules pass in RTS (e.g. `+RTS ... -RTS`) options for GHC, which can't
    # be parsed when inside an argsfile.
    compile_cmd.add(ctx.attrs.compiler_flags)

    compile_args = cmd_args()
    compile_args.add("-no-link", "-i")
    compile_args.add("-package-env=-")

    # Without this, GHC's own implicit global package db (always loaded,
    # independent of anything passed via -package-db below) leaks in
    # alongside the deps get_packages_info() computes - normally harmless
    # (nothing there collides with an ordinary project's own package
    # names), but GHC ships boot libraries under names a project can
    # itself build from source under the same name (e.g. `Cabal`,
    # `Cabal-syntax`) - then both the boot copy (auto-exposed globally)
    # and this target's own explicitly `-package-id`-exposed one export
    # the same module name, and GHC fails with "Ambiguous module name"
    # for any of that module's importers, even though the -package-id
    # given to *this* compile is perfectly unambiguous on its own.
    # get_packages_info() already computes exactly the exposure set this
    # compile needs (direct deps + base, see its own comment) - with
    # `-hide-all-packages` GHC uses only that, ignoring the global db's
    # own default exposure entirely.
    compile_args.add("-hide-all-packages")

    if enable_profiling:
        compile_args.add("-prof")

    if link_style == LinkStyle("shared"):
        compile_args.add("-dynamic", "-fPIC")
    elif link_style == LinkStyle("static_pic"):
        compile_args.add("-fPIC", "-fexternal-dynamic-refs")

    if dynamic_too:
        # Produces .dyn_o/.dyn_hi alongside this compile's ordinary .o/.hi,
        # in the same -odir/-hidir (the only way to get both from GHC in
        # --make mode - there's no flag to write them to different
        # directories). GHC guarantees these are consistent with the
        # primary .o/.hi, since they come from the same compile pass and
        # share its frontend work - unlike reusing an *independently*
        # compiled "shared" variant's interfaces would be, which carries no
        # such guarantee. See haskell.bzl's use of this (building a
        # library's static archive and shared library from a single
        # -dynamic-too compile instead of two independent ones) for why
        # this matters enough to ask for explicitly rather than just
        # tolerating two compiles.
        compile_args.add("-dynamic-too")

    # We want maximum determinism, so we turn this on when it's available.
    if _ghc_at_least(haskell_toolchain, (9, 12)):
        compile_args.add("-fobject-determinism")

    osuf, hisuf = output_extensions(link_style, enable_profiling)
    compile_args.add("-osuf", osuf, "-hisuf", hisuf)

    if getattr(ctx.attrs, "main", None) != None:
        compile_args.add(["-main-is", ctx.attrs.main])

    # Add args from preprocess-able inputs: for the C preprocessor of Haskell
    # code, and for the C that GHC compiles itself. For example:
    #   foreign import capi "Header.h ..." ...
    # generates a C file that includes Header.h, so we need to pass the
    # preprocessor options via -optc too.
    inherited_pre = cxx_inherited_preprocessor_infos(attr_deps(ctx))
    pre = cxx_merge_cpreprocessors(ctx.actions, [], inherited_pre)
    pre_args = pre.set.project_as_args("args")
    compile_args.add(cmd_args(pre_args, format = "-optP={}"))
    compile_args.add(cmd_args(pre_args, format = "-optc={}"))

    if pkgname:
        compile_args.add(["-this-unit-id", pkgname])

    return compile_cmd, compile_args

def get_producing_indices(ctx: AnalysisContext) -> bool:
    toolchain_flags = ctx.attrs._haskell_toolchain[HaskellToolchainInfo].compiler_flags or []
    return "-fwrite-ide-info" in toolchain_flags + ctx.attrs.compiler_flags

def compile_args(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname = None, dynamic_too: bool = False, final: [dict[str, bool], None] = None) -> CompileArgsInfo:
    compile_cmd, compile_args = ghc_flags(ctx, link_style, enable_profiling, pkgname, dynamic_too)

    # Add -package-db and -package/-expose-package flags for each Haskell
    # library dependency.
    packages_info = get_packages_info(
        ctx,
        link_style,
        specify_pkg_version = False,
        enable_profiling = enable_profiling,
        final = final,
    )

    compile_args.add(packages_info.exposed_package_args)
    compile_args.add(packages_info.packagedb_args)

    arg_srcs = []
    hidden_srcs = []
    for _, src in srcs_to_pairs(ctx.attrs.srcs):
        # hs-boot files aren't expected to be an argument to compiler but does need
        # to be included in the directory of the associated src file
        if is_haskell_src(src):
            arg_srcs.append(src)
        else:
            hidden_srcs.append(src)
    srcs = cmd_args(
        arg_srcs,
        hidden = hidden_srcs,
    )

    return CompileArgsInfo(
        srcs = srcs,
        args_for_cmd = compile_cmd,
        args_for_file = compile_args,
        variant = variant_name(link_style, enable_profiling),
    )

# Shell steps that run before `ghc --make`, in the same shell as the
# toolchain's environment (see in_env). Each step takes its arguments from
# the front of the positional parameters and shifts them off, so that what
# is left at the end is the command to run.

# GHC creates the -stubdir only when it compiles a module. The action keeps
# the outputs of its previous run (see no_outputs_cleanup in compile), so if
# GHC finds every module up to date, it compiles nothing. If the stub
# directory is missing in that case, for example because Buck removed it,
# the action would fail to produce one of its outputs. This step makes the
# directory that its argument names.
_MAKE_STUBDIR = 'mkdir -p "$1"; shift; '

# Copies the .dyn_o objects of another compile of the same sources into this
# compile's -odir. The arguments are the -odir and the other compile's
# objects directory.
_COPY_DYN_OBJECTS = """\
odir=$1; src=$2; shift 2
(cd "$src" && find . -name '*.dyn_o') | while read -r f; do
  mkdir -p "$odir/${f%/*}"
  cp -f "$src/$f" "$odir/$f"
done
"""

# The environment for the rule's `data_dirs`: each variable name mapped to the
# directory it should point at. A package's generated Paths_<pkg> module reads
# its `<pkg>_datadir` variable to find the package's data-files, so setting
# these lets `getDataFileName` work both at compile time (in a Template Haskell
# splice, or a build tool run by the compile) and when a binary runs.
def data_dirs_env(ctx: AnalysisContext) -> dict[str, Artifact]:
    return {name: dep[DefaultInfo].default_outputs[0] for name, dep in ctx.attrs.data_dirs.items()}

# The data dirs that the Paths_<pkg> modules in `modules` use. Paths_foo
# reads foo_datadir.
def paths_data_dirs(modules, data_dirs: dict[str, Artifact]) -> dict[str, Artifact]:
    vars = [m.removeprefix("Paths_") + "_datadir" for m in modules if m.startswith("Paths_")]
    return {var: data_dirs[var] for var in vars if var in data_dirs}

# The data dirs that the rule's own Paths_<pkg> modules use.
def own_data_dirs(ctx: AnalysisContext) -> dict[str, Artifact]:
    return paths_data_dirs([m for m, _ in srcs_to_pairs(ctx.attrs.srcs)], data_dirs_env(ctx))

# The data dirs to set for a compilation action.
def compile_data_dirs(data_dirs: dict[str, Artifact], lib_dirs: dict[str, Artifact], own_modules: list[str], runs_tools: bool) -> dict[str, Artifact]:
    # A tool might read data files of its own.
    if runs_tools:
        return data_dirs
    return lib_dirs | paths_data_dirs(own_modules, data_dirs)

# The data dirs to set for a compilaion action that builds all the target's modules, 
# assuming that the splices can run code from the libraries in `final` (see
# target_splice_libraries).
def splice_data_dirs(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, final: dict[str, bool]) -> dict[str, Artifact]:
    libs = [lib for lib in dependency_libs(ctx, link_style, enable_profiling).traverse() if lib.name in final]
    return compile_data_dirs(
        data_dirs_env(ctx),
        {var: d for lib in libs for var, d in lib.data_dirs.items()},
        [m for m, _ in srcs_to_pairs(ctx.attrs.srcs)],
        len(build_tools(ctx)) > 0,
    )

# The target's build tools (build_tool_depends), by the name of each tool's
# executable, which is the name that a program looks it up by on PATH.
def build_tools(ctx: AnalysisContext) -> dict[str, Artifact]:
    return {
        dep[DefaultInfo].default_outputs[0].basename: dep[DefaultInfo].default_outputs[0]
        for dep in ctx.attrs.build_tool_depends
    }

# The environment to run GHC in: the toolchain's compile_env variables, and
# the target's build tools added to PATH.
def ghc_env(ctx: AnalysisContext, build_tool_dir: str):
    return tools_env(ctx.actions, ctx.attrs._haskell_toolchain[HaskellToolchainInfo].compile_env, build_tools(ctx), build_tool_dir)

# The environment to run GHC in: the `compile_env` variables, and the build
# tools in `tools` (as build_tools gives them) added to PATH. The tools are
# linked into a directory at `build_tool_dir`.
def tools_env(actions: AnalysisActions, compile_env: dict[str, str], tools: dict[str, Artifact], build_tool_dir: str):
    script = compile_env_script(compile_env) if compile_env else ""
    args = []

    # We smuggle the build tools in via an extra argument and make the shell
    # command add them to the PATH.
    if tools:
        script += 'export PATH="$PATH:$1"; shift; '
        args.append(actions.symlinked_dir(build_tool_dir, tools, has_content_based_path = False))
    return struct(script = script, args = args)

def in_env(env, cmd: cmd_args) -> cmd_args:
    return in_compile_env(env.script, env.args, cmd)

# Whether the target has modules for GHC to compile (e.g. not a target whose
# code is all C).
def has_modules(ctx: AnalysisContext) -> bool:
    return any([is_haskell_src(src) for _, src in srcs_to_pairs(ctx.attrs.srcs)])

# Which objects GHC loads when a splice runs code from the target's own
# modules. GHC decides this, and the compile has to put those objects where
# GHC will look for them:
#
# - "own": the objects the compile makes itself. An external interpreter
#   loads these, because it runs in the same way as the compile, and so
#   does a GHC that isn't dynamically linked.
# - "dynamic": a dynamically linked GHC's internal interpreter loads
#   dynamic objects. A shared compile makes these anyway, and a static one
#   makes them with -dynamic-too.
# - "from_non_profiled": like "dynamic", but a profiled compile doesn't
#   make dynamic objects, so it uses the ones from the non-profiled compile.
def splice_objects_kind(ctx: AnalysisContext, enable_profiling: bool) -> str:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    flags = (haskell_toolchain.compiler_flags or []) + ctx.attrs.compiler_flags
    if "-fexternal-interpreter" in flags or not haskell_toolchain.dynamic_ghc:
        return "own"
    return "from_non_profiled" if enable_profiling else "dynamic"

# A tree of the shared libraries in `sets`, named by soname, or None if there
# are none. Each library appears once, however many of the sets have it. A
# splice finds them from `LD_LIBRARY_PATH`.
def native_libs_tree(ctx: AnalysisContext, name: str, sets: list[SharedLibraryInfo]) -> [Artifact, None]:
    sos = traverse_shared_library_info(merge_shared_libraries(ctx.actions, deps = sets), transformation_provider = None)
    if not sos:
        return None
    return create_shlib_symlink_tree(actions = ctx.actions, out = name, shared_libs = sos)

# Compile all the context's sources with `ghc --make`.
#
# For a profiled compile, `dynamic_from` is the non-profiled compile of the
# same sources. When a splice runs code from this library's own modules,
# GHC's internal interpreter may want a module's .dyn_o (see
# splice_objects_kind), and it looks for it next to the profiled object, in
# this compile's -odir. With Cabal both compiles share a build directory, so
# it's there. Here each compile has its own -odir, so we copy the .dyn_o
# files in first.
def compile(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, pkgname: str | None = None, native_libs: SharedLibraryInfo = EMPTY_SHARED_LIBRARY_INFO, dynamic_too: bool = False, dynamic_from: [CompileResultInfo, None] = None) -> CompileResultInfo:
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    compile_cmd = cmd_args(haskell_toolchain.compiler)

    splices = target_splice_env(ctx, link_style, enable_profiling, native_libs)
    args = compile_args(ctx, link_style, enable_profiling, pkgname, dynamic_too = dynamic_too, final = splices.final)
    result = CompileResultInfo(
        objects = ctx.actions.declare_output("objects-" + args.variant, dir = True, has_content_based_path = False),
        hi = ctx.actions.declare_output("hi-" + args.variant, dir = True, has_content_based_path = False),
        stubs = ctx.actions.declare_output("stubs-" + args.variant, dir = True, has_content_based_path = False),
        producing_indices = get_producing_indices(ctx),
    )

    if not has_modules(ctx):
        ctx.actions.run(
            cmd_args("mkdir", "-p", result.objects.as_output(), result.hi.as_output(), result.stubs.as_output()),
            category = "haskell_compile",
            identifier = args.variant,
        )
        return result

    compile_cmd.add(args.args_for_cmd)
    outputs = cmd_args(
        "-odir",
        result.objects.as_output(),
        "-hidir",
        result.hi.as_output(),
        "-hiedir",
        result.hi.as_output(),
        "-stubdir",
        result.stubs.as_output(),
    )
    compile_cmd.add(ghc_file_args(ctx, "args-" + args.variant + ".haskell_compile_argsfile", cmd_args(args.args_for_file, outputs), args.srcs))

    steps = _MAKE_STUBDIR
    step_args = [result.stubs.as_output()]
    if dynamic_from != None and splice_objects_kind(ctx, enable_profiling) == "from_non_profiled":
        steps += _COPY_DYN_OBJECTS
        step_args += [result.objects.as_output(), dynamic_from.objects]

    # This keeps the previous run's -odir/-hidir (see run_ghc), so that `ghc
    # --make` can do its own recompilation checking and only rebuild the
    # modules whose sources or imported interfaces changed.
    #
    # GHC >= 9.4 tracks file changes with hashes rather than
    # timestamps, so this is safe even though Buck doesn't preserve
    # timestamps on artifacts.
    run_ghc(ctx, compile_cmd, splices, args.variant, args.variant, steps, step_args, "haskell_compile")

    return result

# The environment for splices in a compilation action. That is: the libraries 
# in `final` (see target_splice_libraries), the native libraries of those and of the target
# (`native_libs`), and their data dirs (see splice_data_dirs).
def target_splice_env(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool, native_libs: SharedLibraryInfo):
    final = target_splice_libraries(ctx, link_style, enable_profiling)
    return struct(
        final = final,
        native_libs = [native_libs] + [lib.native_libs for lib in dependency_libs(ctx, link_style, enable_profiling).traverse() if lib.name in final],
        data_dirs = splice_data_dirs(ctx, link_style, enable_profiling, final),
    )

# Run `cmd`, a GHC program, with its splice environment (`splices`, from target_splice_env) 
# and the target's build tools (see ghc_env). First the shell runs `steps`, shell
# commands which take `step_args` from the front of the positional parameters and
# shift them off. `variant` is the action's identifier (see variant_name), and
# `name` names the directories it makes, unique among the target's run_ghc
# actions.
#
# The action does not clean up its outputs, as we sometimes want GHC to reuse them; set `-fforce-recomp` 
# if you don't want that. 
def run_ghc(ctx: AnalysisContext, cmd: cmd_args, splices, variant: str, name: str, steps: str, step_args: list, category: str):
    env = ghc_env(ctx, "build-tool-depends-" + name)
    native_dir = native_libs_tree(ctx, "native-libs-" + name, splices.native_libs)
    ctx.actions.run(
        in_env(struct(script = env.script + "set -eu; " + steps, args = env.args + step_args), cmd_args(cmd, hidden = [native_dir] if native_dir != None else [])),
        category = category,
        identifier = variant,
        no_outputs_cleanup = True,
        env = splices.data_dirs | ({"LD_LIBRARY_PATH": cmd_args(native_dir)} if native_dir != None else {}),
    )

# GHC's arguments `args` and the sources `srcs`, in a file named `name` if
# the toolchain uses one (use_argsfile).
def ghc_file_args(ctx: AnalysisContext, name: str, args: cmd_args, srcs: cmd_args) -> cmd_args:
    if ctx.attrs._haskell_toolchain[HaskellToolchainInfo].use_argsfile:
        return at_argfile(actions = ctx.actions, name = name, args = [args, srcs], allow_args = True)
    return cmd_args(args, srcs)
