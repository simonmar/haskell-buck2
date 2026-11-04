# A tiny wrapper rule that takes an existing execution platform (`base`)
# and produces a new one identical to it except for extra constraint
# values merged into its configuration. Used to derive `:exec-opt` from
# `prelude//platforms:default` below, without having to reimplement that
# rule's own executor_config (remote-exec settings, path separators,
# etc.) - we just read it back off `base` and reuse it verbatim, so this
# stays correct even if that vendored rule's own executor_config logic
# ever changes.
load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")
load("@prelude//haskell:per_module_worker.bzl", "has_per_module_worker")

# The execution platform's executor config. Without a cache or persistent
# workers, it is the base platform's config. With either, every action runs
# locally, and nothing runs remotely. With `cache`, the actions' results are
# looked up in, and uploaded to, a remote action cache (the one that
# `[buck2_re_client]` in the buckconfig points to). With
# `persistent_workers`, an action that names a persistent worker may run in
# that worker.
def _executor_config(base: ExecutionPlatformInfo, cache: bool, persistent_workers: bool):
    if not cache and not persistent_workers:
        return base.executor_config
    return CommandExecutorConfig(
        local_enabled = True,
        remote_enabled = False,
        remote_cache_enabled = cache,
        allow_cache_uploads = cache,
        use_persistent_workers = persistent_workers,
    )

def _execution_platform_with_constraints_impl(ctx: AnalysisContext) -> list[Provider]:
    base = ctx.attrs.base[ExecutionPlatformInfo]
    constraints = dict(base.configuration.constraints)
    for constraint_value in ctx.attrs.constraint_values:
        info = constraint_value[ConstraintValueInfo]
        constraints[info.setting.label] = info

    cfg = ConfigurationInfo(constraints = constraints, values = {})
    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = _executor_config(base, ctx.attrs.cache, ctx.attrs.persistent_workers),
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(
            platforms = [platform],
            exec_marker_constraint = get_exec_platform_marker(),
        ),
    ]

execution_platform_with_constraints = rule(
    impl = _execution_platform_with_constraints_impl,
    attrs = {
        "base": attrs.dep(providers = [ExecutionPlatformInfo]),
        "constraint_values": attrs.list(attrs.dep(providers = [ConstraintValueInfo]), default = []),
        # `[cabal_buck2] cache = true` in the buckconfig (.buckconfig.local,
        # where `cabal buck2 --cache=ADDRESS` writes it together with the
        # remote cache's address).
        "cache": attrs.bool(default = read_root_config("cabal_buck2", "cache", "false") == "true"),
        # Whether actions may run in persistent workers. This is on when the
        # buckconfig sets up a worker for the per-module compiles (see
        # prelude/haskell/per_module_worker.bzl).
        "persistent_workers": attrs.bool(default = has_per_module_worker()),
    },
)

# `.buckconfig`'s `[build] execution_platforms` takes exactly one target
# pattern, not a list - buck2 gets multiple candidate execution
# platforms from that *one* target's own `ExecutionPlatformRegistrationInfo.
# platforms` list instead (confirmed directly: pointing it at two
# space-separated targets fails to parse as a target pattern at all).
# This aggregates any number of platform deps into one such list, in the
# order given - buck2 picks the first one in that order compatible with
# a given target's `exec_compatible_with`.
def _execution_platforms_impl(ctx: AnalysisContext) -> list[Provider]:
    platforms = [p[ExecutionPlatformInfo] for p in ctx.attrs.platforms]
    return [
        DefaultInfo(),
        ExecutionPlatformRegistrationInfo(
            platforms = platforms,
            exec_marker_constraint = get_exec_platform_marker(),
        ),
    ]

execution_platforms = rule(
    impl = _execution_platforms_impl,
    attrs = {
        "platforms": attrs.list(attrs.dep(providers = [ExecutionPlatformInfo])),
    },
)
