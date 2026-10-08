# Compiling Cmm (the `cmm-sources` of a Cabal component) into a library that
# Haskell libraries can depend on.
#
# GHC compiles .cmm files itself, so this runs it on each of them, once for
# each kind of object that a link needs: ordinary ones for static linking and
# position-independent ones for shared libraries (dynamic ones, in GHC's
# terms). The objects are archived and the archives wrapped in a
# prebuilt_cxx_library(), through which they are linked into whatever depends
# on it.

load("@prelude//cxx:archive.bzl", "make_archive")
load("@prelude//cxx:cxx_context.bzl", "get_cxx_toolchain_info")
load("@prelude//decls/toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo")
load("@third-party-haskell//:tools.bzl", "CC_FINGERPRINT", "GHC_FINGERPRINT")

def _cmm_objects_impl(ctx: AnalysisContext) -> list[Provider]:
    ghc = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    sub_targets = {}
    for variant, flags in (("static", []), ("pic", ["-dynamic", "-fPIC"])):
        objects = []
        for src in ctx.attrs.srcs:
            obj = ctx.actions.declare_output(variant, src.short_path + ".o")
            cmd = cmd_args(
                ghc.compiler,
                ghc.compiler_flags,
                ["-prof"] if ctx.attrs.profiling else [],
                flags,
                ctx.attrs.flags,
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
        archive = make_archive(ctx, "lib" + ctx.label.name + "-" + variant + ".a", objects)
        sub_targets[variant] = [DefaultInfo(default_output = archive.artifact)]
    return [DefaultInfo(sub_targets = sub_targets)]

_cmm_objects = rule(
    impl = _cmm_objects_impl,
    attrs = {
        "flags": attrs.list(attrs.arg(), default = []),
        "profiling": attrs.bool(default = False),
        "srcs": attrs.list(attrs.source()),
        "_cxx_toolchain": toolchains_common.cxx(),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)

_PROFILING = select({
    "root//buck2/constraints:prof": True,
    "DEFAULT": False,
})

def cmm_library(name, srcs, flags = [], **kwargs):
    """A library of Cmm code, to depend on from haskell_library().

    Args:
      name: the target name.
      srcs: the .cmm files.
      flags: options for GHC when it compiles them.
    """
    _cmm_objects(name = name + "-objects", srcs = srcs, flags = flags, profiling = _PROFILING)

    # The Cmm code is only reached from Haskell code, by symbol, so every object has to be kept.
    native.prebuilt_cxx_library(
        name = name,
        static_lib = ":" + name + "-objects[static]",
        static_pic_lib = ":" + name + "-objects[pic]",
        link_whole = True,
        **kwargs
    )
