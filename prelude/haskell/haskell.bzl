# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

# Implementation of the Haskell build rules.

load("@prelude//:paths.bzl", "paths")
load("@prelude//cxx:archive.bzl", "make_archive")
load(
    "@prelude//cxx:cxx.bzl",
    "get_auto_link_group_specs",
)
load(
    "@prelude//cxx:cxx_context.bzl",
    "get_cxx_toolchain_info",
)
load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "CxxToolchainInfo",
    "LinkerType",
    "PicBehavior",
)
load("@prelude//cxx:groups.bzl", "get_dedupped_roots_from_groups")
load(
    "@prelude//cxx:link_groups.bzl",
    "BuildLinkGroupsContext",
    "LinkGroupContext",
    "collect_linkables",
    "create_link_groups",
    "find_relevant_roots",
    "get_filtered_labels_to_links_map",
    "get_filtered_links",
    "get_link_group_info",
    "get_link_group_preferred_linkage",
    "get_public_link_group_nodes",
    "get_transitive_deps_matching_labels",
    "is_link_group_shlib",
)
load(
    "@prelude//cxx:linker.bzl",
    "LINKERS",
    "get_rpath_origin",
    "get_shared_library_flags",
)
load(
    "@prelude//cxx:preprocessor.bzl",
    "CPreprocessor",
    "CPreprocessorArgs",
    "cxx_inherited_preprocessor_infos",
    "cxx_merge_cpreprocessors",
)
load(
    "@prelude//haskell:compile.bzl",
    "CompileResultInfo",
    "compile",
    "data_dirs_env",
    "own_data_dirs",
    "dependency_libs",
)
load(
    "@prelude//haskell:compile_per_module.bzl",
    "advice_validations",
    "compile_per_module",
    "compiles_per_module",
)
load(
    "@prelude//haskell:haskell_haddock.bzl",
    "haskell_haddock_lib",
)
load(
    "@prelude//haskell:library_info.bzl",
    "HaskellLibraryInfo",
    "HaskellLibraryInfoTSet",
    "HaskellLibraryProvider",
    "HaskellModuleFiles",
)
load(
    "@prelude//haskell:link_info.bzl",
    "HaskellLinkInfo",
    "HaskellProfLinkInfo",
    "attr_link_style",
    "cxx_toolchain_link_style",
)
load(
    "@prelude//haskell:toolchain.bzl",
    "HaskellToolchainInfo",
)
load(
    "@prelude//haskell:util.bzl",
    "attr_deps",
    "attr_deps_haskell_link_infos_sans_template_deps",
    "attr_deps_merged_link_infos",
    "attr_deps_shared_library_infos",
    "variant_name",
    "haskell_library_name",
    "haskell_library_unit_id",
    "is_haskell_src",
    "output_extensions",
    "src_to_module_name",
    "module_name_to_file",
    "srcs_to_pairs",
)
load(
    "@prelude//linking:link_groups.bzl",
    "gather_link_group_libs",
    "merge_link_group_lib_info",
)
load(
    "@prelude//linking:link_info.bzl",
    "Archive",
    "ArchiveContentsType",
    "ArchiveLinkable",
    "LibOutputStyle",
    "LinkArgs",
    "LinkInfo",
    "LinkInfos",
    "LinkOrdering",
    "LinkStyle",
    "LinkedObject",
    "MergedLinkInfo",
    "SharedLibLinkable",
    "create_merged_link_info",
    "default_output_style_for_link_strategy",
    "get_lib_output_style",
    "get_link_args_for_strategy",
    "get_output_styles_for_linkage",
    "get_own_link_infos",
    "legacy_output_style_to_link_style",
    "process_link_strategy_for_pic_behavior",
    "process_output_style_for_pic_behavior",
    "to_link_strategy",
    "unpack_link_args",
)
load(
    "@prelude//linking:linkable_graph.bzl",
    "LinkableGraph",
    "create_linkable_graph",
    "create_linkable_graph_node",
    "create_linkable_node",
    "reduce_linkable_graph",
)
load(
    "@prelude//linking:linkables.bzl",
    "linkables",
)
load(
    "@prelude//linking:shared_libraries.bzl",
    "SharedLibraryInfo",
    "create_shared_libraries",
    "create_shlib_symlink_tree",
    "merge_shared_libraries",
    "traverse_shared_library_info",
)
load("@prelude//linking:types.bzl", "Linkage")
load(
    "@prelude//python:python.bzl",
    "PythonLibraryInfo",
)
load("@prelude//utils:argfile.bzl", "at_argfile")
load("@prelude//utils:utils.bzl", "filter_and_map_idx", "flatten")

HaskellIndexingTSet = transitive_set()

# A list of hie dirs
HaskellIndexInfo = provider(
    fields = {
        "info": provider_field(typing.Any, default = None),  # dict[LinkStyle, HaskellIndexingTset]
    },
)

# This conversion is non-standard, see TODO about link style below
def _to_lib_output_style(link_style: LinkStyle) -> LibOutputStyle:
    return default_output_style_for_link_strategy(to_link_strategy(link_style))

def _attr_preferred_linkage(ctx: AnalysisContext) -> Linkage:
    preferred_linkage = ctx.attrs.preferred_linkage

    # force_static is deprecated, but it has precedence over preferred_linkage
    if getattr(ctx.attrs, "force_static", False):
        preferred_linkage = "static"

    return Linkage(preferred_linkage)

# --

def _get_haskell_prebuilt_libs(ctx, link_style: LinkStyle, enable_profiling: bool) -> list[Artifact]:
    if link_style == LinkStyle("shared"):
        if enable_profiling:
            # Profiling doesn't support shared libraries
            return []

        return ctx.attrs.shared_libs.values()
    elif link_style == LinkStyle("static"):
        if enable_profiling:
            return ctx.attrs.profiled_static_libs
        return ctx.attrs.static_libs
    elif link_style == LinkStyle("static_pic"):
        if enable_profiling:
            return ctx.attrs.pic_profiled_static_libs
        return ctx.attrs.pic_static_libs
    else:
        fail("Unexpected LinkStyle: " + link_style.value)

def haskell_prebuilt_library_impl(ctx: AnalysisContext) -> list[Provider]:
    # MergedLinkInfo for both with and without profiling
    native_infos = []
    prof_native_infos = []

    haskell_infos = []
    shared_library_infos = []
    for dep in ctx.attrs.deps:
        used = False
        if HaskellLinkInfo in dep:
            used = True
            haskell_infos.append(dep[HaskellLinkInfo])
        li = dep.get(MergedLinkInfo)
        if li != None:
            used = True
            native_infos.append(li)
            if HaskellLinkInfo not in dep:
                prof_native_infos.append(li)
        if HaskellProfLinkInfo in dep:
            prof_native_infos.append(dep[HaskellProfLinkInfo].prof_infos)
        if SharedLibraryInfo in dep:
            used = True
            shared_library_infos.append(dep[SharedLibraryInfo])
        if PythonLibraryInfo in dep:
            used = True
        if not used:
            fail("Unexpected link info encountered")

    hlibinfos = {}
    prof_hlibinfos = {}
    hlinkinfos = {}
    prof_hlinkinfos = {}
    link_infos = {}
    prof_link_infos = {}
    for link_style in LinkStyle:
        libs = _get_haskell_prebuilt_libs(ctx, link_style, False)
        prof_libs = _get_haskell_prebuilt_libs(ctx, link_style, True)

        hlibinfo = HaskellLibraryInfo(
            name = ctx.attrs.name,
            db = ctx.attrs.db,
            import_dirs = [],
            stub_dirs = [],
            id = ctx.attrs.id,
            libs = libs,
            version = ctx.attrs.version,
            is_prebuilt = True,
            profiling_enabled = False,
        )
        prof_hlibinfo = HaskellLibraryInfo(
            name = ctx.attrs.name,
            db = ctx.attrs.db,
            import_dirs = [],
            stub_dirs = [],
            id = ctx.attrs.id,
            libs = prof_libs,
            version = ctx.attrs.version,
            is_prebuilt = True,
            profiling_enabled = True,
        )

        def archive_linkable(lib):
            return ArchiveLinkable(
                archive = Archive(artifact = lib),
                linker_type = LinkerType("gnu"),
            )

        def shared_linkable(lib):
            return SharedLibLinkable(
                lib = lib,
            )

        linkables = [(shared_linkable if link_style == LinkStyle("shared") else archive_linkable)(lib) for lib in libs]
        prof_linkables = [(shared_linkable if link_style == LinkStyle("shared") else archive_linkable)(lib) for lib in prof_libs]

        hlibinfos[link_style] = hlibinfo
        hlinkinfos[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = hlibinfo,
            children = [lib.info[link_style] for lib in haskell_infos],
        )
        prof_hlibinfos[link_style] = prof_hlibinfo
        prof_hlinkinfos[link_style] = ctx.actions.tset(
            HaskellLibraryInfoTSet,
            value = prof_hlibinfo,
            children = [lib.prof_info[link_style] for lib in haskell_infos],
        )
        link_infos[link_style] = LinkInfos(
            default = LinkInfo(
                pre_flags = ctx.attrs.exported_linker_flags,
                post_flags = ctx.attrs.exported_post_linker_flags,
                linkables = linkables,
            ),
        )
        prof_link_infos[link_style] = LinkInfos(
            default = LinkInfo(
                pre_flags = ctx.attrs.exported_linker_flags,
                post_flags = ctx.attrs.exported_post_linker_flags,
                linkables = prof_linkables,
            ),
        )

    haskell_link_infos = HaskellLinkInfo(
        info = hlinkinfos,
        prof_info = prof_hlinkinfos,
    )
    haskell_lib_provider = HaskellLibraryProvider(
        lib = hlibinfos,
        prof_lib = prof_hlibinfos,
    )

    # The link info that will be used when this library is a dependency of a non-Haskell
    # target (e.g. a cxx_library()). We need to pick the profiling libs if we're in
    # profiling mode.
    default_link_infos = prof_link_infos if ctx.attrs.enable_profiling else link_infos
    default_native_infos = prof_native_infos if ctx.attrs.enable_profiling else native_infos
    merged_link_info = create_merged_link_info(
        ctx,
        # We don't have access to a CxxToolchain here (yet).
        # Give that it's already built, this doesn't mean much, use a sane default.
        pic_behavior = PicBehavior("supported"),
        link_infos = {_to_lib_output_style(s): v for s, v in default_link_infos.items()},
        exported_deps = default_native_infos,
    )

    prof_merged_link_info = create_merged_link_info(
        ctx,
        # We don't have access to a CxxToolchain here (yet).
        # Give that it's already built, this doesn't mean much, use a sane default.
        pic_behavior = PicBehavior("supported"),
        link_infos = {_to_lib_output_style(s): v for s, v in prof_link_infos.items()},
        exported_deps = prof_native_infos,
    )

    solibs = {}
    for soname, lib in ctx.attrs.shared_libs.items():
        solibs[soname] = LinkedObject(output = lib, unstripped_output = lib)
    shared_libs = create_shared_libraries(ctx, solibs)

    # The executables that depend on this library have its runtime_shared_libs
    # in their symlink trees of shared libraries, along with its shared_libs.
    # The linkable graph only has the shared_libs, so nothing is linked
    # against the runtime_shared_libs.
    for soname, lib in ctx.attrs.runtime_shared_libs.items():
        solibs[soname] = LinkedObject(output = lib, unstripped_output = lib)
    runtime_shared_libs = create_shared_libraries(ctx, solibs)

    linkable_graph = create_linkable_graph(
        ctx,
        node = create_linkable_graph_node(
            ctx,
            linkable_node = create_linkable_node(
                ctx = ctx,
                exported_deps = ctx.attrs.deps,
                link_infos = {_to_lib_output_style(s): v for s, v in link_infos.items()},
                shared_libs = shared_libs,
                default_soname = None,
            ),
        ),
        deps = ctx.attrs.deps,
    )

    inherited_pp_info = cxx_inherited_preprocessor_infos(ctx.attrs.deps)
    own_pp_info = CPreprocessor(
        args = CPreprocessorArgs(args = flatten([["-isystem", d] for d in ctx.attrs.cxx_header_dirs])),
    )

    return [
        DefaultInfo(),
        haskell_lib_provider,
        cxx_merge_cpreprocessors(ctx.actions, [own_pp_info], inherited_pp_info),
        merge_shared_libraries(
            ctx.actions,
            runtime_shared_libs,
            shared_library_infos,
        ),
        merge_link_group_lib_info(deps = ctx.attrs.deps),
        haskell_link_infos,
        merged_link_info,
        HaskellProfLinkInfo(
            prof_infos = prof_merged_link_info,
        ),
        linkable_graph,
    ]

def _srcs_to_objfiles(ctx: AnalysisContext, odir: Artifact, osuf: str) -> list[Artifact]:
    objfiles = []
    for modl, src in srcs_to_pairs(ctx.attrs.srcs):
        # Don't link boot sources, as they're only meant to be used for compiling.
        if is_haskell_src(src):
            objfiles.append(odir.project(module_name_to_file(modl, osuf)))
    return objfiles

# The packager is the rest of the arguments: it may be a command with
# arguments of its own.
_REGISTER_PACKAGE = """\
set -eu
DB=$1
PKGCONF=$2
ALWAYS_USE_CACHE=$3
FORCE=$4
shift 4
"$@" init "$DB"
"$@" register --package-conf "$DB" --no-expand-pkgroot $ALWAYS_USE_CACHE $FORCE "$PKGCONF"
"""

# Create a package
#
# The way we use packages is a bit strange. We're not using them
# at link time at all: all the linking info is in the
# HaskellLibraryInfo and we construct linker command lines
# manually. Packages are used for:
#
#  - finding .hi files at compile time
#
#  - symbol namespacing (so that modules with the same name in
#    different libraries don't clash).
#
#  - controlling module visibility: only dependencies that are
#    directly declared as dependencies may be used
#
#  - Template Haskell: the compiler needs to load libraries itself
#    at compile time, so it uses the package specs to find out
#    which libraries and where.
def _make_package(
    ctx: AnalysisContext,
    link_style: LinkStyle,
    pkgname: str,
    libname: str,
    hlis: list[HaskellLibraryInfo],
    hi: list[Artifact],
    lib: list[Artifact],
    # Libraries whose directories go in dynamic-library-dirs, where a
    # dynamically linked GHC looks for the package's library. Like `lib`, it
    # is ignored for an early or library-less package.
    dynamic_lib: list[Artifact],
    enable_profiling: bool,
    # The directory, relative to the target's outputs, that the interfaces are
    # written to (see import_dir on CompileResultInfo). 
    import_dir: str,
    # Every library this one depends on, when it re-exports modules: the
    # package the module is defined in may be one that the dependency re-exports it
    # from, and ghc-pkg has to find it.
    all_hlis: list[HaskellLibraryInfo] = [],
    # See HaskellLibraryInfo.early_db
    early: bool = False,
    library_less: bool = False,
) -> Artifact:
    variant = variant_name(link_style, enable_profiling)
    db_variant = ("early-" if early else "nolib-" if library_less else "") + variant

    # Don't expose boot sources, as they're only meant to be used for compiling.
    modules = [x for x, src in srcs_to_pairs(ctx.attrs.srcs) if is_haskell_src(src)]

    db = ctx.actions.declare_output("db-" + db_variant, has_content_based_path = False)

    # The package names the directories of the interfaces and libraries it
    # was given, wherever they are, by their paths relative to ${pkgroot}: the
    # directory that the package db is in.
    def pkgroot_path(artifact: Artifact, parent: int = 0) -> cmd_args:
        return cmd_args(artifact, parent = parent, relative_to = (db, 1), format = '"${pkgroot}/{}"')

    # An early db mustn't depend on the target's interfaces. It is registered
    # before any of the target's modules compile, so that a dependent's module
    # can compile as soon as the interfaces it imports exist. So it refers to 
    # the directory that the interfaces are written to by its path (`import_dir`),
    # rather than by an artifact.
    #
    # It also has to use only that one directory, because GHC's dependency
    # analysis accepts interfaces that don't exist yet _only_ when a package has
    # a single import directory.
    #
    # Every other db names its interfaces using the `hi` artifacts, which is
    # a lot simpler. 
    if early:
        import_dirs = cmd_args('"${pkgroot}/' + import_dir + '"')
    else:
        import_dirs = cmd_args([pkgroot_path(d) for d in hi], delimiter = ", ")
    library_dirs = cmd_args([pkgroot_path(l, parent = 1) for l in lib], delimiter = ", ")

    # Reexports are identified by the unit ID they come from, and are sorted
    # by module name to match Cabal's behaviour.
    reexports = []
    for new_name, (origin, original_name) in sorted(ctx.attrs.reexported_modules.items()):
        if origin == None:
            origin_id = pkgname
        else:
            provider = origin.get(HaskellLibraryProvider)
            origin_id = (provider.prof_lib if enable_profiling else provider.lib)[link_style].id
        reexports.append("{} from {}:{}".format(new_name, origin_id, original_name))

    conf = [
        "name: " + (ctx.attrs.package_name or pkgname),
        "version: " + (ctx.attrs.package_version or "1.0.0"),
        "id: " + pkgname,
        "key: " + pkgname,
        "exposed: " + ("True" if ctx.attrs.exposed else "False"),
        "exposed-modules: " + ", ".join([m for m in modules if m not in ctx.attrs.hidden_modules] + reexports),
        "hidden-modules: " + ", ".join(ctx.attrs.hidden_modules),
        cmd_args("import-dirs: ", import_dirs, delimiter = ""),
        "depends: " + ", ".join([lib.id for lib in hlis]),
    ]
    if not early and not library_less:
        conf += [
            cmd_args("library-dirs: ", library_dirs, delimiter = ""),
            "extra-libraries: " + libname,
            cmd_args("dynamic-library-dirs: ", cmd_args([pkgroot_path(l, parent = 1) for l in dynamic_lib], delimiter = ", "), delimiter = ""),
        ]
    pkg_conf = ctx.actions.write("pkg-" + db_variant + ".conf", conf, has_content_based_path = False)

    # While the list of hlis is unique, there may be multiple packages in the same db.
    # Cutting down the GHC_PACKAGE_PATH significantly speeds up GHC.
    db_deps = {(x.early_db if (early or library_less) and x.early_db != None else x.db): None for x in hlis + all_hlis}.keys()

    # So that ghc-pkg can find the DBs for the dependencies. We might
    # be able to use flags for this instead, but this works.
    ghc_package_path = cmd_args(
        db_deps,
        delimiter = ":",
    )

    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    # --always-use-cache is a custom option to ghc-pkg that tells it to ignore the
    # modification time on the package cache and use it anyway. This is useful in
    # RE where file modification times can't be relied upon; without this option
    # ghc-pkg will fall back to reading all the package configs which is much
    # slower.
    if haskell_toolchain.support_always_use_cache:
        use_cache_arg = "--always-use-cache"
    else:
        use_cache_arg = ""

    ctx.actions.run(
        cmd_args(
            [
                "sh",
                "-c",
                _REGISTER_PACKAGE,
                "",
                db.as_output(),
                pkg_conf,
                use_cache_arg,
                "--force" if early else "",
                haskell_toolchain.packager,
            ],
            # needs hi, because ghc-pkg checks that the .hi files exist
            hidden = [] if early else hi if library_less else hi + lib + dynamic_lib,
        ),
        category = "haskell_package",
        identifier = db_variant,
        env = {"GHC_PACKAGE_PATH": ghc_package_path} if db_deps else {},
    )

    return db

# The library built in one variant: its compile, and what was linked from it.
Library = record(
    link_style = LinkStyle,
    compiled = CompileResultInfo,
    libs = list[Artifact],
    solibs = dict[str, LinkedObject],
    link_infos = LinkInfos,
)

HaskellLibBuildOutput = record(
    library = Library,
    hlib = HaskellLibraryInfo,
)

def _get_haskell_shared_library_name_linker_flags(linker_type: LinkerType, soname: str) -> list[str]:
    if linker_type == LinkerType("gnu"):
        return ["-Wl,-soname,{}".format(soname)]
    elif linker_type == LinkerType("darwin"):
        # Passing `-install_name @rpath/...` or
        # `-Xlinker -install_name -Xlinker @rpath/...` instead causes
        # ghc-9.6.3: panic! (the 'impossible' happened)
        return ["-Wl,-install_name,@rpath/{}".format(soname)]
    else:
        fail("Unknown linker type '{}'.".format(linker_type))

# The shared libraries of a target's native dependencies, and of their
# dependencies in turn. A splice that runs the
# target's code finds them through LD_LIBRARY_PATH (see native_libs_tree in
# compile.bzl, and Note [Template Haskell modules] in compile_per_module.bzl).
#
# It leaves out the shared libraries of the target's Haskell dependencies,
# which GHC loads by their paths in the package dbs, so that a compile that
# loads them doesn't wait for any other Haskell library to be linked. The
# Haskell dependencies have sets of their own, which a compile merges with
# this one.
def _native_libs(ctx: AnalysisContext) -> SharedLibraryInfo:
    return merge_shared_libraries(ctx.actions, deps = [d[SharedLibraryInfo] for d in ctx.attrs.deps if SharedLibraryInfo in d and HaskellLinkInfo not in d])

# _link_library() and _register_library() are invoked once for each variant
# that the library builds (see Note [Link styles and profiling]).
def _link_library(
    ctx,
    libname: str,
    nlis: list[MergedLinkInfo],  # native link infos from all deps
    link_style: LinkStyle,
    enable_profiling: bool,
    # The variant's compile. For "shared", this may be the dynamic view of
    # a static compile (see _dynamic_view).
    compiled: CompileResultInfo,
) -> Library:
    linker_info = ctx.attrs._cxx_toolchain[CxxToolchainInfo].linker_info

    # Link the objects into a library
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    osuf, _hisuf = output_extensions(link_style, enable_profiling)

    solibs = {}
    variant = variant_name(link_style, enable_profiling)

    if link_style == LinkStyle("shared"):
        libfile = "lib" + libname + "." + LINKERS[linker_info.type].default_shared_library_extension
    else:
        libfile = "lib" + libname + ".a"

    lib_short_path = paths.join("lib-{}".format(variant), libfile)

    objfiles = _srcs_to_objfiles(ctx, compiled.objects, osuf)

    if link_style == LinkStyle("shared"):
        lib = ctx.actions.declare_output(lib_short_path, has_content_based_path = False)
        link = cmd_args(
            [haskell_toolchain.linker]
            + [haskell_toolchain.linker_flags]
            + [ctx.attrs.linker_flags]
            + ["-o", lib.as_output()]
            + [
                "-package-env=-",
                get_shared_library_flags(linker_info.type),
                "-dynamic",
                cmd_args(
                    _get_haskell_shared_library_name_linker_flags(linker_info.type, _soname(ctx, libfile)),
                    prepend = "-optl",
                ),
            ]
            # The objects of its internal_deps are part of it, as in its archive.
            + [objfiles, _internal_objects(ctx, LinkStyle("shared"))],
            hidden = compiled.stubs,
        )

        infos = get_link_args_for_strategy(
            ctx.actions,
            ctx.label,
            linker_info,
            nlis,
            to_link_strategy(LinkStyle("shared")),
            prefer_stripped = False,
            transformation_spec_context = None,
        )
        # Wrap linker args that we pass to GHC as `-optl=X`, not `-optl X`:
        # if X is an argsfile (@file) we want it passed literally to
        # the C compiler rather than GHC expanding it which wouldn't wrap
        # each argument in `-optl`. We do the same thing for `-optP` and
        # `-optc` in compile_args().
        link.add(cmd_args(unpack_link_args(infos), format = "-optl={}"))
        ctx.actions.run(
            link,
            category = "haskell_link",
            identifier = variant,
            env = haskell_toolchain.link_env,
        )

        solibs[_soname(ctx, libfile)] = LinkedObject(output = lib, unstripped_output = lib)
        link_infos = LinkInfos(default = LinkInfo(
            pre_flags = ctx.attrs.exported_linker_flags,
            linkables = [SharedLibLinkable(lib = lib)],
        ))
        libs = [lib]

    else:  # static flavours
        # TODO: avoid making an archive for a single object, like cxx does
        # (but would that work with Template Haskell?)
        # TODO: Opt haskell actions into content based paths.
        archive = make_archive(ctx, lib_short_path, objfiles + _internal_objects(ctx, link_style, enable_profiling), force_disable_content_based_path = True)
        lib = archive.artifact
        libs = [lib] + (archive.external_objects if archive.archive_contents_type == ArchiveContentsType("thin") else [])
        link_infos = LinkInfos(
            default = LinkInfo(
                pre_flags = ctx.attrs.exported_linker_flags,
                linkables = [
                    ArchiveLinkable(
                        archive = archive,
                        linker_type = linker_info.type,
                        link_whole = ctx.attrs.link_whole,
                    ),
                ],
            ),
        )

    return Library(
        link_style = link_style,
        compiled = compiled,
        libs = libs,
        solibs = solibs,
        link_infos = link_infos,
    )

def _register_library(
    ctx,
    libname: str,
    pkgname: str,
    hlis: list[HaskellLinkInfo],  # haskell link infos from all deps
    enable_profiling: bool,
    # The library's native libraries (see _native_libs).
    native_libs: SharedLibraryInfo,
    library: Library,
    # The splice variant of `library`: the variant whose code GHC loads when
    # a splice in a module compiled against `library` runs this library's
    # code. It may be `library` itself (see Note [Link styles and
    # profiling]).
    splice_variant: Library,
) -> HaskellLibBuildOutput:
    link_style = library.link_style
    compiled = library.compiled
    linfos = [x.prof_info if enable_profiling else x.info for x in hlis]

    # only gather direct dependencies
    uniq_infos = [x[link_style].value for x in linfos]
    all_hlis = [lib for x in linfos for lib in x[link_style].traverse()] if ctx.attrs.reexported_modules else []
    below = ctx.actions.tset(HaskellLibraryInfoTSet, children = [x[link_style] for x in linfos])

    # The package names the variant's own interfaces, stubs and libraries,
    # and those of its splice variant. Its library-dirs names only the
    # variant's own library, because listing both can confuse a profiled
    # external interpreter. GHC's internal interpreter finds a shared splice
    # variant's library through dynamic-library-dirs instead. When the
    # variant is its own splice variant, or both come from one -dynamic-too
    # compile, they share some files, so each file is named only once.
    def unique(xs: list) -> list:
        return list({x: None for x in xs}.keys())

    import_artifacts = unique([compiled.hi, splice_variant.compiled.hi])
    stub_dirs = unique([compiled.stubs, splice_variant.compiled.stubs])
    all_libs = unique(library.libs + splice_variant.libs)

    db = _make_package(
        ctx,
        link_style,
        pkgname,
        libname,
        uniq_infos,
        import_artifacts,
        [library.libs[0]],
        [splice_variant.libs[0]],
        enable_profiling = enable_profiling,
        import_dir = compiled.import_dir,
        all_hlis = all_hlis,
    )

    hlib = HaskellLibraryInfo(
        name = pkgname,
        db = db,
        id = pkgname,
        import_dirs = import_artifacts,
        stub_dirs = stub_dirs,
        libs = all_libs,
        native_libs = native_libs,
        data_dirs = own_data_dirs(ctx),
        version = ctx.attrs.package_version or "1.0.0",
        is_prebuilt = False,
        profiling_enabled = enable_profiling,
        **_per_module_fields(ctx, link_style, pkgname, libname, uniq_infos, compiled, enable_profiling = enable_profiling, all_hlis = all_hlis, hi = import_artifacts, below = below)
    )

    return HaskellLibBuildOutput(library = library, hlib = hlib)

# The link style of the splice variant of a variant with this link style,
# whether profiled or not (see Note [Link styles and profiling]). Where this
# returns the style unchanged, a non-profiled variant is its own splice
# variant.
def _splice_variant_style(ctx: AnalysisContext, link_style: LinkStyle) -> LinkStyle:
    dynamic_ghc = ctx.attrs._haskell_toolchain[HaskellToolchainInfo].dynamic_ghc
    return LinkStyle("shared") if dynamic_ghc else link_style

# Given a compilation built with -dynamic-too, produce a `CompileResultInfo`
# that sees the "extra" dynamic interface files as the primary ones. The
# objects need no change, because the shared variant's link takes the .dyn_o
# files from the same directory.
def _dynamic_view(compiled: CompileResultInfo) -> CompileResultInfo:
    modules = None
    if compiled.modules != None:
        modules = {m: HaskellModuleFiles(hi = f.dyn_hi, abi = f.abi) for m, f in compiled.modules.items()}
    return CompileResultInfo(
        objects = compiled.objects,
        hi = compiled.hi,
        stubs = compiled.stubs,
        producing_indices = compiled.producing_indices,
        import_dir = compiled.import_dir,
        modules = modules,
        closures = compiled.closures,
        dynamic_objects = compiled.dynamic_objects,
        advice = compiled.advice,
    )

# The HaskellLibraryInfo fields that per-module compiles of a library's
# dependents use (see library_info.bzl). They are filled in for every
# library, whether or not it is itself compiled per-module, because any of
# its dependents might be:
#
# - For a library built with --make: its library-less db, and `below`.
# - For a library compiled per-module: its early db, the files of each of
#   its modules, and their closure sets.
def _per_module_fields(
        ctx: AnalysisContext,
        link_style: LinkStyle,
        pkgname: str,
        libname: str,
        hlis: list[HaskellLibraryInfo],
        compiled: CompileResultInfo,
        enable_profiling: bool = False,
        all_hlis: list[HaskellLibraryInfo] = [],
        hi: list[Artifact] = [],
        below: [TransitiveSet, None] = None) -> dict:
    if compiled.modules == None:
        # Built with --make: the library-less db its per-module dependents
        # compile against, and its dependencies.
        return {
            "below": below,
            "early_db": _make_package(ctx, link_style, pkgname, libname, hlis, hi, [], [], enable_profiling = enable_profiling, import_dir = compiled.import_dir, all_hlis = all_hlis, library_less = True),
        }
    return {
        "early_db": _make_package(ctx, link_style, pkgname, libname, hlis, [], [], [], enable_profiling = enable_profiling, import_dir = compiled.import_dir, all_hlis = all_hlis, early = True),
        "modules": compiled.modules,
        "closures": compiled.closures,
    }

def _soname(ctx: AnalysisContext, libfile: str) -> str:
    # The soname of the library's shared library, whose file is `libfile`.
    return ctx.attrs.soname or libfile

def _internal_objects(ctx: AnalysisContext, link_style: LinkStyle, enable_profiling: bool = False) -> list[Artifact]:
    # The objects of the library's internal_deps (its prof_internal_deps, if
    # it has them, when profiled), which its archive has in it as well as its
    # own.
    objects = []
    deps = ctx.attrs.prof_internal_deps if enable_profiling and ctx.attrs.prof_internal_deps else ctx.attrs.internal_deps
    for dep in deps:
        infos = get_own_link_infos(dep[MergedLinkInfo], to_link_strategy(link_style))
        if infos == None:
            fail("{}: internal dependency {} has nothing to link for {} linking".format(ctx.label, dep.label, link_style.value))
        for linkable in infos.default.linkables:
            if not hasattr(linkable, "objects"):
                fail("{}: internal dependency {} isn't objects, which the library's archive can include (use_archive = False, for a cxx_library)".format(ctx.label, dep.label))
            objects.extend(linkable.objects)
    return objects

def _exported_link_infos(ctx: AnalysisContext, enable_profiling: bool) -> list[MergedLinkInfo]:
    # The link infos of the library's dependencies, but not of its
    # internal_deps.
    return filter(None, [
        (d.get(HaskellProfLinkInfo).prof_infos if enable_profiling and d.get(HaskellProfLinkInfo) else d.get(MergedLinkInfo))
        for d in ctx.attrs.deps
    ])

def haskell_library_impl(ctx: AnalysisContext) -> list[Provider]:
    preferred_linkage = _attr_preferred_linkage(ctx)
    if ctx.attrs.enable_profiling and preferred_linkage == Linkage("any"):
        preferred_linkage = Linkage("static")

    # Get haskell and native link infos from all deps (but not internal_deps,
    # whose objects are the library's own)
    hlis = attr_deps_haskell_link_infos_sans_template_deps(ctx)
    nlis = attr_deps_merged_link_infos(ctx, ctx.attrs.deps)
    shared_library_infos = attr_deps_shared_library_infos(ctx)

    solibs = {}
    link_infos = {}
    prof_link_infos = {}
    hlib_infos = {}
    hlib_compiled = {}
    hlink_infos = {}
    prof_hlib_infos = {}
    prof_hlink_infos = {}
    indexing_tsets = {}
    sub_targets = {}

    libname = haskell_library_name(ctx.label)
    pkgname = ctx.attrs.unit_id or haskell_library_unit_id(ctx.label)

    native_libs = _native_libs(ctx)

    link_styles = [legacy_output_style_to_link_style(o) for o in get_output_styles_for_linkage(preferred_linkage)]

    # The static link style that a statically-linked consumer actually
    # uses: "static", unless the toolchain's code is always
    # position-independent (macOS), when it's "static_pic".
    pic_behavior = ctx.attrs._cxx_toolchain[CxxToolchainInfo].pic_behavior
    consumed_static_link_style = legacy_output_style_to_link_style(
        process_output_style_for_pic_behavior(LibOutputStyle("archive"), pic_behavior),
    )

    # Records one variant's outputs in the dicts above. A variant that the
    # library builds only to be a splice variant has a package, for its
    # dependents' splice variants to compile against, but nothing links it,
    # so it has no link infos, shared libraries or sub-target.
    def record(link_style: LinkStyle, enable_profiling: bool, hlib_build_out: HaskellLibBuildOutput):
        hlib = hlib_build_out.hlib
        splice_only = not enable_profiling and link_style not in link_styles
        if not splice_only:
            solibs.update(hlib_build_out.library.solibs)
        compiled = hlib_build_out.library.compiled
        libs = hlib_build_out.library.libs

        if enable_profiling:
            prof_hlib_infos[link_style] = hlib
            prof_hlink_infos[link_style] = ctx.actions.tset(
                HaskellLibraryInfoTSet,
                value = hlib,
                children = [li.prof_info[link_style] for li in hlis],
            )
            prof_link_infos[link_style] = hlib_build_out.library.link_infos
        else:
            hlib_infos[link_style] = hlib
            hlib_compiled[link_style] = compiled
            hlink_infos[link_style] = ctx.actions.tset(
                HaskellLibraryInfoTSet,
                value = hlib,
                children = [li.info[link_style] for li in hlis],
            )
            if not splice_only:
                link_infos[link_style] = hlib_build_out.library.link_infos

        # Build the indices and create subtargets only once, with profiling
        # enabled or disabled based on what was set in the library's
        # target.
        if ctx.attrs.enable_profiling == enable_profiling and not splice_only:
            if compiled.producing_indices:
                tset = derive_indexing_tset(
                    ctx.actions,
                    link_style,
                    compiled.hi,
                    attr_deps(ctx),
                )
                indexing_tsets[link_style] = tset

            sub_targets[link_style.value.replace("_", "-")] = [
                DefaultInfo(
                    default_outputs = libs,
                )
            ]

    # Profiled code can only be linked statically, so whatever the library's
    # preferred_linkage, a profiled link wants a profiled archive of it: a
    # library that is otherwise only shared (preferred_linkage "shared") is a
    # profiled archive to a profiled executable. These are only built when a
    # profiled link asks for them. See Note [Link styles and profiling].
    prof_link_styles = [legacy_output_style_to_link_style(o) for o in get_output_styles_for_linkage(Linkage("static"))]

    unprof_link_styles = list(link_styles)
    for style in link_styles + prof_link_styles:
        splice_style = _splice_variant_style(ctx, style)
        if splice_style not in unprof_link_styles:
            unprof_link_styles.append(splice_style)

    # When the shared variant and the static style that executables use are
    # both built, they come from one -dynamic-too compile instead of two
    # independent ones (see _dynamic_view).
    build_shared_too = (
        consumed_static_link_style in unprof_link_styles and
        LinkStyle("shared") in unprof_link_styles
    )

    compiles = {}

    def compile_variant(link_style: LinkStyle, enable_profiling: bool, dynamic_from: [CompileResultInfo, None]) -> CompileResultInfo:
        key = (link_style, enable_profiling)
        if key not in compiles:
            compiles[key] = (compile_per_module if compiles_per_module(ctx) else compile)(
                ctx,
                link_style,
                enable_profiling = enable_profiling,
                pkgname = pkgname,
                native_libs = native_libs,
                dynamic_too = build_shared_too and link_style == consumed_static_link_style and not enable_profiling,
                dynamic_from = dynamic_from,
            )
        return compiles[key]

    # Each variant is built after its splice variant, so the shared variant
    # first.
    variants = (
        [(False, s) for s in unprof_link_styles if s == LinkStyle("shared")] +
        [(False, s) for s in unprof_link_styles if s != LinkStyle("shared")] +
        [(True, s) for s in prof_link_styles]
    )
    # The libraries of the non-profiled variants, by style.
    libraries = {}
    for enable_profiling, link_style in variants:
        splice_style = _splice_variant_style(ctx, link_style)
        if build_shared_too and link_style == LinkStyle("shared"):
            compiled = _dynamic_view(compile_variant(consumed_static_link_style, False, None))
        else:
            dynamic_from = libraries[splice_style].compiled if enable_profiling and splice_style == LinkStyle("shared") else None
            compiled = compile_variant(link_style, enable_profiling, dynamic_from)

        library = _link_library(ctx, libname, nlis, link_style, enable_profiling, compiled)
        if not enable_profiling:
            libraries[link_style] = library
        record(link_style, enable_profiling, _register_library(
            ctx,
            libname,
            pkgname,
            hlis = hlis,
            enable_profiling = enable_profiling,
            native_libs = native_libs,
            library = library,
            splice_variant = libraries[splice_style],
        ))

    link_style = cxx_toolchain_link_style(ctx)
    output_style = get_lib_output_style(
        to_link_strategy(link_style),
        preferred_linkage,
        pic_behavior,
    )
    shared_libs = create_shared_libraries(ctx, solibs)

    # TODO(cjhopman): this haskell implementation does not consistently handle LibOutputStyle
    # and LinkStrategy as expected and it's hard to tell what the intent of the existing code is
    # and so we currently just preserve its existing use of the legacy LinkStyle type and just
    # naively convert it at the boundaries of other code. This needs to be cleaned up by someone
    # who understands the intent of the code here.
    actual_link_style = legacy_output_style_to_link_style(output_style)

    # The link info for this library as a dependency of a non-Haskell target
    # (a cxx_binary(), say). When the library is profiled and that target
    # links it shared, there is no profiled shared library (GHC doesn't
    # support profiling with dynamic linking), so it gets the non-profiled
    # one. A profiled Haskell link uses prof_merged_link_info, which never
    # does.
    default_link_infos = link_infos
    if ctx.attrs.enable_profiling:
        default_link_infos = dict(prof_link_infos)
        if LinkStyle("shared") in link_infos:
            default_link_infos[LinkStyle("shared")] = link_infos[LinkStyle("shared")]
    merged_link_info = create_merged_link_info(
        ctx,
        pic_behavior = pic_behavior,
        link_infos = {_to_lib_output_style(s): v for s, v in default_link_infos.items()},
        preferred_linkage = preferred_linkage,
        # Haskell code may refer to the code of any library below it (through
        # inlining), so the libraries it depends on are linked with it, but
        # not those that are part of it (its internal_deps, in its archive or
        # linked into its shared library).
        exported_deps = _exported_link_infos(ctx, enable_profiling = ctx.attrs.enable_profiling),
    )

    prof_merged_link_info = create_merged_link_info(
        ctx,
        pic_behavior = pic_behavior,
        link_infos = {_to_lib_output_style(s): v for s, v in prof_link_infos.items()},
        # A profiled archive, for any link strategy (see prof_link_styles).
        preferred_linkage = Linkage("static"),
        exported_deps = _exported_link_infos(ctx, enable_profiling = True),
    )

    linkable_graph = create_linkable_graph(
        ctx,
        node = create_linkable_graph_node(
            ctx,
            linkable_node = create_linkable_node(
                ctx = ctx,
                preferred_linkage = preferred_linkage,
                exported_deps = ctx.attrs.deps,
                link_infos = {_to_lib_output_style(s): v for s, v in link_infos.items()},
                shared_libs = shared_libs,
                # TODO(cjhopman): this should be set to non-None
                default_soname = None,
            ),
        ),
        deps = ctx.attrs.deps,
    )

    default_output = libraries[actual_link_style].libs

    inherited_pp_info = cxx_inherited_preprocessor_infos(attr_deps(ctx))

    # We would like to expose the generated _stub.h headers to C++
    # compilations, but it's hard to do that without overbuilding. Which
    # link_style should we pick below? If we pick a different link_style from
    # the one being used by the root rule, we'll end up building all the
    # Haskell libraries multiple times.
    #
    #    pp = [CPreprocessor(
    #        args =
    #            flatten([["-isystem", dir] for dir in hlib_infos[actual_link_style].stub_dirs]),
    #    )]
    pp = []

    # The interfaces of the default output's compile.
    sub_targets["interfaces"] = [DefaultInfo(default_output = hlib_compiled[actual_link_style].hi)]

    providers = [
        DefaultInfo(
            default_outputs = default_output,
            sub_targets = sub_targets,
        ),
        HaskellLibraryProvider(
            lib = hlib_infos,
            prof_lib = prof_hlib_infos,
        ),
        HaskellLinkInfo(
            info = hlink_infos,
            prof_info = prof_hlink_infos,
        ),
        merged_link_info,
        HaskellProfLinkInfo(
            prof_infos = prof_merged_link_info,
        ),
        linkable_graph,
        cxx_merge_cpreprocessors(ctx.actions, pp, inherited_pp_info),
        merge_shared_libraries(
            ctx.actions,
            shared_libs,
            shared_library_infos,
        ),
        haskell_haddock_lib(ctx, pkgname, actual_link_style, hlib_compiled[actual_link_style], _native_libs(ctx)),
    ]

    if indexing_tsets:
        providers.append(HaskellIndexInfo(info = indexing_tsets))

    # TODO(cjhopman): This code is for templ_vars is duplicated from cxx_library
    templ_vars = {}

    # Add in ldflag macros.
    for link_style in (LinkStyle("static"), LinkStyle("static_pic")):
        name = "ldflags-" + link_style.value.replace("_", "-")
        args = cmd_args()
        linker_info = ctx.attrs._cxx_toolchain[CxxToolchainInfo].linker_info
        args.add(linker_info.linker_flags)
        args.add(
            unpack_link_args(
                get_link_args_for_strategy(
                    ctx.actions,
                    ctx.label,
                    linker_info,
                    [merged_link_info],
                    to_link_strategy(link_style),
                    prefer_stripped = False,
                    transformation_spec_context = None,
                ),
            )
        )
        templ_vars[name] = args

    # TODO(T110378127): To implement `$(ldflags-shared ...)` properly, we'd need
    # to setup a symink tree rule for all transitive shared libs.  Since this
    # currently would be pretty costly (O(N^2)?), and since it's not that
    # commonly used anyway, just use `static-pic` instead.  Longer-term, once
    # v1 is gone, macros that use `$(ldflags-shared ...)` (e.g. Haskell's
    # hsc2hs) can move to a v2 rules-based API to avoid needing this macro.
    templ_vars["ldflags-shared"] = templ_vars["ldflags-static-pic"]

    providers.append(TemplatePlaceholderInfo(keyed_variables = templ_vars))

    providers.append(merge_link_group_lib_info(deps = attr_deps(ctx)))
    providers += advice_validations(hlib_compiled[actual_link_style])

    return providers

# TODO(cjhopman): should this be LibOutputType or LinkStrategy?
def derive_indexing_tset(actions: AnalysisActions, link_style: LinkStyle, value: Artifact | None, children: list[Dependency]) -> HaskellIndexingTSet:
    index_children = []
    for dep in children:
        li = dep.get(HaskellIndexInfo)
        if li:
            if link_style in li.info:
                index_children.append(li.info[link_style])

    return actions.tset(
        HaskellIndexingTSet,
        value = value,
        children = index_children,
    )

def _run_tools(ctx: AnalysisContext) -> list[Artifact]:
    return [t[DefaultInfo].default_outputs[0] for t in ctx.attrs.run_tool_depends]

# Write a wrapper script that sets up the binary's environment and then runs
# it, as `cabal run` does. The script sets the environment variables for the
# rule's data_dirs, and puts the directories of its run_tool_depends at the
# front of PATH.
#
# The script refers to the data directories, the tools and the binary by
# paths relative to its own location, and turns them into absolute paths when
# it runs. That way they don't depend on where buck-out is, and they keep
# working if the binary is started from another directory (a test run by
# run_in_cwd, say) or changes directory itself.
def _run_wrapper(ctx: AnalysisContext, binary: Artifact) -> Artifact:
    script = ctx.actions.declare_output(binary.basename + "-run", has_content_based_path = False)
    tools = _run_tools(ctx)
    ctx.actions.write(
        script,
        cmd_args(
            "#!/bin/sh",
            'here=$(cd "$(dirname "$0")" && pwd)',
            [
                cmd_args("export ", name, '="$here/', dir, '"', delimiter = "")
                for name, dir in data_dirs_env(ctx).items()
            ],
            cmd_args(
                'export PATH="',
                [cmd_args("$here/", cmd_args(t, parent = 1), ":", delimiter = "") for t in tools],
                '$PATH"',
                delimiter = "",
            ) if tools else [],
            cmd_args('exec "$here/', binary, '" "$@"', delimiter = ""),
            relative_to = (script, 1),
        ),
        is_executable = True,
    )
    return script

def haskell_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    enable_profiling = ctx.attrs.enable_profiling

    # Decide what kind of linking we're doing

    link_style = attr_link_style(ctx)

    # Link Groups
    link_group_info = get_link_group_info(
        ctx,
        filter_and_map_idx(LinkableGraph, attr_deps(ctx)),
        to_link_strategy(link_style),
    )

    # Profiling doesn't support shared libraries
    if enable_profiling and link_style == LinkStyle("shared"):
        link_style = LinkStyle("static")

    link_style = LinkStyle(
        process_link_strategy_for_pic_behavior(to_link_strategy(link_style), get_cxx_toolchain_info(ctx).pic_behavior).value
    )
    haskell_toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]

    compiled = (compile_per_module if compiles_per_module(ctx) else compile)(
        ctx,
        link_style,
        enable_profiling = enable_profiling,
        native_libs = _native_libs(ctx),
    )

    output = ctx.actions.declare_output(ctx.attrs.exe_name or ctx.attrs.name, has_content_based_path = False)
    link = cmd_args(
        [haskell_toolchain.compiler] + ["-o", output.as_output()] + [haskell_toolchain.linker_flags] + [ctx.attrs.linker_flags],
        hidden = compiled.stubs,
    )

    # Without this, GHC will link the non-profiled RTS which leads to
    # duplicate symbols. We already do this at compile-time in
    # compile.bzl:compile_args.
    if enable_profiling:
        link.add("-prof")

    # Without this, GHC links its static RTS into a binary whose
    # Haskell libraries are shared, and the linker discards whatever
    # parts of it the binary itself doesn't use - but the shared
    # libraries need them too, since they aren't linked against an RTS
    # themselfs (which RTS - threaded or not - is only decided here).
    # With it, GHC links the correct shared RTS instead.
    if link_style == LinkStyle("shared"):
        link.add("-dynamic")

    link_args = cmd_args("-package-env=-")

    # By default GHC links the rts, ghc-internal and base packages of its
    # own package database. When a dependency provides the RTS (is_rts), the
    # link passes -no-auto-link-packages, and the RTS's package database and
    # -package-id, so that GHC links that RTS in place of its own. The
    # RTS's files are inputs of the link, because GHC reads them. Other
    # packages, including ghc-internal and base, are linked as the
    # dependencies' link infos say, so the link doesn't need their package
    # databases.
    rts = {
        lib.id: lib
        for lib in dependency_libs(ctx, link_style, enable_profiling).traverse()
        if lib.is_rts
    }.values()
    if len(rts) > 1:
        fail("{}: more than one RTS among the dependencies: {}".format(ctx.label, ", ".join([lib.id for lib in rts])))
    if rts:
        link_args.add(
            "-no-auto-link-packages",
            cmd_args("-package-db", rts[0].db),
            cmd_args("-package-id", rts[0].id, hidden = rts[0].libs),
        )

    osuf, _hisuf = output_extensions(link_style, enable_profiling)

    objfiles = _srcs_to_objfiles(ctx, compiled.objects, osuf)
    link_args.add(objfiles)

    indexing_tsets = {}
    if compiled.producing_indices:
        tset = derive_indexing_tset(ctx.actions, link_style, compiled.hi, attr_deps(ctx))
        indexing_tsets[link_style] = tset

    slis = []
    for lib in attr_deps(ctx):
        li = lib.get(SharedLibraryInfo)
        if li != None:
            slis.append(li)
    shlib_info = merge_shared_libraries(
        ctx.actions,
        deps = slis,
    )

    sos = []

    link_strategy = to_link_strategy(link_style)
    if link_group_info != None:
        own_binary_link_flags = []
        auto_link_groups = {}
        link_group_libs = {}
        link_deps = linkables(attr_deps(ctx))
        reduced_linkable_graph = reduce_linkable_graph(link_group_info.graph)
        linkable_graph_node_map = reduced_linkable_graph.nodes
        link_group_preferred_linkage = get_link_group_preferred_linkage(link_group_info.groups.values())

        # If we're using auto-link-groups, where we generate the link group links
        # in the prelude, the link group map will give us the link group libs.
        # Otherwise, pull them from the `LinkGroupLibInfo` provider from out deps.
        auto_link_group_specs = get_auto_link_group_specs(ctx, link_group_info)
        executable_deps = [d.linkable_graph.nodes.value.label for d in link_deps if d.linkable_graph != None]
        public_nodes = get_public_link_group_nodes(
            linkable_graph_node_map,
            link_group_info.mappings,
            executable_deps,
            None,
        )
        if auto_link_group_specs != None:
            linked_link_groups = create_link_groups(
                ctx = ctx,
                link_strategy = link_strategy,
                linkable_graph = reduced_linkable_graph,
                link_group_mappings = link_group_info.mappings,
                link_group_preferred_linkage = link_group_preferred_linkage,
                executable_deps = executable_deps,
                link_group_specs = auto_link_group_specs,
                public_nodes = public_nodes,
            )
            for name, linked_link_group in linked_link_groups.libs.items():
                auto_link_groups[name] = linked_link_group.artifact
                if linked_link_group.library != None:
                    link_group_libs[name] = linked_link_group.library
            own_binary_link_flags += linked_link_groups.symbol_ldflags

        else:
            # NOTE(agallagher): We don't use version scripts and linker scripts
            # for non-auto-link-group flow, as it's note clear it's useful (e.g.
            # it's mainly for supporting dlopen-enabled libs and extensions).
            link_group_libs = gather_link_group_libs(
                children = [d.link_group_lib_info for d in link_deps],
            )

        link_group_relevant_roots = find_relevant_roots(
            linkable_graph_node_map = linkable_graph_node_map,
            link_group_mappings = link_group_info.mappings,
            roots = get_dedupped_roots_from_groups(link_group_info.groups.values()),
        )

        roots = set(
            [d.linkable_graph.nodes.value.label for d in link_deps if d.linkable_graph != None] + link_group_relevant_roots,
        )
        is_executable_link = True
        pic_behavior = PicBehavior("supported")
        exec_linkables = collect_linkables(
            reduced_linkable_graph,
            is_executable_link,
            link_strategy,
            link_group_preferred_linkage,
            pic_behavior,
            roots,
        )
        build_context = BuildLinkGroupsContext(
            public_nodes = public_nodes,
            linkable_graph = reduced_linkable_graph,
            link_groups = link_group_info.groups,
            link_group_mappings = link_group_info.mappings,
            link_group_preferred_linkage = link_group_preferred_linkage,
            link_strategy = link_strategy,
            pic_behavior = pic_behavior,
            link_group_libs = {name: (lib.label, lib.shared_link_infos) for name, lib in link_group_libs.items()},
            prefer_stripped = False,
            prefer_optimized = False,
        )
        labels_to_links = get_filtered_labels_to_links_map(
            link_group = None,
            linkables = exec_linkables,
            is_executable_link = True,
            build_context = build_context,
            force_static_follows_dependents = True,
        )

        # NOTE: Our Haskell DLL support impl currently links transitive haskell
        # deps needed by DLLs which get linked into the main executable as link-
        # whole.  To emulate this, we mark Haskell rules with a special label
        # and traverse this to find all the nodes we need to link whole.
        public_nodes = []
        if ctx.attrs.link_group_public_deps_label != None:
            public_nodes = get_transitive_deps_matching_labels(
                linkable_graph_node_map = linkable_graph_node_map,
                label = ctx.attrs.link_group_public_deps_label,
                roots = link_group_relevant_roots,
            )

        link_infos = []
        link_infos.append(
            LinkInfo(
                pre_flags = own_binary_link_flags,
            ),
        )
        link_infos.extend(get_filtered_links(labels_to_links.map, set(public_nodes)))
        infos = LinkArgs(infos = link_infos)

        link_group_ctx = LinkGroupContext(
            link_group_mappings = link_group_info.mappings,
            link_group_libs = link_group_libs,
            link_group_preferred_linkage = link_group_preferred_linkage,
            labels_to_links_map = labels_to_links.map,
            targets_consumed_by_link_groups = {},
        )

        for shared_lib in traverse_shared_library_info(shlib_info, transformation_provider = None):
            label = shared_lib.label
            if is_link_group_shlib(label, link_group_ctx):
                sos.append(shared_lib)

        # When there are no matches for a pattern based link group,
        # `link_group_mappings` will not have an entry associated with the lib.
        for _name, link_group_lib in link_group_libs.items():
            sos.extend(link_group_lib.shared_libs.libraries)

    else:
        nlis = []
        for lib in attr_deps(ctx):
            if enable_profiling:
                hli = lib.get(HaskellProfLinkInfo)
                if hli != None:
                    nlis.append(hli.prof_infos)
                    continue
            li = lib.get(MergedLinkInfo)
            if li != None:
                nlis.append(li)
        sos.extend(traverse_shared_library_info(shlib_info, transformation_provider = None))
        cxx_toolchain = ctx.attrs._cxx_toolchain[CxxToolchainInfo]
        infos = get_link_args_for_strategy(
            ctx.actions,
            ctx.label,
            cxx_toolchain.linker_info,
            nlis,
            to_link_strategy(link_style),
            prefer_stripped = False,
            transformation_spec_context = None,
        )

    # `link_ordering = "topological"`, not the default `"preorder"`: this
    # migration hands raw static-archive paths straight to the linker
    # (unlike a plain Cabal/GHC `-package`-based link, which computes
    # correct archive order itself from the package DB). buck2's own
    # LinkOrdering docs (prelude/linking/link_info.bzl) describe exactly
    # what a single left-to-right `ld` pass needs here: "topological sort,
    # such that nodes are listed after all nodes that have them as
    # descendants" - i.e. a shared descendant (e.g. `primitive`, needed by
    # both `fb-util` and `vector`, two independent direct deps of the same
    # binary) is positioned after *every* consumer that needs it, not just
    # whichever one's subtree the default preorder-with-first-occurrence-
    # wins traversal happens to reach first (which, for two *independent*
    # siblings that share a transitive dependency, has no way to know the
    # *other* sibling needs it too - producing "undefined reference" even
    # though the defining archive is genuinely present on the command
    # line, just too early for the second consumer). This is a real,
    # first-class ordering mode already implemented in buck2's own tset
    # machinery - not a workaround - haskell_binary_impl here just never
    # requested it, always taking the `unpack_link_args` default.
    link_args.add(cmd_args(unpack_link_args(infos, link_ordering = LinkOrdering("topological")), format = "-optl={}"))

    link.add(
        at_argfile(
            actions = ctx.actions,
            name = "args.haskell_link_argsfile",
            args = link_args,
            allow_args = True,
        )
    )

    symlink_dir = None
    if link_style == LinkStyle("shared") or link_group_info != None:
        # Built *before* the link action below (not after, as this used to
        # be) so its real, build-time-valid path can be passed to the linker
        # as `-rpath-link` right now - see the comment on that flag below for
        # why this reordering is load-bearing, not cosmetic.
        sos_dir = "__{}__shared_libs_symlink_tree".format(ctx.attrs.name)
        symlink_dir = create_shlib_symlink_tree(
            actions = ctx.actions,
            out = sos_dir,
            shared_libs = sos,
        )
        linker_type = get_cxx_toolchain_info(ctx).linker_info.type
        rpath_ref = get_rpath_origin(linker_type)
        rpath_ldflag = "-Wl,{}/{}".format(rpath_ref, sos_dir)
        is_gnu_linker = linker_type == LinkerType("gnu")

        # `--disable-new-dtags`: without it, GNU ld's default emits the
        # modern DT_RUNPATH tag for `-rpath`, which the dynamic loader only
        # consults when resolving *this object's own* direct NEEDED entries
        # - it is deliberately not inherited by anything loaded as a result
        # of it. That's invisible for a single-hop native shared dependency
        # (executable -> core.so -> rts.so: core.so's own link already
        # embeds a direct reference to rts.so, so the executable's runpath
        # is never even needed for that hop) but breaks a multi-hop chain
        # like executable -> db.so -> rocksdb.so -> storage.so: none of
        # db.so/rocksdb.so carry any rpath of their own (nothing in this
        # migration's cxx_library()/haskell_library() link steps sets one),
        # so once the executable's own DT_RUNPATH resolves db.so, nothing
        # is left to tell the loader where storage.so lives when resolving
        # *rocksdb.so's* NEEDED entries - "cannot open shared object file"
        # at process startup despite the .so genuinely being right there in
        # the symlink tree that got built. The legacy DT_RPATH tag doesn't
        # have this limitation: the loader folds every RPATH it encounters
        # into one global search list used for the *whole* transitive
        # resolution, not just the object that carries it - exactly what a
        # dependency chain of arbitrary depth needs, without requiring every
        # library along the way to separately carry its own rpath.
        # (GNU ld only: Mach-O has no such distinction.)
        if is_gnu_linker:
            link.add("-optl", "-Wl,--disable-new-dtags")
        link.add("-optl", "-Wl,-rpath", "-optl", rpath_ldflag)

        # `-rpath` (above) only takes effect once the *finished binary* runs
        # - it's a token ($ORIGIN/...) baked into the ELF's DT_RUNPATH,
        # meaningless to the linker invoked *right now* to produce that
        # binary, since there's no running process yet for $ORIGIN to refer
        # to. That's invisible for a single-hop shared dependency (e.g. this
        # binary -> rts.so directly): buck2's normal cxx linking machinery
        # already emits a direct, real `-L<dir> -l<name>` for anything in
        # `nlis` above, which the build-time linker can resolve on its own.
        # It breaks down for a *multi-hop* native shared-library chain (e.g.
        # this binary -> db.so -> rocksdb.so -> storage.so, where storage
        # is only ever a dependency-of-a-dependency, never listed directly
        # in any Haskell target's own `deps`): the linker, while resolving
        # rocksdb.so's own DT_NEEDED entry on storage.so to check whether it
        # actually provides the symbols db.so's own code references, has no
        # real, existing-right-now path to look in, and conservatively
        # reports those symbols undefined rather than assuming they'd
        # resolve at runtime. `-rpath-link` is the link-time-only counterpart
        # to `-rpath`: same directory, but as a real path valid *now*, purely
        # a search hint for the linker's own transitive-NEEDED resolution -
        # it doesn't get embedded in the output at all. Passing both this and
        # the $ORIGIN-relative `-rpath` fixes multi-hop native shared
        # dependencies generally, without needing to know in advance whether
        # any given target's dependency graph actually has one.
        #
        # (GNU ld only: Apple's ld doesn't resolve a dependency's own
        # dependencies at link time.)
        if is_gnu_linker:
            link.add("-optl", cmd_args("-Wl,-rpath-link,", symlink_dir, delimiter = ""))

    ctx.actions.run(link, category = "haskell_link", env = haskell_toolchain.link_env)

    if symlink_dir != None:
        run = cmd_args(output, hidden = symlink_dir)
    else:
        run = cmd_args(output)

    # With data_dirs or run_tool_depends, `buck2 run` and tests go through
    # the wrapper script. The original command, the data directories and the
    # tools are hidden inputs, so that they (and the symlink_dir of shared
    # libraries) are materialized too.
    if ctx.attrs.data_dirs or ctx.attrs.run_tool_depends:
        run = cmd_args(
            _run_wrapper(ctx, output),
            hidden = [run, data_dirs_env(ctx).values(), [t.get(RunInfo) or t[DefaultInfo].default_outputs for t in ctx.attrs.run_tool_depends]],
        )

    providers = [
        DefaultInfo(
            default_output = output,
            sub_targets = {"interfaces": [DefaultInfo(default_output = compiled.hi)]},
        ),
        RunInfo(args = run),
    ] + advice_validations(compiled)

    if indexing_tsets:
        providers.append(HaskellIndexInfo(info = indexing_tsets))

    return providers

# Note [Link styles and profiling]
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
# The big picture
# ---------------
#
# Haskell code can be linked in three styles:
#
#   static      archives (.a) of ordinary code
#   static_pic  archives of position-independent code
#   shared      shared libraries (.so, .dylib)
#
# and, independently, profiled or not. Profiled code can only be linked
# statically: GHC doesn't support profiling with dynamic linking. So there are
# five variants of a library: static, static_pic and shared unprofiled, and
# static and static_pic profiled.
#
# Two parties decide how a library is linked, separately:
#
#  * The library, by its preferred_linkage, decides which variants it offers.
#    It can't know how the executables that use it will be linked: a target
#    is analysed apart from the targets that depend on it, and all it sees of
#    them is its configuration.
#
#  * The executable, by its link_style, decides which variant it asks for.
#
# Where the two disagree, buck2 lets the library win: for each library, the
# variant an executable gets is get_lib_output_style(link strategy,
# preferred_linkage), in prelude/linking/link_info.bzl. In particular, a
# library whose preferred_linkage is "shared" is linked shared whatever the
# executable asks for.
#
# Profiling breaks that rule, because a profiled executable can't link a
# shared library: to it, every library is linked statically. The rest of this
# Note is about how each side does its part, and how profiling and Template
# Haskell fit in.
#
# What a library offers
# ---------------------
#
# haskell_library_impl declares the actions for each variant it offers. For
# each, it compiles the library's modules, registers the package in a package
# database of its own (for compiling against it), and makes the library
# itself (an archive, or a shared library). buck2 only runs the actions whose
# outputs are demanded, so it costs nothing extra to offer all the variants.
#
#  * The unprofiled variants are those of its preferred_linkage
#    (get_output_styles_for_linkage):
#
#      "any"     static, static_pic, shared
#      "static"  static, static_pic
#      "shared"  static_pic, shared
#
#  * The profiled variants are always static and static_pic, whatever its
#    preferred_linkage (prof_link_styles).
#
# What it offers is described by these providers:
#
#  * HaskellLinkInfo: the package of each variant, with those of its
#    dependencies, by link style: `info` for the unprofiled variants and
#    `prof_info` for the profiled ones. This is what a compile against the
#    library uses.
#
#  * MergedLinkInfo: how to link the library and its dependencies, for each
#    link strategy, by the get_lib_output_style table. This is what an
#    unprofiled link uses, and what any non-Haskell target that depends on the
#    library uses (a cxx_binary, say).
#
#  * HaskellProfLinkInfo: the same for a profiled link, made as if the
#    library's preferred_linkage were "static", so that it gives the profiled
#    archive of the same style for every link strategy (prof_merged_link_info).
#    It never gives a shared library: there is no profiled one, and an
#    unprofiled one linked into a profiled executable fails at runtime.
#
# A library can itself have enable_profiling = True. Then its "any" linkage
# becomes "static", and its MergedLinkInfo is that of its profiled variants,
# for a non-Haskell target to link. Such a target may still link it shared, so
# its MergedLinkInfo also offers the unprofiled shared library, where there is
# one (default_link_infos).
#
# What an executable asks for
# ---------------------------
#
# haskell_binary_impl takes its link_style from the attribute, or else from the
# C++ toolchain's default, and then adjusts it:
#
#  * A profiled executable asking for "shared" is linked "static".
#
#  * Where all code is position-independent (macOS: the toolchain's
#    pic_behavior is "always_enabled"), "static" is "static_pic".
#
# It then uses that link style twice, with the libraries it depends on:
#
#  1. To compile its own modules against them. It asks each for the package of
#     that link style (info[link_style], or prof_info[link_style] when
#     profiled), so each library must offer a variant of that style.
#
#  2. To link them. An unprofiled executable takes each library's
#     MergedLinkInfo for its link strategy, and so gets whatever variant the
#     get_lib_output_style table picks; a profiled one takes each library's
#     HaskellProfLinkInfo, and so gets the profiled archive of its style.
#
# Template Haskell
# ----------------
#
# GHC runs a Template Haskell splice in its own process, by loading the code
# the splice uses: the modules it uses of the libraries the module depends on,
# and of the module's own library. GHC loads code the way that it was itself
# linked (GHC calls this its "host way"). A GHC linked statically loads
# archives, and the ordinary .hi interfaces that go with them: any
# non-profiled static variant will do. A GHC linked dynamically
# (haskell_toolchain.dynamic_ghc, which is how GHC is normally installed)
# loads shared libraries, and the .dyn_hi interfaces that go with them. It
# can also load a non-profiled archive, with GHC's own runtime linker, but we
# don't rely on that. No GHC can load profiled code.
#
# For each variant of a library, its splice variant is the variant whose code
# GHC loads when a splice in a module compiled against that variant runs the
# library's code. With a dynamic GHC, every variant's splice variant is the
# shared variant. With a static GHC, it is the non-profiled variant of the
# same style, so a non-profiled variant is its own. The library builds a
# splice variant even if it doesn't otherwise offer it, and then nothing links
# it.
#
# A variant's package names its splice variant's interfaces in import-dirs,
# beside its own. With a dynamic GHC, the package's dynamic-library-dirs
# names the shared library's directory (see _register_library). GHC finds
# the shared library there because it has the same name as the variant's own
# library. A static GHC looks in library-dirs, which names only the variant's
# own library, so it doesn't find a profiled variant's splice variant (see
# Known gaps below).
#
# When the shared variant and the static style that executables use
# (consumed_static_link_style: "static", or "static_pic" on macOS) are both
# built, we compile the static variant with -dynamic-too (build_shared_too),
# and make the shared variant from the same compile: the shared library is
# linked from the .dyn_o files, and the .dyn_hi files are beside the .hi
# files, in the static variant's own directory.
#
# A splice can also use a module of the same library. GHC then loads that
# module's .dyn_o from the compile's own output directory, where it would be
# if, as with Cabal, both ways were compiled in one place. A profiled compile
# writes only profiled objects, so the .dyn_o of the unprofiled compile that
# made the shared library are copied in before it runs (`dynamic_from` on
# compile).
#
# Examples
# --------
#
# With a dynamic GHC:
#
#  * Libraries "shared", executables "shared": each module is compiled once,
#    the dynamic way. (Offering a static variant as well would make that one
#    compile with -dynamic-too, which costs about as much as two.)
#
#  * Libraries "any" or "static", executables "static": each module is
#    compiled once with -dynamic-too, for both the static and the shared
#    variant. A "static" library's shared variant is only for splices.
#
#  * Either of those, with executables that have enable_profiling = True: the
#    executables compile against their libraries' profiled packages and link
#    their profiled archives, whatever their link_style. The libraries'
#    profiled variants are compiled as well, and registered with their shared
#    variants, which are built already.
#
# Known gaps
# ----------
#
#  * An unprofiled executable whose link_style is "static" fails analysis when
#    a library it depends on doesn't offer static (its preferred_linkage is
#    "shared"): there is no package of that style to compile against. One
#    whose link_style is "static_pic" compiles against the libraries'
#    static_pic packages, but still links their shared libraries.
#
#  * With a static GHC, a profiled module can't use a library's code in a
#    splice, unless it is compiled with -fexternal-interpreter. GHC's
#    internal interpreter looks for the library in the profiled package's
#    library-dirs, which names only the profiled archive, and it can't load
#    profiled code. Cabal puts both archives in one directory. Here a
#    library's package is shared by targets that may or may not use an
#    external interpreter, and the two want different archives under the
#    same name. This is from reading GHC's loader: the tests use a dynamic
#    GHC.
