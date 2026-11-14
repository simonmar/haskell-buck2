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
            dynamic_ghc = ctx.attrs.dynamic_ghc,
            per_module_deps = ctx.attrs.per_module_deps[RunInfo] if ctx.attrs.per_module_deps else None,
            per_module_compile = ctx.attrs.per_module_compile[RunInfo] if ctx.attrs.per_module_compile else None,
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
        # Whether the `compiler` above is itself dynamically linked.
        # We need to know this because it affects how Template Haskell
        # code needs to be compiled. It can be found by running `ghc
        # --info`: look for the "GHC Dynamic" value.
        "dynamic_ghc": attrs.bool(default = True),
        # The tools of the per-module compiles, if the prelude's can't be
        # used (see per_module_deps in prelude/haskell/toolchain.bzl).
        "per_module_deps": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
        "per_module_compile": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
    },
    is_toolchain_rule = True,
)
