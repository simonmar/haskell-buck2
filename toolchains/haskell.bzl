load("@prelude//haskell:toolchain.bzl", "HaskellPlatformInfo", "HaskellToolchainInfo", "per_module_worker_info")
load(":per_module_worker.bzl", "per_module_worker_build_tools", "per_module_worker_rts_options", "per_module_worker_session_mode", "per_module_worker_sessions")

def _tool(tool):
    if isinstance(tool, Dependency):
        return tool[RunInfo]
    return tool

def _haskell_toolchain_impl(ctx):
    compiler = _tool(ctx.attrs.compiler)
    worker = _tool(ctx.attrs.per_module_worker) if ctx.attrs.per_module_worker != None else None
    sessions = int(ctx.attrs.per_module_worker_sessions) if ctx.attrs.per_module_worker_sessions else None
    session_mode = ctx.attrs.per_module_worker_session_mode or None
    tools = ctx.attrs.per_module_worker_build_tools
    tools_dir = ctx.actions.symlinked_dir(
        "per-module-worker-build-tools",
        {t[DefaultInfo].default_outputs[0].basename: t[DefaultInfo].default_outputs[0] for t in tools},
        has_content_based_path = False,
    ) if tools else None
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
            # Made once, here, so that every target gets the same worker.
            per_module_shared_worker = per_module_worker_info(worker, ctx.attrs.compile_env, ctx.attrs.per_module_worker_rts_options, sessions, session_mode, tools_dir) if worker != None else None,
            per_module_worker_rts_options = ctx.attrs.per_module_worker_rts_options,
            per_module_worker_sessions = sessions,
            per_module_worker_session_mode = session_mode,
            per_module_worker_build_tools = [t.label.raw_target() for t in tools],
            per_module_worker_build_tools_dir = tools_dir,
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
        # Whether the `compiler` above is itself dynamically linked -
        # see buck2/gen-haskell-prebuilt.py's own `_ghc_dynamic()` for
        # how this gets discovered (not assumed), and buck2/prelude/
        # haskell/haskell.bzl's own uses of `haskell_toolchain.
        # dynamic_ghc` for what it actually gates.
        "dynamic_ghc": attrs.bool(default = True),
        # See HaskellToolchainInfo.
        "per_module_worker": attrs.option(attrs.one_of(attrs.exec_dep(providers = [RunInfo]), attrs.string()), default = None),
        "per_module_worker_rts_options": attrs.list(attrs.string(), default = per_module_worker_rts_options()),
        # Empty for the worker's default: `attrs.option` can't default to a value.
        "per_module_worker_sessions": attrs.string(default = per_module_worker_sessions()),
        "per_module_worker_session_mode": attrs.string(default = per_module_worker_session_mode()),
        "per_module_worker_build_tools": attrs.list(attrs.exec_dep(), default = per_module_worker_build_tools()),
    },
    is_toolchain_rule = True,
)
