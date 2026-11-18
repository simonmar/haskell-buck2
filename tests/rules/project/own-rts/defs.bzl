load("@prelude//haskell:library_info.bzl", "HaskellLibraryInfo", "HaskellLibraryInfoTSet", "HaskellLibraryProvider")
load("@prelude//haskell:link_info.bzl", "HaskellLinkInfo")

def _as_rts(info):
    return HaskellLibraryInfo(
        name = info.name,
        db = info.db,
        id = info.id,
        import_dirs = info.import_dirs,
        stub_dirs = info.stub_dirs,
        libs = info.libs,
        version = info.version,
        is_prebuilt = info.is_prebuilt,
        profiling_enabled = info.profiling_enabled,
        is_rts = True,
    )

def _own_rts_impl(ctx: AnalysisContext) -> list[Provider]:
    rts = ctx.attrs.rts
    lib = rts[HaskellLibraryProvider]
    link = rts[HaskellLinkInfo]

    def tsets(infos):
        return {
            style: ctx.actions.tset(HaskellLibraryInfoTSet, value = _as_rts(tset.value))
            for style, tset in infos.items()
        }

    others = [p for p in rts.providers if not isinstance(p, HaskellLibraryProvider) and not isinstance(p, HaskellLinkInfo)]
    return others + [
        HaskellLibraryProvider(
            lib = {style: _as_rts(info) for style, info in lib.lib.items()},
            prof_lib = {style: _as_rts(info) for style, info in lib.prof_lib.items()},
        ),
        HaskellLinkInfo(info = tsets(link.info), prof_info = tsets(link.prof_info)),
    ]

# The package of an RTS (`rts`, a prebuilt library), marked as the RTS that
# the project provides (HaskellLibraryInfo.is_rts). It stands in for an RTS
# that a project builds itself, as GHC's own build does. Its other providers
# are the prebuilt library's.
own_rts = rule(
    impl = _own_rts_impl,
    attrs = {"rts": attrs.dep()},
)
