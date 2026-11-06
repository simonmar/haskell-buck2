load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo")

def _tool(tool):
    if isinstance(tool, Dependency):
        return tool[RunInfo]
    return tool

def _haskell_toolchain_impl(ctx):
    compiler = _tool(ctx.attrs.compiler)
    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = compiler,
            packager = _tool(ctx.attrs.packager),
            linker = compiler,
            haddock = _tool(ctx.attrs.haddock),
            hsc2hs = _tool(ctx.attrs.hsc2hs),
            compiler_flags = ctx.attrs.compiler_flags,
            linker_flags = ctx.attrs.linker_flags,
            compile_env = ctx.attrs.compile_env,
            link_env = ctx.attrs.link_env,
            allow_cache_upload = ctx.attrs.allow_cache_upload,
            allow_dep_file_cache_upload = ctx.attrs.allow_dep_file_cache_upload,
            dynamic_ghc = ctx.attrs.dynamic_ghc,
        ),
        HaskellPlatformInfo(name = host_info().arch),
    ]

# A tool is either the name of a program on $PATH, or a target that builds it.
def _tool_attr(default):
    return attrs.one_of(attrs.exec_dep(providers = [RunInfo]), attrs.string(), default = default)

haskell_toolchain = rule(
    impl = _haskell_toolchain_impl,
    attrs = {
        "compiler": _tool_attr("ghc"),
        "packager": _tool_attr("ghc-pkg"),
        "haddock": _tool_attr("haddock"),
        "hsc2hs": _tool_attr("hsc2hs"),
        "compiler_flags": attrs.list(attrs.string(), default = []),
        "linker_flags": attrs.list(attrs.string(), default = []),
        "compile_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "link_env": attrs.dict(attrs.string(), attrs.string(), default = {}),
        # See HaskellToolchainInfo.
        "allow_cache_upload": attrs.bool(default = False),
        "allow_dep_file_cache_upload": attrs.bool(default = False),
        # Whether the `compiler` above is itself dynamically linked -
        # see buck2/gen-haskell-prebuilt.py's own `_ghc_dynamic()` for
        # how this gets discovered (not assumed), and buck2/prelude/
        # haskell/haskell.bzl's own uses of `haskell_toolchain.
        # dynamic_ghc` for what it actually gates.
        "dynamic_ghc": attrs.bool(default = True),
    },
    is_toolchain_rule = True,
)
