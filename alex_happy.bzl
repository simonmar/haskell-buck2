# Rules for running alex and happy.
#
# Unlike hsc2hs, alex/happy don't ship with GHC - they're separate Hackage
# packages. buck2/gen-haskell-prebuilt.py asks Cabal where it put them
# (`cabal list-bin alex`/`happy`) and freezes the answer in
# third-party/haskell/tools.bzl, the same "Cabal identifies/builds it,
# buck2 just references the frozen result" approach third-party/haskell/BUCK
# uses for library packages. Re-run that script to pick up a version bump.

load("@third-party-haskell//:tools.bzl", "ALEX", "ALEX_DATA", "ALEX_DATA_ENV", "ALEX_TARGET", "HAPPY", "HAPPY_DATA", "HAPPY_DATA_ENV", "HAPPY_TARGET")

# Either `tool`, a path to an executable that is installed, or `tool_dep`, an
# executable that buck2 builds (when `cabal buck2 --source-deps` builds the
# dependencies); then `data_dep` is where the tool finds its templates, which
# it is told by an environment variable, `data_env`.
def _run_tool_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)
    tool = ctx.attrs.tool_dep[RunInfo] if ctx.attrs.tool_dep else ctx.attrs.tool
    env = {}
    if ctx.attrs.data_dep:
        env[ctx.attrs.data_env] = ctx.attrs.data_dep[DefaultInfo].default_outputs[0]
    ctx.actions.run(
        cmd_args(tool, ctx.attrs.src, "-o", out.as_output()),
        category = ctx.attrs.category,
        env = env,
    )
    return [DefaultInfo(default_output = out)]

_run_tool = rule(
    impl = _run_tool_impl,
    attrs = {
        "category": attrs.string(),
        "data_dep": attrs.option(attrs.dep(), default = None),
        "data_env": attrs.option(attrs.string(), default = None),
        "out": attrs.string(),
        "src": attrs.source(),
        "tool": attrs.string(),
        "tool_dep": attrs.option(attrs.exec_dep(providers = [RunInfo]), default = None),
    },
)

def alex(name, src, out):
    _run_tool(name = name, src = src, out = out, tool = ALEX, tool_dep = ALEX_TARGET, data_dep = ALEX_DATA, data_env = ALEX_DATA_ENV, category = "alex")

def happy(name, src, out):
    _run_tool(name = name, src = src, out = out, tool = HAPPY, tool_dep = HAPPY_TARGET, data_dep = HAPPY_DATA, data_env = HAPPY_DATA_ENV, category = "happy")
