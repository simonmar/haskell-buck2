# A rule for the persistent worker that compiles the modules of per-module
# targets, when the project builds the worker from source
# (`per_module_worker = local`; see prelude/haskell/per_module_worker.bzl).
# buck2 starts one worker process for each WorkerInfo that actions name, so
# all the per-module targets name the same target of this rule, and so
# share one worker.
#
# For a worker program that the toolchain is given, the toolchain makes the
# WorkerInfo itself (see per_module_worker_info). It can't do that for a
# worker that is built from source, because the worker is built with the
# toolchain (see Note [The persistent worker] in
# prelude/haskell/compile_per_module.bzl).

load("@prelude//decls:toolchains_common.bzl", "toolchains_common")
load("@prelude//haskell:toolchain.bzl", "HaskellToolchainInfo", "per_module_worker_info")

def _haskell_per_module_worker_impl(ctx: AnalysisContext) -> list[Provider]:
    worker = ctx.attrs.worker[RunInfo]
    toolchain = ctx.attrs._haskell_toolchain[HaskellToolchainInfo]
    return [
        DefaultInfo(),
        per_module_worker_info(worker, toolchain.compile_env, toolchain.per_module_worker_rts_options, toolchain.per_module_worker_sessions, toolchain.per_module_worker_session_mode, toolchain.per_module_worker_build_tools_dir),
    ]

haskell_per_module_worker = rule(
    impl = _haskell_per_module_worker_impl,
    attrs = {
        # The worker program (tools/buck2-ghc-worker's executable).
        "worker": attrs.exec_dep(providers = [RunInfo]),
        "_haskell_toolchain": toolchains_common.haskell(),
    },
)
