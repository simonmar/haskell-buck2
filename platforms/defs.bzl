# A tiny wrapper rule that takes an existing execution platform (`base`)
# and produces a new one identical to it except for extra constraint
# values merged into its configuration. Used to derive `:exec-opt` from
# `prelude//platforms:default` below, without having to reimplement that
# rule's own executor_config (remote-exec settings, path separators,
# etc.) - we just read it back off `base` and reuse it verbatim, so this
# stays correct even if that vendored rule's own executor_config logic
# ever changes.
load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")

# Actions run locally, and their results are looked up in, and uploaded to, a
# remote action cache (the one `[buck2_re_client]` in .buckconfig points to).
# Nothing runs remotely.
def _cache_executor_config():
    return CommandExecutorConfig(
        local_enabled = True,
        remote_enabled = False,
        remote_cache_enabled = True,
        allow_cache_uploads = True,
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
        executor_config = _cache_executor_config() if ctx.attrs.cache else base.executor_config,
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
        # `[cabal_buck2] cache = true` in .buckconfig, which `cabal buck2
        # --cache=ADDRESS` writes together with the remote cache's address.
        "cache": attrs.bool(default = read_root_config("cabal_buck2", "cache", "false") == "true"),
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
