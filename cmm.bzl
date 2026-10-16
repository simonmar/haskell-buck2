# Compiling Cmm (the `cmm-sources` of a Cabal component) into a library that
# Haskell libraries can depend on.
#
# GHC compiles .cmm files itself, so this runs it on each of them, once for
# each kind of object that a link needs: ordinary ones for static linking and
# position-independent ones for shared libraries (dynamic ones, in GHC's
# terms). The library is the objects themselves, to be linked (all of them)
# into the library of the component's Haskell code, as in Cabal: see
# `internal_deps` of haskell_library().

load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//cxx:preprocessor.bzl", "cxx_inherited_preprocessor_infos", "cxx_merge_cpreprocessors")
load("@prelude//haskell:library_info.bzl", "HaskellLibraryInfoTSet")
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo")
load(
    "@prelude//linking:link_info.bzl",
    "LibOutputStyle",
    "LinkInfo",
    "LinkInfos",
    "LinkStyle",
    "ObjectsLinkable",
    "create_merged_link_info",
)
load("@prelude//linking:types.bzl", "Linkage")
load("@prelude//linking:linkable_graph.bzl", "create_linkable_graph", "create_linkable_graph_node", "create_linkable_node")
load("@prelude//linking:shared_libraries.bzl", "EMPTY_SHARED_LIBRARY_INFO")
load("@prelude//decls/toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")
load("@third-party-haskell//:tools.bzl", "CC_FINGERPRINT", "GHC_FINGERPRINT")

def _package_db_args(ctx: AnalysisContext, link_style: LinkStyle) -> cmd_args:
    # The package databases of the Haskell libraries among the deps, and
    # theirs: GHC finds the platform constants in the rts package.
    # A library built only some ways (shared only, say) has the packages of
    # those, which have the same rts in them.
    children = []
    for dep in ctx.attrs.deps:
        info = dep.get(HaskellLinkInfo)
        if info:
            infos = info.prof_info if ctx.attrs.profiling else info.info
            children.append(infos[link_style] if link_style in infos else infos.values()[0])
    libs = list(ctx.actions.tset(HaskellLibraryInfoTSet, children = children).traverse())
    dbs = {lib.db: None for lib in libs}
    return cmd_args(
        [cmd_args("-package-db", db) for db in dbs],
        hidden = [lib.include_dirs for lib in libs],
    )

def _cmm_library_impl(ctx: AnalysisContext) -> list[Provider]:
    ghc = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    linker_type = get_cxx_toolchain_info(ctx).linker_info.type
    pre = cxx_merge_cpreprocessors(ctx.actions, [], cxx_inherited_preprocessor_infos(ctx.attrs.deps))
    pre_args = cmd_args(pre.set.project_as_args("args"), format = "-optCmmP={}")
    link_infos = {}
    for output_style, link_style, flags in (
        (LibOutputStyle("archive"), LinkStyle("static"), []),
        (LibOutputStyle("pic_archive"), LinkStyle("shared"), ["-dynamic", "-fPIC"]),
    ):
        variant = link_style.value
        package_db_args = _package_db_args(ctx, link_style)
        objects = []
        for entry in ctx.attrs.srcs:
            src, src_flags = entry if type(entry) == type(()) else (entry, [])
            obj = ctx.actions.declare_output(variant, src.short_path + ".o")
            cmd = cmd_args(
                ghc.compiler,
                ghc.compiler_flags,
                ["-prof"] if ctx.attrs.profiling else [],
                flags,
                ctx.attrs.flags,
                package_db_args,
                pre_args,
                src_flags,
                "-c",
                src,
                "-o",
                obj.as_output(),
            )

            # The fingerprints are not read: they make the GHC installation and
            # the C toolchain part of the action's cache key (see toolchains/BUCK).
            ctx.actions.run(
                cmd,
                category = "ghc_cmm",
                identifier = variant + "/" + src.short_path,
                env = {"CABAL_BUCK2_GHC": GHC_FINGERPRINT, "CABAL_BUCK2_CC": CC_FINGERPRINT},
            )
            objects.append(obj)

        # The Cmm code is only reached from Haskell code, by symbol, so every
        # object has to be kept.
        link_infos[output_style] = LinkInfos(default = LinkInfo(
            name = ctx.label.name,
            linkables = [ObjectsLinkable(objects = objects, linker_type = linker_type, link_whole = True)],
        ))

    return [
        DefaultInfo(),
        create_merged_link_info(ctx, get_cxx_toolchain_info(ctx).pic_behavior, link_infos, preferred_linkage = Linkage("static")),
        EMPTY_SHARED_LIBRARY_INFO,
        create_linkable_graph(
            ctx,
            node = create_linkable_graph_node(
                ctx,
                linkable_node = create_linkable_node(
                    ctx = ctx,
                    default_soname = None,
                    preferred_linkage = Linkage("static"),
                    link_infos = link_infos,
                ),
            ),
        ),
    ]

_cmm_library = rule(
    impl = _cmm_library_impl,
    attrs = {
        "deps": attrs.list(attrs.dep(), default = []),
        "flags": attrs.list(attrs.arg(), default = []),
        "labels": attrs.list(attrs.string(), default = []),
        "profiling": attrs.bool(default = False),
        "srcs": attrs.list(attrs.one_of(attrs.source(), attrs.tuple(attrs.source(), attrs.list(attrs.arg())))),
        "_cxx_toolchain": toolchains_common.cxx(),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)

_PROFILING = select({
    "root//buck2/constraints:prof": True,
    "DEFAULT": False,
})

def cmm_library(name, srcs, flags = [], deps = [], **kwargs):
    """A library of Cmm code, to depend on from haskell_library() (as one
    of its `internal_deps`).

    Args:
      name: the target name.
      srcs: the .cmm files, each alone or paired with flags of its own.
      flags: options for GHC when it compiles them.
      deps: the libraries whose headers they include: C libraries, and the
          Haskell libraries of the packages the code depends on.
    """
    _cmm_library(name = name, srcs = srcs, flags = flags, deps = deps, profiling = _PROFILING, **kwargs)
