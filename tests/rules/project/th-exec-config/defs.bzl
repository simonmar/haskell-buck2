def _run_tool_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.run(cmd_args(ctx.attrs.tool[RunInfo], out.as_output()), category = "run_tool")
    return [DefaultInfo(default_output = out)]

# Runs a build tool (in the execution platform's configuration), which writes
# the given file, without a shell.
run_tool = rule(
    impl = _run_tool_impl,
    attrs = {
        "out": attrs.string(),
        "tool": attrs.exec_dep(providers = [RunInfo]),
    },
)
